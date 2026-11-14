<!--
  Header for the minimal example README. Edit this file, then run `just docs`
  (or ./Sort-LdoTerraform.ps1 -IncludeExamples) to regenerate the section between the markers.
  The example's main.tf is embedded into the README automatically (see .terraform-docs.yml).
-->
<div align="center">
  <a href="https://libredevops.org">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://libredevops.org/assets/libre-devops-white.png">
      <img alt="Libre DevOps" src="https://libredevops.org/assets/libre-devops-black.png" width="200">
    </picture>
  </a>
</div>

# Minimal example

The smallest useful call: an Ubuntu VM with no public IP, in a subnet that admits SSH from the
`AzureBastionSubnet` only, and `libre_devops.python` run on it from Terraform through a bastion
that exists only during an apply with `configure = true`. Ansible signs in with Entra ID (the
vm-entra-login module), so the admin key the linux-vm module needs is never used. The environment
comes from the Terraform workspace (`terraform.workspace`).

With `configure = false` (the default) the apply builds the infrastructure only. The scripts are not
written yet, so leave it false until the module's first release.

[![Terraform Registry](https://img.shields.io/badge/registry-libre--devops-7B42BC?logo=terraform&logoColor=white)](https://registry.terraform.io/namespaces/libre-devops)

<!-- BEGIN_TF_DOCS -->
## Example configuration

```hcl
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
```

## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11.0, < 2.0.0 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | >= 4.23.0, < 5.0.0 |
| <a name="requirement_tls"></a> [tls](#requirement\_tls) | >= 4.1.0, < 5.0.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_tls"></a> [tls](#provider\_tls) | >= 4.1.0, < 5.0.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_bastion_session"></a> [bastion\_session](#module\_bastion\_session) | ../../ | n/a |
| <a name="module_linux_vm"></a> [linux\_vm](#module\_linux\_vm) | libre-devops/linux-vm/azurerm | ~> 4.1 |
| <a name="module_nat_gateway"></a> [nat\_gateway](#module\_nat\_gateway) | libre-devops/nat-gateway/azurerm | ~> 4.0 |
| <a name="module_network"></a> [network](#module\_network) | libre-devops/network/azurerm | ~> 4.0 |
| <a name="module_nsg"></a> [nsg](#module\_nsg) | libre-devops/nsg/azurerm | ~> 4.0 |
| <a name="module_public_ip_nat"></a> [public\_ip\_nat](#module\_public\_ip\_nat) | libre-devops/public-ip/azurerm | ~> 4.0 |
| <a name="module_python"></a> [python](#module\_python) | git::https://github.com/libre-devops/terraform-ansible-role.git | 4.0.0 |
| <a name="module_rg"></a> [rg](#module\_rg) | libre-devops/rg/azurerm | ~> 4.0 |
| <a name="module_tags"></a> [tags](#module\_tags) | libre-devops/tags/azurerm | ~> 4.0 |
| <a name="module_vm_entra_login"></a> [vm\_entra\_login](#module\_vm\_entra\_login) | git::https://github.com/libre-devops/terraform-azurerm-vm-entra-login.git | 4.0.1 |

## Resources

| Name | Type |
| ---- | ---- |
| [tls_private_key.admin](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/private_key) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_configure"></a> [configure](#input\_configure) | Open a bastion session in this apply and run the roles through it. Leave false for an ordinary infrastructure apply. | `bool` | `false` | no |
| <a name="input_deployed_branch"></a> [deployed\_branch](#input\_deployed\_branch) | Git branch the deployment came from. Auto-filled in CI from TF\_VAR\_deployed\_branch. | `string` | `""` | no |
| <a name="input_deployed_repo"></a> [deployed\_repo](#input\_deployed\_repo) | Repository URL the deployment came from. Auto-filled in CI from TF\_VAR\_deployed\_repo. | `string` | `""` | no |
| <a name="input_loc"></a> [loc](#input\_loc) | Outfix: short Azure region code used in resource names (for example uks). | `string` | `"uks"` | no |
| <a name="input_regions"></a> [regions](#input\_regions) | Map of short region codes to Azure region slugs. | `map(string)` | <pre>{<br/>  "eus": "eastus",<br/>  "euw": "westeurope",<br/>  "uks": "uksouth",<br/>  "ukw": "ukwest"<br/>}</pre> | no |
| <a name="input_short"></a> [short](#input\_short) | Infix: short product code used in resource names. | `string` | `"ldo"` | no |
| <a name="input_vm_size"></a> [vm\_size](#input\_vm\_size) | Size of the VM. | `string` | `"Standard_D2lds_v6"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_bastion_name"></a> [bastion\_name](#output\_bastion\_name) | Name of the bastion the session creates while it is open. |
| <a name="output_configured"></a> [configured](#output\_configured) | Whether this apply opened a session and ran the roles. |
| <a name="output_vm_ids"></a> [vm\_ids](#output\_vm\_ids) | Map of VM name to VM id. |
<!-- END_TF_DOCS -->
