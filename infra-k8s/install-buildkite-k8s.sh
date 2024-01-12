set -ex

# gcloud container clusters get-credentials vllm-ci-test-cluster --region us-central1 --project vllm-405802

# ensure current K8s cluster is vllm-ci-test-cluster
kubectl config current-context | grep vllm-ci-test-cluster || (echo "Current K8s cluster is not vllm-ci-test-cluster" && exit 1)


agentToken=${TF_VAR_buildkite_agent_token:-}
if [ -z "$agentToken" ]; then
    echo "TF_VAR_buildkite_agent_token is not set"
    exit 1
fi

graphqlToken=${BUILDKITE_GRAPHQL_TOKEN:-}
if [ -z "$graphqlToken" ]; then
    echo "BUILDKITE_GRAPHQL_TOKEN is not set"
    exit 1
fi


helm upgrade --install agent-stack-k8s oci://ghcr.io/buildkite/helm/agent-stack-k8s \
    --create-namespace \
    --namespace buildkite \
    --set config.org=vllm \
    --set agentToken=$agentToken \
    --set graphqlToken=$graphqlToken