#!/usr/bin/env python3
"""Render the Kueue objects for every cluster from prod.auto.tfvars.

Kueue's queues have to agree with the node pools Terraform builds: a quota that
does not match the reservation either strands chips or admits work that can
never be scheduled. Reading the same tfvars Terraform reads keeps the two from
drifting, at the cost of parsing HCL here.

The output goes to kueue/generated/, which is committed. Reviewing a queue
change means reading the diff of the YAML that will be applied, not inferring
it from a template, and deploy_manifests.py refuses to run if the committed
tree does not match a fresh render.

generate() also returns the fleet it just rendered - the versions to install and
the clusters to install them on - which is how deploy_manifests.py knows where
to go, rather than from an index file that would be a third thing to keep in
step.
"""

from __future__ import annotations

import argparse
import hashlib
import math
import shutil
import sys
from pathlib import Path

import hcl2
import yaml

ROOT = Path(__file__).resolve().parent.parent
TFVARS = ROOT / "prod.auto.tfvars"
TEMPLATES = ROOT / "kueue" / "templates"
DEFAULT_OUT = ROOT / "kueue" / "generated"

# The namespace is read from the tfvars rather than set here, because the cache
# bucket IAM in cache.tf names the workload's service account by namespace: the
# two have to agree, and one of them has to be the source. variables.tf carries
# the reasoning for there being only the one namespace.

# What the SecretSync calls the Secret it writes, and what the agent-stack-k8s
# chart is told to read. Here rather than in either template because it is the
# join between them: the controller looks the Secret up by name, so a rename on
# one side and not the other leaves it crash-looping on a Secret that is not
# there. Nothing outside this fleet refers to it, so the value itself is
# arbitrary.
AGENT_TOKEN_SECRET_NAME = "buildkite-agent-token"

# The launcher's program, and the ConfigMap deploy_manifests.py builds out of
# it. Not rendered into the generated tree: a second copy of a program as
# indented YAML is not a diff anyone reads, and the two can disagree. Named
# here because launcher.yaml.tpl's PodTemplate mounts that ConfigMap.
LAUNCHER_SCRIPT = ROOT / "kueue" / "launcher" / "launch.py"
LAUNCHER_SCRIPT_CONFIGMAP = "tpu-launcher-scripts"
# The key is the file name under the mount, and the step's command is that
# path: /opt/launcher/launch, not `python /opt/launcher/launch.py`.
LAUNCHER_SCRIPT_KEY = "launch"

# The Job a step gets when it names hardware and nothing else, deployed the
# same way and for the same reason: it is a manifest, and a copy of it indented
# into a ConfigMap is not one anyone can read a diff of.
LAUNCHER_DEFAULT_JOB = ROOT / "kueue" / "launcher" / "job.yaml"
LAUNCHER_MANIFEST_CONFIGMAP = "tpu-launcher-manifests"
LAUNCHER_DEFAULT_JOB_KEY = "job.yaml"

# The node label GKE puts on a TPU node, by machine family. Not derivable from
# the machine type - a ct6e-standard-8t is `tpu-v6e-slice`, a tpu7x-standard-4t
# is plain `tpu7x` - so these are read off live nodes.
#
# An unlisted family is an error rather than a guess: this is what pins a pod
# to the pool its profile promised, and neither way of getting it wrong is
# reported. A label no node carries waits forever; another family's lands on
# the wrong chips.
ACCELERATOR_LABELS = {
    "ct6e": "tpu-v6e-slice",
    "tpu7x": "tpu7x",
}

# Host memory per TPU machine type, from the accelerator-optimized machine
# family documentation. Only the shapes we run are listed.
MACHINE_MEMORY_GB = {
    "ct6e-standard-1t": 176,
    "ct6e-standard-4t": 720,
    "ct6e-standard-8t": 1440,
    "tpu7x-standard-4t": 960,
}

# How much of the host a workload's gcsfuse file cache may take. Memory, not
# disk: the volume behind it is a `medium: Memory` emptyDir, which is why a
# node's ephemeral storage does not bound it and too high shows up as an OOM.
#
# Per machine type, since host memory runs from 176 GB to 1440 GB across the
# shapes we run. Only the pod's volume can vary that way - the per-mount
# fileCacheCapacity in cache_volumes.yaml.tpl cannot, a PersistentVolume being
# one object per cluster that every shape's pods bind, so that one is sized for
# the smallest shape.
FUSE_VOLUME_RATIO = 0.50
# Small enough to be safe on any host, for a machine type not listed above. Too
# low only costs read speed.
FUSE_FALLBACK = "20Gi"


