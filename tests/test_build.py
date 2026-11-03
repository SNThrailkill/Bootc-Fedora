"""Golden tests for build.py.

The image table is the single source of truth for local builds and CI, so these
tests keep it consistent. Run with:

    python3 -m unittest discover -s tests -v
"""

import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import build  # noqa: E402


class ImageTableTests(unittest.TestCase):
    def test_containerfiles_exist(self):
        for image in build.IMAGES.values():
            with self.subTest(image=image.name):
                self.assertTrue(
                    (ROOT / image.containerfile).is_file(),
                    f"{image.containerfile} for {image.name}",
                )

    def test_ci_images_are_in_the_matrix(self):
        names = {entry["image"] for entry in build.matrix_include()}
        expected = {
            image.name for image in build.IMAGES.values() if image.ci
        }
        self.assertEqual(names, expected)

    def test_sealed_image_is_ci(self):
        self.assertTrue(build.IMAGES["nginx-sealed"].ci)

    def test_matrix_publishes_under_the_content_image_name(self):
        entries = {entry["image"]: entry for entry in build.matrix_include()}
        for image in build.IMAGES.values():
            if not image.ci:
                continue
            with self.subTest(image=image.name):
                expected = image.image_name or image.name
                self.assertEqual(entries[image.name]["image_name"], expected)

    def test_matrix_shape(self):
        for entry in build.matrix_include():
            self.assertEqual(
                set(entry),
                {
                    "image",
                    "containerfile",
                    "build_target",
                    "image_name",
                    "tag_override",
                    "sealed",
                    "oci",
                },
            )

    def test_matrix_includes_sealed_images(self):
        # nginx-sealed is built by CI; it must not silently drop out of the
        # matrix just because it needs a seal step.
        entries = {entry["image"]: entry for entry in build.matrix_include()}
        sealed = entries["nginx-sealed"]
        self.assertTrue(sealed["sealed"])
        self.assertTrue(sealed["oci"])
        self.assertEqual(sealed["image_name"], "nginx")
        self.assertEqual(sealed["tag_override"], "sealed")
        self.assertEqual(sealed["build_target"], "sealed")

    def test_sealed_images_are_complete(self):
        sealed = [i for i in build.IMAGES.values() if i.requires_keys]
        self.assertTrue(sealed, "expected at least one sealed image")
        for image in sealed:
            with self.subTest(image=image.name):
                self.assertEqual(image.target, "sealed")

    def test_sealed_key_scripts_exist(self):
        self.assertTrue((ROOT / "keys" / "util" / "keygen.sh").is_file())
        self.assertTrue((ROOT / "keys" / "util" / "gen-auth.sh").is_file())

    def test_public_secureboot_material_matches(self):
        # The committed certificate and enrollment blobs are what make a
        # pulled sealed image bootable in OVMF Setup Mode. Keep them in sync.
        cert = ROOT / "keys" / "db.crt"
        self.assertTrue(cert.is_file(), "keys/db.crt must be committed")
        for name in ("PK", "KEK", "db"):
            with self.subTest(blob=name):
                blob = ROOT / "keys" / "auth" / "auto" / f"{name}.auth"
                self.assertTrue(blob.is_file(), f"missing {blob}")
                cert = ROOT / "keys" / f"{name}.crt"
                self.assertTrue(cert.is_file(), f"missing {cert}")
                der = subprocess.run(
                    ["openssl", "x509", "-in", str(cert), "-outform", "DER"],
                    check=True,
                    capture_output=True,
                ).stdout
                self.assertIn(
                    der,
                    blob.read_bytes(),
                    f"{blob} does not contain the committed {name} certificate",
                )

    def test_local_tag(self):
        self.assertEqual(build.local_tag("nginx", "demo"), "localhost/nginx:demo")


if __name__ == "__main__":
    unittest.main()
