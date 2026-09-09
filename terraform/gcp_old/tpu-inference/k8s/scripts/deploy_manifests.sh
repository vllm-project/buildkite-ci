#!/usr/bin/env bash
set -euo pipefail

# Applies generated/ to every worker cluster it names.
#
#   deploy_manifests.sh [--yes]
#
# Renders generated/ first, so the diff you approve is the tfvars as it stands
# and not whatever was committed last - these changes are applied from the
# branch before the PR merges, so the committed copy is behind by design.
#
# Nothing is applied without the kubectl diff being printed and agreed to.
# --yes still prints it and skips only the prompt, for a caller that has
# already seen one.
#
# This only ever creates and updates. A shape deleted from the tfvars
# disappears from generated/ but its ComputeClass stays in the cluster until
# someone removes it by hand - and any node pool GKE auto-created for it stays
# with it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$SCRIPT_DIR")"
GENERATED_DIR="${K8S_DIR}/generated"

# The generator imports hcl2. Point PYTHON at an interpreter that has it - a
# virtualenv's - if your python3 does not.
PYTHON="${PYTHON:-python3}"

PROJECT="cloud-ullm-inference-ci-cd"

ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    *) echo "usage: ${0##*/} [--yes]" >&2; exit 2 ;;
  esac
done

# A kubeconfig of its own. get-credentials writes to whatever KUBECONFIG names
# and repoints its current-context, so sharing yours would leave your kubectl
# aimed at the last cluster this touched.
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT
export KUBECONFIG="${TMP_ROOT}/kubeconfig"

# Set by use_cluster, read by apply_dir. Every kubectl call names it explicitly
# rather than trusting the current context, so a get-credentials that failed
# cannot send one cluster's manifests to another.
KCTX=""

use_cluster() {
  local cluster="$1" location="$2"
  gcloud container clusters get-credentials "$cluster" \
    --location "$location" --project "$PROJECT"
  KCTX="$(kubectl config current-context)"
}

confirm() {
  (( ASSUME_YES )) && return 0
  if [[ ! -t 0 ]]; then
    echo "Error: nothing to read a confirmation from; pass --yes to apply unattended." >&2
    exit 1
  fi
  local reply
  read -r -p "$1 [y/N] " reply
  case "$reply" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) echo "Aborted."; exit 1 ;;
  esac
}

apply_dir() {
  local dir="$1" label="$2"

  echo ""
  echo "--- ${label}: pending changes ---"
  # kubectl diff exits 1 for "there are differences" and >1 for a real failure.
  # A cluster without the ComputeClass CRD is the >1 case, which is what this
  # looks like against a GKE version too old to serve cloud.google.com/v1.
  local rc=0
  kubectl --context "$KCTX" diff -f "$dir" || rc=$?
  case "$rc" in
    0) echo "(no changes)"; return 0 ;;
    1) ;;
    *) echo "Error: could not diff against ${label}." >&2; exit 1 ;;
  esac

  confirm "Apply the above to ${label}?"
  # kubectl reads a directory in lexical order, which is what the NN- prefixes
  # encode. ComputeClasses are independent of each other, so the ordering only
  # matters once something in a later file references them.
  kubectl --context "$KCTX" apply -f "$dir"
}

echo "Rendering generated/ from prod.auto.tfvars"
if ! "${PYTHON}" "${SCRIPT_DIR}/generate_manifests.py"; then
  echo "Error: could not render the manifests with '${PYTHON}' (see above)." >&2
  echo "Set PYTHON to an interpreter with hcl2 installed." >&2
  exit 1
fi

shopt -s nullglob
dirs=("${GENERATED_DIR}"/worker-*)
if (( ${#dirs[@]} == 0 )); then
  echo "nothing to apply: ${GENERATED_DIR} has no worker-* directories" >&2
  exit 1
fi

for dir in "${dirs[@]}"; do
  worker="$(basename "$dir")"
  worker="${worker#worker-}"

  echo ""
  echo "========================================================="
  echo "Worker Cluster: ${worker}"
  echo "========================================================="
  # The directory is named for the cluster's region, so it is both the
  # --location and the suffix of the cluster name.
  use_cluster "tpu-ci-${worker}" "${worker}"
  apply_dir "$dir" "worker ${worker}"
done

echo ""
echo "Deployment Complete!"
