#!/usr/bin/env bash
# Sealed-image install and upgrade smoke test.
#
# Inputs (environment):
#   CURRENT_REF   local container image under test (must be in podman storage)
#   PREVIOUS_REF  optional previously published sealed image; when set, the
#                 test installs it first and then applies CURRENT_REF over it
#   IMAGE         registry repository, used for the installed target imgref
#   TAG           tag the installed system tracks (e.g. sealed)
#   KEY_DIR       directory containing db.crt (the expected signing cert)
#   WORK_DIR      scratch directory for the disk image
#
# The install command fails unless every composefs digest embedded in the
# signed UKI matches the EROFS image bootc generates from the pulled layers.
# When PREVIOUS_REF is set, the second phase uses `bootc install
# to-existing-root --replace alongside`, which is the in-place upgrade path:
# it preserves the existing root and adds a new deployment. The test then
# verifies the new UKI and the copied Secure Boot enrollment blobs on the ESP.
set -euo pipefail

: "${CURRENT_REF:?CURRENT_REF is required}"
: "${IMAGE:?IMAGE is required}"
: "${TAG:?TAG is required}"
: "${KEY_DIR:?KEY_DIR is required}"
: "${WORK_DIR:?WORK_DIR is required}"

PREVIOUS_REF="${PREVIOUS_REF:-}"
DISK="${WORK_DIR}/disk.img"
MNT="${WORK_DIR}/target"
LOOP=""

cleanup() {
    set +e
    if mountpoint -q "${MNT}/boot"; then
        sudo umount "${MNT}/boot"
    fi
    if mountpoint -q "${MNT}"; then
        sudo umount "${MNT}"
    fi
    if [ -n "${LOOP}" ]; then
        sudo losetup -d "${LOOP}"
    fi
}
trap cleanup EXIT

podman_run() {
    sudo podman run --rm --privileged --pid=host --ipc=host \
        -v /dev:/dev \
        -v /var/lib/containers:/var/lib/containers \
        "$@"
}

count_deployments() {
    sudo find "${MNT}/ostree/deploy" -maxdepth 3 -type d -name '*.0' \
        2>/dev/null | wc -l
}

mkdir -p "${WORK_DIR}"
rm -rf "${MNT}"
rm -f "${DISK}"
truncate -s 12G "${DISK}"

BASE_REF="${PREVIOUS_REF:-${CURRENT_REF}}"
sudo podman image inspect "${BASE_REF}" >/dev/null
sudo podman image inspect "${CURRENT_REF}" >/dev/null

if [ -n "${PREVIOUS_REF}" ]; then
    previous_id="$(sudo podman image inspect --format '{{.Id}}' "${PREVIOUS_REF}")"
    current_id="$(sudo podman image inspect --format '{{.Id}}' "${CURRENT_REF}")"
    if [ "${previous_id}" = "${current_id}" ]; then
        echo "::notice::Previous and current sealed images are identical; running install-only"
        PREVIOUS_REF=""
        BASE_REF="${CURRENT_REF}"
    fi
fi

if [ -n "${PREVIOUS_REF}" ]; then
    echo "::notice::Installing the previous sealed image, then upgrading to the tested image"
else
    echo "::notice::No previous sealed image; installing the tested image directly"
fi

# Phase 1: a normal install from the base image. bootc verifies the embedded
# composefs digest against the generated EROFS image before staging it.
podman_run -v "${WORK_DIR}:/output" "${BASE_REF}" \
    bootc install to-disk --generic-image --wipe --via-loopback \
        --target-imgref "${IMAGE}:${TAG}" \
        /output/disk.img
echo "::notice::Phase 1 install complete; attaching ${DISK}"

# Mount the installed physical root and ESP so phase 2 can target it and the
# verification can inspect the final ESP. The installer may leave the loop
# device attached; reuse it when present instead of racing another attach.
EXISTING_LOOP="$(sudo losetup -j "${DISK}" | awk -F: 'NR==1 {print $1}')" || true
if [ -n "${EXISTING_LOOP}" ]; then
    LOOP="${EXISTING_LOOP}"
    sudo partprobe "${LOOP}" 2>/dev/null || true
