<!--
  Header for the complete example README. Edit this file, then run `just docs`
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

# Complete example

The fuller surface: Ansible signs in with the admin account's own key, which the ssh-key module
generates ephemerally (never in plan or state) into a deny-by-default key vault, and two
terraform-ansible-role calls are chained on one open session: `libre_devops.python` first, then
`libre_devops.mde_linux` on the hosts in the `mde_linux` group only. The bastion gets a third scale
unit and SSH a longer wait. Pass the runner's egress IP in `key_vault_ip_rules` on every Terraform
step, as azure-orchestration's pipelines do.

With `configure = false` (the default) the apply builds the infrastructure only. The scripts are not
written yet, so leave it false until the module's first release.

[![Terraform Registry](https://img.shields.io/badge/registry-libre--devops-7B42BC?logo=terraform&logoColor=white)](https://registry.terraform.io/namespaces/libre-devops)
