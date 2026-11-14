# The smallest useful call: an Ubuntu VM nobody can reach from outside, and libre_devops.python run
# on it from Terraform through a bastion that exists only during an apply with configure = true.
# Ansible signs in with Entra ID (vm-entra-login), so no key is used. Infrastructure copied from
# azure-orchestration's mde-linux stack, minus its access window, which this module replaces.
locals {
  location = lookup(var.regions, var.loc, "uksouth")
  suffix   = "${var.short}-${var.loc}-${terraform.workspace}-001"

  rg_name     = "rg-${local.suffix}"
  vnet_name   = "vnet-${local.suffix}"
  nsg_name    = "nsg-${local.suffix}"
  ng_name     = "ng-${local.suffix}"
  pip_ng_name = "pip-ng-${local.suffix}"
  bas_name    = "bas-${local.suffix}"
  vm_name     = "vm-${local.suffix}"
  subnet_vm   = "snet-vm-${local.vnet_name}"

  vm_subnet_prefix      = "10.20.1.0/24"
  bastion_subnet_prefix = "10.20.0.0/26"
}

module "tags" {
  source  = "libre-devops/tags/azurerm"
  version = "~> 4.0"

  cost_centre     = "1888/67"
  owner           = "platform@example.com"
  deployed_branch = var.deployed_branch
  deployed_repo   = var.deployed_repo
}

module "rg" {
  source  = "libre-devops/rg/azurerm"
  version = "~> 4.0"

  resource_groups = [{ name = local.rg_name, location = local.location, tags = module.tags.tags }]
}

# The VM subnet, and the AzureBastionSubnet the session's bastion uses. A subnet costs nothing, so
# it stays; only the bastion and its public IP come and go.
module "network" {
  source  = "libre-devops/network/azurerm"
  version = "~> 4.0"

  resource_group_id = module.rg.ids[local.rg_name]
  location          = local.location
  tags              = module.tags.tags

  vnet_name     = local.vnet_name
  address_space = ["10.20.0.0/16"]
  subnets = {
    (local.subnet_vm)    = { address_prefixes = [local.vm_subnet_prefix] }
    "AzureBastionSubnet" = { address_prefixes = [local.bastion_subnet_prefix] }
  }
}

# The VM subnet admits SSH from the bastion subnet only, on top of the module's explicit inbound deny.
module "nsg" {
  source  = "libre-devops/nsg/azurerm"
  version = "~> 4.0"

  resource_group_id = module.rg.ids[local.rg_name]
  location          = local.location
  tags              = module.tags.tags

  name = local.nsg_name

  security_rules = {
    AllowBastionSshInbound = {
      priority                   = 200
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      description                = "SSH from the bastion subnet only (the bastion session's tunnels)."
      source_port_range          = "*"
      destination_port_range     = "22"
      source_address_prefix      = local.bastion_subnet_prefix
      destination_address_prefix = local.vm_subnet_prefix
    }
  }

  subnet_associations = {
    (local.subnet_vm) = module.network.subnet_ids[local.subnet_vm]
  }
}

# Egress for the VM subnet: the Entra ID login extension and the package repositories need outbound
# HTTPS, and the network module's subnets have no implicit outbound access.
module "public_ip_nat" {
  source  = "libre-devops/public-ip/azurerm"
  version = "~> 4.0"

  resource_group_id = module.rg.ids[local.rg_name]
  location          = local.location
  tags              = module.tags.tags

  public_ips = { (local.pip_ng_name) = {} }
}

module "nat_gateway" {
  source  = "libre-devops/nat-gateway/azurerm"
  version = "~> 4.0"

  resource_group_id = module.rg.ids[local.rg_name]
  location          = local.location
  tags              = module.tags.tags

  name = local.ng_name

  public_ip_associations = { (local.pip_ng_name) = module.public_ip_nat.public_ip_ids[local.pip_ng_name] }
  subnet_associations    = { (local.subnet_vm) = module.network.subnet_ids[local.subnet_vm] }
}

# The linux-vm module needs one admin key. Ansible never uses it (it signs in with Entra ID); see the
# complete example for a vaulted key that is never in state.
resource "tls_private_key" "admin" {
  algorithm = "ED25519"
}

module "linux_vm" {
  source  = "libre-devops/linux-vm/azurerm"
  version = "~> 4.1"

  resource_group_id = module.rg.ids[local.rg_name]
  location          = local.location
  tags              = module.tags.tags

  linux_virtual_machines = {
    (local.vm_name) = {
      size                = var.vm_size
      admin_username      = "azureuser"
      source_image_simple = "Ubuntu2404"
      subnet_id           = module.network.subnet_ids[local.subnet_vm]
      admin_ssh_keys      = [{ public_key = tls_private_key.admin.public_key_openssh }]
    }
  }

  # The Entra ID login extension installs packages on first boot, so the subnet needs its egress
  # before the VM exists.
  depends_on = [module.nat_gateway]
}

module "vm_entra_login" {
  # Pinned to the GitHub tag until the module is published on the Terraform Registry.
  source = "git::https://github.com/libre-devops/terraform-azurerm-vm-entra-login.git?ref=4.0.1"

  tags = module.tags.tags

  linux_virtual_machine_ids = module.linux_vm.ids
}

# The session: a bastion only while an apply with configure = true runs, Entra ID sign-in, and the
# VM in the python group.
module "bastion_session" {
  source = "../../"

  resource_group_id = module.rg.ids[local.rg_name]
  location          = local.location
  tags              = module.tags.tags

  name      = "minimal"
  configure = var.configure

  bastion = {
    name      = local.bas_name
    subnet_id = module.network.subnet_ids["AzureBastionSubnet"]
  }

  targets = {
    (local.vm_name) = {
      id       = module.linux_vm.ids[local.vm_name]
      groups   = ["python"]
      triggers = { vm_id = module.linux_vm.ids[local.vm_name] }
    }
  }

  close_after = [module.python[*].run_ids]

  depends_on = [module.vm_entra_login]
}

# Any of the standard roles, run through the open session. count, because terraform-ansible-role
# needs at least one host and ansible_hosts is empty when configure is false.
module "python" {
  # Pinned to the GitHub tag until the module is published on the Terraform Registry.
  source = "git::https://github.com/libre-devops/terraform-ansible-role.git?ref=4.0.0"
  count  = var.configure ? 1 : 0

  name               = "python"
  roles              = [{ name = "libre_devops.python", version = "1.0.0" }]
  hosts              = module.bastion_session.ansible_hosts
  gather_facts       = false
  wait_for_ssh       = false
  run_on_every_apply = true
}
