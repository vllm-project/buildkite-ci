project_id  = "cloud-ullm-inference-ci-cd"
name_prefix = "tpu-ci"
network     = "projects/cloud-ullm-inference-ci-cd/global/networks/default"

# Read by both terraform and scripts/generate_manifests.py; see variables.tf for
# why there is only the one.
namespace = "buildkite"

# The token the bare-metal agents already register with, so the kube fleet joins
# the same Buildkite org as the queues it is replacing. Terraform grants read on
# it and never owns its value.
agent_token_secret_id = "vllm_buildkite_agent_token"

# us-central1 to sit with the rest of the CI control plane: the monitoring VM,
# the cache buckets, and the Artifact Registry these nodes pull from. The
# manager holds no TPUs, so it is not tied to a reservation's zone.
manager_region                 = "us-central1"
manager_subnetwork             = "projects/cloud-ullm-inference-ci-cd/regions/us-central1/subnetworks/default"
manager_master_ipv4_cidr_block = "172.16.0.0/28"

# What nodes may pull, manager and worker alike. tpu-inference-ci-docker is in
# asia-south1 and is not listed: nothing in this lane pulls from it, and a
# repository absent here is simply unreadable.
image_repositories = [
  { location = "us-central1", repository = "tpu-inference" },
  { location = "us-central1", repository = "tpu-inference-ci" },
  { location = "us-central1", repository = "vllm-torchtpu" },
  { location = "us-central1", repository = "vllm-torchtpu-ci" },
  { location = "us-central1", repository = "vllm-on-tpu-docker-container" },
]

kueue_version       = "0.19.0"
jobset_version      = "0.12.0"
agent_stack_version = "0.49.0"

# A queue of its own rather than one of the names the bare-metal agents already
# answer to, so the two fleets can run side by side and a pipeline moves over one
# step at a time.
buildkite_queue = "kube"

auth_plugin_image       = "gcr.io/google.com/cloudsdktool/google-cloud-cli:584.0.0"
auth_plugin_source_path = "/usr/lib/google-cloud-sdk/bin/gke-gcloud-auth-plugin"

# A cluster is its project and its region; everything it is called is derived
# from those two. The cluster pins no zones; the reservation's zone (us-east5-a)
# belongs to the TPU pools that draw on it.
worker_clusters = [
  {
    project                = "cloud-ullm-inference-ci-cd"
    location               = "us-east5"
    network                = "projects/cloud-ullm-inference-ci-cd/global/networks/default"
    subnetwork             = "projects/cloud-ullm-inference-ci-cd/regions/us-east5/subnetworks/default"
    master_ipv4_cidr_block = "172.16.0.32/28"

    # Reservation cloudtpu-20260828173000-731402396 in us-east5-a: 128 v6e
    # chips, 102 in use, 26 free. nominal_nodes splits those 26 between the
    # shapes so neither starves the other; max_nodes sums to more, so a shape
    # borrowing the cohort's idle quota can still boot the nodes for it.
    # min_nodes is the part that really does partition the reservation, since
    # those chips stay with one shape once booted, so it is kept small.
    tpu_node_pools = [
      {
        machine_type     = "ct6e-standard-1t"
        topology         = "1x1"
        reservation_name = "cloudtpu-20260828173000-731402396"
        zone             = "us-east5-a"

        min_nodes     = 2
        nominal_nodes = 18
        max_nodes     = 26
      },
      {
        machine_type     = "ct6e-standard-8t"
        topology         = "2x4"
        reservation_name = "cloudtpu-20260828173000-731402396"
        zone             = "us-east5-a"

        # No floor: eight chips is too much of what is free to leave parked, so
        # this shape boots a node per job.
        min_nodes = 0
        # One slice, which is what the disagg benchmark takes. Room for two more
        # by borrowing whatever the single-chip queue is not using.
        nominal_nodes = 1
        max_nodes     = 3
      },
    ]
  },
]

labels = {
  environment = "production"
  workload    = "tpu-ci"
  owner       = "tpu-inference"
}
