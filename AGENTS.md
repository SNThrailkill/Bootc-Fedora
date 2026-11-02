# AGENTS.md — repository knowledge

## CI/CD overview
- Three GitHub Actions workflows in `.github/workflows/`:
  - `build-images.yml` — top-level; triggers on PR/push/schedule (Sun 10:05 UTC) and fans out to per-image reusable workflow jobs: base, nginx, k3s, prometheus, nas.
  - `reusable-build-image.yml` — the actual build/push/sign/attest logic. Buildah builds each target from `Containerfile`, pushes to GHCR (`ghcr.io/<owner>/<repo>/<image>`), generates an SBOM (anchore), scans it (anchore scan-action), uploads SARIF, signs with cosign (key-based, `SIGNING_SECRET`), then attaches an SBOM attestation with cosign.
  - `build-artifact.yml` — manual/PR-triggered; turns a built bootc image into a disk artifact (ami/qcow2/vmdk/...) via bootc-image-builder.
- There is also a `.gitlab-ci.yml`, but the active pipelines are GitHub Actions.
- Containerfile build targets: `base`, `observability`, `prometheus`, `loki`, `nginx`, `k3s`, `nas`, plus the `sealed` target (UKI + composefs + fs-verity). See `Containerfile` for the stage graph.

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
- **Renovate** is the dependency manager (see `renovate.json`). Configured to manage `github-actions` and `dockerfile` dependencies, grouped, with a Monday schedule and a dependency dashboard. Major docker base-image bumps require dashboard approval.
- Dependabot was removed (its config had an empty `package-ecosystem` and would have conflicted with Renovate).
- GitHub Actions are pinned by digest; Renovate keeps both digest and version tag up to date.

## Known issue: Rekor (sigstore transparency log) flakiness
- The public Rekor instance (`rekor.sigstore.dev`) is a shared service with a 99.5% SLO and is intermittently unavailable. Since cosign 2.0, `cosign sign` and `cosign attest` upload to it by default even for key-based signing, so a Rekor outage fails the pipeline with `Post "https://rekor.sigstore.dev/api/v1/log/entries": ... giving up after 4 attempt(s)`.
- This is widely reported (sigstore/cosign#3602, GitHub community discussions#144833) and transient.
- Fix applied in `reusable-build-image.yml`: both the `Sign container image` and `Add SBOM Attestation` steps always run with `--tlog-upload=false`. The signature/attestation is stored in the OCI registry alongside the image (where it can be verified manually); the public Rekor transparency-log entry is skipped entirely. This trades off the public audit record for a reliable build.
- Verify images signed this way with `cosign verify --key cosign.pub --insecure-ignore-tlog=true ...` (and `cosign verify-attestation --insecure-ignore-tlog=true ...` for attestations).

## Known issue: prometheus build target fails dnf install of loki/grafana
- The `prometheus` Containerfile stage pulls the grafana yum repo and runs `dnf install loki grafana -y`, which failed with a Curl SSL CA cert error reaching `https://rpm.grafana.com/repodata/repomd.xml`. The grafana repo config points `sslcacert` at `/etc/pki/tls/certs/ca-bundle.crt`, which must exist/populated before dnf runs.
