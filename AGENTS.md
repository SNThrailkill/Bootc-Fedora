# AGENTS.md — repository knowledge

## CI/CD overview
- Three GitHub Actions workflows in `.github/workflows/`:
  - `build-images.yml` — top-level; triggers on PR/push/schedule (Sun 10:05 UTC) and fans out to per-image reusable workflow jobs: base, nginx, nginx-sealed, k3s, prometheus, nas. The sealed job builds `SEALED_FROM=nginx` directly in one invocation (no base-image-then-seal stage) and runs the loopback install smoke test.
  - `reusable-build-image.yml` — the actual build/push/sign/attest logic. Buildah builds each target from `Containerfile`, pushes to GHCR (`ghcr.io/<owner>/<repo>/<image>`), generates an SBOM (anchore), scans it (anchore scan-action), uploads SARIF, signs with cosign (key-based, `SIGNING_SECRET`), then attaches an SBOM attestation with cosign. After the build it rechunks images with chunkah (`.github/chunkah/`) into content-based layers before SBOM/push/sign. Sealed builds use the ephemeral demo key, are chunked after sealing, verify the seal with a loopback `bootc install` on the chunked image, and sign with Rekor (falling back to no-Rekor if the log is unavailable).
  - `build-artifact.yml` — manual; turns a built bootc image into a disk artifact (ami/qcow2/vmdk/...) with `osbuild/image-builder-action`.
- There is also a `.gitlab-ci.yml`, but the active pipelines are GitHub Actions.
- Containerfile build targets: `base`, `observability`, `prometheus`, `nginx`, `k3s`, `nas`, plus the `sealed` target (UKI + composefs + fs-verity). See `Containerfile` for the stage graph.

## NAS image
- `nas/Containerfile` is a three-stage build: `kernel-target` resolves the latest matching `kernel-devel`, `zfs-builder` compiles OpenZFS with DKMS against that exact kernel, and `nas` copies only the modules plus the userspace manifest.
- `KMOD_KERNEL` is empty by default and tracks the CentOS Stream kernel; `pin-kernel.sh` uses `rpm.vercmp` and handles both downgrade and upgrade. `ZFS_VERSION=2.4.4` is pinned; it comes from `zfs-testing` (EL10 has 2.4.4, and stable EL9 2.2.11 failed against the old 5.14 kernel).
- Stream 10 is the default and requires x86-64-v3; pass `BASE_IMAGE=quay.io/centos-bootc/centos-bootc:stream9` for a v2 host. EL10 currently has `kernel-devel-6.12.0-279.el10` and OpenZFS 2.4.4 in `zfs-testing`; the Stream 10 image builds at ~1.82 GB with kernel 6.12.0-279.
- Secure Boot is not handled: DKMS signs the module with an ephemeral key that is not enrolled. ZFS userspace is manifest-copied and not RPM-owned, so SBOM/package audits will not list it.

## Local builds
- `./build.py` is the local entry point and the single source of truth for the image table, Containerfile targets and the CI matrix. Subcommands: `doctor`, `images`, `build`, `shell`, `keygen`, `seal`, `verify`, `matrix`.
- `Justfile` recipes (`just doctor`, `just build nginx demo`, `just seal`, `just verify`, `just test`) wrap the same commands.
- Sealed images (`nginx-sealed`) use a demo key hierarchy under `target/keys/` (gitignored). `./build.py keygen --demo` creates it; `./build.py seal --image nginx-sealed --tag demo` builds; `verify` inspects the signed UKI. Real keys go to the `SECUREBOOT_DB_KEY` secret; never commit `db.key`. See `docs/sealed.md`.

## Dependency management
- **Renovate** is the dependency manager (see `renovate.json`). Configured to manage `github-actions`, `dockerfile`, and custom regex pins, grouped, with a Monday schedule and a dependency dashboard. Major docker base-image and action bumps require dashboard approval.
- Custom regex managers track the chunkah image in `reusable-build-image.yml`, the k3s/OpenZFS/Cockpit ZFS pins in the Containerfiles, the Syft download, and the Prometheus release ARG.
- Dependabot was removed (its config had an empty `package-ecosystem` and would have conflicted with Renovate).
- GitHub Actions are pinned by digest; Renovate keeps both digest and version tag up to date. Routine action updates are grouped and automerged after CI; majors are manual.
- `build-artifact.yml` uses `osbuild/image-builder-action`, pinned to a `main` commit because upstream has no tagged releases yet. Unlike the archived bootc-image-builder action, it has no config-file/additional-args inputs, so the old root-size customization and `--use-librepo` are not carried over.

## Rekor (sigstore transparency log)
- Public images are signed and attested with the public Rekor log enabled, so anyone can verify the signature/attestation and its transparency-log entry. The primary steps use `.github/cosign/signing-config-rekor.json`.
- Rekor is a shared service and can be unavailable. The primary signing/attestation steps are `continue-on-error`; on failure, fallback steps use `.github/cosign/signing-config-no-rekor.json` and sign anyway, with a warning that no transparency-log entry exists. A Rekor outage therefore cannot block CD.
- Offline signature and attestation verification are enforced against the committed `cosign.pub`. A separate optional Rekor verification runs when the primary Rekor path succeeded and is non-blocking.
- Verify images with `cosign verify --key cosign.pub <image>`; if signed via the fallback, use `--insecure-ignore-tlog=true`. Attestations: `cosign verify-attestation --key cosign.pub --type spdxjson <image>`.

## Known issue: prometheus build target fails dnf install of loki/grafana
- The `prometheus` Containerfile stage pulls the grafana yum repo and runs `dnf install loki grafana -y`, which failed with a Curl SSL CA cert error reaching `https://rpm.grafana.com/repodata/repomd.xml`. The grafana repo config points `sslcacert` at `/etc/pki/tls/certs/ca-bundle.crt`, which must exist/populated before dnf runs.
