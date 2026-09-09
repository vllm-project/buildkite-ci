locals {
  common_labels = merge(var.labels, {
    managed_by = "terraform"
    component  = "tpu-ci"
  })

  # The slice one VM of a TPU machine type covers, for the generations this
  # fleet has chips in. v6e topologies are 2D, v7x 3D. The trailing count is
  # chips per VM, unlike the Buildkite queue names, where tpu7x-8 counts
  # TensorCores and is the four chips of a tpu7x-standard-4t.
  single_host_topology = {
    "ct6e-standard-1t"  = "1x1"
    "ct6e-standard-4t"  = "2x2"
    "ct6e-standard-8t"  = "2x4"
    "tpu7x-standard-1t" = "1x1x1"
    "tpu7x-standard-4t" = "2x2x1"
  }

  # Every cluster's pools in one map, since one resource creates them all. A
  # name used by two clusters collides here rather than silently losing a pool.
  tpu_node_pools = {
    for pool in flatten([
      for worker_name, worker in var.worker_clusters : [
        for pool_name, pool in worker.tpu_node_pools : merge(pool, {
          name   = pool_name
          worker = worker_name

          # One VM covering the whole slice is the ordinary case, and needs no
          # placement policy. Anything wider is a slice GKE has to place as a
          # unit across several VMs, which it only does from one.
          is_multi_host = pool.topology != local.single_host_topology[pool.machine_type]

          cluster_project  = worker.project
          cluster_location = worker.location
        })
      ]
    ]) : pool.name => pool
  }

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
