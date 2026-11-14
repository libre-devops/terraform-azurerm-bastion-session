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
  roles              = [{ name = "libre_devops.mde_linux", version = "1.1.0" }]
  hosts              = module.bastion_session.ansible_hosts
  wait_for_ssh       = false
  run_on_every_apply = true

  depends_on = [module.python] # leave out to run the two calls in parallel
}
```

## How it works

| Step | What happens |
|---|---|
| Open | `terraform_data.open` runs [`scripts/open.sh`](./scripts/open.sh). It grants the identity running Terraform the Entra ID sign-in role on each target (`auth = "entra"`; first, so the grant has the bastion's creation time to apply) or fetches each target's vaulted key (`auth = "key"`). It creates the public IP and a Standard (or Premium) bastion with native client tunnelling in the stack's `AzureBastionSubnet` with `az`, issues a short-lived Entra ID certificate, writes the session's `ssh_config`, and waits until SSH signs in through the bastion on every target. |
| Run | Every `terraform-ansible-role` call given `ansible_hosts` runs through the session, in parallel or chained with `depends_on`. Each SSH connection goes through [`scripts/proxy.sh`](./scripts/proxy.sh), the `ProxyCommand` in `ssh_config`, which relays it to the target's tunnel: one `az network bastion tunnel` per target, started by the first connection and shared by the rest. (Starting a tunnel takes several seconds, longer than the 10 seconds Ansible gives SSH to connect, so a tunnel per connection would time out.) A tunnel that dies is started again, and the Entra ID certificate is renewed before it expires, so long runs keep working. |
| Close | `terraform_data.close` runs [`scripts/close.sh`](./scripts/close.sh) once everything in `close_after` is known, which is after the runs finish. It stops the tunnels, removes the role assignments, deletes the bastion and its public IP, and removes the `ssh_config`, certificate and keys. |

**Why the bastion is not a Terraform resource.** Terraform cannot create and delete the same
resource in one apply, which is what forced the old pattern of two applies (open the window, run
Ansible, apply again to close it). Created and deleted by the scripts instead, the bastion is never
in state, so one apply does all three steps, and an apply with `configure = false` has nothing to
change: no bastion, nothing billed, and plans that can say "No changes".

**Why the role calls take `count`.** `terraform-ansible-role` needs at least one host, and
`ansible_hosts` is empty when `configure` is false, so each call is switched off with the same value.
The first `configure = false` apply after a configure run shows those runs being removed; that
changes nothing on the VMs.

**When a run fails.** If the open step itself fails, `open.sh` runs `close.sh` before it exits,
so nothing it created is left. (It has to: Terraform marks a failed open step tainted, and does not
run a tainted resource's destroy-time provisioner.) A role run that fails is different. Terraform
has no "finally", so the apply stops before the close step and the bastion stays up. Three things
close it:

- **The next apply.** Destroying the open step runs `close.sh` first, and every later apply destroys
  it: one with `configure = true` replaces it, and one with `configure = false` (or a
  `terraform destroy`) removes it. After a clean run that finds nothing to do in a few seconds.
- **An `always()` step in CI**, straight after the apply, so the bastion does not wait for the next
  apply:

  ```yaml
  - name: Close the bastion session
    if: always()
    working-directory: stacks/my-stack
    run: .terraform/modules/bastion_session/scripts/close.sh .terraform/bastion-session/base
  ```

  `close.sh <working directory>` reads the `session.json` the open step left there, so it needs no
  Terraform state (or state storage firewall), and it does nothing when no session is open. The
  `close_script` and `working_directory` outputs give both paths.
- **A scheduled sweeper**, for a run cancelled so hard that Terraform never recorded the open step.

`close.sh` only deletes a bastion and public IP tagged `BastionSession = <name>` and role
assignments whose description is `BastionSession=<name>`, so it never touches anything the session
did not create. For the same reason `open.sh` refuses to start if a bastion with the session's name
exists without that tag.

## Requirements on the machine running Terraform

Linux (or WSL): the scripts use `setsid` and `flock`, which macOS does not have. On it:

- the Azure CLI, signed in (`az login`, or `azure/login` in CI). `open.sh` adds the `bastion` and
  `ssh` extensions if they are missing.
- bash, `jq`, `python3`, `ssh` and `ssh-keygen`, and `ansible-core` for terraform-ansible-role.
- for `auth = "key"`, PowerShell 7 with [LibreDevOpsHelpers](https://www.powershellgallery.com/packages/LibreDevOpsHelpers)
  (installed from PSGallery if it is missing), which opens each key vault's firewall to the machine
  only for the key fetch.

GitHub's `ubuntu-latest` image has everything but Ansible.

**GitHub Actions with OIDC.** `azure/login` (and the terraform-azure action) signs the Azure CLI in
with a GitHub ID token that Entra ID accepts for five minutes. Terraform's own provider fetches a
new one whenever it needs to, but the CLI cannot: it keeps working on the access tokens it already
holds, and the first new one it needs fails with `AADSTS700024`. For the session that is the Entra
ID certificate, 15 or more minutes into the apply. So when the CLI is a service principal signed in
with a federated token and the job has `id-token: write`, the scripts sign it in again with a fresh
GitHub ID token: when the session opens, before the certificate is issued, every 45 minutes while
it is open (for the tunnels' access tokens), and when it closes. Any other sign-in is left alone.

The identity needs to create and delete a bastion and a public IP in the bastion's resource group,
join the `AzureBastionSubnet`, and read the target VMs. For `entra` it also needs to create and
delete role assignments on them (Role Based Access Control Administrator, User Access Administrator
or Owner), or to hold the sign-in role already, with `login_role.enabled = false`. For `key` it
needs Get on the vaults' secrets and the right to change their network rules.

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
