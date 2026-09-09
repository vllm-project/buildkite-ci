# Worker clusters: where the TPUs are. Standard, not Autopilot, because a TPU
# node needs reservation affinity on a named reservation, the google.com/tpu
# taint and COMPACT placement with an explicit topology - none of which
# Autopilot lets through.
#
# The control plane is regional so that it survives a zone going away, and no
# node_locations is set anywhere here: this cluster has no opinion about zones.
# The one thing that does is a TPU node, which must land in its reservation's
# zone, and that is pinned by the compute class that asks for it.

resource "google_container_cluster" "worker" {
  for_each = var.worker_clusters

  name     = "${var.name_prefix}-${each.key}"
  project  = each.value.project
  location = each.value.location

  network    = each.value.network
  subnetwork = each.value.subnetwork

  remove_default_node_pool = true
  initial_node_count       = 1

  deletion_protection = var.deletion_protection

  release_channel {
    channel = var.release_channel
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = each.value.master_ipv4_cidr_block
  }

  # Empty: GKE picks and creates the pod and service secondary ranges. The
  # us-east5 subnet has none, and hand-allocating them buys nothing here.
  ip_allocation_policy {}

  workload_identity_config {
    workload_pool = "${each.value.project}.svc.id.goog"
  }

  # MultiKueue reaches workers through the Connect Gateway, which resolves a
  # Fleet membership rather than a kubeconfig. Registering here is enough: GKE
  # creates the membership itself, in the cluster's region, and ties its
  # lifecycle to the cluster. A google_gke_hub_membership for the same cluster
  # collides with that one instead of adopting it.
  fleet {
    project = var.project_id
  }

  # OPTIMIZE_UTILIZATION because every TPU shape draws on one reservation of 26
  # chips. A node that has gone idle is holding chips another shape cannot have
  # until it is reaped, so reaping promptly is what lets the shapes hand over;
  # BALANCED would let it sit.
  cluster_autoscaling {
    autoscaling_profile = "OPTIMIZE_UTILIZATION"
  }

  resource_labels = merge(local.common_labels, {
    role   = "worker"
    worker = each.key
  })

  lifecycle {
    ignore_changes = [
      # GKE turns these on by itself and reports them back, so they diff on
      # every plan if tracked.
      secret_manager_config,
      secret_sync_config,
      monitoring_config,
    ]
  }
}

# Everything that is not a TPU: the metrics agent, CSI drivers, and the
# per-cluster half of anything MultiKueue installs. TPU nodes carry a NoSchedule
# taint, so without this pool a worker has nowhere to run system pods.
resource "google_container_node_pool" "worker_system" {
  for_each = var.worker_clusters

  name     = "system"
  project  = each.value.project
  cluster  = google_container_cluster.worker[each.key].name
  location = each.value.location

  # total_, not the per-zone min_node_count/max_node_count: in a regional
  # cluster those are multiplied by the number of zones, so a floor of 1 would
  # quietly become one node per zone.
  autoscaling {
    total_min_node_count = each.value.system_min_nodes
    total_max_node_count = each.value.system_max_nodes
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = each.value.system_machine_type
    image_type      = "COS_CONTAINERD"
    service_account = google_service_account.worker_nodes[each.key].email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_integrity_monitoring = true
      enable_secure_boot          = true
    }

    labels = {
      "tpu-ci.google.com/role"   = "system"
      "tpu-ci.google.com/worker" = each.key
    }

    metadata = {
      disable-legacy-endpoints = "true"
    }
  }
}

# Only for a worker in another project. When the worker shares the manager's
# project, enabling the GKE Hub API already grants the service agent this role
# on it; declaring it here would make Terraform the owner of a binding Google
# manages, and destroy would revoke it.
resource "google_project_iam_member" "gkehub_service_agent" {
  for_each = toset([
    for name, w in var.worker_clusters : w.project if w.project != var.project_id
  ])

  project = each.value
  role    = "roles/gkehub.serviceAgent"
  member  = "serviceAccount:service-${data.google_project.manager.number}@gcp-sa-gkehub.iam.gserviceaccount.com"
}

data "google_project" "manager" {
  project_id = var.project_id
}
