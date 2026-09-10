---
# The Buildkite agent token, pulled out of Secret Manager and into a Kubernetes
# Secret the agent-stack-k8s chart can be pointed at.
#
# GKE's own SecretSync, not External Secrets. There is no controller to install
# and none to run: the reconciler lives in the GKE control plane, so nothing
# here appears in `kubectl get pods` and there is nothing for the deploy script
# to wait on. Enabling it is a cluster field, `secret_sync_config` in manager.tf.
#
# Manager only, and not because a worker does no Buildkite work - a TPU pod
# uploads its own artifacts, writes meta-data and reports to Test Engine, since
# it is the only thing that can see its own output files. It is that it does so
# with a different credential.
#
# This one is the org registration token. It is what an agent presents to
# Buildkite to register and claim a job, and the only things that register are
# the agent-stack-k8s controller and the agent pods it creates, both here. What
# a workload pod calls `buildkite-agent` with is BUILDKITE_AGENT_ACCESS_TOKEN,
# which the agent is handed back after registering: it is scoped to the one job,
# it dies with it, and the launcher forwards it as a plain environment variable.
# Nothing syncs it and nothing needs to.
#
# So syncing this secret to a worker would put a long-lived org credential next
# to pods running images named by a pull request, and buy nothing.

# The identity the sync reads Secret Manager as. Its own, not tpu-workload:
# these are two different jobs - one may read the agent token, the other may
# write to the caches - and a workload image named by a pull request runs as the
# second. Nothing mounts this account, so nothing that runs here can use it.
#
# No Google service account annotation: secrets.tf grants the accessor role
# straight to the Workload Identity principal for this account, so there is
# nothing to impersonate and no key to rotate.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: secret-sync
  namespace: ${NAMESPACE}
---
# Which secret, and what to call it on the way through. The path is internal:
# it names the value inside this class so the SecretSync below can refer to it,
# and it is never a file anywhere - nothing mounts this class as a CSI volume.
#
# `versions/latest` rather than a pinned version, because rotation is the point.
# A new version is picked up on the next poll.
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: buildkite-agent-token
  namespace: ${NAMESPACE}
spec:
  provider: gke
  parameters:
    secrets: |
      - resourceName: "projects/${PROJECT_ID}/secrets/${AGENT_TOKEN_SECRET_ID}/versions/latest"
        path: "agent-token"
---
# The Secret itself, which takes this object's own name. The key is not ours to
# choose - agent-stack-k8s reads BUILDKITE_AGENT_TOKEN out of whatever Secret it
# is pointed at - but the name is, and PR 6 points the chart here.
#
# Rotation updates this object in place - same name, new value, within about
# five minutes of a new Secret Manager version. There is no watch, only a poll,
# so treat five minutes as the bound. Pods that read the token at startup pick
# it up on their next start; the controller holds its copy for the life of its
# process, so rotating the token also means restarting that Deployment.
#
# The Secret lands in this namespace because there is nowhere else it could:
# SecretSync has no target-namespace field and writes only beside itself. That
# is where it is wanted anyway.
apiVersion: secret-sync.gke.io/v1
kind: SecretSync
metadata:
  name: buildkite-agent-token
  namespace: ${NAMESPACE}
spec:
  serviceAccountName: secret-sync
  secretProviderClassName: buildkite-agent-token
  secretObject:
    type: Opaque
    data:
      - sourcePath: agent-token
        targetKey: BUILDKITE_AGENT_TOKEN
