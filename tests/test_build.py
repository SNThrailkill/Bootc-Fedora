"""Golden tests for build.py.

The image table is the single source of truth for local builds and CI, so these
tests keep it consistent. Run with:

    python3 -m unittest discover -s tests -v
"""

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

    def test_matrix_shape(self):
        for entry in build.matrix_include():
            self.assertEqual(
                set(entry), {"image", "containerfile", "build_target"}
            )

    def test_matrix_excludes_sealed_images(self):
        names = {entry["image"] for entry in build.matrix_include()}
        for image in build.IMAGES.values():
            if image.requires_keys:
                self.assertNotIn(image.name, names)

    def test_sealed_images_are_complete(self):
        sealed = [i for i in build.IMAGES.values() if i.requires_keys]
        self.assertTrue(sealed, "expected at least one sealed image")
        for image in sealed:
            with self.subTest(image=image.name):
                self.assertEqual(image.target, "sealed")
                self.assertTrue(image.sealed_from)
                self.assertEqual(image.sealed_target, "sealed")

    def test_sealed_key_scripts_exist(self):
        self.assertTrue((ROOT / "keys" / "util" / "keygen.sh").is_file())
        self.assertTrue((ROOT / "keys" / "util" / "gen-auth.sh").is_file())

    def test_local_tag(self):
        self.assertEqual(build.local_tag("nginx", "demo"), "localhost/nginx:demo")


if __name__ == "__main__":
    unittest.main()
