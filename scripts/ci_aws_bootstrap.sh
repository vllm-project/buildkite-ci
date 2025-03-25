#!/bin/bash

set -euo pipefail

if [[ -z "${RUN_ALL:-}" ]]; then
    RUN_ALL=0
fi

if [[ -z "${NIGHTLY:-}" ]]; then
    NIGHTLY=0
fi

upload_pipeline() {
    echo "Uploading pipeline..."
    ls .buildkite || buildkite-agent annotate --style error 'Please merge upstream main branch for buildkite CI'
    curl -sSfL https://github.com/mitsuhiko/minijinja/releases/download/2.3.1/minijinja-cli-installer.sh | sh
    source /var/lib/buildkite-agent/.cargo/env
    if [ $BUILDKITE_PIPELINE_SLUG == "fastcheck" ]; then
        if [ ! -e ".buildkite/test-template-fastcheck.j2" ]; then
            curl -o .buildkite/test-template-fastcheck.j2 https://raw.githubusercontent.com/vllm-project/buildkite-ci/ricliu-patch-1/scripts/test-template-fastcheck.j2
        fi
        cd .buildkite && minijinja-cli test-template-fastcheck.j2 test-pipeline.yaml > pipeline.yml
        cat pipeline.yml
        buildkite-agent pipeline upload pipeline.yml
        exit 0
    fi
    if [ ! -e ".buildkite/test-template.j2" ]; then
        curl -o .buildkite/test-template.j2 https://raw.githubusercontent.com/vllm-project/buildkite-ci/main/scripts/test-template-aws.j2?$(date +%s)
    fi
    if [ -e ".buildkite/pipeline_generator/pipeline_generator.py" ]; then
        python -m pip install click pydantic
        python .buildkite/pipeline_generator/pipeline_generator.py --run_all=$RUN_ALL --list_file_diff="$LIST_FILE_DIFF" --nightly="$NIGHTLY"
        buildkite-agent pipeline upload .buildkite/pipeline.yaml
        exit 0
    fi
    cd .buildkite
    echo "List file diff: $LIST_FILE_DIFF"
    echo "Run all: $RUN_ALL"
    echo "Nightly: $NIGHTLY"
    minijinja-cli test-template.j2 test-pipeline.yaml -D branch="$BUILDKITE_BRANCH" -D list_file_diff="$LIST_FILE_DIFF" -D run_all="$RUN_ALL" -D nightly="$NIGHTLY" > pipeline.yml
    cat pipeline.yml
    buildkite-agent pipeline upload pipeline.yml
    exit 0
}

get_diff() {
    $(git add .)
    echo $(git diff --name-only --diff-filter=ACMDR $(git merge-base origin/main HEAD))
}

get_diff_main() {
    $(git add .)
    echo $(git diff --name-only --diff-filter=ACMDR HEAD~1)
}

file_diff=$(get_diff)
if [[ $BUILDKITE_BRANCH == "main" ]]; then
    file_diff=$(get_diff_main)
fi

patterns=(
    ".buildkite/test-pipeline"
    "Dockerfile"
    "CMakeLists.txt"
    "requirements*"
    "setup.py"
    "csrc/"
)

ignore_patterns=(
    "Dockerfile.rocm"
    "Dockerfile.rocm_base"
    "requirements-rocm"
    "requirements-hpu"
    "requirements-openvino"
    "requirements-neuron"
    "requirements-tpu"
    "requirements-xpu"
    "requirements-cpu"
)

for file in $file_diff; do
    # First check if file matches any pattern
    matches_pattern=0
    for pattern in "${patterns[@]}"; do
        if [[ $file == $pattern* ]] || [[ $file == $pattern ]]; then
            matches_pattern=1
            break
        fi
    done

    # If file matches pattern, check it's not in ignore patterns
    if [[ $matches_pattern -eq 1 ]]; then
        matches_ignore=0
        for ignore in "${ignore_patterns[@]}"; do
            if [[ $file == $ignore* ]] || [[ $file == $ignore ]]; then
                matches_ignore=1
                break
            fi
        done

        if [[ $matches_ignore -eq 0 ]]; then
            RUN_ALL=1
            echo "Found changes: $file. Run all tests"
            break
        fi
    fi
done

LIST_FILE_DIFF=$(get_diff | tr ' ' '|')
if [[ $BUILDKITE_BRANCH == "main" ]]; then
    LIST_FILE_DIFF=$(get_diff_main | tr ' ' '|')
fi
upload_pipeline
