project_id  = "cloud-ullm-inference-ci-cd"
name_prefix = "tpu-ci"
network     = "projects/cloud-ullm-inference-ci-cd/global/networks/default"

# us-central1 to sit with the rest of the CI control plane: the monitoring VM,
# the cache buckets, and the Artifact Registry these nodes pull from. The
# manager holds no TPUs, so it is not tied to a reservation's zone.
manager_region                 = "us-central1"
manager_subnetwork             = "projects/cloud-ullm-inference-ci-cd/regions/us-central1/subnetworks/default"
manager_master_ipv4_cidr_block = "172.16.0.0/28"

labels = {
  environment = "production"
  workload    = "tpu-ci"
  owner       = "tpu-inference"
}
