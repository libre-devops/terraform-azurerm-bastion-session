<!--
  Keep the title and badges OUTSIDE the centered <div>: the Terraform Registry's markdown renderer
  does not parse markdown inside an HTML block, so a # heading or [![badge]] in the div renders as
  literal text on the registry. Only the logo (HTML) goes in the div.
-->
<div align="center">
  <a href="https://libredevops.org">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://libredevops.org/assets/libre-devops-white.png">
      <img alt="Libre DevOps" src="https://libredevops.org/assets/libre-devops-black.png" width="300">
    </picture>
  </a>
</div>

# Bastion Session

Just-in-time Azure Bastion sessions for Terraform: one apply creates a bastion, hands
[terraform-ansible-role](https://github.com/libre-devops/terraform-ansible-role) SSH connections
through it to VMs nobody can reach from outside, and deletes it once the roles have run.

[![CI](https://github.com/libre-devops/terraform-azurerm-bastion-session/actions/workflows/ci.yml/badge.svg)](https://github.com/libre-devops/terraform-azurerm-bastion-session/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/libre-devops/terraform-azurerm-bastion-session?sort=semver&label=release)](https://github.com/libre-devops/terraform-azurerm-bastion-session/releases/latest)
[![Terraform Registry](https://img.shields.io/badge/registry-libre--devops-7B42BC?logo=terraform&logoColor=white)](https://registry.terraform.io/namespaces/libre-devops)
[![License](https://img.shields.io/github/license/libre-devops/terraform-azurerm-bastion-session)](./LICENSE)

---

> **Status: skeleton.** The interface (inputs, outputs, the open and close steps) is in place and
> tested at plan time, but the scripts that create the bastion, carry the SSH connections and
> delete it again are not written yet: they exit "not implemented". Leave `configure = false`
> until the first release.

## Usage

Open a session, chain any of the Libre DevOps roles on it, and close it, all in one apply:

```hcl
module "bastion_session" {
  source = "libre-devops/bastion-session/azurerm"

  name      = "base"
  configure = var.configure # false: an ordinary infrastructure apply, no bastion

  bastion = {
    name                = "bas-ldo-uks-dev-001"
    resource_group_name = "rg-ldo-uks-dev-001"
    location            = "uksouth"
    subnet_id           = module.network.subnet_ids["AzureBastionSubnet"]
  }

  targets = {
    vm-ldo-uks-dev-001 = { id = module.linux_vm.ids["vm-ldo-uks-dev-001"], groups = ["mde_linux"] }
  }

  # Every call that runs through the session, so the bastion closes only after they finish.
  close_after = [module.python[*].run_ids, module.mde_linux[*].run_ids]
}

module "python" {
  source = "git::https://github.com/libre-devops/terraform-ansible-role.git?ref=4.0.0"
  count  = var.configure ? 1 : 0

  name               = "python"
  roles              = [{ name = "libre_devops.python", version = "1.0.0" }]
  hosts              = module.bastion_session.ansible_hosts
  gather_facts       = false
  wait_for_ssh       = false
  run_on_every_apply = true
}

module "mde_linux" {
  source = "git::https://github.com/libre-devops/terraform-ansible-role.git?ref=4.0.0"
  count  = var.configure ? 1 : 0

  name               = "mde-linux"
  roles              = [{ name = "libre_devops.mde_linux", version = "1.0.0" }]
  hosts              = module.bastion_session.ansible_hosts
  wait_for_ssh       = false
  run_on_every_apply = true

  depends_on = [module.python] # leave out to run the two calls in parallel
}
```

## How it works

| Step | What happens |
|---|---|
| Open | `terraform_data.open` runs [`scripts/open.sh`](./scripts/open.sh): it creates the public IP and a Standard (or Premium) bastion with native client tunnelling in the stack's `AzureBastionSubnet` with `az`, grants the identity running Terraform the Entra ID sign-in role (`auth = "entra"`) or fetches each target's vaulted key (`auth = "key"`), writes the session's `ssh_config`, and waits until SSH answers through the bastion. |
| Run | Every `terraform-ansible-role` call given `ansible_hosts` runs through the session, in parallel or chained with `depends_on`. Each SSH connection goes through [`scripts/proxy.sh`](./scripts/proxy.sh), the `ProxyCommand` in `ssh_config`, which opens its own `az network bastion tunnel` and kills it when the connection ends, so no tunnel outlives its connection. |
| Close | `terraform_data.close` runs [`scripts/close.sh`](./scripts/close.sh) once everything in `close_after` is known, which is after the runs finish: it deletes the bastion, its public IP and the role assignment, and removes the `ssh_config`, certificate and keys. |

**Why the bastion is not a Terraform resource.** Terraform cannot create and delete the same
resource in one apply, which is what forced the old pattern of two applies (open the window, run
Ansible, apply again to close it). Created and deleted by the scripts instead, the bastion is never
in state, so one apply does all three steps, and an apply with `configure = false` has nothing to
change: no bastion, nothing billed, and plans that can say "No changes".

**Why the role calls take `count`.** `terraform-ansible-role` needs at least one host, and
`ansible_hosts` is empty when `configure` is false, so each call is switched off with the same value.
The first `configure = false` apply after a configure run shows those runs being removed; that
changes nothing on the VMs.

**When a run fails.** Terraform has no "finally": a failed run skips the close step and leaves the
bastion up. Run the close script in an `always()` step after the apply (the `close_script` and
`session_json` outputs say how), and keep a scheduled sweeper as a backstop.

## Requirements on the machine running Terraform

The Azure CLI, signed in (`az login`, or `azure/login` in CI) with the `bastion` and `ssh`
extensions, bash, `jq` and `setsid`; `ansible-core` for terraform-ansible-role; and for
`auth = "key"` PowerShell 7 with [LibreDevOpsHelpers](https://www.powershellgallery.com/packages/LibreDevOpsHelpers),
which opens each key vault's firewall to the machine only for the key fetch. GitHub's
`ubuntu-latest` image has everything but Ansible.

The identity needs to create and delete a bastion and a public IP in the bastion's resource group,
join the `AzureBastionSubnet`, read the target VMs, and, for `entra`, create and delete role
assignments on them (or hold the sign-in role already, with `login_role.enabled = false`).

## Examples

- [`examples/minimal`](./examples/minimal): an Ubuntu VM and `libre_devops.python`, with Entra ID
  sign-in.
- [`examples/complete`](./examples/complete): the vaulted SSH key, a third scale unit, and two role
  calls chained on one session (`libre_devops.python`, then `libre_devops.mde_linux` on the
  `mde_linux` hosts only).

## Developing

Local work needs **PowerShell 7+** and **[`just`](https://github.com/casey/just)**, because the recipes
wrap the [LibreDevOpsHelpers](https://www.powershellgallery.com/packages/LibreDevOpsHelpers)
PowerShell module (the same engine the `libre-devops/terraform-azure` action runs in CI). Install
just with `brew install just`, or `uv tool add rust-just` then `uv run just <recipe>`.

Run `just` to list recipes: `just validate`, `just scan`, `just test`, `just docs`, and `just plan`,
`just apply`, `just destroy` and `just e2e` against an example. CI also runs `shellcheck` over
`scripts/`. Releasing is `just increment-release [patch|minor|major]`, and the Terraform Registry
picks up the tag.

## Security scan exceptions

This module is scanned with [Trivy](https://github.com/aquasecurity/trivy); HIGH and CRITICAL
findings fail the build. Waivers live in [`.trivyignore.yaml`](./.trivyignore.yaml) and are mirrored
in the table below so the reason is auditable.

| Trivy ID | Resource | Finding | Justification |
|----------|----------|---------|---------------|
| DS-0002 | `**/.terraform/modules/*/tests/e2e/image/Containerfile` | Container image runs as root | Not this module's code: the examples download [terraform-ansible-role](https://github.com/libre-devops/terraform-ansible-role) from git, and with it its end-to-end test fixture, whose SSH hosts run systemd as PID 1 (which must be root). That repo waives the same finding for the same file. |

## Reference

The Requirements, Providers, Inputs, Outputs, and Resources below are generated by `terraform-docs`.
