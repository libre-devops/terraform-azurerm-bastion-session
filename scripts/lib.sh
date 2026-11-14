# shellcheck shell=bash
# Helpers shared by open.sh, proxy.sh and close.sh. Source it; do not run it.
#
# Several began in azure-orchestration/scripts/bastion-ansible.sh (e641357), where they were proven
# on a live run.

# Every bastion and public IP a session creates carries this tag, with the session's name as its
# value, and every role assignment it grants carries "<tag>=<name>" as its description. close.sh
# (and any sweeper) deletes only what carries them, so it never touches anything else.
SESSION_TAG="BastionSession"

log() { printf '[bastion-session] %s\n' "$*" >&2; }

die() {
  log "$*"
  exit 1
}

# The session's settings, as JSON in BASTION_SESSION (set by the module's provisioners, or by hand
# from the module's session_json output). session_get fails when the value is missing or null;
# session_opt prints nothing instead. false prints as false for both (jq -e alone would fail on it).
session_get() {
  jq -er "($1) | select(. != null) | tostring" <<<"${BASTION_SESSION:?BASTION_SESSION is not set}"
}

session_opt() {
  jq -r "($1) | select(. != null) | tostring" <<<"${BASTION_SESSION:?BASTION_SESSION is not set}"
}

need() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd is needed on the machine running Terraform."
  done
}

# Add Azure CLI extensions that are missing.
ensure_extensions() {
  local ext
  for ext in "$@"; do
    az extension show --name "$ext" --only-show-errors >/dev/null 2>&1 ||
      az extension add --name "$ext" --only-show-errors >/dev/null
  done
}

# Run an az show command and print the resource as JSON, or nothing when it does not exist. Any
# other failure (signed out, no access) is an error, so a missing permission is never mistaken for a
# missing resource.
az_show() {
  local err out rc=0
  err="$(mktemp)"
  out="$(az "$@" --output json --only-show-errors 2>"$err")" || rc=$?
  if ((rc != 0)); then
    if grep -qiE 'ResourceNotFound|NotFound|was not found|could not be found' "$err"; then
      out=""
      rc=0
    else
      cat "$err" >&2
    fi
  fi
  rm -f "$err"
  [[ -n "$out" ]] && printf '%s\n' "$out"
  return "$rc"
}

# The session tag on a resource's JSON, or nothing.
session_owner() {
  jq -r --arg tag "$SESSION_TAG" '.tags[$tag] // empty' <<<"$1"
}

# A tunnel is ready once its local port is listening. The CLI's own "Tunnel is ready" line is no use
# here: az runs Python in isolated mode, so PYTHONUNBUFFERED is ignored and the line sits in a buffer.
port_listening() {
  if command -v ss >/dev/null 2>&1; then
    ss -Hltn "sport = :$1" | grep -q .
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
  fi
}

# A local port nothing is listening on.
free_port() {
  python3 -I -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
}

# Object ID and principal type (User or ServicePrincipal) of the identity the Azure CLI is signed in
# as. The object ID comes from its ARM token, so this works for users, service principals and
# managed identities alike, with no Microsoft Graph permission.
signed_in_principal() {
  local token type
  token="$(az account get-access-token --query accessToken --output tsv --only-show-errors)"
  type="$(az account show --query user.type --output tsv --only-show-errors)"
  python3 -I -c 'import base64, json, sys
part = sys.argv[1].split(".")[1]
claims = json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))
print(claims["oid"], "User" if sys.argv[2] == "user" else "ServicePrincipal")' "$token" "$type"
}

# A role assignment name (a GUID) fixed by its inputs, so a session that grants the same role twice
# reuses one assignment rather than piling them up.
assignment_name() {
  python3 -I -c 'import sys, uuid
print(uuid.uuid5(uuid.NAMESPACE_URL, "bastion-session:" + "|".join(sys.argv[1:])))' "$@"
}

