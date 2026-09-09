# The manager cluster: the one place that is always up. It holds the Buildkite
# controller and the Kueue control plane, and it must hold no accelerators, so
# that nothing running here competes with a test for chips. Worker clusters hold
# the TPUs and attach to this one through Fleet.
#
# Autopilot is ForceNew: switching to Standard rebuilds the cluster and every
# workload on it.

# Nodes are private, so egress - image pulls, Buildkite's API, Secret Manager -
# has to go through Cloud NAT.
resource "google_compute_router" "manager" {
  name    = "${var.name_prefix}-mgr-router"
  project = var.project_id
  region  = var.manager_region
  network = var.network
}

resource "google_compute_router_nat" "manager" {
  name                               = "${var.name_prefix}-mgr-nat"
  project                            = var.project_id
  region                             = var.manager_region
  router                             = google_compute_router.manager.name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

resource "google_container_cluster" "manager" {
  project  = var.project_id
  name     = "${var.name_prefix}-manager"
  location = var.manager_region

  network    = var.network
  subnetwork = var.manager_subnetwork

  enable_autopilot    = true
  deletion_protection = var.deletion_protection

  release_channel {
    channel = var.release_channel
  }

  fleet {
    project = var.project_id
  }

  # The fleet-clusterinventory-* labels make GKE Fleet generate ClusterProfile
  # objects in kueue-system, which is what lets MultiKueue authenticate to
  # workers with federated credentials instead of a stored kubeconfig and bearer
  # token. Nothing reads them until Kueue is installed; they are set now because
  # they have to be present when the fleet is registered.
  resource_labels = merge(local.common_labels, {
    fleet-clusterinventory-management-cluster = "true"
    fleet-clusterinventory-namespace          = "kueue-system"
    role                                      = "manager"
  })

  # Autopilot has no node pool to hang a service account on, so this is the only
  # place to keep nodes off the project default compute account - which holds
  # tpu.admin, storage.admin and project-wide secretmanager.secretAccessor,
  # because the bare-metal agent VMs share it.
  #
  # `enabled` must stay unset: on Autopilot the autoscaler is always on and
  # setting it is an error. Only auto_provisioning_defaults is honoured.
  cluster_autoscaling {
    auto_provisioning_defaults {
      service_account = google_service_account.manager_nodes.email
      oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    }
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = var.enable_private_endpoint
    master_ipv4_cidr_block  = var.manager_master_ipv4_cidr_block

    # Worker clusters are in other regions and all of them reach this control
    # plane.
    master_global_access_config {
      enabled = true
    }
  }

  secret_manager_config {
    enabled = true
    rotation_config {
      enabled           = true
      rotation_interval = "300s"
    }
  }

  secret_sync_config {
    enabled = true
    rotation_config {
      enabled           = true
      rotation_interval = "300s"
    }
  }
}
