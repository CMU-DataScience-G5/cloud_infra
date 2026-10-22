variable "project_id" {
  description = "GCP project ID (billing must be enabled)."
  type        = string
}

variable "region" {
  description = "Region for the VPC, buckets and Artifact Registry."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Zone for the (zonal) GKE cluster. Must offer the chosen GPU type."
  type        = string
  default     = "us-central1-a"
}

variable "name_prefix" {
  description = "Prefix for every resource name."
  type        = string
  default     = "ctseg"
}

# ---------------------------------------------------------------- GKE

variable "system_machine_type" {
  description = "Machine type for the CPU pool (gateway, controller, Prometheus/Grafana, EFK)."
  type        = string
  default     = "e2-standard-4"
}

variable "system_min_nodes" {
  type    = number
  default = 2
}

variable "system_max_nodes" {
  type    = number
  default = 4
}

variable "gpu_type" {
  description = "Accelerator type, e.g. nvidia-l4, nvidia-tesla-t4, nvidia-tesla-a100."
  type        = string
  default     = "nvidia-l4"
}

variable "gpu_machine_type" {
  description = "Machine type for the GPU pool. Must be compatible with gpu_type (g2-* for L4, n1-* for T4, a2-* for A100)."
  type        = string
  default     = "g2-standard-8"
}

variable "gpu_zones" {
  description = "Zones (same region) the GPU pool may use. Empty = just var.zone. List several to survive single-zone GPU stockouts."
  type        = list(string)
  default     = []
}

variable "gpu_count_per_node" {
  type    = number
  default = 1
}

variable "gpu_min_nodes" {
  description = "Set to 0 and scale Triton to 0 replicas to stop paying for GPUs when idle."
  type        = number
  default     = 0
}

variable "gpu_max_nodes" {
  type    = number
  default = 2
}

variable "gpu_spot" {
  description = "Use Spot VMs for the GPU pool (~60-70% cheaper, can be preempted)."
  type        = bool
  default     = false
}

variable "master_authorized_cidrs" {
  description = "CIDRs allowed to reach the GKE control plane. Empty = any (still requires IAM auth)."
  type        = list(string)
  default     = []
}

variable "deletion_protection" {
  description = "Protect the GKE cluster from terraform destroy."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------- Storage

variable "data_retention_days" {
  description = "Delete uploaded CT volumes and masks after this many days (0 = keep forever)."
  type        = number
  default     = 30
}

variable "force_destroy_buckets" {
  description = "Allow terraform destroy to delete non-empty buckets."
  type        = bool
  default     = false
}
