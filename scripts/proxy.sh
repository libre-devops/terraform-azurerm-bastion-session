#!/usr/bin/env bash
# The ProxyCommand in the session's ssh_config: carries one SSH connection through the bastion.
#
#   proxy.sh <session working directory> <target name>
#
# Each target has one tunnel (az network bastion tunnel on a free local port, capped at
# tunnel_timeout), shared by every connection to it: starting a tunnel takes several seconds, longer
# than the 10 second ConnectTimeout Ansible gives SSH, so a tunnel per connection would time out.
# The first connection starts the tunnel (open.sh's ready check, normally) and the rest find it
# running; a tunnel that died or timed out is started again. close.sh stops them all.
#
# With entra sign-in it also renews the certificate when less than 10 minutes are left, so long runs
# keep signing in (the connection being made still uses the old one, which is valid for long enough).
#
# stdout is the SSH connection, so everything else goes to stderr (which SSH shows) or log files.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPTS_DIR/lib.sh"

work_dir="${1:?usage: proxy.sh <session working directory> <target name>}"
target="${2:?usage: proxy.sh <session working directory> <target name>}"
[[ -f "$work_dir/session.json" ]] || die "No open session in $work_dir."
BASTION_SESSION="$(cat "$work_dir/session.json")"

[[ -n "$(session_opt ".targets[\"$target\"] | type")" ]] || die "$target is not a target of this session."

# One process at a time checks and (re)starts this target's tunnel. The kernel drops the lock when
# the process exits, even if it is killed.
exec 9>"$work_dir/tunnels/$target.lock"
flock -w 300 9 || die "Timed out waiting for the tunnel lock for $target."

if ! tunnel_alive "$work_dir" "$target"; then
  if id="$(session_opt ".targets[\"$target\"].id")" && [[ -n "$id" ]]; then
    target_args=(--target-resource-id "$id")
  else
    target_args=(--target-ip-address "$(session_get ".targets[\"$target\"].ip_address")")
  fi
  port="$(free_port)"
  pid="$(start_tunnel "$(session_get .bastion.name)" "$(session_get .bastion.resource_group_name)" \
    "${target_args[@]}" "$(session_get ".targets[\"$target\"].port")" "$port" \
    "$(session_get .tunnel_timeout)" "$work_dir/tunnels/$target.log")"
  deadline=$((SECONDS + 90))
  until port_listening "$port"; do
    if ! kill -0 "$pid" 2>/dev/null || ((SECONDS >= deadline)); then
      kill -- -"$pid" 2>/dev/null || true
      log "The tunnel to $target did not start:"
      sed 's/^/  tunnel: /' "$work_dir/tunnels/$target.log" >&2
      exit 1
    fi
    sleep 0.5
  done
  echo "$pid" >"$work_dir/tunnels/$target.pid"
  echo "$port" >"$work_dir/tunnels/$target.port"
fi
port="$(cat "$work_dir/tunnels/$target.port")"
exec 9>&-

# Renew the Entra ID certificate for the connections after this one. Best effort: a failure here
# leaves the current certificate, which still has a few minutes.
cert="$work_dir/keys/id_rsa-cert.pub"
if [[ -f "$cert" ]] && (($(certificate_seconds_left "$cert") < 600)); then
  (
    exec 8>"$work_dir/.certificate.lock"
    if flock -n 8 && (($(certificate_seconds_left "$cert") < 600)); then
      issue_certificate "$work_dir/keys/id_rsa" && log "Renewed the Entra ID SSH certificate." ||
        log "Could not renew the Entra ID SSH certificate."
    fi
  ) || true
fi

exec python3 -I "$SCRIPTS_DIR/relay.py" "$port"
