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

    def test_local_tag(self):
        self.assertEqual(build.local_tag("nginx", "demo"), "localhost/nginx:demo")


if __name__ == "__main__":
    unittest.main()
