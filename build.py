#!/usr/bin/env python3
"""Local build orchestration for the Bootc examples.

Builds and inspects the content images locally, and provides the keygen, seal
and verify flow for the sealed variants.

The IMAGES table below is the single source of truth for image names,
Containerfile targets and the CI matrix. Add new images here; both local builds
and the GitHub Actions workflow use the table (the workflow runs
``./build.py matrix`` to fan out its jobs).

Sealed variants set ``requires_keys`` and build the ``sealed`` Containerfile
target. The db private key is never committed:

* local demo: generated under ``target/keys/`` (gitignored)
* GitHub Actions: repository secret ``SECUREBOOT_DB_KEY``

The public certificates (``keys/PK.crt``, ``keys/KEK.crt``, ``keys/db.crt``)
and UEFI enrollment blobs are safe to commit; the private keys are not. CI
refuses to publish a sealed image on the default branch without the repository
key, unless ``ALLOW_EPHEMERAL_SEAL_KEY=true`` is set as a repository variable.

Usage:
    ./build.py doctor
    ./build.py images
    ./build.py build --image nginx --tag demo
    ./build.py shell --image nginx --tag demo
    ./build.py keygen --demo
    ./build.py seal --image nginx-sealed --tag demo
    ./build.py verify --image nginx-sealed --tag demo
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
DEFAULT_KEY_DIR = ROOT / "target" / "keys"


@dataclass(frozen=True)
class Image:
    name: str
    target: str
    containerfile: str = "Containerfile"
    description: str = ""
    ci: bool = True
    # Registry image name; defaults to `name`. A sealed variant publishes
    # under the content image name with its own tag (e.g. nginx:sealed).
    image_name: Optional[str] = None
    # Publish only this tag for the image (used by sealed variants).
    tag_override: Optional[str] = None
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
    # Sealed demo: build the nginx content stage and seal it with the
    # repository Secure Boot key hierarchy. CI publishes this as nginx:sealed;
    # the image table carries the sealed flag and tag override into the matrix.
    "nginx-sealed": Image(
        "nginx-sealed",
        "sealed",
        description="nginx sealed with UKI + composefs + fs-verity",
        image_name="nginx",
        tag_override="sealed",
        requires_keys=True,
    ),
}


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


def resolve_key_dir(value: Optional[str]) -> Path:
    path = Path(value).expanduser() if value else DEFAULT_KEY_DIR
    if not path.is_absolute():
        path = ROOT / path
    return path.resolve()


def require_keys(directory: Path) -> None:
    missing = [
        directory / name
        for name in ("db.key", "db.crt")
        if not (directory / name).is_file()
    ]
    if missing:
        die(
            "missing "
            + ", ".join(str(path) for path in missing)
            + "; run ./build.py keygen --demo first"
        )


def require_cert(directory: Path) -> Path:
    cert = directory / "db.crt"
    if not cert.is_file():
        die(
            f"missing {cert}; run ./build.py keygen --demo first, or pass "
            "--key-dir with the certificate that signed the image"
        )
    return cert


def ensure_image(manager: str, ref: str, image_name: str, build_command: str, tag: str) -> None:
    probe = subprocess.run(
        [manager, "image", "inspect", ref],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if probe.returncode != 0:
        die(
            f"{ref} not found; run ./build.py {build_command} --image "
            f"{image_name} --tag {tag}"
        )


def matrix_include() -> List[dict]:
    """The image list CI consumes. Keep this shape stable across forges."""
    include: List[dict] = []
    for image in IMAGES.values():
        if not image.ci:
            continue
        sealed = bool(image.requires_keys)
        include.append(
            {
                "image": image.name,
                "containerfile": image.containerfile,
                "build_target": image.target,
                "image_name": image.image_name or image.name,
                "tag_override": image.tag_override or "",
                "sealed": sealed,
                "oci": sealed,
            }
        )
    return include


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
        else "/dev/fuse: missing (needed for sealed images)"
    )

    key_dir = DEFAULT_KEY_DIR
    if (key_dir / "db.key").exists():
        log(f"keys: found in {key_dir.relative_to(ROOT)} (keep out of git)")
    else:
        log(
            "keys: not present; run ./build.py keygen --demo "
            f"(writes {key_dir.relative_to(ROOT)})"
        )

    log("")
    log(f"Content builds: {'ready' if ok else 'not ready'}")
    sealed = ok and fuse.exists()
    log(
        "Sealed images: "
        + ("ready" if sealed else "not ready")
        + "; run ./build.py keygen --demo, then ./build.py seal --image nginx-sealed"
    )
    return 0 if ok else 1


def cmd_images(args: argparse.Namespace) -> int:
    if args.json:
        print(json.dumps([asdict(image) for image in IMAGES.values()], indent=2))
        return 0

    rows = [
        ("NAME", "TARGET", "CONTAINERFILE", "CI", "KEYS", "DESCRIPTION"),
    ]
    for image in IMAGES.values():
        rows.append(
            (
                image.name,
                image.target,
                image.containerfile,
                "yes" if image.ci else "no",
                "yes" if image.requires_keys else "-",
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
            "this is a sealed image; use ./build.py seal --image "
            f"{image.name} --tag {args.tag}"
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
        ensure_image(manager, ref, image.name, "build", args.tag)

    return run_command(
        [manager, "run", "--rm", "-it", "--entrypoint", "/bin/bash", ref],
        args.dry_run,
    )


def cmd_keygen(args: argparse.Namespace) -> int:
    if not args.demo:
        die(
            "keygen only creates an ephemeral demo hierarchy; pass --demo. "
            "For a real hierarchy, run keys/util/keygen.sh directly."
        )

    directory = resolve_key_dir(args.key_dir)
    script = ROOT / "keys" / "util" / "keygen.sh"
    if not script.is_file():
        die(f"keygen script not found: {script.relative_to(ROOT)}")

    code = run_command(["bash", str(script), str(directory)], args.dry_run)
    if code != 0:
        return code

    auth_dir = ROOT / "keys" / "auth" / "auto"
    if not args.dry_run:
        auth_dir.mkdir(parents=True, exist_ok=True)

    if args.with_auth:
        manager = require_container_mgr(args.container_mgr)
        if manager == "buildah":
            die("buildah cannot run the enrollment container; use podman or docker")
        try:
            relative_keys = directory.relative_to(ROOT)
        except ValueError:
            die("--key-dir must be inside the repository when using --with-auth")
        code = run_command(
            [
                manager,
                "run",
                "--rm",
                "-v",
                f"{ROOT}:/work:z",
                "-w",
                "/work",
                "-e",
                f"KEYS_DIR={relative_keys}",
                "-e",
                "OUT_DIR=keys/auth/auto",
                "quay.io/fedora/fedora:44",
                "bash",
                "-c",
                "dnf -y install sbsigntools >/dev/null && ./keys/util/gen-auth.sh",
            ],
            args.dry_run,
        )
        if code != 0:
            return code
        # Keep the committed public certificates in sync with the enrollment
        # blobs so CI can verify the same key hierarchy that signed the image.
        if not args.dry_run:
            for name in ("PK", "KEK", "db"):
                shutil.copyfile(
                    directory / f"{name}.crt", ROOT / "keys" / f"{name}.crt"
                )

    if not args.dry_run:
        log(f"demo keys in {directory} (never commit *.key)")
        log("CI: set SECUREBOOT_DB_KEY to the contents of db.key")
        if not args.with_auth:
            log(
                "no enrollment blobs generated; pass --with-auth before a "
                "Secure Boot VM boot"
            )
        else:
            log(
                "updated keys/{PK,KEK,db}.crt and keys/auth/auto/*.auth; "
                "commit the public material and set SECUREBOOT_DB_KEY from db.key"
            )
    return 0


def cmd_seal(args: argparse.Namespace) -> int:
    image = IMAGES.get(args.image)
    if not image or not image.requires_keys:
        die("choose a sealed image; run ./build.py images")

    manager = require_container_mgr(args.container_mgr)
    if manager != "podman":
        die(
            "sealed builds currently require podman (the build needs "
            "--device /dev/fuse, --cap-add=all and an SELinux label)"
        )

    containerfile = ROOT / image.containerfile
    if not containerfile.is_file():
        die(f"Containerfile not found: {image.containerfile}")

    if not args.dry_run:
        if not Path("/dev/fuse").exists():
            die("/dev/fuse is missing; sealed builds need fuse (see ./build.py doctor)")
        require_keys(resolve_key_dir(args.key_dir))

    directory = resolve_key_dir(args.key_dir)
    ref = local_tag(image.name, args.tag)
    cmd = [
        manager,
        "build",
        "--device",
        "/dev/fuse",
        "--cap-add=all",
        "--security-opt=label=type:container_runtime_t",
        "-f",
        str(ROOT / image.containerfile),
        "--target",
        image.target,
        "--secret",
        f"id=secureboot_key,src={directory / 'db.key'}",
        "--secret",
        f"id=secureboot_cert,src={directory / 'db.crt'}",
        "-t",
        ref,
    ]
    if args.pull:
        cmd.insert(2, "--pull=always")
    cmd.append(str(ROOT))

    code = run_command(cmd, args.dry_run)
    if code == 0 and not args.dry_run:
        log(f"sealed {ref}")
        log(
            "verify with: ./build.py verify --image "
            f"{image.name} --tag {args.tag}"
        )
    return code


def cmd_verify(args: argparse.Namespace) -> int:
    image = IMAGES.get(args.image)
    if not image or not image.requires_keys:
        die("choose a sealed image; run ./build.py images")

    manager = require_container_mgr(args.container_mgr)
    if manager == "buildah":
        die("buildah cannot run images; use podman or docker")

    ref = local_tag(image.name, args.tag)
    if not args.dry_run:
        ensure_image(manager, ref, image.name, "seal", args.tag)

    directory = resolve_key_dir(args.key_dir)
    if not args.dry_run:
        require_cert(directory)

    script = r"""
