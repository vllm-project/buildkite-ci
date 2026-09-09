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
  }))
  description = "Worker clusters keyed by a short name. location is a region; the cluster pins no zones, because only a TPU node cares which zone it is in and the compute class that asks for one pins it there."
  default     = {}

  validation {
    condition = alltrue([
      for name, w in var.worker_clusters :
      length(regexall("^[a-z0-9]+-[a-z0-9]+[0-9]$", w.location)) > 0
    ])
    error_message = "worker_clusters[*].location must be a region, not a zone: a zone here silently gets a zonal control plane, and changing it later rebuilds the cluster."
  }
}

# Declared so prod.auto.tfvars can hold it, but read by scripts/, not by any
# resource here. The clusters and the objects inside them come from one file:
# a ComputeClass names a worker key and a reservation, and keeping that beside
# the cluster it belongs to is what stops the two drifting.
variable "tpu_compute_classes" {
  type = map(object({
    # Key of the worker_clusters entry this belongs to.
    worker = string

    # GKE's accelerator type, "tpu-v6e-slice" for Trillium. With count and
    # topology this is the whole shape request; GKE picks the machine type.
    accelerator_type = string
    # Chips on one node. A slice's chips divided by this is how many nodes GKE
    # puts in it, so the pair is what decides single- or multi-host.
    chips_per_node = number
    topology       = string

    reservation_name    = string
    reservation_project = optional(string)
    # The reservation is zonal, and this is the only zone pinning in the lane -
    # the cluster deliberately has none.
    zones = list(string)

    # Guaranteed capacity for this shape, in nodes. Read by the Kueue
    # generator, not a floor GKE holds.
    nominal_nodes = number
  }))
  description = "TPU shapes a worker can provision on demand, one ComputeClass each."
  default     = {}
}
