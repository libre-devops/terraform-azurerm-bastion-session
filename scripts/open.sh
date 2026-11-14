#!/usr/bin/env bash
# Open a bastion session. Run by the module's terraform_data.open, with the session's settings as
# JSON in BASTION_SESSION (the module's session_json output).
#
#   1. Sign-in. auth entra: grant login_role to the signed-in identity on each target (first, so the
#      grant has the bastion's creation time to apply). auth key: fetch each target's vaulted key to
#      keys/<target>, opening the vault's firewall only for the fetch.
#   2. Create the public IP and the bastion (native client tunnelling, IP connect when asked) in
#      bastion.subnet_id, or reuse a session bastion that a cancelled run left behind.
#   3. auth entra: issue a short-lived Entra ID OpenSSH certificate for the signed-in identity.
#   4. Write ssh_config: a Host block per target whose ProxyCommand is proxy.sh.
#   5. Wait up to ready_timeout for SSH to sign in on every target. That first connection starts the
#      target's tunnel, which every later connection reuses.
#
# On failure it runs close.sh to delete whatever it created, then fails the module's open step and
# the apply. It has to clean up itself: a failed open step is tainted, and Terraform does not run
# the destroy-time close for a tainted resource. (If close.sh cannot finish, session.json stays, so
# the always() step after the apply tries again.)
set -euo pipefail

SCRIPTS_DIR="$(cd "${SCRIPTS_DIR:-$(dirname "$0")}" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPTS_DIR/lib.sh"

need az jq python3 ssh ssh-keygen setsid flock ps

name="$(session_get .name)"
work_dir="$(session_get .work_dir)"
auth="$(session_get .auth)"
bastion="$(session_get .bastion.name)"
rg="$(session_get .bastion.resource_group_name)"
location="$(session_get .bastion.location)"
subnet_id="$(session_get .bastion.subnet_id)"
pip="$(session_get .bastion.public_ip_name)"
sku="$(session_get .bastion.sku)"
scale_units="$(session_get .bastion.scale_units)"
ip_connect="$(session_get .bastion.ip_connect_enabled)"
ready_timeout="$(session_get .ready_timeout)"
mapfile -t targets < <(session_get '.targets | keys[]')
mapfile -t sub < <(subscription_args)
mapfile -t tags < <(jq -r --arg tag "$SESSION_TAG" --arg name "$name" \
  '(.bastion.tags // {}) + {($tag): $name} | to_entries[] | "\(.key)=\(.value)"' <<<"$BASTION_SESSION")

