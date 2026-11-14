variable "auth" {
  description = <<-EOT
    How Ansible signs in to the targets: entra (a short-lived Entra ID OpenSSH certificate for the
    identity running Terraform, issued with az ssh config) or key (each target's own private key,
    fetched from the Key Vault secret in its ssh_key_secret_id and signed in as its user). For key,
    the vault's firewall is opened to this machine only for the fetch, with LibreDevOpsHelpers'
    Add-LdoKeyVaultCurrentIpRule and Remove-LdoKeyVaultCurrentIpRule (needs PowerShell 7).
  EOT
  type        = string
  default     = "entra"

  validation {
    condition     = contains(["entra", "key"], var.auth)
    error_message = "auth must be entra or key."
  }
}

variable "bastion" {
  description = <<-EOT
    The bastion the session creates when it opens and deletes when it closes. It is never in
    Terraform state. subnet_id is the virtual network's AzureBastionSubnet, which the calling stack
    keeps (a subnet costs nothing). The public IP is public_ip_name (default pip-<name>). sku is
    Standard or Premium, the SKUs with native client tunnelling. ip_connect_enabled lets targets be
    given by private IP address (peered or on-premises machines; SSH on port 22 only).
  EOT
  type = object({
    name                = string
    resource_group_name = string
    location            = string
    subnet_id           = string
    public_ip_name      = optional(string)
    sku                 = optional(string, "Standard")
    scale_units         = optional(number, 2)
    ip_connect_enabled  = optional(bool, false)
    tags                = optional(map(string), {})
  })

  validation {
    condition     = contains(["Standard", "Premium"], var.bastion.sku)
    error_message = "bastion.sku must be Standard or Premium: lower SKUs cannot tunnel."
  }

  validation {
    condition     = endswith(var.bastion.subnet_id, "/subnets/AzureBastionSubnet")
    error_message = "bastion.subnet_id must be the virtual network's AzureBastionSubnet."
  }

  validation {
    condition     = var.bastion.scale_units >= 2 && var.bastion.scale_units <= 50
    error_message = "bastion.scale_units must be between 2 and 50."
  }
}

variable "close_after" {
  description = <<-EOT
    Something from every module call that runs through the session, such as
    [module.python[*].run_ids, module.mde_linux[*].run_ids]. The session closes (the bastion is
    deleted) only once all of it is known, which is after those runs have finished. Leave a call out
    and the bastion can close while that call is still running.
  EOT
  type        = any
  default     = null
}

variable "configure" {
  description = <<-EOT
    Open a session in this apply. When true, the apply creates the bastion, the role runs that use
    ansible_hosts go through it, and the bastion is deleted once they finish (see close_after).
    When false (the default), nothing is created, ansible_hosts is empty, and the apply is an
    ordinary infrastructure apply. terraform-ansible-role needs at least one host, so give each
    role call count = <the same value> rather than an empty hosts map.
  EOT
  type        = bool
  default     = false
}

variable "login_role" {
  description = <<-EOT
    Grant the identity running Terraform an Entra ID sign-in role on each target for the length of
    the session (entra sign-in only), and remove it when the session closes. Virtual Machine
    Administrator Login gives the passwordless sudo that become needs; Virtual Machine User Login
    does not. A new assignment can take a minute or two to apply, which ready_timeout allows for.
    Set enabled = false when the identity already holds a standing role.
  EOT
  type = object({
    enabled   = optional(bool, true)
    role_name = optional(string, "Virtual Machine Administrator Login")
  })
  default = {}

  validation {
    condition     = contains(["Virtual Machine Administrator Login", "Virtual Machine User Login"], var.login_role.role_name)
    error_message = "login_role.role_name must be Virtual Machine Administrator Login or Virtual Machine User Login."
  }
}

variable "name" {
  description = "Name of the session, used for its working directory. Unique per module call in a root module."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._-]*$", var.name))
    error_message = "name is used as a directory name: letters, digits, dots, dashes and underscores, starting with a letter or digit."
  }
}

variable "ready_timeout" {
  description = "Seconds to wait, once the bastion is up, for SSH to answer through it on every target (a new sign-in role takes a while to apply)."
  type        = number
  default     = 300
}

variable "targets" {
  description = <<-EOT
    The machines to reach, keyed by the inventory name they get in ansible_hosts. Each entry: id
    (the VM's resource ID; the bastion reaches VMs in its own and peered virtual networks), or
    ip_address instead when bastion.ip_connect_enabled is true; groups (inventory groups); port
    (default 22); for key sign-in, user and ssh_key_secret_id (the Key Vault secret holding the
    private key, such as the ssh-key module's private_key_secret_versionless_ids); and triggers
    (values, such as the VM's ID, passed on to terraform-ansible-role so a replaced VM is
    configured again with a clean known_hosts).
  EOT
  type = map(object({
    id                = optional(string)
    ip_address        = optional(string)
    groups            = optional(list(string), [])
    port              = optional(number, 22)
    user              = optional(string)
    ssh_key_secret_id = optional(string)
    triggers          = optional(map(string), {})
  }))

  validation {
    condition     = length(var.targets) > 0
    error_message = "targets must name at least one machine."
  }

  validation {
    condition     = alltrue([for name in keys(var.targets) : can(regex("^[A-Za-z0-9][A-Za-z0-9._-]*$", name))])
    error_message = "Each targets key is an inventory name and a file name: letters, digits, dots, dashes and underscores, starting with a letter or digit."
  }

  validation {
    condition     = alltrue([for t in values(var.targets) : (t.id == null) != (t.ip_address == null)])
    error_message = "Each target needs exactly one of id or ip_address."
  }

  validation {
    condition     = alltrue([for t in values(var.targets) : t.ip_address == null || (var.bastion.ip_connect_enabled && t.port == 22)])
    error_message = "ip_address targets need bastion.ip_connect_enabled = true and port 22 (a bastion's IP connect only forwards ports 22 and 3389)."
  }

  validation {
    condition     = var.auth != "key" || alltrue([for t in values(var.targets) : t.user != null && t.ssh_key_secret_id != null])
    error_message = "auth = \"key\" needs user and ssh_key_secret_id on every target."
  }
}

variable "tunnel_timeout" {
  description = "Most seconds a target's tunnel stays open (az network bastion tunnel --timeout). One tunnel carries every connection to its target for the whole session, so make this longer than the role runs take: a tunnel that reaches it drops its connections (the next connection starts a new one). It is the backstop that stops a tunnel outliving a session whose close step never ran."
  type        = number
  default     = 7200
}

variable "working_directory" {
  description = "Directory for the session's SSH config, certificate or keys and tunnel logs while it is open. Default: .terraform/bastion-session/<name> in the root module, which Git already ignores. Closing the session removes them."
  type        = string
  default     = null
}
