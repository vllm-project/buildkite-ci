# A cache bucket pair per worker cluster, in that cluster's own region.
#
# The caches are the largest single lever on how efficiently the fleet uses its
# chips, and distance decides their cost: a compilation-cache miss costs about
# 502ms against a bucket 10,000 km away and 36ms against one in the cluster's
# region. A compile-heavy step asks whether an entry exists far more often than
# it reads one, so out-of-region caches roughly double a suite's chip-minutes.
#
# Two buckets rather than one with two prefixes. The gcsfuse CSI driver
# identifies a volume by volumeHandle, which is the bucket name, so two
# PersistentVolumes over one bucket are one volume to the kubelet: it mounts
# once and both mountPaths land on the same directory, so /cache/jax lists the
# model cache. It also lets the two keep their own retention: compilation
# output is cheap to recreate and churns, a model is expensive to fetch and
# rarely changes.

resource "google_storage_bucket" "workload" {
  for_each = local.workload_buckets

  name     = each.value.name
  project  = each.value.project
  location = each.value.location

  uniform_bucket_level_access = true
  storage_class               = "STANDARD"

  # Real folders, and fixed at creation - changing it means replacing the
  # bucket. It matters because of how gcsfuse writes: every write goes to a
  # temporary object and is then renamed, which on a flat bucket is a copy plus
  # a delete. HNS makes it an atomic folder operation with up to 8x the initial
  # QPS limit. Requires uniform bucket-level access, set above.
  #
  # It rules out object versioning, retention and bucket lock, cross-bucket
  # replication and object-level ACLs. A rebuildable cache uses none of those.
  hierarchical_namespace {
    enabled = true
  }

  # No soft delete. It defaults to on with seven days' retention, and
  # soft-deleted objects accrue storage charges for the whole of it. A cache
  # deletes continuously - gcsfuse renames through copy-and-delete, and the
  # lifecycle rule below expires on a schedule - so a week of them would cost
  # more than the cache itself, to protect data that is recomputable.
  soft_delete_policy {
    retention_duration_seconds = 0
  }

  # Nothing here is public and nothing should become public by accident. These
  # hold model weights and compilation output for a CI fleet.
  public_access_prevention = "enforced"

  # The caches are rebuildable by definition - a lost entry costs a recompile,
  # not data - but rebuilding all of it costs about 2.7x a suite's chips, so do
  # not let a terraform mistake take it. Emptying them is a deliberate step in
  # the runbook, not something a destroy does on the way past.
  force_destroy = false

  lifecycle_rule {
    condition {
      age = each.value.retention_days
    }
    action {
      type = "Delete"
    }
  }

  # Resumable uploads that never finished. gcsfuse uploads large objects in
  # parts, and a pod evicted or killed mid-write leaves those parts behind,
  # billed as storage and invisible to an object listing.
  lifecycle_rule {
    condition {
      age = 1
    }
    action {
      type = "AbortIncompleteMultipartUpload"
    }
  }

  # No label for the cluster: a bucket already sits in the worker's project, and
  # that with the region below is the pair that identifies one.
  labels = merge(local.common_labels, {
    purpose = "tpu-ci-${each.value.purpose}"
    region  = each.value.location
  })
}

# Bucket-scoped and additive on purpose. _member manages exactly one (bucket,
# role, member) tuple; _binding would own the whole role and _policy the whole
# bucket, either of which fights anything else managing IAM here.
#
# Granted to tpu-workload rather than the namespace's default account, since
# default is what a pod gets when it names none - and the launcher will run
# images named by a pull request.
resource "google_storage_bucket_iam_member" "workload" {
  for_each = local.workload_buckets

  bucket = google_storage_bucket.workload[each.key].name
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${each.value.project}.svc.id.goog[${var.namespace}/tpu-workload]"
}
