#!/usr/bin/env bash
# Open a bastion session. Run by the module's terraform_data.open, with the session's settings as
# JSON in BASTION_SESSION.
#
# To do:
#   1. Create the public IP and the bastion (Standard or Premium, native client tunnelling, IP
#      connect when asked) in bastion.subnet_id with az, or reuse one a failed run left behind.
#   2. auth entra: grant login_role to the signed-in identity on each target (unless disabled), then
#      az ssh config into the working directory. auth key: fetch_key each target's secret into
#      keys/<name>.
#   3. Write ssh_config: one Host block per target with HostName, Port, a ProxyCommand running
#      proxy.sh for that target, HostKeyAlias, and for entra the User and CertificateFile.
#   4. Wait up to ready_timeout for SSH to answer through the bastion on every target.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "${SCRIPTS_DIR:-$(dirname "$0")}/lib.sh"

log "open.sh is not implemented yet: leave configure = false."
exit 1
