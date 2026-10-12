locals {
  tags = merge(var.tags, {
    environment = "lab"
    workload    = "nfs-long-term-backup"
    managed-by  = "terraform"
    purpose     = "disposable-nfs-backup-lab"
  })

  source_account_name      = "stnfsbksrc${var.storage_name_suffix}"
  destination_account_name = "stnfsbkdst${var.storage_name_suffix}"

  private_dns_zone_names = {
    file = "privatelink.file.core.windows.net"
    blob = "privatelink.blob.core.windows.net"
    dfs  = "privatelink.dfs.core.windows.net"
  }
}

resource "azurerm_resource_group" "lab" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "lab" {
  name                = "vnet-nfsbackup-lab-sea-001"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  address_space       = ["10.78.0.0/16"]
  tags                = local.tags
}

resource "azurerm_subnet" "worker" {
  name                 = "snet-nfsbackup-vm-sea-001"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = ["10.78.1.0/24"]
}

resource "azurerm_subnet" "private_endpoints" {
  name                              = "snet-nfsbackup-pe-sea-001"
  resource_group_name               = azurerm_resource_group.lab.name
  virtual_network_name              = azurerm_virtual_network.lab.name
  address_prefixes                  = ["10.78.2.0/27"]
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_network_security_group" "worker" {
  name                = "nsg-nfsbackup-vm-sea-001"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = local.tags
}

resource "azurerm_network_security_rule" "deny_worker_inbound" {
  name                        = "DenyAllInbound"
  priority                    = 4096
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.lab.name
  network_security_group_name = azurerm_network_security_group.worker.name
}

resource "azurerm_user_assigned_identity" "worker" {
  name                = "id-nfsbackup-worker-sea-001"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = local.tags
}

resource "azurerm_storage_account" "source" {
  name                     = local.source_account_name
  resource_group_name      = azurerm_resource_group.lab.name
  location                 = azurerm_resource_group.lab.location
  account_kind             = "FileStorage"
  account_tier             = "Premium"
  account_replication_type = "LRS"

  public_network_access           = "Disabled"
  shared_access_key_enabled       = false
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  local_user_enabled              = false
  default_to_oauth_authentication = true

  tags = local.tags
}

resource "azurerm_storage_share" "source" {
  name               = var.source_share_name
  storage_account_id = azurerm_storage_account.source.id
  quota              = var.source_share_quota_gib
  access_tier        = "Premium"
  enabled_protocol   = "NFS"
}

resource "azurerm_storage_share" "restore" {
  name               = "nfsbackup-restore"
  storage_account_id = azurerm_storage_account.source.id
  quota              = var.source_share_quota_gib
  access_tier        = "Premium"
  enabled_protocol   = "NFS"
}

resource "azurerm_storage_account" "destination" {
  name                     = local.destination_account_name
  resource_group_name      = azurerm_resource_group.lab.name
  location                 = azurerm_resource_group.lab.location
  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = "LRS"
  access_tier              = "Hot"

  is_hns_enabled                  = true
  public_network_access           = "Disabled"
  shared_access_key_enabled       = false
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  local_user_enabled              = false
  default_to_oauth_authentication = true

  tags = local.tags
}

resource "azurerm_storage_container" "recovery_points" {
  name                  = "nfs-backup-points"
  storage_account_id    = azurerm_storage_account.destination.id
  container_access_type = "private"
}

resource "azurerm_storage_management_policy" "recovery_point_retention" {
  storage_account_id = azurerm_storage_account.destination.id

  rule {
    name    = "delete-recovery-points-after-retention"
    enabled = true

    filters {
      prefix_match = ["recovery-points/"]
      blob_types   = ["blockBlob"]
    }

    actions {
      base_blob {
        delete_after_days_since_creation_greater_than = var.retention_days
      }
    }
  }
}

resource "azurerm_private_dns_zone" "storage" {
  for_each            = local.private_dns_zone_names
  name                = each.value
  resource_group_name = azurerm_resource_group.lab.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "storage" {
  for_each             = azurerm_private_dns_zone.storage
  name                 = "link-nfsbackup-${each.key}-sea-001"
  private_dns_zone_id  = each.value.id
  virtual_network_id   = azurerm_virtual_network.lab.id
  registration_enabled = false
  tags                 = local.tags
}

resource "azurerm_private_endpoint" "source_file" {
  name                = "pep-nfsbackup-source-file-sea-001"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-nfsbackup-source-file"
    private_connection_resource_id = azurerm_storage_account.source.id
    subresource_names              = ["file"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.storage["file"].id]
  }
}

resource "azurerm_private_endpoint" "destination_blob" {
  name                = "pep-nfsbackup-dest-blob-sea-001"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-nfsbackup-dest-blob"
    private_connection_resource_id = azurerm_storage_account.destination.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.storage["blob"].id]
  }
}

resource "azurerm_private_endpoint" "destination_dfs" {
  name                = "pep-nfsbackup-dest-dfs-sea-001"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-nfsbackup-dest-dfs"
    private_connection_resource_id = azurerm_storage_account.destination.id
    subresource_names              = ["dfs"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.storage["dfs"].id]
  }
}

