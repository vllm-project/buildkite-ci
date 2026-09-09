locals {
  common_labels = merge(var.labels, {
    managed_by = "terraform"
    component  = "tpu-ci"
  })

  # Keep this list to what a node needs to boot, log and report metrics. Every
  # pod scheduled to a node can reach that node's identity, so anything a
  # workload needs belongs on the workload's own service account through
  # Workload Identity instead.
  #
  # container.defaultNodeServiceAccount is GKE's maintained definition of that
  # minimum. artifactregistry.reader is not in it and has to be added
  # separately; a node needs it to pull private images.
  manager_node_service_account_roles = toset([
    "roles/container.defaultNodeServiceAccount",
    "roles/artifactregistry.reader",
  ])
}
