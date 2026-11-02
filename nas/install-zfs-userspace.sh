#!/usr/bin/bash
# Install ZFS userspace from the builder manifest into the final bootc image.
#
# Usage: install-zfs-userspace.sh <KERNEL_VRA> <MANIFEST> [BUILDER_ROOT]
#
# Runs with the zfs-builder root mounted read-only at BUILDER_ROOT.  Only the
# paths listed in the manifest are copied; gcc, dkms and kernel-devel stay in
# the throwaway builder.
set -euxo pipefail

K_VRA="${1:?Usage: install-zfs-userspace.sh <KERNEL_VRA> <MANIFEST> [BUILDER_ROOT]}"
MANIFEST="${2:?Usage: install-zfs-userspace.sh <KERNEL_VRA> <MANIFEST> [BUILDER_ROOT]}"
BUILDER_ROOT="${3:-/tmp/zfs-builder-root}"

ENTRY_COUNT=$(wc -l < "${MANIFEST}")
if [ "${ENTRY_COUNT}" -lt 200 ]; then
    echo "FAIL: manifest has only ${ENTRY_COUNT} entries" >&2
    exit 1
fi

COPIED=0
DIRS=0
while IFS= read -r file; do
    [ -z "${file}" ] && continue
    src="${BUILDER_ROOT}${file}"
    if [ -d "${src}" ] && [ ! -L "${src}" ]; then
        mkdir -p "${file}"
        DIRS=$((DIRS + 1))
    elif [ -e "${src}" ] || [ -L "${src}" ]; then
        mkdir -p "$(dirname "${file}")"
        cp -a "${src}" "${file}"
        COPIED=$((COPIED + 1))
    fi
done < "${MANIFEST}"
echo "Installed ${COPIED} ZFS files and ${DIRS} directories"

# Register the copied modules for the target kernel and load zfs at boot.
depmod -a "${K_VRA}"
printf 'zfs\n' > /etc/modules-load.d/zfs.conf

# Import pools, mount datasets, run the event daemon, and honour sharenfs/
# sharesmb properties.  zfs-import-cache is a no-op until /etc/zfs/zpool.cache
# exists; zfs-import-scan covers the first boot and pools without a cache file.
systemctl enable \
    zfs-import-cache.service \
    zfs-import-scan.service \
    zfs-import.target \
    zfs-mount.service \
    zfs-share.service \
    zfs-zed.service \
    zfs.target

echo "Validating final image..."

# No build tooling may have leaked in.
for pkg in dkms gcc kernel-devel; do
    if rpm -q "${pkg}" &>/dev/null; then
        echo "FAIL: build dependency '${pkg}' found in final image" >&2
        exit 1
    fi
done
echo "PASS: no dkms/gcc/kernel-devel in final image"

# Exactly one kernel directory, and it is the one ZFS was built for.
mapfile -t KDIRS < <(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
if [ "${#KDIRS[@]}" -ne 1 ] || [ "${KDIRS[0]}" != "${K_VRA}" ]; then
    echo "FAIL: expected only /usr/lib/modules/${K_VRA}, found: ${KDIRS[*]}" >&2
    exit 1
fi
echo "PASS: single kernel directory ${K_VRA}"

modinfo -k "${K_VRA}" zfs > /dev/null
echo "PASS: zfs module $(modinfo -k "${K_VRA}" -F version zfs) for ${K_VRA}"
zfs --version

for bin in zfs zpool zed; do
    command -v "${bin}" > /dev/null
    if ldd "$(command -v "${bin}")" 2>&1 | grep -q 'not found'; then
        echo "FAIL: ${bin} has unresolved libraries:" >&2
        ldd "$(command -v "${bin}")" | grep 'not found' >&2
        exit 1
    fi
done
echo "PASS: zfs, zpool and zed on PATH with resolved libraries"

for svc in zfs-import-cache zfs-import-scan zfs-mount zfs-share zfs-zed; do
    systemctl is-enabled "${svc}" > /dev/null
done
echo "PASS: ZFS systemd services enabled"
