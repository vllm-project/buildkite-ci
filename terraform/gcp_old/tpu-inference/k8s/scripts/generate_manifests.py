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
import shutil
import sys
from pathlib import Path

import hcl2

ROOT = Path(__file__).resolve().parent.parent
TFVARS = ROOT / "prod.auto.tfvars"
TEMPLATES = ROOT / "kueue" / "templates"
DEFAULT_OUT = ROOT / "kueue" / "generated"

# The one namespace, on the manager and on every worker. The agent-stack-k8s
# controller, the launcher pods it creates and the workloads those submit all
# share it, because a LocalQueue is namespaced and a workload names its queue
# from inside its own namespace. It exists on the workers too because MultiKueue
# mirrors a workload into the namespace it came from.
NAMESPACE = "buildkite"


def clean(value):
    """Undo python-hcl2's quoting of bare identifiers.

    hcl2 hands back object keys and unquoted values as the literal source text,
    so a key written `us-east5` arrives as `"${us-east5}"` or `'us-east5'`
    depending on where it sat. Strip that back to the string HCL means.
    """
    if isinstance(value, str):
        if value.startswith("${") and value.endswith("}"):
            value = value[2:-1]
        return value.strip("\"'")
    return value


def load_tfvars(path: Path) -> dict:
    with path.open() as f:
        raw = hcl2.load(f)
    return {k: clean_deep(v) for k, v in raw.items()}


def clean_deep(value):
    if isinstance(value, dict):
        return {clean(k): clean_deep(v) for k, v in value.items()}
    if isinstance(value, list):
        return [clean_deep(v) for v in value]
    return clean(value)


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


def shapes(worker: dict) -> dict[str, int]:
    """Chips under quota per node pool in a worker cluster, keyed by queue.

    A queue is named for its node pool - <machine type>-<topology>, e.g.
    ct6e-standard-8t-2x4, joined the same way locals.tf joins it - rather than
    for the cluster's copy of that pool, because two regions running the same
    shape are one queue on the manager and MultiKueue picks the region.
    """
    return {
        f"{pool['machine_type']}-{pool['topology']}": (
            # The machine type's last field is chips per VM, unlike the
            # Buildkite queue names, where tpu7x-8 counts TensorCores and is a
            # four-chip tpu7x-standard-4t.
            int(pool["nominal_nodes"])
            * int(pool["machine_type"].rsplit("-", 1)[-1].removesuffix("t"))
        )
        for pool in worker.get("tpu_node_pools", [])
    }


def queues(shapes: dict[str, int], checks: bool) -> str:
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
                NAMESPACE=NAMESPACE,
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


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text.rstrip() + "\n")


def generate(tfvars: dict, out_dir: Path) -> dict:
    project = tfvars["project_id"]
    prefix = tfvars["name_prefix"]
    workers = tfvars.get("worker_clusters", {})

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

    for worker_key in sorted(workers):
        worker = workers[worker_key]
        cluster_name = f"{prefix}-{worker_key}"
        worker_dir = f"worker-{worker_key}"
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
        for name, chips in local.items():
            entry = fleet.setdefault(name, {"chips": 0, "workers": []})
            entry["chips"] += chips
            entry["workers"].append(cluster_name)

        base = out_dir / worker_dir
        write(base / "system" / "10-kueue-config.yaml", kueue_config("worker"))
        write(base / "queues" / "00-namespace.yaml", render("namespace", NAMESPACE=NAMESPACE))
        write(base / "queues" / "10-queues.yaml", queues(local, checks=False))
        write(
            base / "queues" / "20-multikueue-rbac.yaml",
            render("multikueue_rbac_worker", PROJECT_ID=project),
        )

    base = out_dir / manager_dir
    write(base / "system" / "10-kueue-config.yaml", kueue_config("manager"))
    write(
        base / "system" / "20-auth-plugin.yaml",
        render(
            "auth_plugin_overlay",
            AUTH_PLUGIN_IMAGE=tfvars["auth_plugin_image"],
            AUTH_PLUGIN_SRC=tfvars["auth_plugin_source_path"],
        ),
    )
    write(base / "queues" / "00-namespace.yaml", render("namespace", NAMESPACE=NAMESPACE))
    write(
        base / "queues" / "10-queues.yaml",
        queues(
            {name: entry["chips"] for name, entry in fleet.items()},
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

    return {
        "kueue_version": tfvars["kueue_version"],
        "jobset_version": tfvars["jobset_version"],
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
