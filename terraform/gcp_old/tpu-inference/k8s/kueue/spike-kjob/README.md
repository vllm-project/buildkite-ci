# Would kjob replace the launcher?

A spike. Nothing here is deployed, and `deploy_manifests.py` does not read this
directory.

The launcher started as "submit a Job, stream its logs, exit with its status"
and has grown past that. [kjob][kjob] (`kubectl kjob`, formerly `kjobctl`, a
Kubernetes SIG project alongside Kueue) is the obvious candidate to take some of
it back, because it is aimed at exactly this shape of problem: run a templated
Job without hand-editing YAML. This directory is the attempt, so the question
can be settled by looking at artifacts.

**Conclusion: it does not simplify this, and the reason is structural rather
than a missing feature we could wait for.** The detail is below. The short
version is that kjob can carry three of the four values a step varies, and the
fourth - the image - is the one that forces us to keep the machinery the other
three would have removed.

[kjob]: https://github.com/kubernetes-sigs/kjob

## Reproducing the numbers

```
./scripts/kjob_spike.py --summary
```

It reads the two files the launcher reads - the profile registry in
`kueue/generated/manager/workload/10-launcher.yaml` and `kueue/launcher/job.yaml` -
and emits what kjob needs to express the same five shapes. The `.yaml` files
here are its committed output, so the size is readable without running it.

```
shapes:                        5
kjob CRs emitted:              10 (5 JobTemplate + 5 ApplicationProfile)
kjob YAML lines:               530
replaces job.yaml:             131 lines
replaces profile registry:      45 lines
net YAML delta:               +354 lines
```

Line attribution for `launcher/launch.py` (1149 lines), by responsibility:

| lines | responsibility | can kjob take it? |
|------:|----------------|-------------------|
| 323 | templating and the profile registry | this is what it targets |
| 280 | submit, watch, log streaming, status | no - see below |
| 249 | `main()`: argument parsing and the watch loop | the watch loop, no |
| 110 | module header and constants | n/a |
|  64 | env forwarding and secret lookup | no flag |
|  56 | image resolution and digest pinning | no flag |
|  33 | ownership and correlation labels | partially |
|  30 | manifest validation | no |

Regenerate with:

```
python3 - <<'EOF'
import re
src = open("kueue/launcher/launch.py").read().splitlines()
defs = [(i, m.group(2)) for i, l in enumerate(src)
        if (m := re.match(r"^(def |class )(\w+)", l))] + [(len(src), "EOF")]
for (a, n), (b, _) in zip(defs, defs[1:]):
    print(f"{b - a:5d}  {n}")
EOF
```

## What kjob actually offers

From v0.1.0, the only release (January 2025), and from `pkg/cmd` on `main`:

- **Commands**: `create`, `delete`, `describe`, `list`, `printcrds`, `version`.
- **Modes**: `Interactive`, `Job`, `RayJob`, `RayCluster`, `Slurm`.
- **`create job` flags that vary a run**: `--cmd`, `--parallelism`,
  `--completions`, `--request`, `--localqueue`, `--priority`, `--time`,
  `--pod-template-label`, `--pod-template-annotation`.

Everything else about a workload lives in the `JobTemplate` the
`ApplicationProfile` points at. That is the design, and it is a good one for the
audience it names - a researcher picking a preset and changing the command.

Three of our five per-shape values land on flags cleanly:

| launcher profile field | kjob |
|---|---|
| `queue` | `--localqueue` |
| `chips` | `--request google.com/tpu=N` |
| `max_runtime_seconds` | `--time` |
| `topology`, `accelerator_label` | no flag - `nodeSelector`, baked per template |
| `fuse_cache_size` | no flag - `emptyDir.sizeLimit`, baked per template |

That is why the spike emits ten CRs for five shapes rather than one template and
five invocations.

## The two blockers

### The image is per-build, and there is no flag for it

Every step runs an image built by that build:
`.../vllm-tpu:<tpu-inference-sha>-<vllm-sha>-tpu6e`. `resolve_image()` reads it
from the step environment and `pin_digest()` resolves it to a digest before
submission.

`kjobctl create job` has no `--image`. The image can only come from the
`JobTemplate`, which is a cluster object written ahead of time.

This is the structural part. It is not that we lose one feature - it is that the
only ways out put us back where we started or somewhere worse:

- Patch the `JobTemplate` before each run. That is template substitution, which
  is what `render()` already does, plus a write to a cluster object shared by
  every concurrent build. Strictly worse.
- Inject the image with a mutating webhook keyed off
  `--pod-template-annotation`. A webhook in the admission path of every TPU step,
  to avoid a string replacement.
- Keep `render()` for the image alone. Then we keep the manifest loading, the
  placeholder substitution and the YAML round-trip - which is the machinery the
  323 templating lines *are*. kjob's templating then buys nothing, and we have
  added a CRD group and ten CRs to keep in sync with `job.yaml`.

The third is the honest one, and it is why the savings do not survive contact.

### There is no JobSet mode, and the disagg workload is a JobSet

`apis/v1alpha1` defines `JobTemplate`, `RayClusterTemplate`, `RayJobTemplate`
and `VolumeBundle`. There is no JobSet template and no JobSet mode.

P/D disaggregation is a JobSet: prefill, decode and benchmark as separate
replicated jobs wired with `dependsOn`. It reaches the launcher through
`--manifest`, which kjob has no equivalent of. So the launcher stays for that
path regardless, and "simplify" would mean running two submission paths instead
of one.

