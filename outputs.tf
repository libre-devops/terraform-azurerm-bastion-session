output "ansible_hosts" {
  description = "Map of target name to how Ansible reaches it through the session, in terraform-ansible-role's hosts shape: pass it straight to that module's hosts. Empty when configure is false."
  value       = local.ansible_hosts
}

output "bastion_name" {
  description = "Name of the bastion the session creates while it is open."
  value       = var.bastion.name
}

output "close_script" {
  description = "Path to the close script. Run it as <close_script> <working_directory> in an always() step after the apply, so a run that failed (and so skipped the close step) still deletes the bastion straight away. It reads the session.json the open step left in the working directory, needs no Terraform state, and does nothing when no session is open."
  value       = abspath("${path.module}/scripts/close.sh")
}

output "configured" {
  description = "Whether this apply opens a session (the configure input)."
  value       = var.configure
}

output "session_json" {
  description = "The session's settings as the scripts read them (BASTION_SESSION), for running the close script on a machine without the working directory: BASTION_SESSION='<session_json>' <close_script>."
  value       = jsonencode(local.session)
}

output "ssh_config_path" {
  description = "Path to the session's ssh_config while it is open: ssh -F <path> <target name> reaches a target by hand."
  value       = "${local.work_dir}/ssh_config"
}

output "working_directory" {
  description = "The session's working directory."
  value       = local.work_dir
}
