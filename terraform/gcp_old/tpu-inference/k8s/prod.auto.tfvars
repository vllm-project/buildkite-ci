project_id  = "cloud-ullm-inference-ci-cd"
name_prefix = "tpu-ci"
network     = "projects/cloud-ullm-inference-ci-cd/global/networks/default"

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

# Keyed by region. The cluster pins no zones; the reservation's zone
# (us-east5-a) belongs to the compute class that draws on it.
worker_clusters = {
  us-east5 = {
    project                = "cloud-ullm-inference-ci-cd"
    location               = "us-east5"
    network                = "projects/cloud-ullm-inference-ci-cd/global/networks/default"
    subnetwork             = "projects/cloud-ullm-inference-ci-cd/regions/us-east5/subnetworks/default"
    master_ipv4_cidr_block = "172.16.0.32/28"
  }
}

# Reservation cloudtpu-20260828173000-731402396 in us-east5-a: 128 v6e chips,
# 102 in use, 26 free. Those 26 are the budget for every shape here - they are
# not divided between them, which is the point of provisioning on demand.
tpu_compute_classes = {
  v6e-1x1 = {
    worker           = "us-east5"
    accelerator_type = "tpu-v6e-slice"
    chips_per_node   = 1
    topology         = "1x1"
    reservation_name = "cloudtpu-20260828173000-731402396"
    zones            = ["us-east5-a"]
    nominal_nodes    = 10
  }
  v6e-2x4 = {
    worker           = "us-east5"
    accelerator_type = "tpu-v6e-slice"
    chips_per_node   = 8
    topology         = "2x4"
    reservation_name = "cloudtpu-20260828173000-731402396"
    zones            = ["us-east5-a"]
    nominal_nodes    = 2
  }
}

labels = {
  environment = "production"
  workload    = "tpu-ci"
  owner       = "tpu-inference"
}