resource "azurerm_role_definition" "worker_snapshot_operator" {
  name        = "NFS Backup Lab Snapshot Operator ${var.storage_name_suffix}"
  scope       = azurerm_resource_group.lab.id
  description = "Allows the lab worker to create and enumerate Azure Files NFS share snapshots through the management plane."

  permissions {
    actions = [
      "Microsoft.Storage/storageAccounts/read",
      "Microsoft.Storage/storageAccounts/fileServices/shares/read",
      "Microsoft.Storage/storageAccounts/fileServices/shares/write"
    ]
    not_actions = []
  }

  assignable_scopes = [azurerm_resource_group.lab.id]
}

resource "azurerm_role_assignment" "worker_source_snapshot_operator" {
  scope                            = azurerm_storage_account.source.id
  role_definition_id               = azurerm_role_definition.worker_snapshot_operator.role_definition_resource_id
  principal_id                     = azurerm_user_assigned_identity.worker.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "worker_destination_blob_data" {
  scope                            = azurerm_storage_account.destination.id
  role_definition_name             = "Storage Blob Data Contributor"
  principal_id                     = azurerm_user_assigned_identity.worker.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_public_ip" "worker_egress" {
  name                = "pip-nfsbackup-egress-sea-001"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_network_interface" "worker" {
  name                = "nic-nfsbackup-worker-sea-001"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = local.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.worker.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.worker_egress.id
  }
}

resource "azurerm_network_interface_security_group_association" "worker" {
  network_interface_id      = azurerm_network_interface.worker.id
  network_security_group_id = azurerm_network_security_group.worker.id
}

resource "azurerm_log_analytics_workspace" "lab" {
  name                         = "log-nfsbackup-lab-sea-001"
  location                     = azurerm_resource_group.lab.location
  resource_group_name          = azurerm_resource_group.lab.name
  sku                          = "PerGB2018"
  retention_in_days            = 30
  local_authentication_enabled = false
  tags                         = local.tags
}

resource "azurerm_linux_virtual_machine" "worker" {
  name                            = "vm-nfsbackup-worker-sea-001"
  resource_group_name             = azurerm_resource_group.lab.name
  location                        = azurerm_resource_group.lab.location
  size                            = var.vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.worker.id]
  encryption_at_host_enabled      = false
  secure_boot_enabled             = true
  vtpm_enabled                    = true
  custom_data = base64encode(templatefile("${path.module}/cloud-init.yaml.tftpl", {
    source_account_name      = local.source_account_name
    destination_account_name = local.destination_account_name
    source_share_name        = azurerm_storage_share.source.name
    restore_share_name       = azurerm_storage_share.restore.name
    destination_container    = azurerm_storage_container.recovery_points.name
    subscription_id          = var.subscription_id
    resource_group_name      = azurerm_resource_group.lab.name
    worker_client_id         = azurerm_user_assigned_identity.worker.client_id
    seed_total_gib           = var.seed_total_gib
    backup_script_b64        = base64encode(file("${path.module}/../scripts/backup.sh"))
    restore_script_b64       = base64encode(file("${path.module}/../scripts/restore-test.sh"))
    seed_script_b64          = base64encode(file("${path.module}/../scripts/seed-test-data.sh"))
    manifest_script_b64      = base64encode(file("${path.module}/../scripts/manifest.py"))
    snapshot_script_b64      = base64encode(file("${path.module}/../scripts/create-snapshot.ps1"))
    stage_script_b64         = base64encode(file("${path.module}/../scripts/prepare-stage.sh"))
    mount_script_b64         = base64encode(file("${path.module}/../scripts/mount-nfs.sh"))
  }))

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.admin_ssh_public_key
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.worker.id]
  }

  os_disk {
    name                 = "osdisk-nfsbackup-worker-sea-001"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 64
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  boot_diagnostics {}
  tags = local.tags

  depends_on = [
    azurerm_role_assignment.worker_source_snapshot_operator,
    azurerm_role_assignment.worker_destination_blob_data
  ]
}

resource "azurerm_managed_disk" "stage" {
  name                          = "disk-nfsbackup-stage-sea-001"
  location                      = azurerm_resource_group.lab.location
  resource_group_name           = azurerm_resource_group.lab.name
  storage_account_type          = "StandardSSD_LRS"
  create_option                 = "Empty"
  disk_size_gb                  = var.stage_disk_size_gib
  network_access_policy         = "DenyAll"
  public_network_access_enabled = false
  tags                          = local.tags
}

resource "azurerm_virtual_machine_data_disk_attachment" "stage" {
  managed_disk_id    = azurerm_managed_disk.stage.id
  virtual_machine_id = azurerm_linux_virtual_machine.worker.id
  lun                = 0
  caching            = "ReadWrite"
}

resource "azurerm_monitor_diagnostic_setting" "worker_metrics" {
  name                       = "diag-nfsbackup-worker-metrics"
  target_resource_id         = azurerm_linux_virtual_machine.worker.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.lab.id

  enabled_metric {
    category = "AllMetrics"
  }
}