# hcl2 defaults to output you can write back out as HCL, which is not what we
# want to read: a string keeps the quotes it was written with, so
# `project_id = "x"` arrives as the five characters `"x"`. Comments come back
# too, under a __comments__ key beside the variables.
TFVARS_OPTIONS = hcl2.SerializationOptions(
    strip_string_quotes=True, with_comments=False
)


def load_tfvars(path: Path) -> dict:
    with path.open() as f:
        return hcl2.load(f, serialization_options=TFVARS_OPTIONS)


def bucket_name(prefix: str, project: str, location: str, purpose: str) -> str:
    """Where a worker's cache lives, derived rather than configured.

    locals.tf derives it identically and creates the bucket; this writes the
    same string into a PersistentVolume's volumeHandle. Two derivations of one
    name can drift, and the failure is quiet - a volume pointing at a bucket
    that was never created - so deploy_manifests.py checks that every bucket a
    volume names exists before it applies anything. Change one side and the
    other has to move with it.

    The hash covers project and region, which is what identifies a cluster; the
    purpose sits beside it in the clear, so a cluster's two buckets share a
    suffix and read as a pair. The project is in the hash because a bucket name
    is globally unique across the whole of GCP.
    """
    digest = hashlib.sha256(f"{project}/{location}".encode()).hexdigest()[:8]
    return f"{prefix}-{purpose}-{digest}"


def render(name: str, **values) -> str:
    text = (TEMPLATES / f"{name}.yaml.tpl").read_text()
    for key, value in values.items():
        placeholder = "${" + key + "}"
        if placeholder not in text:
            raise KeyError(f"{name}.yaml.tpl has no {placeholder}")
        text = text.replace(placeholder, str(value))
    left = [line for line in text.splitlines() if "${" in line]
    if left:
        raise KeyError(f"{name}.yaml.tpl left unsubstituted: {left}")
    return text


def indent(text: str, spaces: int) -> str:
    pad = " " * spaces
    return "\n".join(pad + line if line else "" for line in text.rstrip().splitlines())


def cohort(queue: str) -> str:
    """The machine family, which names the ResourceFlavor and the cohort."""
    return queue.split("-")[0]


def fuse_cache_size(machine_type: str) -> str:
    """The workload's gcsfuse file cache on this machine type, as a GiB string.

    GB to GiB as well as the ratio: the machine family documentation quotes
    memory in decimal gigabytes and a Kubernetes quantity written Gi is binary,
    so taking the number across unconverted would ask for 7% more of the host
    than intended.
    """
    gb = MACHINE_MEMORY_GB.get(machine_type)
    if gb is None:
        return FUSE_FALLBACK
    return f"{int(gb * FUSE_VOLUME_RATIO * 1000**3 / 1024**3)}Gi"


def shapes(worker: dict) -> dict[str, dict]:
    """Every TPU shape a worker cluster can run, keyed by queue name.

    A queue is named for its node pool - <machine type>-<topology>, e.g.
    ct6e-standard-8t-2x4, joined the same way locals.tf joins it - rather than
    for the cluster's copy of that pool, because two regions running the same
    shape are one queue on the manager and MultiKueue picks the region.

    Everything here but the quota is a fact about the hardware, and it is the
    same dict the launcher's profile registry is built from. So the queue that
    admits a workload and the pod that lands on a node cannot disagree about
    what the shape is: they are the same three lines of tfvars, read once.
    """
    out: dict[str, dict] = {}
    for pool in worker.get("tpu_node_pools", []):
        machine_type = pool["machine_type"]
        topology = pool["topology"]
        name = f"{machine_type}-{topology}"

        # The machine type's last field is chips per VM - unlike the Buildkite
        # queue names, where tpu7x-8 counts TensorCores and means a four-chip
        # tpu7x-standard-4t.
        chips = int(machine_type.rsplit("-", 1)[-1].removesuffix("t"))
        slice_chips = math.prod(int(d) for d in topology.split("x"))
        hosts, remainder = divmod(slice_chips, chips)
        if remainder or not hosts:
            raise ValueError(
                f"{name}: a {topology} slice is {slice_chips} chips, which is "
                f"not a whole number of {machine_type} hosts at {chips} chips "
                "each"
            )

        family = machine_type.split("-")[0]
        if family not in ACCELERATOR_LABELS:
            raise KeyError(
                f"{name}: no accelerator node label known for machine family "
                f"{family!r}. Read cloud.google.com/gke-tpu-accelerator off a "
                "node of that family and add it to ACCELERATOR_LABELS; it "
                "cannot be derived from the machine type."
            )

        # A multi-host slice is admitted and built whole, so quota that is not
        # a multiple of hosts is quota this shape can never use and a ceiling
        # that is not one is a node pool GKE cannot build. Fail here rather
        # than as a workload that queues forever.
        for field in ("nominal_nodes", "max_nodes"):
            if hosts > 1 and int(pool[field]) % hosts:
                raise ValueError(
                    f"{name}: {field}={pool[field]} is not a multiple of the "
                    f"{hosts} hosts in a {topology} slice; a multi-host shape's "
                    "quota has to be whole slices"
                )

        out[name] = {
            "queue": name,
            # How a step names this shape when it asks for the built-in Job.
            # Stated rather than left implicit in the queue name, so the lookup
            # reads the registry instead of re-splitting a string.
            "machine_type": machine_type,
            "chips": chips,
            "hosts": hosts,
            "topology": topology,
            "accelerator_label": ACCELERATOR_LABELS[family],
            "fuse_cache_size": fuse_cache_size(machine_type),
            # The one number here that is a policy rather than a fact, and the
            # only one Kueue reads: this shape's share of the reservation.
            "quota": int(pool["nominal_nodes"]) * chips,
        }
    return out


