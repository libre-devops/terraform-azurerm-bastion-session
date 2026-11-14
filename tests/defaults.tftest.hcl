# Plan-time tests for the module. It uses no providers, so nothing is mocked and no credentials or
# cloud calls are needed:
#   terraform init -backend=false && terraform test

variables {
  name = "tst"

  bastion = {
    name                = "bas-ldo-uks-tst-001"
    resource_group_name = "rg-ldo-uks-tst-001"
    location            = "uksouth"
    subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ldo-uks-tst-001/providers/Microsoft.Network/virtualNetworks/vnet-ldo-uks-tst-001/subnets/AzureBastionSubnet"
  }

  targets = {
    vm-ldo-uks-tst-001 = {
      id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ldo-uks-tst-001/providers/Microsoft.Compute/virtualMachines/vm-ldo-uks-tst-001"
      groups = ["mde_linux"]
    }
  }
}

run "off_by_default" {
  command = plan

  assert {
    condition     = length(terraform_data.open) == 0 && length(terraform_data.close) == 0
    error_message = "With configure left at false, no session should be opened or closed."
  }

  assert {
    condition     = length(output.ansible_hosts) == 0
    error_message = "With configure left at false, ansible_hosts should be empty."
  }
}

run "configure_opens_and_closes_one_session" {
  command = plan

  variables {
    configure   = true
    close_after = ["a run id"]
  }

  assert {
    condition     = length(terraform_data.open) == 1 && length(terraform_data.close) == 1
    error_message = "configure = true should plan one open and one close step."
  }

  assert {
    condition     = keys(output.ansible_hosts) == tolist(["vm-ldo-uks-tst-001"])
    error_message = "ansible_hosts should have one entry per target, keyed by the target name."
  }

  assert {
    condition     = output.ansible_hosts["vm-ldo-uks-tst-001"].groups == tolist(["mde_linux"])
    error_message = "Each host should keep its target's groups."
  }

  assert {
    condition     = output.ansible_hosts["vm-ldo-uks-tst-001"].user == null
    error_message = "entra sign-in should leave the user to the session's ssh_config."
  }

  assert {
    condition     = jsondecode(output.session_json).bastion.public_ip_name == "pip-bas-ldo-uks-tst-001"
    error_message = "The public IP should default to pip-<bastion name> in the settings the scripts read."
  }

  assert {
    condition     = jsondecode(output.session_json).bastion.ip_connect_enabled == false && jsondecode(output.session_json).login_role.enabled
    error_message = "The scripts should get every bastion and login_role default explicitly, false included."
  }
}

run "key_auth_needs_a_user_and_secret" {
  command = plan

  variables {
    auth = "key"
  }

  expect_failures = [var.targets]
}

run "bastion_needs_the_bastion_subnet" {
  command = plan

  variables {
    bastion = {
      name                = "bas-ldo-uks-tst-001"
      resource_group_name = "rg-ldo-uks-tst-001"
      location            = "uksouth"
      subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ldo-uks-tst-001/providers/Microsoft.Network/virtualNetworks/vnet-ldo-uks-tst-001/subnets/snet-vm"
    }
  }

  expect_failures = [var.bastion]
}
