#!/usr/bin/env bash
# Close a bastion session, and leave nothing behind. Run by the module's terraform_data.close once
# every run in close_after has finished; by terraform_data.open when an apply replaces or removes it
# (so a session a failed run left open is closed by the next apply); and by the calling workflow in
# an always() step, because a failed run skips the close step. Safe to run when nothing is open, and
# as often as you like.
#
#   close.sh <the session's working directory>     reads the session.json open.sh left there,
#                                                   and does nothing if there is none
#   BASTION_SESSION='<session_json output>' close.sh
#
#   1. Stop the session's tunnels on this machine.
#   2. Remove the sign-in role assignments the session granted (entra).
#   3. Delete the bastion and its public IP, if they exist and carry the session's tag. Anything
#      else with those names is left alone, with a warning.
#   4. Remove the working directory's ssh_config, certificate, keys and logs. session.json goes too,
#      unless a step failed: then it stays, so running close.sh on the directory again retries.
#
# Every step runs even if an earlier one failed; the exit status says whether all of them worked.
set -euo pipefail

SCRIPTS_DIR="$(cd "${SCRIPTS_DIR:-$(dirname "$0")}" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPTS_DIR/lib.sh"

if [[ -z "${BASTION_SESSION:-}" && -n "${1:-}" ]]; then
  if [[ ! -f "$1/session.json" ]]; then
    log "No session is open in $1."
    exit 0
  fi
  BASTION_SESSION="$(cat "$1/session.json")"
fi

need az jq
ensure_extensions bastion

name="$(session_get .name)"
work_dir="$(session_opt .work_dir)"
auth="$(session_opt .auth)"
bastion="$(session_get .bastion.name)"
rg="$(session_get .bastion.resource_group_name)"
pip="$(session_opt .bastion.public_ip_name)"
pip="${pip:-pip-$bastion}"
rc=0

# A long apply can outlast the Azure CLI's GitHub OIDC sign-in (see lib.sh).
refresh_github_oidc_login "$work_dir" force || log "Could not sign the Azure CLI in again; carrying on with its current sign-in."

# --- 1. Tunnels ------------------------------------------------------------------------------------

stop_tunnels "${work_dir:-/nonexistent}" "$bastion" "$rg"

# --- 2. Sign-in role assignments -------------------------------------------------------------------

if [[ "${auth:-entra}" == "entra" && "$(session_opt .login_role.enabled)" != "false" ]]; then
  mapfile -t scopes < <(session_opt '.targets // {} | .[].id | select(. != null)')
  for scope in "${scopes[@]}"; do
    revoke_login_roles "$scope" "$name" || {
      log "Could not remove the session's sign-in role on ${scope##*/}."
      rc=1
    }
  done
fi

# --- 3. The bastion and its public IP --------------------------------------------------------------

# Delete one resource if it exists and is the session's.
#   delete_owned <kind for messages> <az group> <name>
delete_owned() {
  local kind="$1" group="$2" resource="$3" json
  json="$(az_show network "$group" show --name "$resource" --resource-group "$rg")" || return 1
  if [[ -z "$json" ]]; then
    return 0
  fi
  if [[ "$(session_owner "$json")" != "$name" ]]; then
    log "Leaving the $kind $resource alone: it does not carry $SESSION_TAG=$name, so this session did not create it."
    return 0
  fi
  log "Deleting the $kind $resource${4:-}."
  if [[ "$group" == "bastion" ]]; then
    az network bastion delete --name "$resource" --resource-group "$rg" --yes --only-show-errors --output none
  else
    az network public-ip delete --name "$resource" --resource-group "$rg" --only-show-errors --output none
  fi
}

# No resource group means nothing was ever created (or the stack has gone).
if [[ "$(az group exists --name "$rg" --only-show-errors)" == "true" ]]; then
  delete_owned bastion bastion "$bastion" " (this usually takes a few minutes)" || {
    log "Could not delete the bastion $bastion: delete it by hand, it is billed by the hour."
    rc=1
  }
  delete_owned "public IP" public-ip "$pip" || {
    log "Could not delete the public IP $pip."
    rc=1
  }
fi

# --- 4. Files --------------------------------------------------------------------------------------

if [[ -n "$work_dir" ]]; then
  if ((rc == 0)); then remove_session_files "$work_dir"; else remove_session_files "$work_dir" keep; fi
fi

if ((rc == 0)); then
  log "Session $name is closed."
else
  log "Session $name did not close cleanly: see the messages above. To retry: $0 ${work_dir:-<working directory>}"
fi
exit "$rc"
