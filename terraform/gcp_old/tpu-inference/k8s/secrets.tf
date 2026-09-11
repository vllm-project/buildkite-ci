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

# The Buildkite Test Engine token, in the test suite's own project. Also
# pre-existing: the bare-metal agents read it too, so both lanes report into
# one suite.
data "google_secret_manager_secret" "analytics_token" {
  project   = var.analytics_token_secret_project
  secret_id = var.analytics_token_secret_id
}

# Read straight by the launcher pod, not synced: nothing here has to be pointed
# at a Kubernetes Secret, and a Secret would be a copy of a credential sitting
# in the namespace between runs. Scoped to the one secret, not its project -
# that project is the suite's and holds other people's secrets.
resource "google_secret_manager_secret_iam_member" "launcher_analytics_token" {
  project   = var.analytics_token_secret_project
  secret_id = data.google_secret_manager_secret.analytics_token.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = local.launcher_principal
}

# The Hugging Face token, in the bare-metal agents' project. A model behind a
# gate cannot be fetched without it, and the fleet's model cache is shared, so
# the first step to want a gated model pays for every later one.
data "google_secret_manager_secret" "hf_token" {
  project   = var.hf_token_secret_project
  secret_id = var.hf_token_secret_id
}

# Read by the launcher and forwarded into the workload with --env, so the value
# is never a Kubernetes object and never appears in a pipeline. Same shape as
# the Test Engine grant above and for the same reason: one secret, not the
# project it happens to live in.
resource "google_secret_manager_secret_iam_member" "launcher_hf_token" {
  project   = var.hf_token_secret_project
  secret_id = data.google_secret_manager_secret.hf_token.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = local.launcher_principal
}
