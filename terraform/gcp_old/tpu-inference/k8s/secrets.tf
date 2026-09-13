# Read access to the Buildkite agent token, for the sync that copies it onto the
# manager. The objects that do the copying are generated YAML, not Terraform -
# see kueue/templates/secret_sync.yaml.tpl.
#
# The secret itself predates this fleet and the bare-metal agents read the same
# one, so a data source rather than a resource: a name that is wrong fails at
# plan time instead of quietly creating an empty second secret.
data "google_secret_manager_secret" "agent_token" {
  project   = var.project_id
  secret_id = var.agent_token_secret_id
}

# Scoped to this one secret. The project holds others - REST API tokens, a
# webhook signing key - that nothing here has any business reading.
#
# _member, so this manages one (secret, role, member) tuple and leaves any other
# grant on the secret alone. The member is the Kubernetes service account,
# federated by Workload Identity, so no key exists to leak.
resource "google_secret_manager_secret_iam_member" "agent_token_sync" {
  project   = var.project_id
  secret_id = data.google_secret_manager_secret.agent_token.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${var.project_id}.svc.id.goog[${var.namespace}/secret-sync]"
}

# The credentials a workload reads from its own environment, each in the
# project that owns it - which is never this one. Pre-existing like the agent
# token, and for the same reason data sources: a name that is wrong fails at
# plan time instead of quietly granting access to nothing.
data "google_secret_manager_secret" "env_secret" {
  for_each = var.env_secrets

  project   = each.value.project
  secret_id = each.value.secret
}

# Granted to the sync on every cluster, the same way the git key is. The
# Workload Identity pool is the project's rather than a cluster's, so the
# principal below is one string for the manager and both workers and a new
# worker inherits the grant by existing.
#
# Scoped to the individual secret, which matters more here than for the fleet's
# own: these live in other teams' projects.
resource "google_secret_manager_secret_iam_member" "env_secret_sync" {
  for_each = var.env_secrets

  project   = each.value.project
  secret_id = data.google_secret_manager_secret.env_secret[each.key].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${var.project_id}.svc.id.goog[${var.namespace}/secret-sync]"
}

# The same read for the launcher, which is the fleet's way back to a working
# state if a sync stops writing. Reverting the launcher to resolving values
# itself is one ConfigMap; a grant it does not hold is a Terraform round trip
# through two other teams' projects, at the point where nothing is running.
resource "google_secret_manager_secret_iam_member" "launcher_env_secret" {
  for_each = var.env_secrets

  project   = each.value.project
  secret_id = data.google_secret_manager_secret.env_secret[each.key].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = local.launcher_principal
}

# The GitHub deploy key, in this fleet's own project alongside the agent token.
# A data source for the same reason that one is: a name that is wrong fails at
# plan time rather than quietly creating an empty second secret.
data "google_secret_manager_secret" "git_ssh_key" {
  project   = var.project_id
  secret_id = var.git_ssh_key_secret_id
}

# Granted to the sync rather than to the launcher, unlike the Hugging Face and
# Test Engine tokens above: this one has to become a Kubernetes Secret, because
# the thing that reads it is the agent's own checkout container and it takes the
# key from its environment.
resource "google_secret_manager_secret_iam_member" "git_ssh_key_sync" {
  project   = var.project_id
  secret_id = data.google_secret_manager_secret.git_ssh_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${var.project_id}.svc.id.goog[${var.namespace}/secret-sync]"
}
