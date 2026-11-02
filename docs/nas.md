# NAS image (CentOS Stream 9 + OpenZFS)

`nas/Containerfile` builds a CentOS Stream 9 bootc NAS with OpenZFS. The ZFS
kernel modules are compiled in a throwaway builder against the exact kernel
that ships in the final image, then only the modules and userspace files are
copied forward.

```bash
./build.py build --image nas --tag demo
```

The build context is the repository root, because the final stage copies
`nas/*.sh` helpers and the ZFS userspace manifest.

## Kernel tracking

`kernel-target` runs:

```bash
dnf repoquery --available --latest-limit=1 \
  --qf '%{VERSION}-%{RELEASE}.%{ARCH}' kernel-devel
```

and filters to the build architecture. Both `zfs-builder` and `nas` read the
same `/kmod-kernel` file, so they cannot disagree if repository metadata moves
during the build. `pin-kernel.sh` moves the kernel packages to that version in
either direction using `rpm.vercmp` (a string comparison breaks on RPM release
fields), then verifies `kernel-core`.

`KMOD_KERNEL` is empty by default: a base-image or Renovate bump triggers a
fresh query. Pass `--build-arg KMOD_KERNEL=5.14.0-758.el9.x86_64` to reproduce
an older image.

## Why Stream 9 and zfs-testing

- The Stream 10 bootc base requires x86-64-v3. The build host used for the
  first validation is x86-64-v2, so Stream 10 could not be built or booted
  there. Moving to Stream 10 is a separate, hardware-visible decision; check
  the NAS CPU first.
- Stable EL9 ZFS (`zfs-dkms-2.2.11`) does not compile against the current
  `5.14.0-759` kernel: `struct dentry has no member named d_u`.
- `zfs-testing` has OpenZFS 2.4.4, which builds cleanly and reports the correct
  vermagic for `5.14.0-759.el9.x86_64`. The version is pinned as
  `ZFS_VERSION=2.4.4` so a repo update cannot silently change it.
- Renovate does not track `ZFS_VERSION` or `COCKPIT_ZFS_VERSION` today. If the
  testing repo removes that version, the build fails loudly; bump the ARG
  manually or add a custom manager.

If the testing channel is unacceptable, the alternative is to build OpenZFS
2.4.4 from the upstream source in the builder (Andrew Dunn's newer `basec`
pattern) instead of using the DKMS package.

## What lands in the final image

- `zfs.ko`/`spl.ko` for the pinned kernel under
  `/usr/lib/modules/<KERNEL_VRA>/extra/`
- `zfs`, `zpool`, `zed`, shared libraries, systemd units and udev rules
- `zfs-import-cache`, `zfs-import-scan`, `zfs-mount`, `zfs-share`, `zfs-zed`
  enabled
- Cockpit, NFS, Samba and the 45Drives Cockpit ZFS manager
- No `dkms`, `gcc` or `kernel-devel`; those stay in the builder

`bootc container lint` passes (11 passed, 1 skipped, 3 inherited warnings).
The image is about 2.1 GB.

## Caveats

- **Secure Boot:** DKMS signs the module with an ephemeral key that is not
  enrolled. With Secure Boot enabled the module is rejected. Either leave
  Secure Boot off on the NAS or provide a MOK key/cert and enroll it.
- **RPM ownership:** ZFS userspace is copied from the builder's RPM file
  manifest, so `rpm -q zfs` is empty and package/SBOM tools will not list ZFS.
  This is the manifest-copy pattern; `bootc container lint` passes.
- **Cockpit manager:** pinned to the archived `45Drives/cockpit-zfs-manager`
  `v1.3.1`. The maintained `45Drives/cockpit-zfs` needs a Node build and
  `python3-libzfs`.
- **Boot smoke test:** not run here. Module load, pool import, NFS/Samba
  sharing and the Cockpit UI still need a hardware boot test.
