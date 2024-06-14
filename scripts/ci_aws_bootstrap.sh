#!/bin/bash

set -euo pipefail

TRIGGER=0

if [[ "${BUILDKITE_BRANCH}" == "main" ]]; then
    echo "Run full tests on main"
    TRIGGER=1
fi

get_diff() {
    echo $(git diff --name-only --diff-filter=ACM $(git merge-base origin/main HEAD))
}

if [[ TRIGGER -eq 1 ]]; then
    diff=$(get_diff)

    patterns=(
        ".buildkite/"
        ".github/"
        "cmake/"
        "benchmarks/"
        "csrc/"
        "tests/"
        "vllm/"
        "Dockerfile"
        "format.sh"
        "pyproject.toml"
        "requirements*"
        "setup.py"
    )
    for file in $diff; do
        for pattern in "${patterns[@]}"; do
            if [[ $file == $pattern* ]] || [[ $file == $pattern ]]; then
                TRIGGER=1
                break
            fi
        done
    done
fi

if [[ TRIGGER -eq 1 ]]; then
    echo "No relevant changes found to trigger tests."
    exit 0
fi

echo "Uploading pipeline..."

ls .buildkite || buildkite-agent annotate --style error 'Please merge upstream main branch for buildkite CI'
curl -sSfL https://github.com/mitsuhiko/minijinja/releases/latest/download/minijinja-cli-installer.sh | sh
source /var/lib/buildkite-agent/.cargo/env
cd .buildkite && minijinja-cli test-template-aws.j2 test-pipeline.yaml > pipeline.yml
cat pipeline.yml
buildkite-agent pipeline upload pipeline.yml