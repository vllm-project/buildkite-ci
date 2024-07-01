#!/bin/bash

set -euo pipefail

upload_pipeline() {
    echo "Uploading pipeline..."
    ls .buildkite || buildkite-agent annotate --style error 'Please merge upstream main branch for buildkite CI'
    curl -sSfL https://github.com/mitsuhiko/minijinja/releases/latest/download/minijinja-cli-installer.sh | sh
    source /var/lib/buildkite-agent/.cargo/env
    if [ ! -e ".buildkite/test-template.j2" ]; then
        curl -o .buildkite/test-template.j2 https://raw.githubusercontent.com/vllm-project/buildkite-ci/main/scripts/test-template-aws.j2
    fi
    cd .buildkite && minijinja-cli test-template.j2 test-pipeline.yaml > pipeline.yml
    cat pipeline.yml
    buildkite-agent pipeline upload pipeline.yml
    exit 0
}

get_diff() {
    $(git add .)
    echo $(git diff --name-status --diff-filter=ACMDR $(git merge-base origin/main HEAD))
}

if [[ "${RUN_ALL:-}" == "1" ]]; then
    upload_pipeline
fi

if [[ "${BUILDKITE_BRANCH}" == "main" ]]; then
    echo "Run full tests on main"
    upload_pipeline
fi


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
    "test_docs/"
    "docs/"
)
for file in $diff; do
    for pattern in "${patterns[@]}"; do
        if [[ $file == $pattern* ]] || [[ $file == $pattern ]]; then
            TRIGGER=1
            echo "Found relevant changes: $file"
            upload_pipeline
        fi
    done
done

echo "No relevant changes found to trigger tests."
exit 0
