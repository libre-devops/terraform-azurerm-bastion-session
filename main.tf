# Just-in-time Azure Bastion sessions for Terraform. With configure = true, one apply runs:
#
#   1. open   scripts/open.sh creates the public IP and a tunnelling bastion in the stack's
#             AzureBastionSubnet with az, grants the sign-in role, issues the Entra ID certificate
#             or fetches the vaulted keys, writes the session's ssh_config and waits until SSH
#             answers through the bastion on every target
#   2. runs   any number of terraform-ansible-role calls given ansible_hosts, in parallel or chained
#             with depends_on. Every SSH connection goes through scripts/proxy.sh (the ProxyCommand
#             in ssh_config), which opens its own tunnel and closes it when the connection ends
#   3. close  scripts/close.sh, once everything in close_after is known (the runs have finished):
#             deletes the bastion, its public IP and the role assignment, and removes the
#             ssh_config, certificate and keys
#
# The bastion is created with az rather than as a resource, because Terraform cannot create and
# delete the same resource in one apply. So it is never in state, and an apply with
# configure = false has nothing to change.
#
# STATUS: skeleton. The interface is in place; the scripts exit "not implemented" until the work is
# done, so leave configure = false for now.
locals {
  work_dir = abspath(coalesce(var.working_directory, "${path.root}/.terraform/bastion-session/${var.name}"))

  # Everything the scripts need, handed over as JSON in BASTION_SESSION. Kept in the resources'
  # input as well, so a destroy-time provisioner can read it from self if one is added.
  session = {
    name           = var.name
    work_dir       = local.work_dir
    auth           = var.auth
    bastion        = merge(var.bastion, { public_ip_name = coalesce(var.bastion.public_ip_name, "pip-${var.bastion.name}") })
    login_role     = var.login_role
    ready_timeout  = var.ready_timeout
    tunnel_timeout = var.tunnel_timeout
    targets        = var.targets
  }

  # One session per module call, keyed by its name: for_each over a map, never count.
  sessions = var.configure ? { (var.name) = local.session } : {}

  # terraform-ansible-role's hosts shape. The address is the inventory name, which matches a Host
  # block in the session's ssh_config carrying the ProxyCommand (and, for entra, the User and
  # CertificateFile az ssh config writes). The ssh_config path is read from the open step's output,
  # not from local.work_dir, so every role call given these hosts waits for the session to open.
  ansible_hosts = var.configure ? {
    for name, t in var.targets : name => {
      address          = name
      port             = t.port
      user             = var.auth == "key" ? t.user : null
      private_key_file = var.auth == "key" ? "${terraform_data.open[var.name].output.work_dir}/keys/${name}" : null
      ssh_common_args  = "-F ${terraform_data.open[var.name].output.work_dir}/ssh_config"
      groups           = t.groups
      triggers         = merge({ target = coalesce(t.id, t.ip_address) }, t.triggers)
    }
  } : {}
}

# Opens the session. Replaced on every apply with configure = true (plantimestamp changes each
# plan), so every such apply opens a fresh bastion.
resource "terraform_data" "open" {
  for_each = local.sessions

  input            = each.value
  triggers_replace = plantimestamp()

  provisioner "local-exec" {
    command     = "${path.module}/scripts/open.sh"
    interpreter = ["bash", "-c"]
    environment = {
      BASTION_SESSION = jsonencode(each.value)
      SCRIPTS_DIR     = "${path.module}/scripts"
    }
  }
}

# Closes the session once close_after is known, which is after every run listed there finishes.
# Terraform has no "finally": if a run fails, this is skipped, so the calling workflow runs
# scripts/close.sh in an always() step as well (it is safe to run when nothing is open).
resource "terraform_data" "close" {
  for_each = local.sessions

  input            = each.value
  triggers_replace = [plantimestamp(), var.close_after]

  provisioner "local-exec" {
    command     = "${path.module}/scripts/close.sh"
    interpreter = ["bash", "-c"]
    environment = {
      BASTION_SESSION = jsonencode(each.value)
      SCRIPTS_DIR     = "${path.module}/scripts"
    }
  }

  depends_on = [terraform_data.open]
}
