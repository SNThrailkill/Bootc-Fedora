#!/usr/bin/env python3
"""Print a chunkah-compatible config for a local buildah image.

chunkah accepts either a direct OCI image config or podman/docker inspect
output. `buildah inspect` nests the config under .OCIv1, so lift it into the
single-inspect shape chunkah understands. This keeps labels such as
containers.bootc=1.
"""

import json
import subprocess
import sys

image = sys.argv[1]
raw = subprocess.check_output(
    ["buildah", "inspect", "--format", "{{json .OCIv1}}", image],
    text=True,
)
oci = json.loads(raw)
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
