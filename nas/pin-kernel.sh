#!/usr/bin/bash
# Pin the image's kernel to the exact version the ZFS module was built for.
#
# Usage: pin-kernel.sh <KERNEL_VRA>
#
# The bootc base image can be ahead of (or behind) the kernel-devel package
# currently in the CentOS Stream repos. ZFS must be compiled against the exact
# kernel that ships in the final image, so move the kernel packages in either
# direction and verify the result.
set -euo pipefail

KMOD_KERNEL="${1:?Usage: pin-kernel.sh <KERNEL_VRA>}"

CURRENT=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core)
if [ "${CURRENT}" = "${KMOD_KERNEL}" ]; then
    echo "Kernel ${CURRENT} already matches target, no change needed"
    exit 0
fi

PKGS="kernel-${KMOD_KERNEL} \
      kernel-core-${KMOD_KERNEL} \
      kernel-modules-${KMOD_KERNEL} \
      kernel-modules-core-${KMOD_KERNEL}"

# kernel-modules-extra is optional in the bootc base; only move it if present.
if rpm -q kernel-modules-extra &>/dev/null; then
    PKGS="${PKGS} kernel-modules-extra-${KMOD_KERNEL}"
fi

# rpm.vercmp handles epoch/release correctly (do not compare strings).
CMP=$(rpm --eval "%{lua:print(rpm.vercmp('${CURRENT}','${KMOD_KERNEL}'))}")
if [ "${CMP}" = "1" ]; then
    echo "Downgrading kernel from ${CURRENT} to ${KMOD_KERNEL}..."
    dnf downgrade -y ${PKGS}
elif [ "${CMP}" = "-1" ]; then
    echo "Upgrading kernel from ${CURRENT} to ${KMOD_KERNEL}..."
    dnf upgrade -y ${PKGS}
else
    echo "FAIL: rpm.vercmp returned '${CMP}' for ${CURRENT} vs ${KMOD_KERNEL}" >&2
    exit 1
fi

ACTUAL=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core)
if [ "${ACTUAL}" != "${KMOD_KERNEL}" ]; then
    echo "FAIL: kernel pin failed: wanted ${KMOD_KERNEL}, got ${ACTUAL}" >&2
    exit 1
fi
echo "Kernel pinned: ${ACTUAL}"