set -eux
kver=$(ls /usr/lib/modules)
ls -lh /boot/EFI/Linux/
# --list is diagnostic; --cert is the enforced check that the expected key
# actually signed the image.
sbverify --list "/boot/EFI/Linux/${kver}.efi"
sbverify --cert /keys/db.crt "/boot/EFI/Linux/${kver}.efi"
sbverify --list /usr/lib/systemd/boot/efi/systemd-bootx64.efi
sbverify --cert /keys/db.crt /usr/lib/systemd/boot/efi/systemd-bootx64.efi
objdump -s -j .cmdline "/boot/EFI/Linux/${kver}.efi"
# Read the exact UKI cmdline (not the whole PE, which embeds the kernel and
# initramfs) and assert the composefs digest is present while a traditional
# root= is absent; a stray root= would override the composefs root detection.
objcopy -O binary --only-section=.cmdline "/boot/EFI/Linux/${kver}.efi" /tmp/uki-cmdline
grep -aq "composefs.digest" /tmp/uki-cmdline
if grep -aq "root=" /tmp/uki-cmdline; then
    echo "unexpected root= in UKI cmdline" >&2
    exit 1
fi
for f in PK KEK db; do
    test -s "/usr/lib/bootc/install/secureboot-keys/auto/${f}.auth"
