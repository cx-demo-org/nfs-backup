variable "subscription_id" {
  description = "Subscription that contains only this isolated NFS backup lab."
  type        = string
}

variable "location" {
  description = "Azure region for the lab."
  type        = string
  default     = "southeastasia"
}

variable "resource_group_name" {
  description = "Dedicated disposable resource group for this lab."
  type        = string
  default     = "rg-nfsbackup-lab-change-me"
}

variable "storage_name_suffix" {
  description = "Globally unique lowercase alphanumeric suffix for both storage accounts (4-8 characters)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{4,8}$", var.storage_name_suffix))
    error_message = "storage_name_suffix must contain 4-8 lowercase letters or digits."
  }
}

variable "source_share_name" {
  description = "Disposable Azure Files NFS test share name."
  type        = string
  default     = "nfsbackup-lab"
}

variable "source_share_quota_gib" {
  description = "Provisioned capacity for the premium NFS share. Keep at least 128 GiB for the 28 GiB lab dataset."
  type        = number
  default     = 128

  validation {
    condition     = var.source_share_quota_gib >= 101 && var.source_share_quota_gib <= 102400
    error_message = "Premium Azure Files NFS share quota must be greater than 100 GiB and no more than 102400 GiB."
  }
}

variable "stage_disk_size_gib" {
  description = "Linux worker staging disk size. The 128 GiB default is for the 28 GiB lab, not a 1 TiB production dataset."
  type        = number
  default     = 128

  validation {
    condition     = var.stage_disk_size_gib >= 64 && var.stage_disk_size_gib <= 32767
    error_message = "stage_disk_size_gib must be between 64 and 32767 GiB."
  }
}

variable "seed_total_gib" {
  description = "Approximate synthetic source dataset size for the representative NFS test. This does not imply 1-TiB production readiness."
  type        = number
  default     = 28

  validation {
    condition     = var.seed_total_gib >= 1 && var.seed_total_gib <= 100
    error_message = "seed_total_gib must be between 1 and 100 GiB for this disposable lab."
  }
}

variable "retention_days" {
  description = "Blob lifecycle expiry for lab recovery-point objects. This is not immutable/WORM retention."
  type        = number
  default     = 30

  validation {
    condition     = var.retention_days >= 1 && var.retention_days <= 36500
    error_message = "retention_days must be between 1 and 36500."
  }
}

variable "vm_size" {
  description = "Linux backup worker VM SKU."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "admin_username" {
  description = "Non-root Linux VM administrator account. No inbound SSH rule is created."
  type        = string
  default     = "backupadmin"
}

variable "admin_ssh_public_key" {
  description = "SSH public key installed on the VM. The NSG has no SSH ingress; use Azure Run Command for the lab."
  type        = string
  sensitive   = true
}

variable "tags" {
  description = "Additional cost attribution tags."
  type        = map(string)
  default     = {}
}
