#!/usr/bin/bash
# Build the OpenZFS kernel modules against the exact kernel in the image.
#
# Usage: build-kmod-zfs.sh <KERNEL_VRA> <ZFS_VERSION>
#
# This script runs only in the throwaway zfs-builder stage.  It leaves:
#   /zfs-output/modules/<KERNEL_VRA>/extra/*.ko*  - compiled modules
#   /zfs-files.txt                                - userspace file manifest
set -euxo pipefail

K_VRA="${1:?Usage: build-kmod-zfs.sh <KERNEL_VRA> <ZFS_VERSION>}"
ZFS_VERSION="${2:?Usage: build-kmod-zfs.sh <KERNEL_VRA> <ZFS_VERSION>}"
export LANG=C.UTF-8

echo "Building ZFS ${ZFS_VERSION} for kernel ${K_VRA}"

# kernel-devel must come from the same build as kernel-core.  The caller has
# already pinned kernel-core to K_VRA via pin-kernel.sh.
dnf install -y --nodocs --setopt=install_weak_deps=False \
    "kernel-devel-${K_VRA}"

# zfs-dkms pulls dkms/gcc/kernel-devel and is deliberately builder-only.
# EL9's stable zfs channel still ships 2.2.x, which does not compile against
# the current 5.14.0-759 stream kernel (dentry::d_u backport).  2.4.x lives in
# zfs-testing; pin the exact version so a testing-repo update cannot silently
# change the build.
dnf install -y --nodocs --setopt=install_weak_deps=False \
    --enablerepo=zfs-testing \
    "zfs-dkms-${ZFS_VERSION}" "zfs-${ZFS_VERSION}"

INSTALLED_ZFS=$(rpm -q zfs-dkms --qf '%{VERSION}')
INSTALLED_KERNEL=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core)
[ "${INSTALLED_ZFS}" = "${ZFS_VERSION}" ] || {
    echo "FAIL: wanted zfs-dkms ${ZFS_VERSION}, got ${INSTALLED_ZFS}" >&2
    exit 1
}
[ "${INSTALLED_KERNEL}" = "${K_VRA}" ] || {
    echo "FAIL: wanted kernel ${K_VRA}, got ${INSTALLED_KERNEL}" >&2
    exit 1
}

# -k is essential: without it DKMS targets the container host kernel, not the
# kernel installed in this image.
export MAKEFLAGS="-j$(nproc)"
dkms build -m zfs -v "${ZFS_VERSION}" -k "${K_VRA}" --verbose
dkms install -m zfs -v "${ZFS_VERSION}" -k "${K_VRA}" --verbose

depmod -a "${K_VRA}"

# Builder gate 1: the module exists for the intended kernel.
if ! modinfo -k "${K_VRA}" zfs > /dev/null 2>&1; then
    echo "FAIL: DKMS did not produce a zfs module for ${K_VRA}" >&2
    find "/usr/lib/modules/${K_VRA}" -name '*.ko*' -print | head -20 >&2
    exit 1
fi
echo "PASS: zfs module present ($(modinfo -k "${K_VRA}" -F version zfs))"

# Builder gate 2: userspace tools resolve all shared libraries.
for bin in zfs zpool zed; do
    path=$(command -v "${bin}" || true)
    [ -n "${path}" ] || { echo "FAIL: ${bin} not found" >&2; exit 1; }
    if ldd "${path}" 2>&1 | grep -q 'not found'; then
        echo "FAIL: ${bin} has unresolved libraries:" >&2
        ldd "${path}" | grep 'not found' >&2
        exit 1
    fi
done
echo "PASS: ZFS userspace tools and libraries"

# Copy only the modules that belong to the target kernel.  Do not copy
# /usr/lib/modules wholesale: it contains build/ symlinks to kernel-devel.
mkdir -p "/zfs-output/modules/${K_VRA}"
cp -a "/usr/lib/modules/${K_VRA}/extra" "/zfs-output/modules/${K_VRA}/"

# Stable-ABI library package names changed between ZFS 2.2 (libzfs5) and 2.4
# (libzfs7).  Discover them instead of hard-coding a version.
mapfile -t ZFS_PKGS < <(
    {
        echo zfs
        rpm -qa --qf '%{NAME}\n' \
            | grep -E '^lib(nvpair|uutil|zfs|zpool)[0-9]+$' || true
    } | sort -u
)
rpm -ql "${ZFS_PKGS[@]}" | sort -u > /zfs-files.txt

FILE_COUNT=$(wc -l < /zfs-files.txt)
if [ "${FILE_COUNT}" -lt 200 ]; then
    echo "FAIL: ZFS userspace manifest has only ${FILE_COUNT} files" >&2
    exit 1
fi
echo "PASS: userspace manifest has ${FILE_COUNT} files"

# Keep the builder layer small; nothing below is needed by the final image.
dnf clean all
rm -rf /var/cache/dnf/* /var/cache/yum/* \
       /var/lib/dkms/zfs/*/build \
       "/usr/src/kernels/${K_VRA}" "/usr/src/zfs-${ZFS_VERSION}"

echo "ZFS builder validation complete"