def queues(shapes: dict[str, int], namespace: str, checks: bool) -> str:
    """A flavor per machine family, then a queue per shape sharing it.

    checks is what separates the manager from a worker: on the manager every
    queue carries a MultiKueue AdmissionCheck, so passing quota there means the
    workload is dispatched rather than run.
    """
    out = [
        render("resource_flavor", ACCELERATOR=family)
        for family in sorted({cohort(name) for name in shapes})
    ]
    for name, chips in sorted(shapes.items()):
        out.append(
            render(
                "queue_group",
                QUEUE_NAME=name,
                ACCELERATOR=cohort(name),
                NAMESPACE=namespace,
                NOMINAL_QUOTA=chips,
                ADMISSION_CHECKS=(
                    "\n  admissionChecksStrategy:\n"
                    "    admissionChecks:\n"
                    f"      - name: {name}-multikueue-dispatch"
                    if checks
                    else ""
                ),
            )
        )
    return "".join(out)


def launcher_profiles(fleet: dict, workers: list[str], tfvars: dict) -> str:
    """The registry the launcher resolves a workload's hardware against.

    One profile per shape, named for the shape, which is also the name of the
    Kueue queue that admits it - so a workload asks for hardware that exists in
    the fleet, or is refused before it is submitted. The manager's fleet-wide
    queues are what a profile points at; which region actually runs it is
    MultiKueue's to decide.

    Everything a workload manifest is not trusted to state itself is here,
    because it is here that it can be checked: the registries an image may come
    from, the identities a pod may run as, and the budget the launcher derives
    its admission deadline from.
    """
    return yaml.safe_dump(
        {
            # A step sets WORKLOAD_IMAGE and tpu-inference builds fork pull
            # requests, so it is attacker-controlled. Empty means unrestricted.
            "allowed_image_repos": tfvars["allowed_image_repos"],
            # Identities a workload may run as: tpu-workload is the one the
            # cache buckets authorise, default is for a manifest needing no
            # cloud access. Neither can create JobSets, unlike the launcher's
            # own account, which is the point.
            "workload_service_accounts": ["default", "tpu-workload"],
            "total_max_seconds": int(tfvars["tpu_total_max_seconds"]),
            # How the launcher gets from an admitted workload to the pod logs.
            # Kueue reports the cluster it dispatched to by MultiKueueCluster
            # name, which is also the Fleet membership ID; memberships live in
            # the manager's project whatever project the worker runs in.
            "workers": {
                name: {"membership": name, "project": tfvars["project_id"]}
                for name in sorted(workers)
            },
            "profiles": {
                name: {
                    **{
                        key: value
                        for key, value in entry["shape"].items()
                        # Kueue's, not the launcher's: what a shape's queue may
                        # hold says nothing about where one workload runs.
                        if key != "quota"
                    },
                    "max_runtime_seconds": int(tfvars["tpu_test_max_seconds"]),
                }
                for name, entry in sorted(fleet.items())
            },
        },
        sort_keys=False,
    )