# Grant a role to a principal on one scope, marked with the session's description. When the
# principal already holds the role there (a standing assignment), that one is left alone.
#   grant_login_role <scope> <object id> <principal type> <role> <session name>
grant_login_role() {
  local scope="$1" oid="$2" type="$3" role="$4" session="$5" out
  if out="$(az role assignment create --name "$(assignment_name "$session" "$scope" "$oid" "$role")" \
    --assignee-object-id "$oid" --assignee-principal-type "$type" --role "$role" --scope "$scope" \
    --description "$SESSION_TAG=$session" --only-show-errors --output none 2>&1)"; then
    log "Granted $role on ${scope##*/}."
  elif grep -qi 'RoleAssignmentExists\|already exists' <<<"$out"; then
    log "The signed-in identity already holds $role on ${scope##*/}."
  else
    printf '%s\n' "$out" >&2
    return 1
  fi
}

# Remove every role assignment on a scope that the session granted. Nothing to remove is not an
# error, and neither is a scope that no longer exists (its assignments went with it).
#   revoke_login_roles <scope> <session name>
revoke_login_roles() {
  local scope="$1" session="$2" err ids rc=0
  err="$(mktemp)"
  ids="$(az role assignment list --scope "$scope" --fill-principal-name false \
    --query "[?description=='$SESSION_TAG=$session'].id" --output tsv --only-show-errors 2>"$err")" || rc=$?
  if ((rc != 0)); then
    if grep -qiE 'NotFound|was not found|could not be found' "$err"; then rc=0; else cat "$err" >&2; fi
    rm -f "$err"
    return "$rc"
  fi
  rm -f "$err"
  [[ -n "$ids" ]] || return 0
  # shellcheck disable=SC2086 # one ID per word
  az role assignment delete --ids $ids --only-show-errors --output none &&
    log "Removed the session's sign-in role on ${scope##*/}."
}

# A short-lived Entra ID OpenSSH certificate for the signed-in identity, for <key>.pub, written to
# <key>-cert.pub (where ssh also looks for it).
#   issue_certificate <private key file>
issue_certificate() {
  az ssh cert --public-key-file "$1.pub" --file "$1-cert.pub" --only-show-errors >/dev/null
}

# The user a certificate signs in as: its first principal, as az ssh config does it (the UPN and
# the e-mail address differ for guest users).
certificate_user() {
  ssh-keygen -L -f "$1" | awk '/^[[:space:]]*Principals:/ { getline; gsub(/[[:space:]]/, ""); print; exit }'
}

# Seconds until a certificate expires.
certificate_seconds_left() {
  local to
  to="$(ssh-keygen -L -f "$1" | sed -n 's/^[[:space:]]*Valid: from .* to \(.*\)$/\1/p')"
  [[ -n "$to" ]] || {
    echo 0
    return 0
  }
  echo $(($(date -d "$to" +%s) - $(date +%s)))
}

# Run a LibreDevOpsHelpers command in PowerShell 7 (the same engine the terraform-azure action runs),
# installing the module from PSGallery first when it is missing. ldo sends its output to stderr, as
# a log; ldo_run leaves it on stdout.
ldo_run() {
  pwsh -NoProfile -NonInteractive -Command "\$ErrorActionPreference = 'Stop'
    if (-not (Get-Module -ListAvailable LibreDevOpsHelpers)) { Install-Module LibreDevOpsHelpers -Scope CurrentUser -Force -AllowClobber }
    Import-Module LibreDevOpsHelpers
    Set-LdoLogFormat -Format Text
    $1"
}

ldo() {
  ldo_run "$1" >&2
}

# This machine's public IP address, as the vault firewall sees it.
current_ip() {
  ldo_run "Get-LdoPublicIpAddress" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | tail -n 1
}

# Whether a vault's firewall already lets this machine in: no firewall, default Allow, or an IP rule
# for it (the terraform-azure action's firewall dance, or the stack's own ip_rules).
#   vault_admits <vault name> <ip address>
vault_admits() {
  az keyvault show --name "$1" --query properties.networkAcls --output json --only-show-errors |
    jq -e --arg ip "$2" \
      '. == null or .defaultAction == "Allow" or any(.ipRules[]?; .value == $ip or .value == ($ip + "/32"))' \
      >/dev/null
}

# Close the firewall rule the dance opened. -RuleOnly removes just this machine's IP rule and leaves
# the vault's network configuration (deny-by-default) to Terraform, which owns it.
#   close_vault <resource group> <vault name>
close_vault() {
  ldo "Remove-LdoKeyVaultCurrentIpRule -ResourceGroup '$1' -KeyVaultName '$2' -RuleOnly" ||
    log "Could not close the $2 firewall: remove this machine's IP rule by hand."
}

