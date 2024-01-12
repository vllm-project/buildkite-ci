# vLLM's Buildkite Cluster

This repo contains code to bootstrap vLLM's CI cluster running on GCP for Buildkite.
It contains terraform code to create a GCE instance group, a GKE cluster, and a GAR container registry.
The GKE cluster is configured to scale to zero with node pools of L4 and 2xL4 nodes.

The GKE cluster is connected to Buildkite via the [Buildkite Agent Stack for K8s](https://github.com/buildkite/agent-stack-k8s#readme).