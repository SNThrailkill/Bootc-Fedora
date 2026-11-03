# Bootc Examples

This repo contains some examples of how someone can use bootable containers to deploy a wide variety of applications.
The base images in this repo are based off the [Fedora bootc image](https://quay.io/repository/fedora/fedora-bootc?tab=tags).
All images come with `distrobox`, `cloud-init`, and `cockpit`.
These images assume you are using `cloud-init`, `kickstart`, or similar tool to provision your hosts with things like desired hostnames, IP addresses, etc during initial boot.

The `Containerfile` contains multiple stages that can be used to get exactly the software you need. See [Multi-stage Builds](https://docs.docker.com/build/building/multi-stage/) documentation for more information on how this works. Each image is published under its build target name; the `nginx-sealed` entry is the exception and publishes as `nginx:sealed`.

The GitHub Actions workflow and Containerfile include commented-out hooks for a private registry/repository if you need them.

The GitHub Actions also will create a [SBOM](https://anchore.com/sbom/what-is-an-sbom/) of your image using [Syft](https://github.com/anchore/syft/), run a vulnerability scan using [Grype](https://github.com/anchore/grype/), and upload the report to your Code Scanning page in the Security center of your repository. This will only work if your repo has Code Scanning enabled for your repository. [See the GitHub docs](https://docs.github.com/en/code-security/code-scanning/introduction-to-code-scanning/about-code-scanning) for which repos can enable this.

Published images are rechunked with [chunkah](https://github.com/coreos/chunkah) before they are pushed. Instead of keeping the Dockerfile layer boundaries, the image is split into content-based layers, so a bootc host only pulls the layers that actually changed between updates. The splitter prunes the OSTree `/sysroot` data and keeps the `containers.bootc=1` label.

## Build locally

The examples build with podman (or docker) and Python 3.9+. `build.py` is the
single source of truth for the image list. The GitHub Actions workflow runs
`./build.py matrix` and fans out from it, so the same table drives local builds
and CI. `just` recipes are a convenience wrapper.

```bash
./build.py doctor
./build.py images
./build.py build --image nginx --tag demo
./build.py shell --image nginx --tag demo
```

`./build.py matrix` prints the image matrix as JSON. The GitHub Actions
workflow runs it with `--compact` and passes each entry to the reusable build
workflow, including the sealed entry (`nginx` target `sealed`, `SEALED_FROM=nginx`,
tag `sealed`). Add a new image to `IMAGES` in `build.py` and it joins the
matrix; no workflow edit is required.

### Sealed images (demo)

The `sealed` target builds a content stage with a signed UKI, a composefs root
and fs-verity. The demo uses a throwaway key hierarchy so attendees do not need
to manage Secure Boot keys:

```bash
./build.py keygen --demo
./build.py seal --image nginx-sealed --tag demo
./build.py verify --image nginx-sealed --tag demo
```

`keygen --demo` writes `target/keys/` (gitignored). Never commit a `*.key`. For
a Secure Boot VM boot, add `--with-auth` to generate the UEFI enrollment blobs;
that also refreshes the committed public `keys/{PK,KEK,db}.crt` so the key
material stays consistent.

- Published sealed images require the db private key as the
  `SECUREBOOT_DB_KEY` GitHub Actions repository secret and the matching public
  `keys/db.crt`. CI refuses to publish on `main` with an ephemeral key unless
  the `ALLOW_EPHEMERAL_SEAL_KEY` repository variable is set to `true`.
- The public certificates (`keys/PK.crt`, `keys/KEK.crt`, `keys/db.crt`) and
  the `.auth` enrollment blobs are safe to commit; private keys are not.
- The `sealed` target defaults to `SEALED_FROM=observability`; the
  `nginx-sealed` entry in `build.py` (and CI) sets `SEALED_FROM=nginx`.

See [docs/sealed.md](docs/sealed.md) for the chain and the demo runbook.

CI builds the sealed variant directly with `SEALED_FROM=nginx` — one build
from the content stage, not a base image followed by a separate seal stage.
On `main` it stages the image under a candidate tag, pulls that exact registry
digest, installs it, and (when a previous `:sealed` image exists) applies the
new image over the old installation with `bootc install to-existing-root`.
Only after those checks pass is `:sealed` updated. The checks assert the UKI
and systemd-boot signatures against `keys/db.crt`, the embedded
`composefs.digest`, and the copied `PK/KEK/db.auth` blobs on the ESP. PR builds
run the same test against the local OCI archive because they are not published.
The artifact workflow uses `osbuild/image-builder-action` for disk images and
ISOs.

### Verify published images

Image signatures are recorded in the public Rekor log by default, so the image
digest can be verified without trusting the workflow run:

```bash
cosign verify --key cosign.pub ghcr.io/snthrailkill/bootc-fedora/nginx:latest
```

The full SPDX SBOM is much larger than the public Rekor v1 attestation limit
(100 KB), so the SBOM attestation is stored in OCI alongside the image and
verified offline; it does not get a Rekor entry. Verify it with:

```bash
cosign verify-attestation --key cosign.pub --insecure-ignore-tlog=true \
  --type spdxjson ghcr.io/snthrailkill/bootc-fedora/nginx:latest
```

If Rekor was unavailable during a build, the image signature also uses the
no-Rekor fallback and logs a warning; verify those images with
`--insecure-ignore-tlog=true`. Sealed images additionally carry a signed UKI
and a composefs digest covered by fs-verity; [docs/sealed.md](docs/sealed.md)
describes the full verification chain. To verify the Secure Boot signatures
against the committed key:

```bash
# Inside the sealed image (or against a mounted ESP)
sbverify --cert keys/db.crt /boot/EFI/Linux/<kver>.efi
sbverify --cert keys/db.crt /usr/lib/systemd/boot/efi/systemd-bootx64.efi
```

## K3S
This image simply installs k3s on our base image. Meant to be used as either server or agent.

## NAS
CentOS Stream 10 bootc image with OpenZFS (Stream 9 remains available via
`BASE_IMAGE` for x86-64-v2 hosts). The ZFS kernel modules are compiled in a
throwaway builder against the exact kernel the final image ships, and the
kernel is tracked from the CentOS Stream `kernel-devel` repo, so a base-image
bump picks up the matching kernel automatically. Only the compiled modules and
ZFS userspace cross into the final image; `dkms`, `gcc` and `kernel-devel` stay
in the builder.

```bash
./build.py build --image nas --tag demo
```

Notes: Secure Boot must be off, or the module must be signed with an enrolled
MOK key; ZFS userspace is copied from a manifest and is not RPM-owned, so
package/SBOM tracking will not list it. See [docs/nas.md](docs/nas.md) for the
kernel-pinning and Stream 9 rationale.

## Nginx
This runs as a quadlet and is configured by the `nginx.conf` which is placed in the `/etc/nginx` folder.

## Pihole
This quadlet will work out of the box but because there's no way to include secrets as part of the quadlet definition you will have to `podman exec` into the pod and change the password manually by running `pihole -a -p` to set a password. This is a one time operation.

## Prometheus
This image installs [Prometheus](https://prometheus.io/docs/introduction/overview/) on the host itself instead of using a container. Useful as a base image so observability comes baked into all your systems!