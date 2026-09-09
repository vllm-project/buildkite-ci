# Referenced from the cluster's auto_provisioning_defaults; see manager.tf for
# what happens if nodes are left on the project default instead.
resource "google_service_account" "manager_nodes" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-mgr-node"
  display_name = "Manager GKE Node SA"
}

resource "google_project_iam_member" "manager_nodes" {
  for_each = local.node_service_account_roles

  project = var.project_id
  role    = each.value
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
  for_each = local.worker_node_role_bindings

  project = each.value.project
  role    = each.value.role
  member  = "serviceAccount:${google_service_account.worker_nodes[each.value.worker_name].email}"
}

resource "google_artifact_registry_repository_iam_member" "worker_nodes" {
  for_each = local.worker_node_repository_bindings

  project    = var.project_id
  location   = each.value.location
  repository = each.value.repository
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.worker_nodes[each.value.worker_name].email}"
}
