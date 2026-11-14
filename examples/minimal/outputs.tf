output "bastion_name" {
  description = "Name of the bastion the session creates while it is open."
  value       = module.bastion_session.bastion_name
}

output "configured" {
  description = "Whether this apply opened a session and ran the roles."
  value       = module.bastion_session.configured
}

output "vm_ids" {
  description = "Map of VM name to VM id."
  value       = module.linux_vm.ids
}
