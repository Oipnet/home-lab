variable "zone" {
  description = "Scaleway availability zone"
  type        = string
  default     = "fr-par-1"
}

variable "region" {
  description = "Scaleway region"
  type        = string
  default     = "fr-par"
}

variable "project_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "homelab"
}

variable "control_plane_count" {
  description = "Number of control plane nodes (1 for single master)"
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 3], var.control_plane_count)
    error_message = "Control plane count must be 1 (single master) or 3 (HA)."
  }
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 2
}

variable "control_plane_type" {
  description = "Instance type for control plane nodes"
  type        = string
  default     = "DEV1-S" # 2 vCPU, 2 GB RAM
}

variable "plex_worker_type" {
  description = "Instance type for worker-1 (Plex + stockage local)"
  type        = string
  default     = "DEV1-M" # 3 vCPU, 4 GB RAM
}

variable "worker_type" {
  description = "Instance type pour les workers génériques (worker-2+)"
  type        = string
  default     = "DEV1-S" # 2 vCPU, 2 GB RAM
}

variable "image" {
  description = "OS image for all nodes"
  type        = string
  default     = "ubuntu_jammy" # Ubuntu 22.04 LTS
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key for node access"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

# Networking
variable "plex_wireguard_cidr" {
  description = "WireGuard subnet for external Plex access VPN (wg1)"
  type        = string
  default     = "10.201.0.0/24"
}

variable "allowed_ssh_cidrs" {
  description = "CIDRs allowed to SSH into nodes"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "plex_data_path" {
  description = "Absolute path on the plex worker node for persistent storage"
  type        = string
  default     = "/data/plex"
}
