output "resource_group_name" {
  description = "Disposable resource group containing only this lab's resources."
  value       = azurerm_resource_group.lab.name
}

output "source_storage_account_name" {
  description = "Premium classic FileStorage account hosting the Azure Files NFS test and restore shares."
  value       = azurerm_storage_account.source.name
}

output "source_share_name" {
  description = "Azure Files NFS share to seed and snapshot."
  value       = azurerm_storage_share.source.name
}

output "restore_share_name" {
  description = "Separate Azure Files NFS share used only for restore verification."
  value       = azurerm_storage_share.restore.name
}

output "destination_storage_account_name" {
  description = "HNS-enabled storage account containing timestamped recovery-point archives."
  value       = azurerm_storage_account.destination.name
}

output "destination_container_name" {
  description = "Private container for NFS recovery points and manifests."
  value       = azurerm_storage_container.recovery_points.name
}

output "worker_vm_name" {
  description = "Linux NFS backup worker; run operations using Azure Run Command, not inbound SSH."
  value       = azurerm_linux_virtual_machine.worker.name
}

output "worker_user_assigned_identity_client_id" {
  description = "Managed identity client ID used for the Blob destination and share snapshot management operations."
  value       = azurerm_user_assigned_identity.worker.client_id
}

output "lab_resource_group_id" {
  description = "Resource group ID for a reviewed, explicit destroy operation."
  value       = azurerm_resource_group.lab.id
}
