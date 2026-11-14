#!/usr/bin/env bash
# Close a bastion session. Run by the module's terraform_data.close once every run in close_after
# has finished, and by the calling workflow in an always() step, because a failed run skips the
# module's close step. Safe to run when nothing is open.
#
#   BASTION_SESSION='<the module's session_json output>' close.sh
#
# To do:
#   1. Kill any tunnel still running for the session.
#   2. Remove the login_role assignments the session granted.
#   3. Delete the bastion and its public IP, if they exist.
#   4. Remove the working directory (ssh_config, certificate, keys, logs).
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "${SCRIPTS_DIR:-$(dirname "$0")}/lib.sh"

log "close.sh is not implemented yet."
exit 1
