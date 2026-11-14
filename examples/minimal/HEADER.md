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
