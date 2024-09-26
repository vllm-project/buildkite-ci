#!/bin/bash

set -euo pipefail

RUN_ALL=${RUN_ALL:-0}
VLLM_CI_BRANCH=${VLLM_CI_BRANCH:-main}

generate_pipeline() {
    python -m pip install "click==8.1.7" "pydantic==2.9.2"
    
    # Download necessary files
    mkdir -p .buildkite/pipeline_generator
    for FILE in pipeline_generator.py plugin.py step.py utils.py __init__.py; do
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
    
    # Install minijinja-cli
    curl -sSfL https://github.com/mitsuhiko/minijinja/releases/download/2.3.1/minijinja-cli-installer.sh | sh
    source /var/lib/buildkite-agent/.cargo/env
    
    if [[ $BUILDKITE_PIPELINE_SLUG == "fastcheck" ]]; then
        handle_fastcheck
    else
        handle_regular_pipeline
    fi
}

handle_fastcheck() {
    if [[ ! -e ".buildkite/test-template-fastcheck.j2" ]]; then
        curl -o .buildkite/test-template-fastcheck.j2 https://raw.githubusercontent.com/vllm-project/buildkite-ci/main/scripts/test-template-fastcheck.j2
    fi
    cd .buildkite && minijinja-cli test-template-fastcheck.j2 test-pipeline.yaml > pipeline.yml
    cat pipeline.yml
    buildkite-agent pipeline upload pipeline.yml
    exit 0
}

handle_regular_pipeline() {
    [ ! -e ".buildkite/test-template.j2" ] && \
        curl -o .buildkite/test-template.j2 https://raw.githubusercontent.com/vllm-project/buildkite-ci/main/scripts/test-template-aws.j2
    
    if [ -e ".buildkite/pipeline_generator/pipeline_generator.py" ]; then
        python -m pip install click pydantic
        python .buildkite/pipeline_generator/pipeline_generator.py --run_all=$RUN_ALL --list_file_diff="$LIST_FILE_DIFF"
        buildkite-agent pipeline upload .buildkite/pipeline.yaml
    else
        cd .buildkite
        echo "List file diff: $LIST_FILE_DIFF"
        echo "Run all: $RUN_ALL"
        minijinja-cli test-template.j2 test-pipeline.yaml -D list_file_diff="$LIST_FILE_DIFF" -D run_all="$RUN_ALL" > pipeline.yml
        buildkite-agent pipeline upload pipeline.yml
    fi
    exit 0
}

get_diff() {
    $(git add .)
    echo $(git diff --name-only --diff-filter=ACMDR $(git merge-base origin/main HEAD))
}

get_diff_main() {
    git add .
    git diff --name-only --diff-filter=ACMDR HEAD~1
}

# Determine if we need to run all tests
file_diff=$([ $BUILDKITE_BRANCH == "main" ] && get_diff_main || get_diff)
patterns=(".buildkite/test-pipeline" "Dockerfile" "CMakeLists.txt" "requirements*" "setup.py" "csrc/")

for file in $file_diff; do
    for pattern in "${patterns[@]}"; do
        if [[ $file == $pattern* ]] || [[ $file == $pattern ]]; then
            RUN_ALL=1
            echo "Found changes: $file. Run all tests"
            break 2
        fi
    done
done

LIST_FILE_DIFF=$(echo "$file_diff" | tr ' ' '|')
generate_pipeline