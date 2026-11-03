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

**Never commit `target/keys/*.key`.** The public certificate (`keys/db.crt`)
and the UEFI enrollment blobs (`keys/auth/auto/*.auth`) are safe to commit; the
private key is not.

For a Secure Boot VM boot, also generate the enrollment blobs:

```bash
./build.py keygen --demo --with-auth
```

This runs `keys/util/gen-auth.sh` in a Fedora container because it needs
`sbsigntools`. For a real deployment, use `keys/util/keygen.sh` directly, back
up the private keys and `GUID.txt` offline, and rotate before the certificates
expire.

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

`verify` runs inside the built image and checks the signed UKI, the signed
systemd-boot, the UKI cmdline (including the composefs digest), the bootc
version, and the sealed install config files.

Sealed builds currently require podman. `./build.py doctor` checks for podman
and `/dev/fuse` before the workshop.

## CI

`build-images.yml` has a `build-nginx-sealed` job that builds the `sealed`
target directly: `SEALED_FROM=nginx` makes the content stage and the seal
chain part of one Containerfile invocation, with no dependency on the
unsealed `build-nginx` job or a published base image.

CI generates an ephemeral demo key, builds `nginx:sealed`, and runs a
loopback `bootc install` smoke test on the flat sealed image. That test fails
unless every digest embedded in the signed UKI matches the EROFS image bootc
generates from the pulled layers, so it proves the seal end to end. Sealed
images are deliberately not chunked: chunkah's re-layering does not preserve
the xattrs/EROFS metadata covered by the composefs digest, and the loopback
test fails with a digest mismatch when it is applied. Unsealed images are
chunked. The SBOM is generated from the sealed OCI archive. Signing and SBOM
attestations go to the public Rekor log by default; if Rekor is unavailable
they fall back to no-Rekor signing with a warning (non-blocking). Offline
signature/attestation verification is enforced, the optional Rekor-entry
check is non-blocking, and the seal smoke test is enforced.

## CI secrets

The CI job currently uses an ephemeral demo key for every sealed build, so
forks and PRs can exercise the seal without secrets. For stable published
signatures, add the db private key as `SECUREBOOT_DB_KEY` and commit the
matching `keys/db.crt`, then update the key-preparation step to use them.
The public certificate and enrollment blobs are safe to commit; the private
key is not.

## Full boot (next)

The CI smoke test proves the install-time seal without KVM. The remaining
optional finale is booting the sealed disk under OVMF with the demo keys
enrolled and checking Secure Boot end to end.

## Troubleshooting

- `sealed builds currently require podman`: use podman; the build needs
  `/dev/fuse`, `--cap-add=all` and `--security-opt=label=type:container_runtime_t`.
- `missing target/keys/db.key`: run `./build.py keygen --demo`.
- `bootc container ukify` fails after a base-image bump: the seal chain needs a
  bootc version with `split-kernel-and-rootfs` and `ukify`; the `seal-prep`
  stage updates bootc and regenerates the initramfs when it changes.
