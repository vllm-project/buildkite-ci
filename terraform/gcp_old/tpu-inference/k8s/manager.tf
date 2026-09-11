# The manager cluster: the one place that is always up. It holds the Buildkite
# controller and the Kueue control plane, and it must hold no accelerators, so
# that nothing running here competes with a test for chips. Worker clusters hold
# the TPUs and attach to this one through Fleet.
#
# Standard, like the workers, because this is where every workload podspec is
# born. Autopilot admission-mutates a podspec it considers underspecified - it
# fills in a nodeAffinity on cloud.google.com/extended-duration-pods for any pod
# that arrives without one - and MultiKueue copies the podspec to a worker
# verbatim, where no node carries that label and the pod is unschedulable with
# nothing reporting an error. A launcher that builds podspecs for another
# cluster cannot share a cluster with something that rewrites them.

# Nodes here are private, so egress - image pulls, Buildkite's API, Secret
# Manager - goes through the Cloud NAT covering this region. It is created
# outside this config, with the rest of the networking; see workers.tf.
resource "google_container_cluster" "manager" {
  project  = var.project_id
  name     = "${var.name_prefix}-manager"
  location = var.manager_region

  network    = var.network
  subnetwork = var.manager_subnetwork

  remove_default_node_pool = true
  initial_node_count       = 1

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

  # Empty: GKE picks and creates the pod and service secondary ranges, as on the
  # workers.
  ip_allocation_policy {}

  # How a pod here gets a Google identity without a key: the secret sync reads
  # the agent token, and the launcher reads the Test Engine and Hugging Face
  # tokens. Implicit under Autopilot, explicit here.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
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

# The only pool: the Kueue and JobSet controllers, the Buildkite controller, the
# secret sync, and one launcher pod per TPU step in flight. No taint and no
# label, because everything here is the fleet's own control plane and there is
# nothing to keep apart.
#
# The floor is two nodes rather than one so that a node under repair does not
# take the whole control plane with it. The ceiling follows the Buildkite
# controller's in-flight limit: a launcher pod waiting on quota still occupies a
# node, so the pods that can exist at once, not the chips, is what has to fit.
resource "google_container_node_pool" "manager_system" {
  name     = "system"
  project  = var.project_id
  cluster  = google_container_cluster.manager.name
  location = var.manager_region

  # total_, not the per-zone min_node_count/max_node_count: in a regional
  # cluster those are multiplied by the number of zones, so a floor of 2 would
  # quietly become two nodes per zone.
  autoscaling {
    total_min_node_count = var.manager_system_min_nodes
    total_max_node_count = var.manager_system_max_nodes
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type = var.manager_system_machine_type
    image_type   = "COS_CONTAINERD"

    # Off the project default compute account, which holds tpu.admin,
    # storage.admin and project-wide secretmanager.secretAccessor because the
    # bare-metal agent VMs share it.
    service_account = google_service_account.manager_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_integrity_monitoring = true
      enable_secure_boot          = true
    }

    labels = {
      "tpu-ci.google.com/role" = "manager"
    }

    metadata = {
      disable-legacy-endpoints = "true"
    }
  }
}
