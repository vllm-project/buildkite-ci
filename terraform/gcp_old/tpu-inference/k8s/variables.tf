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

variable "manager_bootstrap_machine_type" {
  type        = string
  description = "Machine type for the default node pool GKE insists on creating and that remove_default_node_pool then deletes. Nothing is ever scheduled on it; it is named only so that the create does not fail on whichever family is short in the region."
  default     = "n2-standard-2"
}

variable "manager_max_cpu" {
  type        = number
  description = "Ceiling on vCPUs auto-provisioning may create across the manager. Bounded by the Buildkite controller's in-flight limit rather than by any TPU quota: a launcher pod waiting for chips occupies a node without holding any."
  default     = 128
}

variable "manager_max_memory_gb" {
  type        = number
  description = "Ceiling on memory auto-provisioning may create across the manager. Generous against the CPU ceiling, so that the family fallback is free to land on a memory-heavy shape when the balanced ones are short."
  default     = 512
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

variable "analytics_token_secret_project" {
  type        = string
  description = "Project holding the Buildkite Test Engine token. Not this one: it belongs to the suite, which predates this fleet and is shared with the bare-metal lane."
}

variable "hf_token_secret_project" {
  type        = string
  description = "Project holding the Hugging Face token. Not this one: it belongs to the bare-metal agents, and a gated model should be fetched under the same identity in both lanes."
}

variable "hf_token_secret_id" {
  type        = string
  description = <<-EOT
    Secret Manager secret holding the Hugging Face token.

    Read by the launcher pod and forwarded into the workload, since the pod
    that downloads the weights is the only one that needs it.

    Named rather than defaulted because the grant is scoped to this one secret.
  EOT
}

variable "git_ssh_key_secret_id" {
  type        = string
  description = <<-EOT
    Secret Manager secret in project_id holding the SSH deploy key for the
    private repositories this fleet builds.

    Synced into the manager's namespace and read by the checkout container of
    every agent pod; a public repository ignores it. Its algorithm is part of
    the contract - see GIT_SSH_KEY_ENV in scripts/generate_manifests.py - so
    replacing it with a key of another type is a change in two places.
  EOT
}

variable "analytics_token_secret_id" {
  type        = string
  description = <<-EOT
    Secret Manager secret holding the Buildkite Test Engine token.

    Read by the launcher pod and forwarded into the workload, since a TPU pod
    is the only thing that can see its own test output.

    Named rather than defaulted because the grant is scoped to this one secret.
  EOT
}

# The ten variables below are read by scripts/generate_manifests.py, not by
# any resource here. They live in the same tfvars so that the cluster and what
# runs on it are described in one place and change in one review, and so that
# `terraform validate` type-checks them.
#
# None of them has a default, and none should: the generator reads the tfvars
# file rather than this schema, so a default would be a value Terraform sees
# and the generator does not.

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

variable "agent_stack_version" {
  type        = string
  description = "agent-stack-k8s chart to install, without the leading v. Rendered with `helm template` at deploy time and applied like any other manifest; a chart version is immutable, so pinning one pins the bytes."
}

variable "buildkite_queue" {
  type        = string
  description = <<-EOT
    Buildkite queue the controller claims jobs from.

    One queue for the whole fleet, not one per TPU shape. A step names a
    profile and the launcher submits the real workload to Kueue, so the shape
    is chosen inside the cluster; a new shape is a regenerated profile
    registry, not another queue and another agent to run it.
  EOT
}

variable "launcher_image" {
  type        = string
  description = <<-EOT
    Image the launcher pod runs: the Google Cloud CLI image, for kubectl,
    gcloud and gke-gcloud-auth-plugin, plus PyYAML, which it does not ship in
    a form Python 3 can import.

    Built by hand from kueue/launcher/Dockerfile - the command is in
    kueue/launcher/cloudbuild.yaml. Nothing rebuilds it on a commit; it changes
    only when the CLI version here does.
  EOT
}

variable "allowed_image_repos" {
  type        = list(string)
  description = <<-EOT
    Registry prefixes a workload image may come from.

    WORKLOAD_IMAGE is the pipeline's to set, since CI images are built per
    commit and the cluster cannot know the tag - which in a public repo means
    a pull request's to set. The launcher refuses an image that does not start
    with one of these. An empty list accepts any image, and only makes sense
    before the queue is open to fork PRs.
  EOT

  # A prefix stopping at a repository name also matches a longer one, so
  # "…/tpu-inference" would admit "…/tpu-inference-x" from anyone who can
  # create a repository in that project.
  validation {
    condition     = alltrue([for r in var.allowed_image_repos : endswith(r, "/")])
    error_message = "Every allowed_image_repos entry must end in / so it cannot match a longer repository name."
  }
}

variable "tpu_test_max_seconds" {
  type        = number
  description = "How long a TPU workload runs for when it says nothing. The launcher puts it on the submitted workload as activeDeadlineSeconds, so a hung test releases the chips rather than holding them until the Buildkite step times out. A manifest that knows better states its own, bounded by tpu_total_max_seconds."
}

variable "tpu_total_max_seconds" {
  type        = number
  description = <<-EOT
    How long a TPU step may take in total, queueing included.

    Also the ceiling on any deadline a manifest asks for, since the one thing
    that must hold is that a workload does not outlast the launcher watching
    it. The launcher waits for admission for whatever this leaves once the
    workload's own run is allowed for, so this and tpu_test_max_seconds are the
    only deadlines worth choosing and every other one follows from them.
  EOT
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

