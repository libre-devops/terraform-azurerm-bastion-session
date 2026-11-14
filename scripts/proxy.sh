#!/usr/bin/env bash
# The ProxyCommand in the session's ssh_config: carries one SSH connection through the bastion.
#
#   proxy.sh <session working directory> <target name>
#
# To do:
#   1. Read the target (resource ID or IP address, port) and the bastion from the session.
#   2. Pick a free local port and start_tunnel to the target, capped at tunnel_timeout.
#   3. Wait for port_listening, then relay stdin and stdout to 127.0.0.1:<port>.
#   4. On exit (SSH closed the connection, or any failure) kill the tunnel's process group, so no
#      tunnel outlives its connection.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

log "proxy.sh is not implemented yet."
exit 1
