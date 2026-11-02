#!/usr/bin/env bash
# Derive UEFI authenticated-variable (.auth) enrollment blobs from the
# PK/KEK/db certificates. These are PUBLIC (signed cert payloads, no key
# material) and are committed at keys/auth/auto/ so they can be shipped in
# the image at /usr/lib/bootc/install/secureboot-keys/auto/.
#
# At install time bootc copies them to <ESP>/loader/keys/auto/. When the
# firmware is in Setup Mode (for example a VM with pre-enrolled keys off),
# systemd-boot's default `secure-boot-enroll=if-safe` auto-enrolls them on
# first boot inside a VM and reboots into Secure Boot.
#
# Requires sbsiglist/sbvarsign (sbsigntools). On hosts without them, run via
# `just auth-files` which uses an ephemeral Fedora container.
#
# Env:
#   KEYS_DIR  private keys + DER certs   (default target/keys)
#   OUT_DIR   committed .auth output     (default keys/auth/auto)
set -euo pipefail

KEYS_DIR="${KEYS_DIR:-target/keys}"
OUT_DIR="${OUT_DIR:-keys/auth/auto}"

for f in PK KEK db; do
    [[ -f "${KEYS_DIR}/${f}.key" && -f "${KEYS_DIR}/${f}.cer" ]] || {
        echo "missing ${KEYS_DIR}/${f}.{key,cer} - run keygen first" >&2; exit 1; }
done

GUID=$(cat "${KEYS_DIR}/GUID.txt")
ATTR=EFI_VARIABLE_NON_VOLATILE,EFI_VARIABLE_BOOTSERVICE_ACCESS,EFI_VARIABLE_RUNTIME_ACCESS,EFI_VARIABLE_TIME_BASED_AUTHENTICATED_WRITE_ACCESS

mkdir -p "${OUT_DIR}"

# EFI signature lists (one x509 cert each)
for f in PK KEK db; do
    sbsiglist --owner "${GUID}" --type x509 \
        --output "${KEYS_DIR}/${f}.esl" "${KEYS_DIR}/${f}.cer"
done

# PK and KEK variables are signed by the PK; db is signed by the KEK.
sbvarsign --attr "${ATTR}" \
    --key "${KEYS_DIR}/PK.key" --cert "${KEYS_DIR}/PK.crt" \
    --output "${OUT_DIR}/PK.auth" PK "${KEYS_DIR}/PK.esl"
sbvarsign --attr "${ATTR}" \
    --key "${KEYS_DIR}/PK.key" --cert "${KEYS_DIR}/PK.crt" \
    --output "${OUT_DIR}/KEK.auth" KEK "${KEYS_DIR}/KEK.esl"
sbvarsign --attr "${ATTR}" \
    --key "${KEYS_DIR}/KEK.key" --cert "${KEYS_DIR}/KEK.crt" \
    --output "${OUT_DIR}/db.auth" db "${KEYS_DIR}/db.esl"

rm -f "${KEYS_DIR}"/*.esl
echo "Wrote ${OUT_DIR}/{PK,KEK,db}.auth (owner GUID ${GUID})"
