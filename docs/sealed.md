# Sealed images (demo)

This is the demo runbook for the sealed variants of the example images. It is
the local-first path: build and inspect a sealed image on a laptop, then wire
the same commands into CI.

A sealed image boots through a fully authenticated chain:

```
OVMF (Secure Boot, demo db key)
  -> signed systemd-boot
    -> signed UKI (kernel + initramfs + cmdline with composefs.digest=...)
      -> initramfs mounts root as a composefs overlay with verity=require
        -> every file read is fs-verity-checked against the signed digest
```

Tampering with the sealed root causes an I/O error at read time; tampering with
the UKI or bootloader fails Secure Boot.

The chain is the same three stages used by the production images:

1. `seal-prep` installs the UKI toolchain, regenerates the initramfs if bootc
   changed, signs systemd-boot, scrubs the tree and splits the kernel out.
2. `seal-flat` flattens the tree so the composefs digest cannot depend on layer
   stacking.
3. `sealed` computes the digest, embeds it in a signed UKI and copies the UKI
   under `/boot` (outside the digest).

## Demo keys

```bash
./build.py keygen --demo
```

This creates PK, KEK and db keys under `target/keys/` (gitignored), using
`keys/util/keygen.sh`. The db key signs systemd-boot and every UKI.

**Never commit `target/keys/*.key`.** The public certificates
(`keys/PK.crt`, `keys/KEK.crt`, `keys/db.crt`) and the UEFI enrollment blobs
(`keys/auth/auto/*.auth`) are safe to commit; the private keys are not.

For a Secure Boot VM boot, also generate the enrollment blobs:

```bash
./build.py keygen --demo --with-auth
```

This runs `keys/util/gen-auth.sh` in a Fedora container because it needs
`sbsigntools`. It also copies the public `PK.crt`, `KEK.crt` and `db.crt` into
`keys/` so the committed certificates and enrollment blobs stay consistent.
For a real deployment, use `keys/util/keygen.sh` directly, back up the private
keys and `GUID.txt` offline, and rotate before the certificates expire.

## Build and verify

```bash
./build.py seal --image nginx-sealed --tag demo
./build.py verify --image nginx-sealed --tag demo
```

`seal` calls the `sealed` target with:

- `--build-arg SEALED_FROM=nginx` (the content stage from `build.py`)
- `--secret id=secureboot_key,src=target/keys/db.key`
- `--secret id=secureboot_cert,src=target/keys/db.crt`
- `--device /dev/fuse --cap-add=all` and an SELinux label

`verify` runs inside the built image. It prints the signatures with
`sbverify --list` for diagnostics, then **enforces** the expected key with
`sbverify --cert /keys/db.crt` for both the UKI and systemd-boot. It also checks
the UKI cmdline contains `composefs.digest`, the bootc version, the sealed
install config files, and that the `PK/KEK/db.auth` blobs are present. Use
`--key-dir` if the signing certificate is not in `target/keys/`.

Sealed builds currently require podman. `./build.py doctor` checks for podman
and `/dev/fuse` before the workshop.

## CI

`build-images.yml` runs `./build.py matrix` and passes each entry to the
reusable workflow. The sealed entry builds the `sealed` target directly:
`SEALED_FROM=nginx` makes the content stage and the seal chain part of one
Containerfile invocation, with no dependency on the unsealed `nginx` job or a
published base image.

On `main`, CI uses the repository Secure Boot key (`SECUREBOOT_DB_KEY`) and the
committed `keys/db.crt`. It refuses to publish a sealed image with an ephemeral
key unless the `ALLOW_EPHEMERAL_SEAL_KEY` repository variable is set to `true`;
PR builds use an ephemeral key because they are not published. The build stays
flat (chunkah is disabled) because chunkah's re-layering does not preserve the
xattrs/EROFS metadata covered by the composefs digest.

The test does not trust the local build alone:

1. CI tags the sealed image as `sealed-candidate` and pushes it.
2. It pulls that exact registry digest into podman.
3. It installs a previous `:sealed` image when one exists, then applies the
   candidate over it with `bootc install to-existing-root --replace
   alongside`. This is the in-place upgrade path: the old deployment is kept
   and a new one is added.
4. It verifies the new UKI and systemd-boot with `sbverify --cert`, checks the
   `composefs.digest` string, and checks the `PK/KEK/db.auth` enrollment blobs
   on the ESP.
5. Only then does it push the public `:sealed` tag. A failing test leaves the
   previous good image in place.

PR builds run the same install/upgrade checks against the local OCI archive
because they are not published. The SBOM is generated from that archive.
Signing and SBOM attestations go to the public Rekor log by default; if Rekor
is unavailable they fall back to no-Rekor signing with a warning
(non-blocking). Offline signature/attestation verification is enforced, the
optional Rekor-entry check is non-blocking, and the sealed smoke test is
enforced.

## CI secrets

- `SECUREBOOT_DB_KEY` — the PEM-encoded db private key used to sign
  systemd-boot and the UKI. Required to publish sealed images on `main`; must
  match the committed `keys/db.crt`.
- `ALLOW_EPHEMERAL_SEAL_KEY` (repository variable, optional) — set to `true`
  only for a demo fork that intentionally publishes throwaway-key images. Such
  images cannot be verified or booted without that run's key.

The public certificates and enrollment blobs are safe to commit; the private
keys are not.

## Full boot (next)

The CI smoke test proves install and the in-place upgrade path without KVM. The
remaining optional finale is booting the sealed disk under OVMF with the
committed keys enrolled and checking Secure Boot end to end, including
auto-enrollment from the `keys/auth/auto/*.auth` blobs.

## Troubleshooting

- `sealed builds currently require podman`: use podman; the build needs
  `/dev/fuse`, `--cap-add=all` and `--security-opt=label=type:container_runtime_t`.
- `missing target/keys/db.key`: run `./build.py keygen --demo`.
- `bootc container ukify` fails after a base-image bump: the seal chain needs a
  bootc version with `split-kernel-and-rootfs` and `ukify`; the `seal-prep`
  stage updates bootc and regenerates the initramfs when it changes.
