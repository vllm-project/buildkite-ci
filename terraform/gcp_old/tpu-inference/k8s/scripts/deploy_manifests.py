#!/usr/bin/env python3
"""Install Kueue and JobSet on every cluster in prod.auto.tfvars and apply this
fleet's configuration on top.

Not Terraform: the Kubernetes and Helm providers need a reachable API server at
plan time, which turns creating a cluster and configuring it into two separate
runs with a hand-edited variable between them. Here the clusters Terraform built
are the input and every apply is idempotent, so this is safe to re-run and the
plan is `kubectl diff`.

  pip install -r scripts/requirements.txt

  ./scripts/deploy_manifests.py              # diff, then confirm before applying
  ./scripts/deploy_manifests.py --diff-only  # show what would change and stop
  ./scripts/deploy_manifests.py --yes        # no prompt
"""

from __future__ import annotations

import argparse
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from generate_manifests import DEFAULT_OUT, TFVARS, generate, load_tfvars

UPSTREAM_MANIFESTS = {
    "kueue": "https://github.com/kubernetes-sigs/kueue/releases/download/v{version}/manifests.yaml",
    "jobset": "https://github.com/kubernetes-sigs/jobset/releases/download/v{version}/manifests.yaml",
}


def upstream(name: str, index: dict) -> str:
    return UPSTREAM_MANIFESTS[name].format(version=index[f"{name}_version"])


def run(*args: str, quiet: bool = False) -> None:
    """Run a command, or stop. There is no recovering from a failure here: what
    we would be continuing from is a half-configured cluster."""
    stdout = subprocess.DEVNULL if quiet else None
    if subprocess.run(args, stdout=stdout).returncode:
        raise SystemExit(f"failed: {shlex.join(args)}")


def show_diff(*args: str) -> bool:
    """Preview one apply. False if the preview could not be produced.

    A failure is not fatal. Before the first install there is no kueue-system
    namespace to diff namespaced objects against, so diff cannot work and there
    is nothing yet to be careful about; afterwards a failure is worth seeing but
    the apply would report it too. Either way the operator is told the preview
    is incomplete before being asked to confirm.
    """
    # kubectl diff exits 1 when there are differences and above that when it
    # failed, so only the second is a problem.
    if subprocess.run(["kubectl", "diff", *args]).returncode > 1:
        # On stderr, next to the error it is explaining.
        print("  (could not diff the above; nothing installed yet, "
              "or the cluster rejected it)", file=sys.stderr)
        return False
    return True


def apply_ssa(*args: str) -> None:
    """Server-side is mandatory, not a preference: the workloads and jobsets
    CRDs are each over a megabyte, and a client-side apply stores the whole
    object in the last-applied-configuration annotation, capped at 256 KB.

    --force-conflicts is how our ConfigMap override survives. Applying an
    upstream release hands ownership of every field it sets back to upstream;
    taking it back is the point of applying ours afterwards. Field ownership is
    per list item, so the auth plugin's container, volume and mount collide with
    nothing.
    """
    run("kubectl", "apply", "--server-side", "--force-conflicts", *args)


