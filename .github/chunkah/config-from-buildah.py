#!/usr/bin/env python3
"""Print a chunkah-compatible config for a local buildah image.

chunkah accepts either a direct OCI image config or podman/docker inspect
output. `buildah inspect` nests the OCI image under .OCIv1 (and older buildah
versions do not support the `json` template function), so read the full
inspect JSON and lift the config into the single-inspect shape chunkah
understands. This keeps labels such as containers.bootc=1.
"""

import json
import subprocess
import sys

image = sys.argv[1]
raw = subprocess.check_output(["buildah", "inspect", image], text=True)
data = json.loads(raw)

oci = data.get("OCIv1")
if isinstance(oci, str):
    oci = json.loads(oci)
if not isinstance(oci, dict):
    raise SystemExit("buildah inspect did not return an OCIv1 image")

print(
    json.dumps(
        {
            "Config": oci.get("config", {}),
            "Architecture": oci.get("architecture"),
            "Created": oci.get("created"),
            "Annotations": oci.get("annotations", {}),
        },
        separators=(",", ":"),
    )
)
