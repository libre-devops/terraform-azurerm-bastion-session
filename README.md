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

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11.0, < 2.0.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [terraform_data.close](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [terraform_data.open](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_auth"></a> [auth](#input\_auth) | How Ansible signs in to the targets: entra (a short-lived Entra ID OpenSSH certificate for the<br/>identity running Terraform, issued with az ssh config) or key (each target's own private key,<br/>fetched from the Key Vault secret in its ssh\_key\_secret\_id and signed in as its user). For key,<br/>the vault's firewall is opened to this machine only for the fetch, with LibreDevOpsHelpers'<br/>Add-LdoKeyVaultCurrentIpRule and Remove-LdoKeyVaultCurrentIpRule (needs PowerShell 7). | `string` | `"entra"` | no |
| <a name="input_bastion"></a> [bastion](#input\_bastion) | The bastion the session creates when it opens and deletes when it closes. It is never in<br/>Terraform state. subnet\_id is the virtual network's AzureBastionSubnet, which the calling stack<br/>keeps (a subnet costs nothing). The public IP is public\_ip\_name (default pip-<name>). sku is<br/>Standard or Premium, the SKUs with native client tunnelling. ip\_connect\_enabled lets targets be<br/>given by private IP address (peered or on-premises machines; SSH on port 22 only). | <pre>object({<br/>    name                = string<br/>    resource_group_name = string<br/>    location            = string<br/>    subnet_id           = string<br/>    public_ip_name      = optional(string)<br/>    sku                 = optional(string, "Standard")<br/>    scale_units         = optional(number, 2)<br/>    ip_connect_enabled  = optional(bool, false)<br/>    tags                = optional(map(string), {})<br/>  })</pre> | n/a | yes |
| <a name="input_close_after"></a> [close\_after](#input\_close\_after) | Something from every module call that runs through the session, such as<br/>[module.python[*].run\_ids, module.mde\_linux[*].run\_ids]. The session closes (the bastion is<br/>deleted) only once all of it is known, which is after those runs have finished. Leave a call out<br/>and the bastion can close while that call is still running. | `any` | `null` | no |
| <a name="input_configure"></a> [configure](#input\_configure) | Open a session in this apply. When true, the apply creates the bastion, the role runs that use<br/>ansible\_hosts go through it, and the bastion is deleted once they finish (see close\_after).<br/>When false (the default), nothing is created, ansible\_hosts is empty, and the apply is an<br/>ordinary infrastructure apply. terraform-ansible-role needs at least one host, so give each<br/>role call count = <the same value> rather than an empty hosts map. | `bool` | `false` | no |
| <a name="input_login_role"></a> [login\_role](#input\_login\_role) | Grant the identity running Terraform an Entra ID sign-in role on each target for the length of<br/>the session (entra sign-in only), and remove it when the session closes. Virtual Machine<br/>Administrator Login gives the passwordless sudo that become needs; Virtual Machine User Login<br/>does not. A new assignment can take a minute or two to apply, which ready\_timeout allows for.<br/>Set enabled = false when the identity already holds a standing role. | <pre>object({<br/>    enabled   = optional(bool, true)<br/>    role_name = optional(string, "Virtual Machine Administrator Login")<br/>  })</pre> | `{}` | no |
| <a name="input_name"></a> [name](#input\_name) | Name of the session, used for its working directory. Unique per module call in a root module. | `string` | n/a | yes |
| <a name="input_ready_timeout"></a> [ready\_timeout](#input\_ready\_timeout) | Seconds to wait, once the bastion is up, for SSH to answer through it on every target (a new sign-in role takes a while to apply). | `number` | `300` | no |
| <a name="input_targets"></a> [targets](#input\_targets) | The machines to reach, keyed by the inventory name they get in ansible\_hosts. Each entry: id<br/>(the VM's resource ID; the bastion reaches VMs in its own and peered virtual networks), or<br/>ip\_address instead when bastion.ip\_connect\_enabled is true; groups (inventory groups); port<br/>(default 22); for key sign-in, user and ssh\_key\_secret\_id (the Key Vault secret holding the<br/>private key, such as the ssh-key module's private\_key\_secret\_versionless\_ids); and triggers<br/>(values, such as the VM's ID, passed on to terraform-ansible-role so a replaced VM is<br/>configured again with a clean known\_hosts). | <pre>map(object({<br/>    id                = optional(string)<br/>    ip_address        = optional(string)<br/>    groups            = optional(list(string), [])<br/>    port              = optional(number, 22)<br/>    user              = optional(string)<br/>    ssh_key_secret_id = optional(string)<br/>    triggers          = optional(map(string), {})<br/>  }))</pre> | n/a | yes |
| <a name="input_tunnel_timeout"></a> [tunnel\_timeout](#input\_tunnel\_timeout) | Most seconds a target's tunnel stays open (az network bastion tunnel --timeout). One tunnel carries every connection to its target for the whole session, so make this longer than the role runs take: a tunnel that reaches it drops its connections (the next connection starts a new one). It is the backstop that stops a tunnel outliving a session whose close step never ran. | `number` | `7200` | no |
| <a name="input_working_directory"></a> [working\_directory](#input\_working\_directory) | Directory for the session's SSH config, certificate or keys and tunnel logs while it is open. Default: .terraform/bastion-session/<name> in the root module, which Git already ignores. Closing the session removes them. | `string` | `null` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_ansible_hosts"></a> [ansible\_hosts](#output\_ansible\_hosts) | Map of target name to how Ansible reaches it through the session, in terraform-ansible-role's hosts shape: pass it straight to that module's hosts. Empty when configure is false. |
| <a name="output_bastion_name"></a> [bastion\_name](#output\_bastion\_name) | Name of the bastion the session creates while it is open. |
| <a name="output_close_script"></a> [close\_script](#output\_close\_script) | Path to the close script. Run it as <close\_script> <working\_directory> in an always() step after the apply, so a run that failed (and so skipped the close step) still deletes the bastion straight away. It reads the session.json the open step left in the working directory, needs no Terraform state, and does nothing when no session is open. |
| <a name="output_configured"></a> [configured](#output\_configured) | Whether this apply opens a session (the configure input). |
| <a name="output_session_json"></a> [session\_json](#output\_session\_json) | The session's settings as the scripts read them (BASTION\_SESSION), for running the close script on a machine without the working directory: BASTION\_SESSION='<session\_json>' <close\_script>. |
| <a name="output_ssh_config_path"></a> [ssh\_config\_path](#output\_ssh\_config\_path) | Path to the session's ssh\_config while it is open: ssh -F <path> <target name> reaches a target by hand. |
| <a name="output_working_directory"></a> [working\_directory](#output\_working\_directory) | The session's working directory. |
<!-- END_TF_DOCS -->
