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
  # minimum. It does not cover pulling private images; that is granted per
  # repository in iam.tf, from var.image_repositories, to both node accounts.
  node_service_account_roles = toset([
    "roles/container.defaultNodeServiceAccount",
  ])

  manager_repository_bindings = {
    for repo in var.image_repositories :
    "${repo.location}/${repo.repository}" => repo
  }

  worker_node_role_bindings = {
    for item in flatten([
      for worker_name, worker in var.worker_clusters : [
        for role in local.node_service_account_roles : {
          key         = "${worker_name}/${role}"
          worker_name = worker_name
          project     = worker.project
          role        = role
        }
      ]
    ]) : item.key => item
  }

  worker_node_repository_bindings = {
    for item in flatten([
      for worker_name, worker in var.worker_clusters : [
        for repo in var.image_repositories : {
          key         = "${worker_name}/${repo.location}/${repo.repository}"
          worker_name = worker_name
          location    = repo.location
          repository  = repo.repository
        }
      ]
    ]) : item.key => item
  }
}