# On every generated file, because the tree is committed and so reads like
# something you could edit in place. The last sentence is the operative one: an
# edit here is not just overwritten on the next render, it stops the deploy.
HEADER = """\
# Generated by scripts/generate_manifests.py from prod.auto.tfvars. Do not edit.
#
# Change the tfvars or kueue/templates/ and re-run the generator. An edit made
# here is never applied: deploy_manifests.py re-renders and refuses to deploy a
# tree that does not match.
"""


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(HEADER + text.rstrip() + "\n")


def generate(tfvars: dict, out_dir: Path) -> dict:
    project = tfvars["project_id"]
    prefix = tfvars["name_prefix"]
    namespace = tfvars["namespace"]

    # Sorted by the pair that identifies a cluster, so the render is stable
    # whatever order the tfvars lists them in - the tree is committed, and a
    # reordering that changed no configuration would still show up as a diff.
    workers = sorted(
        tfvars.get("worker_clusters", []),
        key=lambda w: (w["project"], w["location"]),
    )

    manager_name = f"{prefix}-manager"
    manager_dir = "manager"

    # Per shape, the workers that can run it and the chips they add up to. The
    # manager's quota is the fleet's, because it admits on behalf of all of
    # them; each worker then admits again against its own.
    fleet: dict[str, dict] = {}
    clusters = [
        {
            "dir": manager_dir,
            "role": "manager",
            "project": project,
            "location": tfvars["manager_region"],
            "name": manager_name,
        }
    ]

    for worker in workers:
        # Nested rather than one flattened name, so the tree groups by project
        # the way the fleet does and a region is a leaf under it. Both parts are
        # needed: two projects may each run a us-east5.
        worker_dir = f"workers/{worker['project']}/{worker['location']}"
        cluster_name = f"{prefix}-{worker['location']}"
        clusters.append(
            {
                "dir": worker_dir,
                "role": "worker",
                "project": worker["project"],
                "location": worker["location"],
                "name": cluster_name,
            }
        )

        local = shapes(worker)
        for name, shape in local.items():
            # The shape is stored once, not summed: two clusters running it
            # run the same hardware. Only the quota adds up.
            entry = fleet.setdefault(name, {"quota": 0, "workers": [], "shape": shape})
            entry["quota"] += shape["quota"]
            entry["workers"].append(cluster_name)

        base = out_dir / worker_dir
        write(base / "system" / "10-kueue-config.yaml", kueue_config("worker"))
        write(base / "queues" / "00-namespace.yaml", render("namespace", NAMESPACE=namespace))
        write(
            base / "queues" / "10-queues.yaml",
            queues(
                {name: shape["quota"] for name, shape in local.items()},
                namespace,
                checks=False,
            ),
        )
        write(
            base / "queues" / "20-multikueue-rbac.yaml",
            render("multikueue_rbac_worker", PROJECT_ID=project),
        )

        # Workers only: the TPU pods are the only thing that mounts a cache, and
        # a PersistentVolume naming the gcsfuse driver is not satisfiable on the
        # manager, which does not have it enabled.
        write(
            base / "workload" / "00-service-account.yaml",
            render("workload_sa", NAMESPACE=namespace, PROJECT_ID=worker["project"]),
        )
        write(
            base / "workload" / "10-cache-volumes.yaml",
            render(
                "cache_volumes",
                NAMESPACE=namespace,
                CACHE_BUCKET=bucket_name(
                    prefix, worker["project"], worker["location"], "cache"
                ),
                MODELS_BUCKET=bucket_name(
                    prefix, worker["project"], worker["location"], "models"
                ),
            ),
        )
        # The launcher runs on the manager; all it wants here is to read the
        # logs of the pods MultiKueue put in this cluster. PROJECT_ID is the
        # manager's, because that is the Workload Identity pool the launcher's
        # service account is federated through.
        write(
            base / "workload" / "20-launcher-rbac.yaml",
            render("launcher_rbac_worker", NAMESPACE=namespace, PROJECT_ID=project),
        )

    base = out_dir / manager_dir
    write(base / "system" / "10-kueue-config.yaml", kueue_config("manager"))
    # Manager only. A worker's TPU pods do call buildkite-agent, but with the
    # per-job access token the launcher forwards, not with this one - see the
    # template.
    write(
        base / "workload" / "00-agent-token.yaml",
        render(
            "secret_sync",
            NAMESPACE=namespace,
            PROJECT_ID=project,
            SECRET_NAME=AGENT_TOKEN_SECRET_NAME,
            AGENT_TOKEN_SECRET_ID=tfvars["agent_token_secret_id"],
        ),
    )
    write(
        base / "system" / "20-auth-plugin.yaml",
        render(
            "auth_plugin_overlay",
            AUTH_PLUGIN_IMAGE=tfvars["auth_plugin_image"],
            AUTH_PLUGIN_SRC=tfvars["auth_plugin_source_path"],
        ),
    )
    # Manager only, and after the agent token: the launcher pods are created by
    # the controller that reads it, and every TPU step in the fleet goes through
    # them. A worker gets only the log-reading grant above.
    write(
        base / "workload" / "10-launcher.yaml",
        render(
            "launcher",
            NAMESPACE=namespace,
            LAUNCHER_IMAGE=tfvars["launcher_image"],
            LAUNCHER_PROFILES=indent(
                launcher_profiles(
                    fleet,
                    [c["name"] for c in clusters if c["role"] == "worker"],
                    tfvars,
                ),
                4,
            ),
        ),
    )
    write(base / "queues" / "00-namespace.yaml", render("namespace", NAMESPACE=namespace))
    write(
        base / "queues" / "10-queues.yaml",
        queues(
            {name: entry["quota"] for name, entry in fleet.items()},
            namespace,
            checks=True,
        ),
    )
    write(
        base / "queues" / "20-multikueue.yaml",
        "".join(
            render("multikueue_cluster", WORKER_NAME=name, CLUSTER_PROFILE_NAME=profile)
            for name, profile in sorted(
                {
                    c["name"]: f"{c['name']}-{c['location']}"
                    for c in clusters
                    if c["role"] == "worker"
                }.items()
            )
        )
        + "".join(
            render("admission_check", QUEUE_NAME=queue)
            + render(
                "multikueue_config",
                QUEUE_NAME=queue,
                WORKER_LIST="\n".join(
                    f"    - {name}" for name in sorted(entry["workers"])
                ),
            )
            for queue, entry in sorted(fleet.items())
        ),
    )

    # Under charts/ rather than beside the manifests, because it is not one.
    # deploy_manifests.py applies system/, queues/ and workload/; this is an
    # input to a helm render, and applying it would be an error.
    write(
        base / "charts" / "agent-stack-k8s.yaml",
        render(
            "agent_stack_values",
            AGENT_TOKEN_SECRET_NAME=AGENT_TOKEN_SECRET_NAME,
            BUILDKITE_QUEUE=tfvars["buildkite_queue"],
        ),
    )

    return {
        "kueue_version": tfvars["kueue_version"],
        "jobset_version": tfvars["jobset_version"],
        "agent_stack_version": tfvars["agent_stack_version"],
        # For the chart render, which is the one thing deployed by flag rather
        # than by manifest and so cannot read its namespace off the object.
        "namespace": namespace,
        "clusters": clusters,
    }


