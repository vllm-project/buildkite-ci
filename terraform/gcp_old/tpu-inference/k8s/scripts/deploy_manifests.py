#!/usr/bin/env python3
"""Install Kueue and JobSet on every cluster in prod.auto.tfvars and apply this
fleet's configuration on top.

Not Terraform: the Kubernetes and Helm providers need a reachable API server at
plan time, which turns creating a cluster and configuring it into two separate
runs with a hand-edited variable between them. Here the clusters Terraform built
are the input and every apply is idempotent, so this is safe to re-run and the
plan is `kubectl diff`.

  pip install -r scripts/requirements.txt

  ./scripts/deploy_manifests.py               # diff, then confirm before applying
  ./scripts/deploy_manifests.py --mode diff   # show what would change and stop
  ./scripts/deploy_manifests.py --mode apply  # no preview, no prompt
"""

from __future__ import annotations

import argparse
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

from generate_manifests import DEFAULT_OUT, TFVARS, generate, load_tfvars

# Server-side apply records which manager owns which field, and removes any
# field a manager owned and then stopped sending. So the upstream release and
# our overlay of it cannot go on under one name: applied as "kubectl", the
# auth-plugin overlay reads as that manager's new and complete idea of the
# Deployment, and strips every field the upstream apply had just set - selector,
# image, template labels. Upstream keeps kubectl's default, so that applying the
# same release by hand behaves the same way; ours is its own.
FIELD_MANAGER = "tpu-ci"
UPSTREAM_FIELD_MANAGER = "kubectl"

UPSTREAM_MANIFESTS = {
    "kueue": "https://github.com/kubernetes-sigs/kueue/releases/download/v{version}/manifests.yaml",
    "jobset": "https://github.com/kubernetes-sigs/jobset/releases/download/v{version}/manifests.yaml",
}


def upstream(name: str, index: dict) -> str:
    return UPSTREAM_MANIFESTS[name].format(version=index[f"{name}_version"])


def run_command(*args: str, quiet: bool = False) -> None:
    """Run a command, or stop. There is no recovering from a failure here: what
    we would be continuing from is a half-configured cluster."""
    stdout = subprocess.DEVNULL if quiet else None
    if subprocess.run(args, stdout=stdout).returncode:
        raise SystemExit(f"failed: {shlex.join(args)}")


def ssa_flags(field_manager: str) -> list[str]:
    """Server-side is mandatory, not a preference: the workloads and jobsets
    CRDs are each over a megabyte, and a client-side apply stores the whole
    object in the last-applied-configuration annotation, capped at 256 KB.

    --force-conflicts is how our ConfigMap override survives. Applying an
    upstream release hands ownership of every field it sets back to upstream;
    taking it back is the point of applying ours afterwards. Field ownership is
    per list item, so the auth plugin's container, volume and mount collide with
    nothing.
    """
    return ["--server-side", "--force-conflicts", f"--field-manager={field_manager}"]


@dataclass(frozen=True)
class Apply:
    """One kubectl apply, and the preview of that same apply."""

    what: str
    source: str | Path
    field_manager: str = FIELD_MANAGER

    def _target(self) -> list[str]:
        # An upstream release is one file; ours are directories.
        if isinstance(self.source, Path):
            return ["-R", "-f", str(self.source)]
        return ["-f", self.source]

    def run(self) -> None:
        run_command("kubectl", "apply", *ssa_flags(self.field_manager), *self._target())

    def diff(self) -> bool:
        """Preview it. False if the preview could not be produced.

        A failure is not fatal. Before the first install there is no
        kueue-system namespace to diff namespaced objects against, so diff
        cannot work and there is nothing yet to be careful about; afterwards a
        failure is worth seeing but the apply would report it too. Either way
        the operator is told the preview is incomplete before being asked to
        confirm.
        """
        # The same flags as the apply, so the preview merges the way the apply
        # will. A client-side diff would have shown the auth-plugin overlay as a
        # clean three-field addition and said nothing about the fields it was
        # going to take off the Deployment.
        #
        # kubectl diff exits 1 when there are differences and above that when it
        # failed, so only the second is a problem.
        cmd = ["kubectl", "diff", *ssa_flags(self.field_manager), *self._target()]
        if subprocess.run(cmd).returncode > 1:
            # On stderr, next to the error it is explaining.
            print("  (could not diff the above; nothing installed yet, "
                  "or the cluster rejected it)", file=sys.stderr)
            return False
        return True


@dataclass(frozen=True)
class Settle:
    """Wait for the controllers the applies before it installed."""

    what: str = "wait for the CRDs and the controllers"

    def run(self) -> None:
        run_command("kubectl", "wait", "--for=condition=Established", "--timeout=180s",
                    "crd/clusterqueues.kueue.x-k8s.io",
                    "crd/localqueues.kueue.x-k8s.io",
                    "crd/resourceflavors.kueue.x-k8s.io",
                    "crd/jobsets.jobset.x-k8s.io")

        # Picks up both the ConfigMap and the plugin: a mounted ConfigMap
        # changing does not restart anything by itself.
        run_command("kubectl", "rollout", "restart",
                    "deployment/kueue-controller-manager", "-n", "kueue-system")
        run_command("kubectl", "rollout", "status", "deployment/kueue-controller-manager",
                    "-n", "kueue-system", "--timeout=300s")
        run_command("kubectl", "rollout", "status", "deployment/jobset-controller-manager",
                    "-n", "jobset-system", "--timeout=300s")

    def diff(self) -> bool:
        # Nothing to preview: it changes nothing, and what it waits for may not
        # exist until the applies above it have run.
        return True


