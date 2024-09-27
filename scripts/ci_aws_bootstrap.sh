#!/bin/bash

set -euo pipefail

RUN_ALL=${RUN_ALL:-0}
VLLM_CI_BRANCH=${VLLM_CI_BRANCH:-main}

generate_pipeline() {
    python -m pip install "click==8.1.7" "pydantic==2.9.2"

    # Download necessary files
    mkdir -p .buildkite/pipeline_generator
    for FILE in pipeline_generator.py pipeline_generator_helper.py plugin.py step.py utils.py __init__.py; do
        curl -o ".buildkite/pipeline_generator/$FILE" "https://raw.githubusercontent.com/vllm-project/buildkite-ci/$VLLM_CI_BRANCH/scripts/pipeline_generator/$FILE"
    done

    # Generate and upload pipeline
    cd .buildkite
    python -m pipeline_generator.pipeline_generator --run_all="$RUN_ALL" --list_file_diff="$LIST_FILE_DIFF"
    cat pipeline.yaml
    buildkite-agent pipeline upload pipeline.yaml
}

upload_pipeline() {
    echo "Uploading pipeline..."
    ls .buildkite || buildkite-agent annotate --style error 'Please merge upstream main branch for buildkite CI'
    curl -sSfL https://github.com/mitsuhiko/minijinja/releases/latest/download/minijinja-cli-installer.sh | sh
    source /var/lib/buildkite-agent/.cargo/env
    if [ $BUILDKITE_PIPELINE_SLUG == "fastcheck" ]; then
        if [ ! -e ".buildkite/test-template-fastcheck.j2" ]; then
            curl -o .buildkite/test-template-fastcheck.j2 https://raw.githubusercontent.com/vllm-project/buildkite-ci/main/scripts/test-template-fastcheck.j2
        fi
        cd .buildkite && minijinja-cli test-template-fastcheck.j2 test-pipeline.yaml > pipeline.yml
        cat pipeline.yml
        buildkite-agent pipeline upload pipeline.yml
        exit 0
    fi
    if [ ! -e ".buildkite/test-template.j2" ]; then
        curl -o .buildkite/test-template.j2 https://raw.githubusercontent.com/vllm-project/buildkite-ci/main/scripts/test-template-aws.j2
    fi
    if [ -e ".buildkite/pipeline_generator/pipeline_generator.py" ]; then
        python -m pip install click pydantic
        python .buildkite/pipeline_generator/pipeline_generator.py --run_all=$RUN_ALL --list_file_diff="$LIST_FILE_DIFF"
        buildkite-agent pipeline upload .buildkite/pipeline.yaml
        exit 0
    fi
    cd .buildkite
    echo "List file diff: $LIST_FILE_DIFF"
    echo "Run all: $RUN_ALL"
    minijinja-cli test-template.j2 test-pipeline.yaml -D list_file_diff="$LIST_FILE_DIFF" -D run_all="$RUN_ALL" > pipeline.yml
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
for file in $file_diff; do
    for pattern in "${patterns[@]}"; do
        if [[ $file == $pattern* ]] || [[ $file == $pattern ]]; then
            RUN_ALL=1
            echo "Found changes: $file. Run all tests"
            break
        fi
    done
done

LIST_FILE_DIFF=$(get_diff | tr ' ' '|')
if [[ $BUILDKITE_BRANCH == "main" ]]; then
    LIST_FILE_DIFF=$(get_diff_main | tr ' ' '|')
fi

if [[ $BUILDKITE_PIPELINE_SLUG == "fastcheck" ]]; then
    upload_pipeline
else
    generate_pipeline
fi
