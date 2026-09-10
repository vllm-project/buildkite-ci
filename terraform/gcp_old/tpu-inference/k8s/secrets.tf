# Read access to the Buildkite agent token, for the sync that copies it onto the
# manager. The objects that do the copying are generated YAML, not Terraform -
# see kueue/templates/secret_sync.yaml.tpl - because GKE's SecretSync reconciler
# runs in the control plane and there is nothing to install for it.
#
# The secret itself is not declared here. It predates this fleet, the bare-metal
# agents read the same one, and its value is not something Terraform should hold
# or replace. A data source rather than a resource, so a name that is wrong
# fails at plan time instead of quietly creating an empty second secret.
data "google_secret_manager_secret" "agent_token" {
  project   = var.project_id
  secret_id = var.agent_token_secret_id
}

# Scoped to this one secret. The project holds five others - REST API tokens, a
# webhook signing key - and the bare-metal agents reach all of them through a
# project-wide secretAccessor on the default compute account, which is the grant
# this migration exists to stop inheriting.
#
# _member, so this manages one (secret, role, member) tuple and leaves any other
# grant on the secret alone.
#
# The member is the Kubernetes service account, federated by Workload Identity
# into a principal that can hold a role directly. No Google service account
# stands behind it and no key exists to leak - which matters more here than for
# the caches, since what is behind this one is a credential.
resource "google_secret_manager_secret_iam_member" "agent_token_sync" {
  project   = var.project_id
  secret_id = data.google_secret_manager_secret.agent_token.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${var.project_id}.svc.id.goog[${var.namespace}/secret-sync]"
}

# The Buildkite Test Engine token, in the test suite's own project. A data
# source for the same reason as above: it predates this fleet and the
# bare-metal agents read it too, so both lanes report into one suite.
data "google_secret_manager_secret" "analytics_token" {
  project   = var.analytics_token_secret_project
  secret_id = var.analytics_token_secret_id
}

# Read straight by the launcher pod, not synced: unlike the agent token there
# is no consumer that has to be pointed at a Kubernetes Secret, and a Secret
# would be a copy of a credential sitting in the namespace between runs.
#
# Scoped to the one secret, not its project: that project is the suite's and
# holds other people's secrets.
resource "google_secret_manager_secret_iam_member" "launcher_analytics_token" {
  project   = var.analytics_token_secret_project
  secret_id = data.google_secret_manager_secret.analytics_token.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = local.launcher_principal
}
