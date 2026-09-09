---
# One flavor per TPU generation, and deliberately no nodeLabels.
#
# The flavor, not the queue, is Kueue's quota partition: quota is counted per
# flavor, cohort borrowing is per flavor, and Kueue skips a flavor whose
# nodeLabels conflict with what a podSet already asks for. A flavor per shape
# would therefore make it impossible for a 1-chip job to use idle 8-chip
# capacity, whatever the numbers said. Bare and shared, the per-shape queues
# above it can lend to each other.
#
# Placement is the workload's: it carries the gke-tpu-accelerator,
# gke-tpu-topology and gke-accelerator-count nodeSelectors itself.
apiVersion: kueue.x-k8s.io/v1beta2
kind: ResourceFlavor
metadata:
  name: ${ACCELERATOR}
