#!/usr/bin/env bash
# Generate the UEFI Secure Boot key hierarchy for sealed bootc images.
#
#   PK  - Platform Key: root of trust, authorizes KEK updates
#   KEK - Key Exchange Key: authorizes db updates
#   db  - Signature Database key: signs systemd-boot + UKIs (the day-to-day key)
#
# Output goes to KEYS_DIR (default target/keys/, which is gitignored).
# Private keys never leave that directory; only the public PK/KEK/db
# certificates and the derived keys/auth/auto/*.auth enrollment blobs are
# committed (all public).
#
# Keys are RSA-4096, self-signed, 10-year validity. Re-running is a no-op
# for keys that already exist.
set -euo pipefail

KEYS_DIR="${1:-target/keys}"
DAYS=3650
BITS=4096

mkdir -p "$KEYS_DIR"

for name in PK KEK db; do
    if [[ -f "${KEYS_DIR}/${name}.key" ]]; then
        echo "${name}: exists, skipping (${KEYS_DIR}/${name}.key)"
        continue
    fi
    echo "${name}: generating RSA-${BITS} key + self-signed cert (${DAYS}d)"
    openssl req -quiet -newkey "rsa:${BITS}" -nodes \
        -keyout "${KEYS_DIR}/${name}.key" -new -x509 -sha256 -days "${DAYS}" \
        -subj "/CN=bootc examples Secure Boot ${name}/" \
        -out "${KEYS_DIR}/${name}.crt"
    openssl x509 -outform DER -in "${KEYS_DIR}/${name}.crt" -out "${KEYS_DIR}/${name}.cer"
done

if [[ ! -f "${KEYS_DIR}/GUID.txt" ]]; then
    python3 -c 'import uuid; print(uuid.uuid4())' > "${KEYS_DIR}/GUID.txt"
fi

chmod 600 "${KEYS_DIR}"/*.key
echo
echo "Keys in ${KEYS_DIR}/:"
ls -l "${KEYS_DIR}"
cat <<'EOF'

Next steps:
  1. For a real deployment, back up *.key + GUID.txt offline NOW.
     db.key loss = cannot sign new images; PK/KEK loss = cannot rotate keys.
  2. Demo builds keep the keys in target/keys (gitignored). Never commit *.key.
  3. In CI, set the db private key as the SECUREBOOT_DB_KEY secret
     (GitHub Actions repository secret, or a masked/protected GitLab CI variable).
     The public certificates (PK.crt, KEK.crt, db.crt) and enrollment blobs
     (.auth) are safe to commit.
EOF
