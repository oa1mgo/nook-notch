"""Exercise real AppKit rendering, not an empty background placeholder."""

from pathlib import Path
import subprocess
import tempfile
import unittest


ASSETS = Path(__file__).resolve().parent


class BackgroundTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="nook-dmg-background-test-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.output = Path(cls.temporary.name)
        subprocess.run(["xcrun", "swift", str(ASSETS / "render-background.swift"),
            str(ASSETS / "layout.json"), str(cls.output)], check=True, capture_output=True)

    def validate(self, *paths):
        return subprocess.run(["xcrun", "swift", str(ASSETS / "validate-background.swift"),
            str(ASSETS / "layout.json"), *map(str, paths)], capture_output=True, text=True)

    def testStandardAndRetinaHaveMatchingLayout(self):
        result = self.validate(self.output / "background.png", self.output / "background@2x.png")
        self.assertEqual(result.returncode, 0, result.stderr)

    def testPackagedTIFFPreservesBothRepresentations(self):
        tiff = self.output / "background.tiff"
        subprocess.run(["tiffutil", "-cathidpicheck", str(self.output / "background.png"),
            str(self.output / "background@2x.png"), "-out", str(tiff)], check=True, capture_output=True)
        result = self.validate(tiff)
        self.assertEqual(result.returncode, 0, result.stderr)

    def testMissingRetinaRepresentationIsRejected(self):
        result = self.validate(self.output / "background.png")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("both 1x and 2x", result.stderr)

    def testDuplicateRepresentationIsRejected(self):
        result = self.validate(self.output / "background.png", self.output / "background.png")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Duplicate", result.stderr)


if __name__ == "__main__":
    unittest.main()
