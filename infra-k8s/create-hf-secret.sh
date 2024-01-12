# read HF_TOKEN and use kubectl to generate a Secret in buildkite namespace so that the agent can use it

set -ex

# ensure current K8s cluster is vllm-ci-test-cluster
kubectl config current-context | grep vllm-ci-test-cluster || (echo "Current K8s cluster is not vllm-ci-test-cluster" && exit 1)

# Check if HF_TOKEN is set
if [[ -z "${HF_TOKEN}" ]]; then
  echo "HF_TOKEN is not set. Please set it and rerun the script."
  exit 1
fi

# Create a secret in the buildkite namespace
kubectl create secret generic hf-token-secret --from-literal=token=$HF_TOKEN -n buildkite

echo "Secret created successfully."