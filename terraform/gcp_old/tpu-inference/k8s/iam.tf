# Referenced from the cluster's auto_provisioning_defaults; see manager.tf for
# what happens if nodes are left on the project default instead.
resource "google_service_account" "manager_nodes" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-mgr-node"
  display_name = "Manager GKE Node SA"
}

# container.defaultNodeServiceAccount is GKE's maintained definition of what a
# node needs to boot, log and report metrics, and a node gets nothing beyond it.
# Every pod scheduled to a node can reach that node's identity, so anything a
# workload needs belongs on the workload's own service account through Workload
# Identity instead.
#
# It does not cover pulling private images; that is granted per repository
# below, from var.image_repositories, to both node accounts.
resource "google_project_iam_member" "manager_nodes" {
  project = var.project_id
  role    = "roles/container.defaultNodeServiceAccount"
  member  = "serviceAccount:${google_service_account.manager_nodes.email}"
}

resource "google_artifact_registry_repository_iam_member" "manager_nodes" {
  for_each = local.manager_repository_bindings

  project    = var.project_id
  location   = each.value.location
  repository = each.value.repository
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.manager_nodes.email}"
}

# One per worker cluster rather than one shared account, so that revoking a
# worker's access is deleting a principal and not editing a policy.
resource "google_service_account" "worker_nodes" {
  for_each = var.worker_clusters

  project      = each.value.project
  account_id   = "${var.name_prefix}-wkr-${each.key}"
  display_name = "Worker GKE Node SA (${each.key})"
}

resource "google_project_iam_member" "worker_nodes" {
  for_each = var.worker_clusters

  project = each.value.project
  role    = "roles/container.defaultNodeServiceAccount"
  member  = "serviceAccount:${google_service_account.worker_nodes[each.key].email}"
}

# Both bindings used to be indexed by role as well, back when a list of roles
# looked like it would grow. Without these Terraform would revoke and re-grant
# rather than re-index, and a moved block cannot be generated, so a new worker
# cluster needs a line here until these are deleted after the next apply.
moved {
  from = google_project_iam_member.manager_nodes["roles/container.defaultNodeServiceAccount"]
  to   = google_project_iam_member.manager_nodes
}

moved {
  from = google_project_iam_member.worker_nodes["us-east5/roles/container.defaultNodeServiceAccount"]
  to   = google_project_iam_member.worker_nodes["us-east5"]
}

resource "google_artifact_registry_repository_iam_member" "worker_nodes" {
  for_each = local.worker_node_repository_bindings

  project    = var.project_id
  location   = each.value.location
  repository = each.value.repository
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.worker_nodes[each.value.worker_name].email}"
}

# Lets the manager's Kueue controller reach a worker's API server through
# Connect Gateway. It authenticates as its Kubernetes service account directly,
# with no Google service account in between, so there is no key and nothing to
# rotate; gke-gcloud-auth-plugin turns that identity into the gateway's token.
#
# Per membership, not per project: a gatewayEditor on the project would also be
# an editor of every cluster registered to the fleet later. What the controller
# may then do inside the worker is the kueue-multikueue-remote ClusterRole,
# which the generated manifests bind to this same principal.
resource "google_gke_hub_membership_iam_member" "kueue_manager_gateway" {
  for_each = var.worker_clusters

  project       = each.value.project
  location      = google_container_cluster.worker[each.key].fleet[0].membership_location
  membership_id = google_container_cluster.worker[each.key].fleet[0].membership_id
  role          = "roles/gkehub.gatewayEditor"
  member        = local.kueue_controller_principal
}