def deploy_cluster(cluster: dict, index: dict, diff_only: bool) -> bool:
    """Configure one cluster, or preview it. False if the preview was partial."""
    base = DEFAULT_OUT / cluster["dir"]

    print(f"\n=== {cluster['name']} ({cluster['location']}, {cluster['role']}) ===")

    # Only stdout is dropped. A failure here would otherwise leave the previous
    # cluster selected and quietly apply one cluster's manifests to another.
    run("gcloud", "container", "clusters", "get-credentials", cluster["name"],
        "--project", cluster["project"], "--location", cluster["location"],
        quiet=True)

    if diff_only:
        # A list, not a generator: all three previews should be shown, and all()
        # would stop at the first one that could not be produced.
        return all([
            show_diff("-f", upstream("jobset", index)),
            show_diff("-f", upstream("kueue", index)),
            show_diff("-R", "-f", str(base)),
        ])

    # JobSet first: Kueue only enables its jobset integration for a CRD that
    # exists when the controller starts, and the rollout at the end is what makes
    # that true on a fresh cluster.
    apply_ssa("-f", upstream("jobset", index))
    apply_ssa("-f", upstream("kueue", index))

    # Immediately after, so the window in which the controller could come up on
    # upstream's default configuration - no MultiKueue, quota checks blocking on
    # undeclared resources - is as short as possible.
    apply_ssa("-R", "-f", str(base / "system"))

    run("kubectl", "wait", "--for=condition=Established", "--timeout=180s",
        "crd/clusterqueues.kueue.x-k8s.io",
        "crd/localqueues.kueue.x-k8s.io",
        "crd/resourceflavors.kueue.x-k8s.io",
        "crd/jobsets.jobset.x-k8s.io")

    # Picks up both the ConfigMap and the plugin: a mounted ConfigMap changing
    # does not restart anything by itself.
    run("kubectl", "rollout", "restart",
        "deployment/kueue-controller-manager", "-n", "kueue-system")
    run("kubectl", "rollout", "status", "deployment/kueue-controller-manager",
        "-n", "kueue-system", "--timeout=300s")
    run("kubectl", "rollout", "status", "deployment/jobset-controller-manager",
        "-n", "jobset-system", "--timeout=300s")

    # Last, because ClusterQueue and LocalQueue go through Kueue's validating
    # webhook, which is the controller that just restarted.
    apply_ssa("-R", "-f", str(base / "queues"))
    return True


def verify_generated() -> dict:
    """Re-render the manifests, and refuse to deploy a committed tree that has
    drifted from them.

    A stale generated/ would silently deploy the previous tfvars, and the diff
    below would look clean. The cluster list comes back from that same render
    rather than from a file of its own, so what is deployed and what was checked
    cannot describe different fleets.
    """
    with tempfile.TemporaryDirectory() as fresh:
        index = generate(load_tfvars(TFVARS), Path(fresh))
        if subprocess.run(["diff", "-ru", str(DEFAULT_OUT), fresh]).returncode:
            raise SystemExit(
                "\nkueue/generated is out of date: "
                "run scripts/generate_manifests.py and commit."
            )
    return index


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--diff-only", action="store_true",
                        help="show what would change and stop")
    parser.add_argument("--yes", "-y", action="store_true",
                        help="apply without prompting")
    args = parser.parse_args()

    # Our output is interleaved with kubectl's and gcloud's, which write to the
    # terminal directly. Left buffered, every heading here arrives after the
    # output it was meant to introduce.
    sys.stdout.reconfigure(line_buffering=True)

    for tool in ("kubectl", "gcloud"):
        if shutil.which(tool) is None:
            raise SystemExit(f"{tool} is not on PATH")

    # Do not touch the operator's own kubeconfig or leave a context selected.
    with tempfile.TemporaryDirectory() as kubeconfig_dir:
        os.environ["KUBECONFIG"] = str(Path(kubeconfig_dir) / "config")

        index = verify_generated()
        # In the order the generator listed them: the manager first, so its
        # queues exist before a worker starts reporting to them.
        clusters = index["clusters"]
        print(f"Kueue v{index['kueue_version']}, JobSet v{index['jobset_version']}, "
              f"{len(clusters)} cluster(s).")

        if not args.diff_only and not args.yes:
            complete = all([
                deploy_cluster(c, index, diff_only=True) for c in clusters
            ])
            print()
            if not complete:
                print("Part of the preview above is missing; "
                      "read the notes before answering.")
            if input(f"Apply to all {len(clusters)} cluster(s)? [y/N] ").lower() != "y":
                raise SystemExit("aborted")

        for cluster in clusters:
            deploy_cluster(cluster, index, diff_only=args.diff_only)

    print("\ndone")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
