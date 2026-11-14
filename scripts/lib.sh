# shellcheck shell=bash
# Helpers shared by open.sh, proxy.sh and close.sh. Source it; do not run it.
#
# Copied from azure-orchestration/scripts/bastion-ansible.sh (e641357), where each was proven on a
# live run, and reshaped into functions that take their inputs as arguments. Not wired up yet.

log() { printf '[bastion-session] %s\n' "$*" >&2; }

# The session's settings, as JSON in BASTION_SESSION (set by the module's provisioners, or by hand
# from the module's session_json output). Prints one value: session_get '.bastion.name'.
session_get() {
  jq -er "$1" <<<"${BASTION_SESSION:?BASTION_SESSION is not set}"
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

# Run a LibreDevOpsHelpers command in PowerShell 7 (the same engine the terraform-azure action runs),
# installing the module from PSGallery first when it is missing.
ldo() {
  pwsh -NoProfile -NonInteractive -Command "\$ErrorActionPreference = 'Stop'
    if (-not (Get-Module -ListAvailable LibreDevOpsHelpers)) { Install-Module LibreDevOpsHelpers -Scope CurrentUser -Force -AllowClobber }
    Import-Module LibreDevOpsHelpers
    Set-LdoLogFormat -Format Text
    $1" >&2
}

# Close the firewall rule the dance opened. -RuleOnly removes just this machine's IP rule and leaves
# the vault's network configuration (deny-by-default) to Terraform, which owns it.
#   close_vault <resource group> <vault name>
close_vault() {
  ldo "Remove-LdoKeyVaultCurrentIpRule -ResourceGroup '$1' -KeyVaultName '$2' -RuleOnly" ||
    log "Could not close the $2 firewall: remove this machine's IP rule by hand."
}

# Fetch one target's private key from a Key Vault secret ID into a 0600 file, opening the vault's
# firewall to this machine for the fetch and closing it straight after, pass or fail.
#   fetch_key <secret id> <destination file>
fetch_key() {
  local secret_id="$1" dest="$2" vault vault_rg attempt rc=1
  vault="${secret_id#https://}"
  vault="${vault%%.*}"
  vault_rg="$(az keyvault show --name "$vault" --query resourceGroup --output tsv --only-show-errors)"
  ldo "Add-LdoKeyVaultCurrentIpRule -ResourceGroup '$vault_rg' -KeyVaultName '$vault'"
  # A new network rule can take a little while to apply, so retry the read.
  for attempt in $(seq 1 18); do
    if (umask 077 && az keyvault secret show --id "$secret_id" --query value --output tsv \
      --only-show-errors >"$dest" 2>/dev/null) && [[ -s "$dest" ]]; then
      rc=0
      break
    fi
    ((attempt < 18)) && sleep 5
  done
  close_vault "$vault_rg" "$vault"
  if ((rc != 0)); then
    rm -f "$dest"
    log "Could not read $secret_id."
  fi
  return "$rc"
}

# Start one tunnel in its own process group (setsid), because az is a wrapper script around Python:
# killing only its PID leaves the Python tunnel running. Kill it with: kill -- -<pid>.
#   start_tunnel <bastion> <resource group> <target id> <resource port> <local port> <timeout> <log file>
# Prints the tunnel's PID.
start_tunnel() {
  setsid az network bastion tunnel --name "$1" --resource-group "$2" \
    --target-resource-id "$3" --resource-port "$4" --port "$5" --timeout "$6" --only-show-errors \
    >"$7" 2>&1 &
  echo "$!"
}