# The ProxyCommand line is run by a shell and %-expanded by ssh, so keep both paths plain.
for path in "$work_dir" "$SCRIPTS_DIR"; do
  [[ "$path" != *[\'%\"]* ]] || die "Paths with quotes or % cannot go in a ProxyCommand: $path"
done

# From here on, a failure closes what was created before it is handed back.
opened=false
on_exit() {
  local rc=$?
  if ((rc != 0)) && [[ "$opened" == "false" ]]; then
    log "Opening failed: closing what this session created."
    "$SCRIPTS_DIR/close.sh" || log "Could not close everything: run $SCRIPTS_DIR/close.sh $work_dir"
  fi
  exit "$rc"
}
trap on_exit EXIT

ensure_extensions bastion
[[ "$auth" == "entra" ]] && ensure_extensions ssh

# A fresh working directory: nothing from an earlier session (tunnels, keys, host keys) carries over.
stop_tunnels "$work_dir" "$bastion" "$rg"
remove_session_files "$work_dir"
mkdir -p "$work_dir"
chmod 700 "$work_dir"
mkdir -m 700 "$work_dir/keys" "$work_dir/tunnels"
(umask 077 && printf '%s\n' "$BASTION_SESSION" >"$work_dir/session.json")
refresh_github_oidc_login "$work_dir" force

# --- 1. Sign-in ------------------------------------------------------------------------------------

if [[ "$auth" == "entra" ]]; then
  if [[ "$(session_get .login_role.enabled)" == "true" ]]; then
    role="$(session_get .login_role.role_name)"
    read -r oid principal_type < <(signed_in_principal)
    for target in "${targets[@]}"; do
      id="$(session_opt ".targets[\"$target\"].id")"
      if [[ -n "$id" ]]; then
        grant_login_role "$id" "$oid" "$principal_type" "$role" "$name"
      else
        log "$target is given by IP address, so no role is granted on it: the identity needs a standing sign-in role there."
      fi
    done
  fi
else
  # Several targets can share one secret; fetch each secret once.
  declare -A fetched=()
  for target in "${targets[@]}"; do
    secret_id="$(session_get ".targets[\"$target\"].ssh_key_secret_id")"
    if [[ -n "${fetched[$secret_id]:-}" ]]; then
      install -m 600 "${fetched[$secret_id]}" "$work_dir/keys/$target"
    else
      fetch_key "$secret_id" "$work_dir/keys/$target" "${sub[@]}"
      fetched[$secret_id]="$work_dir/keys/$target"
    fi
    log "Fetched the SSH key for $target."
  done
fi

# --- 2. The bastion --------------------------------------------------------------------------------

# Whether a bastion's JSON already has the settings the session asks for.
bastion_matches() {
  jq -e --arg sku "$sku" --argjson ip "$ip_connect" --argjson units "$scale_units" \
    '.sku.name == $sku and .enableTunneling == true and (.enableIpConnect // false) == $ip and .scaleUnits == $units' \
    <<<"$1" >/dev/null
}

# Wait for a bastion that is being deleted to go.
wait_bastion_gone() {
  local deadline=$((SECONDS + 1800))
  while [[ -n "$(az_show network bastion show --name "$bastion" --resource-group "$rg" "${sub[@]}")" ]]; do
    ((SECONDS < deadline)) || die "$bastion was still being deleted after 30 minutes."
    sleep 15
  done
}

reuse=false
bastion_json="$(az_show network bastion show --name "$bastion" --resource-group "$rg" "${sub[@]}")"
if [[ -n "$bastion_json" ]]; then
  [[ "$(session_owner "$bastion_json")" == "$name" ]] ||
    die "A bastion called $bastion already exists in $rg and is not this session's (no $SESSION_TAG=$name tag): give the session another bastion.name, or delete that bastion."
  state="$(jq -r .provisioningState <<<"$bastion_json")"
  if [[ "$state" == "Succeeded" ]] && bastion_matches "$bastion_json"; then
    log "Reusing $bastion, which an earlier session left open."
    reuse=true
  elif [[ "$state" == "Deleting" ]]; then
    log "Waiting for $bastion, left by an earlier session, to finish deleting."
    wait_bastion_gone
  else
    log "Deleting $bastion, left by an earlier session ($state, or with other settings)."
    az network bastion delete --name "$bastion" --resource-group "$rg" "${sub[@]}" --yes --only-show-errors
    wait_bastion_gone
  fi
fi

if [[ "$reuse" == "false" ]]; then
  pip_json="$(az_show network public-ip show --name "$pip" --resource-group "$rg" "${sub[@]}")"
  if [[ -n "$pip_json" ]]; then
    [[ "$(session_owner "$pip_json")" == "$name" ]] ||
      die "A public IP called $pip already exists in $rg and is not this session's (no $SESSION_TAG=$name tag): set bastion.public_ip_name to another name, or delete it."
    log "Reusing the public IP $pip, which an earlier session left."
  else
    log "Creating the public IP $pip."
    az network public-ip create --name "$pip" --resource-group "$rg" "${sub[@]}" --location "$location" \
      --sku Standard --allocation-method Static --version IPv4 --tags "${tags[@]}" \
      --only-show-errors --output none
  fi

  log "Creating $sku bastion $bastion with $scale_units scale units (this usually takes 5 to 10 minutes)."
  az network bastion create --name "$bastion" --resource-group "$rg" "${sub[@]}" --location "$location" \
    --vnet-name "${subnet_id%/subnets/*}" --public-ip-address "$pip" --sku "$sku" \
    --scale-units "$scale_units" --enable-tunneling true --enable-ip-connect "$ip_connect" \
    --tags "${tags[@]}" --only-show-errors --output none
  log "$bastion is up."
fi

# --- 3. The Entra ID certificate -------------------------------------------------------------------

if [[ "$auth" == "entra" ]]; then
  # The bastion took minutes, so in GitHub Actions the sign-in needs a fresh GitHub ID token for the
  # certificate's new access token.
  refresh_github_oidc_login "$work_dir" force
  ssh-keygen -q -t rsa -b 4096 -N '' -C "bastion-session-$name" -f "$work_dir/keys/id_rsa"
  issue_certificate "$work_dir/keys/id_rsa"
  entra_user="$(certificate_user "$work_dir/keys/id_rsa-cert.pub")"
  [[ -n "$entra_user" ]] || die "Could not read the user from the Entra ID certificate."
  log "Issued an Entra ID SSH certificate for $entra_user."
fi

# --- 4. ssh_config ---------------------------------------------------------------------------------

{
  echo "# Written by the bastion-session module for session $name; removed when it closes."
  echo "# Every Host below goes through bastion $bastion: ssh -F $work_dir/ssh_config <target>"
  for target in "${targets[@]}"; do
    echo
    echo "Host $target"
    echo "  HostKeyAlias $target"
    echo "  ProxyCommand bash '$SCRIPTS_DIR/proxy.sh' '$work_dir' '$target'"
    if [[ "$auth" == "entra" ]]; then
      echo "  User $entra_user"
      echo "  IdentityFile $work_dir/keys/id_rsa"
      echo "  CertificateFile $work_dir/keys/id_rsa-cert.pub"
    else
      echo "  User $(session_get ".targets[\"$target\"].user")"
      echo "  IdentityFile $work_dir/keys/$target"
    fi
    echo "  IdentitiesOnly yes"
  done
  echo
  echo "Host *"
  echo "  StrictHostKeyChecking accept-new"
  echo "  UserKnownHostsFile $work_dir/known_hosts"
  echo "  ServerAliveInterval 30"
  echo "  ServerAliveCountMax 4"
} >"$work_dir/ssh_config"
chmod 600 "$work_dir/ssh_config"

# --- 5. Wait for SSH -------------------------------------------------------------------------------

# Sign in once on one target, retrying until ready_timeout: the VM may still be booting, and a new
# sign-in role takes a while to apply.
wait_ready() {
  local target="$1" deadline=$((SECONDS + ready_timeout)) out
  while :; do
    if out="$(ssh -F "$work_dir/ssh_config" -n -o BatchMode=yes -o ConnectTimeout=120 "$target" true 2>&1)"; then
      log "SSH signs in on $target."
      return 0
    fi
    if ((SECONDS >= deadline)); then
      log "SSH did not sign in on $target within ${ready_timeout}s. Last error: $out"
      [[ -f "$work_dir/tunnels/$target.log" ]] && sed 's/^/  tunnel: /' "$work_dir/tunnels/$target.log" >&2
      return 1
    fi
    log "Waiting for SSH on $target: ${out##*$'\n'}"
    sleep 10
  done
}

log "Waiting up to ${ready_timeout}s for SSH on ${#targets[@]} target(s)."
pids=()
for target in "${targets[@]}"; do
  wait_ready "$target" &
  pids+=("$!")
done
failed=0
for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
((failed == 0)) || die "The session did not come up on every target."

opened=true
log "Session $name is open: ssh -F $work_dir/ssh_config <target>"
