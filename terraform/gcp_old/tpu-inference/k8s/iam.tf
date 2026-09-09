# Referenced from the cluster's auto_provisioning_defaults; see manager.tf for
# what happens if nodes are left on the project default instead.
resource "google_service_account" "manager_nodes" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-mgr-node"
  display_name = "Manager GKE Node SA"
}

resource "google_project_iam_member" "manager_nodes" {
  for_each = local.manager_node_service_account_roles

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.manager_nodes.email}"
}