done
bootc --version
rpm -q bootc
test -f /usr/lib/bootc/install/00-ext4-default.toml
test -f /usr/lib/composefs/setup-root-conf.toml
""".strip()

    cmd = [manager, "run", "--rm"]
    if not args.dry_run:
        # The key directory is read-only input to the verification container.
        cmd += [
            "--security-opt=label=disable",
            "-v",
            f"{directory}:/keys:ro",
        ]
    cmd += ["--entrypoint", "/bin/bash", ref, "-c", script]
    return run_command(cmd, args.dry_run)


def cmd_matrix(args: argparse.Namespace) -> int:
    if args.compact:
        print(json.dumps({"include": matrix_include()}, separators=(",", ":")))
    else:
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

    keygen = sub.add_parser(
        "keygen", help="generate an ephemeral demo Secure Boot key hierarchy"
    )
    keygen.add_argument(
        "--demo",
        action="store_true",
        help="required: create demo keys under target/keys (never commit them)",
    )
    keygen.add_argument("--key-dir", help="key directory (default: target/keys)")
    keygen.add_argument(
        "--with-auth",
        action="store_true",
        help="also generate UEFI .auth enrollment blobs in a container",
    )
    keygen.add_argument("--container-mgr", choices=("podman", "docker", "buildah"))
    keygen.add_argument("--dry-run", action="store_true")
    keygen.set_defaults(func=cmd_keygen)

    seal = sub.add_parser("seal", help="build a sealed image with demo keys")
    seal.add_argument("--image", default="nginx-sealed", choices=sorted(IMAGES))
    seal.add_argument("--tag", default=DEFAULT_TAG)
    seal.add_argument("--key-dir", help="key directory (default: target/keys)")
    seal.add_argument("--container-mgr", choices=("podman", "docker", "buildah"))
    seal.add_argument("--pull", action="store_true", help="always pull the base image")
    seal.add_argument("--dry-run", action="store_true", help="print the command only")
    seal.set_defaults(func=cmd_seal)

    verify = sub.add_parser("verify", help="inspect a sealed image's UKI and config")
    verify.add_argument("--image", default="nginx-sealed", choices=sorted(IMAGES))
    verify.add_argument("--tag", default=DEFAULT_TAG)
    verify.add_argument("--key-dir", help="key directory (default: target/keys)")
    verify.add_argument("--container-mgr", choices=("podman", "docker", "buildah"))
    verify.add_argument("--dry-run", action="store_true")
    verify.set_defaults(func=cmd_verify)

    matrix = sub.add_parser("matrix", help="print the CI image matrix as JSON")
    matrix.add_argument(
        "--compact",
        action="store_true",
        help="single-line JSON for CI matrix outputs",
    )
    matrix.set_defaults(func=cmd_matrix)

    return parser


def main(argv: Optional[List[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
