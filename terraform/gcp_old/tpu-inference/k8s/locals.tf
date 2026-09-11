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

  # The launcher's service account on the manager cluster, in the older syntax
  # the rest of this fleet's namespaced grants use. The account name is fixed by
  # kueue/templates/launcher.yaml.tpl, which is rendered rather than declared
  # here, and the namespace is shared with Terraform for exactly this reason -
  # see var.namespace.
  launcher_principal = "serviceAccount:${var.project_id}.svc.id.goog[${var.namespace}/tpu-launcher]"

  # Worker clusters keyed by the pair that identifies one, rather than by a
  # positional index, which would renumber - and so rebuild - every cluster
  # after one that was removed.
  #
  # Two names come out of that pair, because they have to be unique in two
  # places. A cluster, a service account, a router, a NAT are all project
  # scoped, so the region alone names them. The Terraform address, the rendered
  # directory and the MultiKueueCluster are fleet-wide, so those carry the
  # project too.
  workers = {
    for w in var.worker_clusters : "${w.project}/${w.location}" => merge(w, {
      short_name = w.location
      fleet_name = "${w.project}-${w.location}"
    })
  }

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
      for worker_name, worker in local.workers : [
        for pool in worker.tpu_node_pools : [
          # dims is the topology's dimensions padded to three with 1s, so that the
          # product below is one expression: Terraform has no product(), and v7x
          # topologies are 3D where v6e's are 2D.
          for dims in [concat([for d in split("x", pool.topology) : parseint(d, 10)], [1, 1])] :
          merge(pool, {
            name = "${pool.machine_type}-${pool.topology}"
            # worker keys back into local.workers; short_name is carried
            # alongside it because a Kubernetes label value may not hold the
            # slash that key has in it.
            worker     = worker_name
            short_name = worker.short_name

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

  # Both caches for every worker in one map, since one resource creates them all
  # and one grants access to them all. Only retention and purpose differ.
  #
  # scripts/generate_manifests.py derives the same name, because it has to put
  # it in a PersistentVolume's volumeHandle. A name computed twice is a name
  # that can differ, and the failure is a volume pointing at a bucket that was
  # never created, so deploy_manifests.py checks every bucket a volume names
  # exists before applying.
  #
  # The hash covers project and region, which is what identifies a cluster; the
  # purpose is spelled out beside it so the two buckets of one cluster read as a
  # pair. The project has to be in the hash because bucket names are globally
  # unique, so two organisations running this would otherwise collide.
  workload_buckets = merge([
    for worker in var.worker_clusters : {
      for purpose, retention_days in {
        cache  = var.cache_lifecycle_age_days
        models = var.models_lifecycle_age_days
        } : "${worker.project}/${worker.location}/${purpose}" => {
        purpose        = purpose
        project        = worker.project
        location       = worker.location
        retention_days = retention_days
        name = join("-", [
          var.name_prefix,
          purpose,
          substr(sha256("${worker.project}/${worker.location}"), 0, 8),
        ])
      }
    }
  ]...)

  manager_repository_bindings = {
    for repo in var.image_repositories :
    "${repo.location}/${repo.repository}" => repo
  }

  worker_node_repository_bindings = {
    for item in flatten([
      for worker_name, worker in local.workers : [
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
