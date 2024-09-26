# vLLM CI

This repo contains infrastructure and bootstrap code for vLLM Buildkite pipeline.

Currently, the CI infrastructure contains the following:
- Buildkite Elastic CI stack on AWS: see `infra/aws`
- 8 TPU nodes: see `infra/gcp_old`
- 1 GKE cluster (currently not in use): see `infra/gcp`

The bootstrap scripts are located in `scripts/` 
