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

variable "namespace" {
  type        = string
  description = <<-EOT
    The one namespace, on the manager and on every worker.

    The agent-stack-k8s controller, the launcher pods it creates and the
    workloads those submit all share it, because a LocalQueue is namespaced and
    a workload names its queue from inside its own namespace. It exists on the
    workers too, because MultiKueue mirrors a workload into the namespace it
    came from.

    Here rather than only in generate_manifests.py because the cache bucket
    grants name the workload's service account by namespace, so Terraform and
    the generator have to agree on it. Required rather than defaulted for the
    same reason: a default would be a second place the name is written.
  EOT
}

variable "cache_lifecycle_age_days" {
  type        = number
  default     = 30
  description = <<-EOT
    Days before a compilation cache object is deleted.

    Longer than the four days the bare-metal bucket uses, because the two are
    not alike: this bucket is per region and shared by every shape, so an entry
    is worth more and the whole namespace is only tens of gigabytes.
  EOT
}

variable "models_lifecycle_age_days" {
  type        = number
  default     = 120
  description = <<-EOT
    Days before a cached model object is deleted.

    Longer than the compilation cache, because the two are not alike. A model
    is expensive to fetch and does not change; a compilation entry is cheap to
    recreate and is invalidated by any compiler change.
  EOT
}

variable "image_repositories" {
  type = list(object({
    location   = string
    repository = string
  }))
  description = "Artifact Registry repositories in project_id that manager and worker nodes may pull from. Grants are per repository; a repository absent here is not readable."
  default     = []
}

variable "agent_token_secret_id" {
  type        = string
  description = <<-EOT
    Secret Manager secret holding the Buildkite agent token, in project_id.

    Not created here: it predates this fleet and the bare-metal agents read the
    same one, so Terraform reads it and grants access to it but never owns its
    value. Named rather than defaulted because the grant is scoped to this one
    secret, and a wrong default would be a grant on the wrong thing.
  EOT
}

# The four variables below are read by scripts/generate_manifests.py, not by
# any resource here. They live in the same tfvars so that the cluster and what
# runs on it are described in one place and change in one review, and so that
# `terraform validate` type-checks them.

variable "kueue_version" {
  type        = string
  description = "Kueue release to install, without the leading v. Its manifests are fetched from the GitHub release at deploy time; a tag is immutable, so pinning one pins the bytes."
}

variable "jobset_version" {
  type        = string
  description = "JobSet release to install, without the leading v. Kueue's jobset integration needs the CRD present, so this is installed first."
}

variable "auth_plugin_image" {
  type        = string
  description = "Image the manager's Kueue controller copies its Connect Gateway credential plugin out of. The Google CLI image is the only place Google publishes gke-gcloud-auth-plugin as a container; the binary is static, so it runs in Kueue's distroless image."
}

variable "auth_plugin_source_path" {
  type        = string
  description = "Path to the credential plugin inside auth_plugin_image."
}

variable "worker_clusters" {
  type = list(object({
    # What identifies a worker cluster. Every name it gets is derived from this
    # pair and nothing else, so there is no label to invent and none to keep in
    # step: locals.tf builds the project-scoped names from location alone, and
    # the fleet-wide ones - the Terraform address, the generated directory, the
    # MultiKueueCluster on the manager - from both.
    project  = string
    location = string

    network                = string
    subnetwork             = string
    master_ipv4_cidr_block = string

    system_machine_type = optional(string, "e2-standard-4")
    system_min_nodes    = optional(number, 1)
    system_max_nodes    = optional(number, 3)

    # One per TPU shape this cluster can run. A list rather than a map, because
    # the node pool's name is its shape - <machine type>-<topology>, e.g.
    # ct6e-standard-8t-2x4 - and locals.tf builds it from the two fields below
    # rather than taking it from here, so it cannot name hardware the pool does
    # not have. generate_manifests.py names the shape's Kueue queue the same way.
    tpu_node_pools = optional(list(object({
      # The machine type is the VM, the topology the slice asked of it. Both are
      # needed because a topology does not imply a machine type: 2x4 is eight
      # chips either as one ct6e-standard-8t or as two ct6e-standard-4t, and
      # those differ in pod count, chips per pod and JobSet parallelism.
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

      # This shape's share of the reservation, and the only one of the three
      # counts that no resource here reads: generate_manifests.py turns it into
      # the nominalQuota of the shape's ClusterQueue. Chips a shape can always
      # get, so the shapes cannot starve each other, while the queues sit in
      # one cohort and lend out whatever is idle. Summed across a cluster's
      # pools it should be the chips the reservation actually has free, which
      # is what max_nodes deliberately oversubscribes.
      nominal_nodes = number
    })), [])
  }))
  description = "Worker clusters. location is a region; the cluster pins no zones, because only a TPU node cares which zone it is in and its own node pool pins it there."
  default     = []

  validation {
    condition = alltrue([
      for w in var.worker_clusters :
      length(regexall("^[a-z0-9]+-[a-z0-9]+[0-9]$", w.location)) > 0
    ])
    error_message = "worker_clusters[*].location must be a region, not a zone: a zone here silently gets a zonal control plane, and changing it later rebuilds the cluster."
  }

  # A list has no keys, so nothing here is unique by construction the way a map
  # key would be. locals.tf keys every cluster on this pair, so a repeat does
  # not fail - it drops one of the two clusters, silently. Two clusters in one
  # region are fine; two in one region *and* one project are the same cluster.
  validation {
    condition = length(distinct([
      for w in var.worker_clusters : "${w.project}/${w.location}"
    ])) == length(var.worker_clusters)
    error_message = "Two worker_clusters have the same project and location. A cluster is identified by that pair, so the second would overwrite the first."
  }

  # The pool name is derived, so a repeated shape does not collide loudly the
  # way a repeated map key would - it silently drops one of the two pools.
  validation {
    condition = alltrue([
      for w in var.worker_clusters :
      length(distinct([
        for p in w.tpu_node_pools : "${p.machine_type}-${p.topology}"
      ])) == length(w.tpu_node_pools)
    ])
    error_message = "Two tpu_node_pools in one worker cluster have the same machine type and topology. The node pool is named for that pair, so the second would overwrite the first."
  }
}

