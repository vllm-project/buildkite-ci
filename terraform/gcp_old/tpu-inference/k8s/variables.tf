variable "project_id" {
  type        = string
  description = "GCP project holding the manager cluster."
}

variable "name_prefix" {
  type        = string
  description = "Prefix for created resources."
  default     = "tpu-ci"
}

variable "network" {
  type        = string
  description = "Self link of the network the manager cluster sits on."
}

variable "manager_region" {
  type        = string
  description = "Region for the manager cluster. Regional, not zonal: the control plane is the only thing every TPU lane depends on, and a zonal one goes away during a zone's maintenance."
}

variable "manager_subnetwork" {
  type        = string
  description = "Self link of the subnetwork for manager nodes."
}

variable "manager_master_ipv4_cidr_block" {
  type        = string
  description = "RFC1918 /28 for the manager control plane. Must not overlap any worker cluster's block, because the manager peers with all of them."
}

variable "labels" {
  type        = map(string)
  description = "Labels applied to every resource that takes them."
  default     = {}
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "release_channel" {
  type    = string
  default = "REGULAR"
}

variable "enable_private_endpoint" {
  type        = bool
  description = "Whether the control plane is reachable only from inside the VPC. False while the cluster is administered from laptops and from Buildkite agents that live outside it."
  default     = false
}

variable "image_repositories" {
  type = list(object({
    location   = string
    repository = string
  }))
  description = "Artifact Registry repositories in project_id that manager and worker nodes may pull from. Grants are per repository; a repository absent here is not readable."
  default     = []
}

variable "worker_clusters" {
  type = map(object({
    project                = string
    location               = string
    network                = string
    subnetwork             = string
    master_ipv4_cidr_block = string

    system_machine_type = optional(string, "e2-standard-4")
    system_min_nodes    = optional(number, 1)
    system_max_nodes    = optional(number, 3)

    # One per TPU shape this cluster can run, keyed by node pool name. Names
    # have to be unique across all clusters, not just within one, because the
    # pools are flattened into a single map to create them.
    tpu_node_pools = optional(map(object({
      # The machine type is the VM, the topology the slice asked of it. Matching
      # shapes mean one VM holds the whole slice; a larger topology means one
      # slice across several, which GKE only builds from a placement policy.
      machine_type = string
      topology     = string

      reservation_name = string
      # The reservation is zonal and the cluster pins no zones, so this is the
      # only thing keeping a node out of a zone that cannot serve it.
      zone = string

      # Scale-down floor: nodes this shape keeps once it has booted them. Those
      # chips are unavailable to the other shapes from then on, idle or not.
      min_nodes = number
      # Above this pool's share of the reservation, so the shapes compete for
      # free chips; the reservation running out is what stops a scale-up.
      max_nodes = number
    })), {})
  }))
  description = "Worker clusters keyed by a short name. location is a region; the cluster pins no zones, because only a TPU node cares which zone it is in and its own node pool pins it there."
  default     = {}

  validation {
    condition = alltrue([
      for name, w in var.worker_clusters :
      length(regexall("^[a-z0-9]+-[a-z0-9]+[0-9]$", w.location)) > 0
    ])
    error_message = "worker_clusters[*].location must be a region, not a zone: a zone here silently gets a zonal control plane, and changing it later rebuilds the cluster."
  }
}

