#!/usr/bin/env python3
"""Local build orchestration for the Bootc examples.

Stage 1 (this file): build and inspect the content images locally.
Stage 2 (next):      seal a content image with a demo Secure Boot key.

The IMAGES table below is the single source of truth for image names,
Containerfile targets and the CI matrix. Add new images here; CI can consume
``./build.py matrix`` instead of hard-coding the list in a workflow.

Sealed variants (stage 2) add ``sealed_from`` and ``requires_keys``. The db
private key is never committed:

* local demo: generated under ``target/keys/`` (gitignored)
* GitHub Actions: repository secret ``SECUREBOOT_DB_KEY``
* GitLab CI: masked/protected CI/CD variable ``SECUREBOOT_DB_KEY``

The public certificate (``keys/db.crt``) and UEFI enrollment blobs are safe to
commit; the private key is not.

Usage:
    ./build.py doctor
    ./build.py images
    ./build.py build --image nginx --tag demo
    ./build.py shell --image nginx --tag demo
    ./build.py matrix | jq
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Dict, List, NoReturn, Optional

ROOT = Path(__file__).resolve().parent
LOCAL_REGISTRY = "localhost"
DEFAULT_TAG = "latest"


@dataclass(frozen=True)
class Image:
    name: str
    target: str
    containerfile: str = "Containerfile"
    description: str = ""
    ci: bool = True
    # Reserved for stage 2 (sealed images). The table carries the metadata now
    # so adding the seal chain does not change the CLI or the CI matrix shape.
    sealed_from: Optional[str] = None
    sealed_target: Optional[str] = None
    requires_keys: bool = False


# The image names match the build targets in Containerfile, except k3s and nas
# which have their own Containerfiles. `ci` controls what `./build.py matrix`
# publishes; local-only stages stay out of the default CI matrix.
IMAGES: Dict[str, Image] = {
    "base": Image(
        "base",
        "base",
        description="Fedora bootc base with cloud-init, cockpit, distrobox",
    ),
    "observability": Image(
        "observability",
        "observability",
        description="Base plus Alloy for metrics and logs",
        ci=False,
    ),
    "prometheus": Image(
        "prometheus",
        "prometheus",
        description="Observability plus Prometheus, Loki and Grafana",
    ),
    "nginx": Image(
        "nginx",
        "nginx",
        description="Observability plus nginx and Pi-hole quadlets",
    ),
    "k3s": Image(
        "k3s",
        "k3s",
        containerfile="k3s/Containerfile",
        description="Base plus k3s server and agent",
    ),
    "nas": Image(
        "nas",
        "nas",
        containerfile="nas/Containerfile",
        description="CentOS Stream 10 NAS with OpenZFS (kernel-tracked)",
        ci=True,
    ),
}

# Stage 2 will add entries like:
#   "nginx-sealed": Image(
#       "nginx-sealed", "sealed",
#       sealed_from="nginx", sealed_target="sealed", requires_keys=True,
#       description="nginx sealed with UKI + composefs + fs-verity",
#   ),
# `seal` will pass --build-arg SEALED_FROM=<sealed_from> and mount the db key
# and cert as podman secrets.


def log(message: str) -> None:
    """Diagnostics go to stderr so stdout stays machine-readable."""
    print(message, file=sys.stderr)


def die(message: str, code: int = 1) -> NoReturn:
    log(f"error: {message}")
    raise SystemExit(code)


def find_container_mgr(explicit: Optional[str] = None) -> Optional[str]:
    """Return the container manager to use, or None if none is available."""
    if explicit:
        return explicit if shutil.which(explicit) else None
    env = os.environ.get("CONTAINER_MGR")
    if env:
        return env if shutil.which(env) else None
    for candidate in ("podman", "docker", "buildah"):
        if shutil.which(candidate):
            return candidate
    return None


def require_container_mgr(explicit: Optional[str]) -> str:
    manager = find_container_mgr(explicit)
    if not manager:
        die(
            "no container manager found; install podman (recommended) or "
            "docker, or pass --container-mgr"
        )
    return manager


def local_tag(image: str, tag: str) -> str:
    return f"{LOCAL_REGISTRY}/{image}:{tag}"


def matrix_include() -> List[dict]:
    """The image list CI consumes. Keep this shape stable across forges."""
    return [
        {
            "image": image.name,
            "containerfile": image.containerfile,
            "build_target": image.target,
        }
        for image in IMAGES.values()
        if image.ci
    ]


def run_command(cmd: List[str], dry_run: bool = False) -> int:
    log("+ " + shlex.join(cmd))
    if dry_run:
        return 0
    try:
        return subprocess.run(cmd, cwd=ROOT).returncode
    except FileNotFoundError:
        log(f"error: {cmd[0]} not found")
        return 127


def cmd_doctor(args: argparse.Namespace) -> int:
    ok = True

    manager = find_container_mgr(args.container_mgr)
    if manager:
        proc = subprocess.run(
            [manager, "--version"], capture_output=True, text=True
        )
        version = (proc.stdout or proc.stderr).strip().splitlines()
        log(f"container manager: {manager} ({version[0] if version else 'unknown'})")
    else:
        log("container manager: not found - install podman (recommended) or docker")
        ok = False

    free_gib = shutil.disk_usage(ROOT).free / (1024**3)
    log(f"free disk: {free_gib:.1f} GiB")
    if free_gib < 20:
        log("warning: base images want roughly 20 GiB free")

    fuse = Path("/dev/fuse")
    log(
        "/dev/fuse: present"
        if fuse.exists()
        else "/dev/fuse: missing (needed for sealed images, stage 2)"
    )

    key_dir = ROOT / "target" / "keys"
    if (key_dir / "db.key").exists():
        log(f"demo keys: found in {key_dir.relative_to(ROOT)} (keep out of git)")
    else:
        log(
            "demo keys: not present; stage 2 will generate them in "
            f"{key_dir.relative_to(ROOT)}"
        )

    log("")
    log(f"Stage 1 (local content builds): {'ready' if ok else 'not ready'}")
    log("Stage 2 (sealed images): next; needs /dev/fuse and demo keys")
    return 0 if ok else 1


def cmd_images(args: argparse.Namespace) -> int:
    if args.json:
        print(json.dumps([asdict(image) for image in IMAGES.values()], indent=2))
        return 0

    rows = [
        ("NAME", "TARGET", "CONTAINERFILE", "CI", "SEALED", "DESCRIPTION"),
    ]
    for image in IMAGES.values():
        rows.append(
            (
                image.name,
                image.target,
                image.containerfile,
                "yes" if image.ci else "no",
                image.sealed_from or "-",
                image.description,
            )
        )

    widths = [max(len(row[col]) for row in rows) for col in range(6)]
    for row in rows:
        print("  ".join(row[col].ljust(widths[col]) for col in range(6)).rstrip())
    return 0


def cmd_build(args: argparse.Namespace) -> int:
    image = IMAGES.get(args.image)
    if not image:
        die(f"unknown image '{args.image}'; run ./build.py images")
    if image.requires_keys:
        die(
            "sealed builds are not wired yet; stage 2 adds ./build.py seal "
            "(see README.md)"
        )

    containerfile = ROOT / image.containerfile
    if not containerfile.is_file():
        die(f"Containerfile not found: {image.containerfile}")

    manager = require_container_mgr(args.container_mgr)
    ref = local_tag(image.name, args.tag)
    cmd = [
        manager,
        "build",
        "-f",
        str(containerfile),
        "--target",
        image.target,
        "-t",
        ref,
    ]
    if args.pull:
        cmd.insert(2, "--pull=always")
    cmd.append(str(ROOT))

    code = run_command(cmd, args.dry_run)
    if code == 0 and not args.dry_run:
        log(f"built {ref}")
    return code


def cmd_shell(args: argparse.Namespace) -> int:
    image = IMAGES.get(args.image)
    if not image:
        die(f"unknown image '{args.image}'; run ./build.py images")

    manager = require_container_mgr(args.container_mgr)
    if manager == "buildah":
        die("buildah cannot run images; use podman or docker")

    ref = local_tag(image.name, args.tag)
    if not args.dry_run:
        probe = subprocess.run(
            [manager, "image", "inspect", ref],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if probe.returncode != 0:
            die(
                f"{ref} not found; run ./build.py build --image {image.name} "
                f"--tag {args.tag}"
            )

    return run_command(
        [manager, "run", "--rm", "-it", "--entrypoint", "/bin/bash", ref],
        args.dry_run,
    )


def cmd_matrix(args: argparse.Namespace) -> int:
    print(json.dumps({"include": matrix_include()}, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Build Bootc example images locally.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    sub = parser.add_subparsers(dest="command", required=True)

    doctor = sub.add_parser("doctor", help="check local build prerequisites")
    doctor.add_argument("--container-mgr", choices=("podman", "docker", "buildah"))
    doctor.set_defaults(func=cmd_doctor)

    images = sub.add_parser("images", help="list image names and targets")
    images.add_argument("--json", action="store_true", help="print JSON")
    images.set_defaults(func=cmd_images)

    build = sub.add_parser("build", help="build one image locally")
    build.add_argument("--image", default="base", choices=sorted(IMAGES))
    build.add_argument("--tag", default=DEFAULT_TAG, help="local tag (default: latest)")
    build.add_argument("--container-mgr", choices=("podman", "docker", "buildah"))
    build.add_argument("--pull", action="store_true", help="always pull the base image")
    build.add_argument("--dry-run", action="store_true", help="print the command only")
    build.set_defaults(func=cmd_build)

    shell = sub.add_parser("shell", help="open a bash shell in a built image")
    shell.add_argument("--image", default="base", choices=sorted(IMAGES))
    shell.add_argument("--tag", default=DEFAULT_TAG)
    shell.add_argument("--container-mgr", choices=("podman", "docker", "buildah"))
    shell.add_argument("--dry-run", action="store_true")
    shell.set_defaults(func=cmd_shell)

    matrix = sub.add_parser("matrix", help="print the CI image matrix as JSON")
    matrix.set_defaults(func=cmd_matrix)

    return parser


def main(argv: Optional[List[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
