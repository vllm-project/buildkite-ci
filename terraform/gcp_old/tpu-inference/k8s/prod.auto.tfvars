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

# The Test Engine token, in the suite's own project rather than this one. Also
# not created here: the bare-metal agents read the same secret, and the results
# of a kube run and a bare-metal run should land in one suite.
analytics_token_secret_project = "cloud-tpu-inference-test"
analytics_token_secret_id      = "tpu_commons_buildkite_analytics_token"

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
  # This fleet's own images - the launcher - as opposed to the CI images below,
  # which are built from the tpu-inference repo and named by a step.
  { location = "us-central1", repository = "tpu-ci" },
  { location = "us-central1", repository = "tpu-inference" },
  { location = "us-central1", repository = "tpu-inference-ci" },
  { location = "us-central1", repository = "vllm-torchtpu" },
  { location = "us-central1", repository = "vllm-torchtpu-ci" },
  { location = "us-central1", repository = "vllm-on-tpu-docker-container" },
]

kueue_version       = "0.19.0"
jobset_version      = "0.12.0"
agent_stack_version = "0.49.0"

# A queue of its own, so this fleet and the bare-metal one run side by side and
# a pipeline moves over one step at a time.
buildkite_queue = "kube"

auth_plugin_image       = "gcr.io/google.com/cloudsdktool/google-cloud-cli:584.0.0"
auth_plugin_source_path = "/usr/lib/google-cloud-sdk/bin/gke-gcloud-auth-plugin"

# Built by kueue/launcher/cloudbuild.yaml from the Cloud CLI image the auth
# plugin is copied out of, at the same version. Still a variable of its own:
# there that image is a source of one static binary for a distroless container,
# here it is the whole runtime a pod boots into, and the two move for different
# reasons.
#
# The suffix after the CLI version is the Dockerfile revision, bumped when the
# Dockerfile changes and the base image does not, so a tag names one set of
# bytes.
launcher_image = "us-central1-docker.pkg.dev/cloud-ullm-inference-ci-cd/tpu-ci/launcher:584.0.0-1"

# A test may hold chips for three hours and a step may take eight in total,
# queueing included; the launcher waits for admission for the difference. Both
# match the bare-metal budgets, so a step moving between the two lanes gets the
# same allowance.
tpu_test_max_seconds  = 10800
tpu_total_max_seconds = 28800

# Every CI image this fleet runs is built into the manager project's Artifact
# Registry, and a step names its own tag, so the project is the boundary rather
# than the repository. Trailing slash required: without it the prefix would also
# match a longer repository name.
allowed_image_repos = [
  "us-central1-docker.pkg.dev/cloud-ullm-inference-ci-cd/",
]

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
        # One slice guaranteed, and room for two more by borrowing whatever the
        # single-chip queue is not using.
        nominal_nodes = 1
        max_nodes     = 3
      },
    ]
  },

  # The v7x lane, in us-central1 because that is where its reservation is.
  {
    project                = "cloud-ullm-inference-ci-cd"
    location               = "us-central1"
    network                = "projects/cloud-ullm-inference-ci-cd/global/networks/default"
    subnetwork             = "projects/cloud-ullm-inference-ci-cd/regions/us-central1/subnetworks/default"
    master_ipv4_cidr_block = "172.16.0.64/28"

    # Larger than the e2-standard-4 default, because a workload role that holds
    # no chips lands here rather than on a TPU node - a benchmark client driving
    # the engines over HTTP wants real cores to keep hundreds of streams fed.
    system_machine_type = "e2-standard-16"

    # Reservation cloudtpu-20251114223000-2002888989 in us-central1-c: 128 v7x
    # chips, fully consumed, so the eight here are ones moved off an existing
    # cluster rather than spare capacity.
    tpu_node_pools = [
      {
        machine_type     = "tpu7x-standard-4t"
        topology         = "2x2x1"
        reservation_name = "cloudtpu-20251114223000-2002888989"
        zone             = "us-central1-c"

        # No floor, so the chips go back to the reservation once a pool goes
        # idle. max and nominal are equal because there is nothing free in the
        # reservation to borrow beyond them.
        min_nodes     = 0
        nominal_nodes = 2
        max_nodes     = 2
      },
    ]
  },
]

labels = {
  environment = "production"
  workload    = "tpu-ci"
  owner       = "tpu-inference"
}
