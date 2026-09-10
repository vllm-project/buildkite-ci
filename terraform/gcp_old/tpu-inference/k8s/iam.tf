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
  for_each = local.workers

  project      = each.value.project
  account_id   = "${var.name_prefix}-wkr-${each.value.short_name}"
  display_name = "Worker GKE Node SA (${each.value.short_name})"
}

resource "google_project_iam_member" "worker_nodes" {
  for_each = local.workers

  project = each.value.project
  role    = "roles/container.defaultNodeServiceAccount"
  member  = "serviceAccount:${google_service_account.worker_nodes[each.key].email}"
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
# On the project, which is the one grant here that is not scoped to the resource
# it is about. Connect Gateway does not check gkehub.gateway.get against the
# fleet membership; it checks its own resource, projects/<project>/
# gkeMemberships/<id>, which carries no location and which a binding on the
# membership does not cover. The same principal holding gatewayEditor on the
# membership is refused with PERMISSION_DENIED, and the call succeeds only once
# the role is held project-wide.
#
# So the bound on what the controller may do in a worker is not in IAM but in
# the worker: the kueue-multikueue-remote ClusterRole that the generated
# manifests bind to this principal is the whole of its access there.
resource "google_project_iam_member" "kueue_manager_gateway" {
  for_each = toset([for w in var.worker_clusters : w.project])

  project = each.value
  role    = "roles/gkehub.gatewayEditor"
  member  = local.kueue_controller_principal
}
