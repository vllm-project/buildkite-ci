#!/usr/bin/env python3
"""Render generated/ from prod.auto.tfvars.

    generate_manifests.py            # write generated/
    generate_manifests.py --check    # fail if generated/ is stale

The tfvars is the single source of truth for both halves of the lane: Terraform
reads it for the clusters, this reads it for the objects inside them. Anything
that would have to be kept in step by hand between the two belongs there, not
here.

generated/ is committed and reviewed, and deploy_manifests.sh applies that
rather than a fresh render - a shared cluster should only ever see what someone
read in a PR.
"""

import argparse
import difflib
import shutil
import sys
import tempfile
from pathlib import Path
from string import Template

import hcl2

K8S_DIR = Path(__file__).resolve().parent.parent
TEMPLATES = K8S_DIR / "manifests" / "templates"
TFVARS = K8S_DIR / "prod.auto.tfvars"


def clean(val):
    """hcl2 leaves the quotes on values and on keys that were written quoted.

    Those keys become Kubernetes object names, so a stray quote yields a
    ComputeClass literally named "v6e-1x1" and fails a long way from its cause.
    """
    return val.strip("\"'") if isinstance(val, str) else val


def load_tfvars():
    with TFVARS.open() as f:
        data = hcl2.load(f)

    project_id = clean(data["project_id"])
    name_prefix = clean(data["name_prefix"])

    workers = {}
    for raw_key, worker in data.get("worker_clusters", {}).items():
        key = clean(raw_key)
        workers[key] = {
            "project": clean(worker["project"]),
            # Mirrors iam.tf's account_id. Auto-created pools have to be told
            # which account to run as; nothing infers it from the cluster.
            "node_service_account": (
                f"{name_prefix}-wkr-{key}@{clean(worker['project'])}"
                ".iam.gserviceaccount.com"
            ),
            "compute_classes": {},
        }

    for raw_key, cc in data.get("tpu_compute_classes", {}).items():
        name = clean(raw_key)
        worker = clean(cc["worker"])
        if worker not in workers:
            sys.exit(
                f"tpu_compute_classes[{name}].worker = {worker!r} "
                f"is not a key of worker_clusters"
            )
        workers[worker]["compute_classes"][name] = {
            "accelerator_type": clean(cc["accelerator_type"]),
            "chips_per_node": int(cc["chips_per_node"]),
            "topology": clean(cc["topology"]),
            "reservation_name": clean(cc["reservation_name"]),
            "reservation_project": clean(
                cc.get("reservation_project", workers[worker]["project"])
            ),
            "zones": [clean(z) for z in cc["zones"]],
        }

    return project_id, workers


def render(out_dir: Path, workers):
    template = Template((TEMPLATES / "compute-class.yaml.tpl").read_text())
    # The rationale is the file's, not each object's; rendering it per document
    # would repeat it once per shape.
    header = (TEMPLATES / "compute-class.header").read_text()

    for key, worker in workers.items():
        if not worker["compute_classes"]:
            continue
        target = out_dir / f"worker-{key}"
        target.mkdir(parents=True, exist_ok=True)

        # Sorted so the committed file does not churn on dict ordering.
        docs = [
            template.substitute(
                name=name,
                node_service_account=worker["node_service_account"],
                # Flow style: the template has no way to indent a block list.
                zones="[" + ", ".join(cc["zones"]) + "]",
                **{
                    k: v
                    for k, v in cc.items()
                    if k != "zones"
                },
            )
            for name, cc in sorted(worker["compute_classes"].items())
        ]
        (target / "01-compute-classes.yaml").write_text(header + "".join(docs))


def diff_trees(committed: Path, fresh: Path) -> str:
    """Unified diff between the committed tree and a fresh render.

    Names alone would say generated/ is stale without saying how, and "rerun
    the generator" is hard to trust without seeing what that would change.
    """

    def files(root: Path) -> dict[Path, Path]:
        if not root.exists():
            return {}
        return {p.relative_to(root): p for p in root.rglob("*") if p.is_file()}

    old_files, new_files = files(committed), files(fresh)
    out = []
    for rel in sorted(old_files.keys() | new_files.keys()):
        old = old_files[rel].read_text().splitlines(keepends=True) if rel in old_files else []
        new = new_files[rel].read_text().splitlines(keepends=True) if rel in new_files else []
        if old != new:
            out += difflib.unified_diff(old, new, f"committed/{rel}", f"fresh/{rel}")
    return "".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--check",
        action="store_true",
        help="render to a scratch directory and fail if generated/ differs",
    )
    args = ap.parse_args()

    _, workers = load_tfvars()
    generated = K8S_DIR / "generated"

    if args.check:
        with tempfile.TemporaryDirectory() as tmp:
            render(Path(tmp), workers)
            drift = diff_trees(generated, Path(tmp))
        if drift:
            sys.exit(
                "generated/ does not match what prod.auto.tfvars renders:\n\n"
                + drift
                + "\nRun scripts/generate_manifests.py and commit the result, so what "
                "reaches the cluster is what was reviewed."
            )
        return

    if generated.exists():
        shutil.rmtree(generated)
    render(generated, workers)
    print(f"wrote {generated.relative_to(K8S_DIR.parent)}")


if __name__ == "__main__":
    main()