# Fetch one target's private key from a Key Vault secret ID into a 0600 file. When the vault's
# firewall does not already let this machine in, it is opened to it for the fetch and closed straight
# after, pass or fail; a rule someone else put there (the terraform-azure action's dance, or the
# stack's ip_rules, in the middle of an apply) is left alone.
#   fetch_key <secret id> <destination file>
fetch_key() {
  local secret_id="$1" dest="$2" vault vault_rg attempt ip opened=false rc=1
  vault="${secret_id#https://}"
  vault="${vault%%.*}"
  vault_rg="$(az keyvault show --name "$vault" --query resourceGroup --output tsv --only-show-errors)"
  ip="$(current_ip)" || ip=""
  if [[ -n "$ip" ]] && vault_admits "$vault" "$ip"; then
    log "The $vault firewall already admits $ip."
  else
    ldo "Add-LdoKeyVaultCurrentIpRule -ResourceGroup '$vault_rg' -KeyVaultName '$vault'"
    opened=true
  fi
  # A new network rule can take a little while to apply, so retry the read.
  for attempt in $(seq 1 18); do
    if (umask 077 && az keyvault secret show --id "$secret_id" --query value --output tsv \
      --only-show-errors >"$dest" 2>/dev/null) && [[ -s "$dest" ]]; then
      rc=0
      break
    fi
    ((attempt < 18)) && sleep 5
  done
  [[ "$opened" == "true" ]] && close_vault "$vault_rg" "$vault"
  if ((rc != 0)); then
    rm -f "$dest"
    log "Could not read $secret_id."
  fi
  return "$rc"
}

# Start one tunnel in its own process group (setsid), because az is a wrapper script around Python:
# killing only its PID leaves the Python tunnel running. Kill it with: kill -- -<pid>. All three
# standard streams are redirected, so the tunnel never holds Terraform's or SSH's pipes open, and
# the lock descriptors proxy.sh uses are closed, so it never holds a lock either.
#   start_tunnel <bastion> <resource group> <--target-resource-id|--target-ip-address> <target>
#                <resource port> <local port> <timeout> <log file>
# Prints the tunnel's PID.
start_tunnel() {
  setsid az network bastion tunnel --name "$1" --resource-group "$2" \
    "$3" "$4" --resource-port "$5" --port "$6" --timeout "$7" --only-show-errors \
    </dev/null >"$8" 2>&1 8>&- 9>&- &
  echo "$!"
}

# Whether the tunnel recorded in <dir>/tunnels/<target>.pid and .port is still running and listening.
#   tunnel_alive <working directory> <target>
tunnel_alive() {
  local pid port
  pid="$(cat "$1/tunnels/$2.pid" 2>/dev/null)" || return 1
  port="$(cat "$1/tunnels/$2.port" 2>/dev/null)" || return 1
  [[ "$(ps -o args= -p "$pid" 2>/dev/null)" == *"bastion tunnel"* ]] && port_listening "$port"
}

# Stop the session's tunnels: the ones recorded in the working directory, and any other tunnel to
# this bastion on this machine (from a working directory that has gone).
#   stop_tunnels <working directory> <bastion> <resource group>
stop_tunnels() {
  local pidfile pid
  for pidfile in "$1"/tunnels/*.pid; do
    [[ -e "$pidfile" ]] || continue
    pid="$(cat "$pidfile")"
    kill -- -"$pid" 2>/dev/null || true
    rm -f "$pidfile" "${pidfile%.pid}.port"
  done
  pkill -f -- "bastion tunnel --name $2 --resource-group $3 " 2>/dev/null || true
}

# Remove what a session writes to its working directory, and the directory once it is empty.
# Only these paths, so a working_directory shared with other files keeps them. With "keep",
# session.json stays, so close.sh can be run on the directory again.
#   remove_session_files <working directory> [keep]
remove_session_files() {
  [[ -d "$1" ]] || return 0
  rm -rf "$1/keys" "$1/tunnels"
  rm -f "$1/ssh_config" "$1/known_hosts" "$1/known_hosts.old" "$1/.certificate.lock"
  [[ "${2:-}" == "keep" ]] || rm -f "$1/session.json"
  rmdir "$1" 2>/dev/null || true
}
