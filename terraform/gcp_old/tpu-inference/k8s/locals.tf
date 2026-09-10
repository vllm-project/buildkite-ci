locals {
  common_labels = merge(var.labels, {
    managed_by = "terraform"
    component  = "tpu-ci"
  })

  # The Kueue controller on the manager cluster, as IAM sees it. Workload
  # Identity federates a Kubernetes service account into a principal in its own
  # right, so this can hold roles without a Google service account to
  # impersonate. The name is Kueue's own and is fixed by its release manifests.
  kueue_controller_principal = join("", [
    "principal://iam.googleapis.com/projects/${data.google_project.manager.number}",
    "/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog",
    "/subject/ns/kueue-system/sa/kueue-controller-manager",
  ])

  # Every cluster's pools in one map, since one resource creates them all.
  #
  # A pool is named for its shape - the machine type and the topology asked of
  # that machine, e.g. ct6e-standard-8t-2x4 - and the name is built here rather
  # than given in the tfvars, so it cannot describe hardware the pool does not
  # have. The map is keyed by cluster as well, because the name only has to be
  # unique inside its own cluster and two regions running the same shape should
  # name it the same thing.
  tpu_node_pools = {
    for pool in flatten([
      for worker_name, worker in var.worker_clusters : [
        for pool in worker.tpu_node_pools : [
          # dims is the topology's dimensions padded to three with 1s, so that the
          # product below is one expression: Terraform has no product(), and v7x
          # topologies are 3D where v6e's are 2D.
          for dims in [concat([for d in split("x", pool.topology) : parseint(d, 10)], [1, 1])] :
          merge(pool, {
            name   = "${pool.machine_type}-${pool.topology}"
            worker = worker_name

            # One VM covering the whole slice is the ordinary case, and needs no
            # placement policy. Anything wider is a slice GKE has to place as a
            # unit across several VMs, which it only does from one. The machine
            # type's suffix is chips per VM, unlike the Buildkite queue names,
            # where tpu7x-8 counts TensorCores and is a four-chip
            # tpu7x-standard-4t.
            is_multi_host = dims[0] * dims[1] * dims[2] > parseint(
              trimsuffix(reverse(split("-", pool.machine_type))[0], "t"), 10
            )
          })
        ]
      ]
    ]) : "${pool.worker}/${pool.name}" => pool
  }

  manager_repository_bindings = {
    for repo in var.image_repositories :
    "${repo.location}/${repo.repository}" => repo
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