def top_level_keys(text: str) -> set[str]:
    """The keys a YAML document sets at column zero."""
    return {
        line.split(":", 1)[0]
        for line in text.splitlines()
        if ":" in line and line[:1].isalpha()
    }


def kueue_config(role: str) -> str:
    """The controller ConfigMap: the shared configuration, plus the manager's.

    The two sides admit the same workload, so most of the configuration has to
    be the same on both and lives in one file rather than in two that a comment
    asks you to keep in step. The manager's extra keys are appended, which is
    only sound while the two files set disjoint top-level keys, so that is
    checked rather than trusted.
    """
    text = (ROOT / "kueue" / "common-config.yaml").read_text()
    if role == "manager":
        extra = (ROOT / "kueue" / "manager-config.yaml").read_text()
        clash = top_level_keys(text) & top_level_keys(extra)
        if clash:
            raise KeyError(
                f"manager-config.yaml also sets {sorted(clash)}; appending it to "
                f"common-config.yaml would leave the key twice in one document"
            )
        text = f"{text.rstrip()}\n{extra}"
    return render("kueue_config", CONFIG=indent(text, 4))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT)
    args = parser.parse_args()

    tfvars = load_tfvars(TFVARS)

    # Rendered into a fresh tree so a cluster or a generation that goes away
    # leaves no file behind for deploy_manifests.py to keep applying.
    if args.out_dir.exists():
        shutil.rmtree(args.out_dir)
    generate(tfvars, args.out_dir)

    print(f"wrote {args.out_dir}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