def plan(cluster: dict, index: dict) -> list[Apply | Settle]:
    """The install order, written once.

    The preview walks this same list, in this same order, which is the point of
    it being a list. Held as two sequences of calls instead, the two drifted:
    the preview took the whole generated tree as one -R, kubectl diff walked it
    alphabetically, queues was read first, its missing namespace and CRDs
    aborted the run - and an overlay that would have deleted half the Kueue
    Deployment previewed clean.
    """
    base = DEFAULT_OUT / cluster["dir"]
    steps: list[Apply | Settle] = [
        # JobSet first: Kueue only enables its jobset integration for a CRD that
        # exists when the controller starts, and the rollout below is what makes
        # that true on a fresh cluster.
        Apply("JobSet release", upstream("jobset", index), UPSTREAM_FIELD_MANAGER),
        Apply("Kueue release", upstream("kueue", index), UPSTREAM_FIELD_MANAGER),

        # Immediately after, so the window in which the controller could come up
        # on upstream's default configuration - no MultiKueue, quota checks
        # blocking on undeclared resources - is as short as possible.
        Apply("fleet configuration", base / "system"),

        Settle(),

        # Before the workload directory, because ClusterQueue and LocalQueue go
        # through Kueue's validating webhook - the controller that just
        # restarted - and because the namespace everything below lives in is
        # created here.
        Apply("queues", base / "queues"),
    ]

    # Workers only. The manager runs no TPU pod, so it has neither a workload
    # service account nor a cache to mount, and generate_manifests.py writes it
    # no workload directory to apply.
    if (base / "workload").is_dir():
        steps.append(Apply("workload service account and caches", base / "workload"))

    return steps


def deploy_cluster(cluster: dict, index: dict, preview: bool) -> bool:
    """Configure one cluster, or preview it. False if the preview was partial."""
    print(f"\n=== {cluster['name']} ({cluster['location']}, {cluster['role']}) ===")

    # Only stdout is dropped. A failure here would otherwise leave the previous
    # cluster selected and quietly apply one cluster's manifests to another.
    run_command("gcloud", "container", "clusters", "get-credentials", cluster["name"],
                "--project", cluster["project"], "--location", cluster["location"],
                quiet=True)

    steps = plan(cluster, index)
    complete = True
    for position, step in enumerate(steps, start=1):
        print(f"\n-- {position}/{len(steps)} {step.what}")
        if not preview:
            step.run()
        # Not `complete and step.diff()`: every step should be previewed, and
        # short-circuiting would drop the rest after the first one that failed.
        elif not step.diff():
            complete = False
    return complete


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


def verify_buckets() -> None:
    """Every bucket a PersistentVolume names has to exist already.

    generate_manifests.py derives the name and locals.tf derives it again to
    create the bucket, so the two can drift - and Kubernetes will not notice. A
    volume naming a bucket nobody created applies cleanly and keeps working
    until a pod tries to mount it, which is somewhere else, later, and reads as
    a broken pod rather than a broken name. Terraform runs before this script,
    so by now the bucket either exists or the name is wrong.

    Read by line rather than parsed: this tree is generated, so the spelling is
    ours, and it saves the script a YAML dependency it otherwise does not need.
    """
    handles = sorted({
        line.split(":", 1)[1].strip()
        for path in DEFAULT_OUT.rglob("*.yaml")
        for line in path.read_text().splitlines()
        if line.strip().startswith("volumeHandle:")
    })
    missing = [
        bucket for bucket in handles
        if subprocess.run(
            ["gcloud", "storage", "buckets", "describe", f"gs://{bucket}"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        ).returncode
    ]
    if missing:
        raise SystemExit(
            f"\nno such bucket: {', '.join(missing)}\n"
            "A PersistentVolume names it, so either terraform has not been "
            "applied yet, or locals.tf and generate_manifests.py no longer "
            "derive the same name."
        )
    print(f"{len(handles)} cache bucket(s) exist.")


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    # One choice rather than two booleans, because the preview and the apply are
    # the same walk over the same files - what varies is only how much of it to
    # do, which is one question with three answers and not two with four.
    parser.add_argument("--mode", choices=("diff", "confirm", "apply"),
                        default="confirm",
                        help="diff: show what would change and stop. "
                             "confirm: diff, then ask before applying (default). "
                             "apply: skip the preview and the prompt.")
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
        verify_buckets()
        # In the order the generator listed them: the manager first, so its
        # queues exist before a worker starts reporting to them.
        clusters = index["clusters"]
        print(f"Kueue v{index['kueue_version']}, JobSet v{index['jobset_version']}, "
              f"{len(clusters)} cluster(s).")

        if args.mode != "apply":
            # A list, not a generator: every cluster should be previewed, and
            # all() would stop at the first one whose preview was partial.
            complete = all([
                deploy_cluster(c, index, preview=True) for c in clusters
            ])
            print()
            if not complete:
                print("Part of the preview above could not be produced; "
                      "see the notes above.")

        if args.mode == "confirm":
            if input(f"Apply to all {len(clusters)} cluster(s)? [y/N] ").lower() != "y":
                raise SystemExit("aborted")

        if args.mode != "diff":
            for cluster in clusters:
                deploy_cluster(cluster, index, preview=False)

    print("\ndone")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
