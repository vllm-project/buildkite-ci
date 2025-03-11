# vLLM Continuous Integration (CI) Infrastructure

## Overview
This repository contains the infrastructure and bootstrap code for the vLLM continuous integration pipeline using Buildkite.

Current CI Infrastructure Setup:

- AWS Buildkite Elastic CI Stack: Infrastructure code in `infra/aws`
- 8 TPU Nodes on GCP: Infrastructure code in `infra/gcp_old`
- GKE Cluster on GCP (currently not in use): Infrastructure code in `infra/gcp`

Bootstrap scripts are located in the `scripts/` directory.

## How vLLM Uses Buildkite for CI
vLLM leverages Buildkite for CI workflow. Whenever a commit is pushed to the vLLM GitHub repository, a Buildkite webhook triggers an event that initiates a new build in the Buildkite pipeline with relevant details like Github branch and commit.

Build Process Overview:

- Bootstrap Step:
    - Executed via `scripts/ci_aws_bootstrap.sh`.
    - Utilizes a CI Jinja2 template (`scripts/test-template-aws.j2`) along with the [list of tests from vLLM](https://github.com/vllm-project/vllm/blob/main/.buildkite/test-pipeline.yaml) to render a Buildkite YAML configuration that defines all build/test steps and their configurations.
    - Uploads the rendered YAML to Buildkite to initiate the build.
    - Note: We are transitioning to a custom Buildkite pipeline generator to replace the Jinja2 template rendering soon.

- Job Queueing and Execution:
    - Each Buildkite step is associated with an agent queue.
    - After uploaded, steps are pushed into the queue, waiting to be picked up by a Buildkite agent.
    
## Buildkite Agent Cluster Setup
We use the [Buildkite Elastic CI Stack](https://github.com/buildkite/elastic-ci-stack-for-aws) to set up our autoscaling Buildkite agent cluster on AWS.

Components of the stack for each Agent Queue:

- AWS CloudFormation Stack:
    - Contains an EC2 Auto Scaling Group and an AWS Lambda function.

- EC2 Auto Scaling Group:
    - Automatically scales number of EC2 instances based on the workload from the Buildkite queue.
    - Each EC2 instance comes with a Buildkite agent that executes jobs.

- AWS Lambda Function:
    - Periodically polls Buildkite to assess capacity needs for the queue and adjusts the size of the Auto Scaling Group accordingly.

## How to test changes in this repo
1. Create a feature branch on this repo, say named `my-feature-branch`. If you can't create a feature branch, ping @khluu to add you into the repo.
2. Once the branch is created, you can start making changes and commit to the branch. Also, please remember to change `main` to `my-feature-branch` here: https://github.com/vllm-project/buildkite-ci/blob/main/scripts/ci_aws_bootstrap.sh#L28
3. After the changes are pushed to the branch, wait a few minutes, then create a new build on Buildkite with this environment variable `VLLM_CI_BRANCH=my-feature-branch` to test your changes against vLLM codebase.