## What it cannot do that we currently depend on

`create`, `delete`, `describe`, `list`, `printcrds`, `version` is the whole
surface. There is no `logs`, no `wait`, no `--follow`, and no status
propagation - `grep -r wait pkg/cmd` finds nothing relevant. So none of this is
covered:

- **Waiting for the workload and exiting with its result.** A Buildkite step is
  a process whose exit code is the test result. `create job` returns once the
  object is created.
- **Streaming logs from a different cluster.** The agent runs on the manager;
  the pods run on a worker, reached over Connect Gateway. `LogCollector`,
  `worker_env()` and `worker_pods()` exist for this. kjob has no log command at
  all, let alone a cross-cluster one.
- **Reporting why a workload is not running.** `describe_admission()` and
  `startup_note()` turn Kueue conditions and pod events into a line per state
  change, so a step queued behind capacity says so instead of going silent.
- **Cleaning up on cancellation.** The SIGTERM handler and the
  `ownerReference` release the chips when a build is cancelled.
- **Env forwarding.** `--env NAME` passes a value from the step without it
  appearing in the pipeline file. No kjob flag carries environment.

These are 280 lines plus most of `main()`, and they are the part that is
actually load-bearing.

## Two smaller findings

**The comments do not survive.** `job.yaml` is 131 lines of which a good half
explain why - why `safe-to-evict` is false, why the fuse cache is in RAM, why
`dshm` is 16Gi. Rendering it into five `JobTemplate` CRs drops all of it, and
leaves five copies to keep in step. Compare `spike-kjob/tpu-ct6e-standard-8t-2x4.yaml`
against `launcher/job.yaml`.

**It would make the launcher image bigger, not smaller.** The `kubectl-kjob`
binary is 78 MB (`kubectl-kjob-linux-amd64`, v0.1.0). The image is already 1.25 GB
and slow to cold-pull; this adds to that rather than helping.

## Project health

Worth stating plainly, because it bears on adopting an `x-k8s.io` CRD group into
the admission path of every TPU test:

- One release, `v0.1.0`, January 2025.
- Commit activity: steady through 2025, then 1 commit in March 2026, 3 in May
  2026, and nothing since June 2026.
- 9 open issues, 44 stars.
- Installation is `make install` plus a Go build, or an unsigned release binary.

Not abandoned, but not a project to depend on for the critical path.

## The comparison that matters is three-way

Measuring kjob against the launcher as it stands understates the problem,
because there is a third option that changes the shape rather than the line
count: let agent-stack-k8s's own `batch/v1` Job carry
`kueue.x-k8s.io/queue-name` and let Kueue suspend it directly, with no launcher
in the middle for single-pod steps.

That option is being evaluated separately and is not settled. What matters here
is where each one lands:

| | single-pod lanes | JobSet lanes (disagg, multihost) | step shows `running` while queued |
|---|---|---|---|
| launcher today | launcher | launcher | yes |
| launcher + kjob | launcher, thinner in templating only | launcher | yes |
| native controller + Kueue | no launcher | still needs a submitter | no |

Two things follow.

The first is that kjob does not touch the symptom the launcher is most often
criticised for. The Buildkite step reads `running` from the moment the launcher
pod starts, because that pod has acquired the job and is now waiting on chips.
kjob is a better submitter; the launcher still acquires and still waits. The UI
lies exactly as much afterwards.

The second is the one that decides this. kjob's savings are entirely in the
single-pod lane - the JobSet path has no kjob equivalent at all. That is the
same lane the native-controller option removes outright. So kjob is only worth
adopting in the world where we keep the launcher for single-pod steps, which is
the world the other option is trying to leave. Spending a CRD group and ten CRs
on it now would be spending them on the part most likely to be deleted.

## What I would do instead

The premise behind the question is right - the launcher does more than submit
and watch, and some of it does not belong there. kjob is just not the lever.
The responsibilities that do have somewhere better to go:

- **Secret Manager lookup** (`secret_env()`, 28 lines and a `gcloud` dependency)
  → the GKE Secret Manager add-on / SecretSync CSI, already in use for the
  vllm-torchtpu deploy key. Mount secrets into the workload pod and delete the
  code path.
- **Manifest validation** (`validate()`, 30 lines) → ValidatingAdmissionPolicy.
  In-tree CEL, and enforced cluster-side rather than by a script a caller can
  bypass, which makes it stronger as well as smaller.
- **Digest pinning** (`pin_digest()`, 32 lines and a `gcloud` call on the hot
  path) → have the image build emit its digest.

Together that is roughly 90 lines and both `gcloud` dependencies, which also
unblocks a much smaller launcher base image. Cross-cluster log streaming and
Buildkite lifecycle coupling stay - nothing off the shelf does them, which is
the same reason kjob cannot.

And ahead of all of it, settle the native-controller question, because it
decides how much launcher there is left to simplify.

## Notes on this evaluation

Measured against `main` at the time of writing, so `job.yaml` here is 131 lines
and does not include the `backoffLimit` change in flight on
`launcher-cleanup-on-error`.

The `kubectl-kjob` v0.1.0 darwin-arm64 binary could not be executed locally to
produce a live `--dry-run` render; it is killed on startup in this sandbox. The
capability claims above therefore come from the API types in `apis/v1alpha1`,
the `pkg/cmd` tree, and the reference docs that are generated from that source -
not from a live run. Anyone with a cluster and the CRDs installed can check them
against `kubectl kjob create job --help`.
