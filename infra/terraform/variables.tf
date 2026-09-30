# Locked decisions (T0/T1). Sizes carry the locked defaults;
# github_token arrives via TF_VAR_github_token env only (T3, JIT).

variable "github_token" {
  description = "Runner registration token (JIT preferred). Unused until T3."
  type        = string
  sensitive   = true
  default     = ""
}

variable "vcpu" {
  description = "Locked runner shape."
  type        = number
  default     = 8
}

variable "memory_kib" {
  description = "Locked runner shape (16 GiB; 0.9 provider takes KiB)."
  type        = number
  default     = 16777216
}

variable "disk_bytes" {
  description = "Locked 60 GB disk."
  type        = number
  default     = 64424509440
}

variable "storage_pool" {
  description = "T0: default pool 41 GB free < 60 GB disk; use iso."
  type        = string
  default     = "iso"
}

variable "image_url" {
  description = "Pinned stock Debian trixie cloud image."
  type        = string
  default     = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
}

variable "image_sha512" {
  description = "Pinned checksum for image_url (SHA512SUMS 2026-09-30)."
  type        = string
  default     = "95e110dfcdbd0ed8a82a75ed9579802f9950cabf51a810dcc6388e81bc778188713878b9f28d583a0ea602fbf48b35996ae9ad37f584166d8fbd6489df248f53"
}
