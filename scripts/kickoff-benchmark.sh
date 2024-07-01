#!/usr/bin/env bash

# NOTE(simon): this script runs inside a buildkite agent with CPU only access.
set -euo pipefail

target_yaml_file=""

# If BUILDKITE_PULL_REQUEST != "false", then we check the PR labels using curl and jq
if [ "$BUILDKITE_PULL_REQUEST" != "false" ]; then
  PR_LABELS=$(curl -s "https://api.github.com/repos/vllm-project/vllm/pulls/$BUILDKITE_PULL_REQUEST" | jq -r '.labels[].name')

  if [[ $PR_LABELS == *"perf-benchmarks"* ]]; then
    echo "This PR has the 'perf-benchmarks' label. Proceeding with the performance benchmarks."
    target_yaml_file=".buildkite/nightly-benchmarks/benchmark-pipeline.yaml"
  fi

  if [[ $PR_LABELS == *"nightly-benchmarks"* ]]; then
    echo "This PR has the 'nightly-benchmark' label. Proceeding with the nightly benchmarks."
    target_yaml_file=".buildkite/nightly-benchmarks/nightly-pipeline.yaml"
  fi
fi

if [ -n "$target_yaml_file" ]; then
  # Upload sample.yaml
  buildkite-agent pipeline upload $target_yaml_file
fi