else
    if ! ATTACHED="$(sudo losetup -Pf --show "${DISK}" 2>&1)"; then
        echo "::error::could not attach ${DISK} to a loop device: ${ATTACHED}"
        exit 1
    fi
    LOOP="${ATTACHED}"
fi
if [ -z "${LOOP}" ]; then
    echo "::error::could not attach ${DISK} to a loop device"
    exit 1
fi
sudo udevadm settle 2>/dev/null || true
ROOT_PART="$(sudo lsblk -flnpo NAME,FSTYPE "${LOOP}" | awk '$2 ~ /^(ext4|xfs|btrfs)$/ && !found {print $1; found=1}')"
ESP_PART="$(sudo lsblk -flnpo NAME,FSTYPE "${LOOP}" | awk '$2 == "vfat" && !found {print $1; found=1}')"
if [ -z "${ROOT_PART}" ] || [ -z "${ESP_PART}" ]; then
    echo "::error::could not identify the root/ESP partitions on ${DISK}"
    sudo lsblk -f "${LOOP}"
    exit 1
fi
sudo mkdir -p "${MNT}" "${MNT}/boot"
if ! sudo mount "${ROOT_PART}" "${MNT}"; then
    echo "::error::failed to mount root partition ${ROOT_PART}"
    exit 1
fi
if ! sudo mount "${ESP_PART}" "${MNT}/boot"; then
    echo "::error::failed to mount ESP ${ESP_PART}"
    exit 1
fi
echo "::notice::Mounted ${ROOT_PART} at ${MNT} and ${ESP_PART} at ${MNT}/boot"

BEFORE="$(count_deployments)"

if [ -n "${PREVIOUS_REF}" ]; then
    # Phase 2: apply the tested image over the existing installation. This is
    # the in-place upgrade path; it wipes /boot and adds a deployment while
    # preserving /var and the old deployment for rollback.
    if ! podman_run -v "${MNT}:/target" "${CURRENT_REF}" \
        bootc install to-existing-root /target \
            --replace alongside --generic-image \
            --target-imgref "${IMAGE}:${TAG}" \
            --skip-fetch-check; then
        echo "::error::bootc install to-existing-root failed"
        exit 1
    fi
    AFTER="$(count_deployments)"
    if [ "${AFTER}" -le "${BEFORE}" ]; then
        echo "::error::upgrade did not add a deployment (${BEFORE} -> ${AFTER})"
        exit 1
    fi
    echo "::notice::Upgrade added a deployment (${BEFORE} -> ${AFTER})"
else
    echo "::notice::Install created ${BEFORE} deployment(s)"
fi

# Verify the ESP produced by the final deployment. The cert check is not just
# a display of the signer: sbverify --cert fails when the expected key did not
# sign the image.
sudo podman run --rm --entrypoint /bin/bash \
    -v "${MNT}:/target:ro" \
    -v "${KEY_DIR}:/keys:ro" \
    "${CURRENT_REF}" -s <<'EOS'
set -eux
kver=$(ls /usr/lib/modules | head -1)
test -n "$kver"
test -s "/target/boot/EFI/Linux/${kver}.efi"
sbverify --cert /keys/db.crt "/target/boot/EFI/Linux/${kver}.efi"
strings -a "/target/boot/EFI/Linux/${kver}.efi" | grep -q "composefs.digest"

for f in PK KEK db; do
    test -s "/target/boot/loader/keys/auto/${f}.auth"
done

boot="$(find /target/boot/EFI -iname 'systemd-bootx64.efi' -o -iname 'BOOTX64.EFI' | head -1)"
test -n "$boot"
sbverify --cert /keys/db.crt "$boot"
EOS

echo "::notice::Sealed smoke test passed - expected key signed the installed UKI and systemd-boot, and the enrollment blobs are on the ESP"
