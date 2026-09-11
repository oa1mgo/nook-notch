from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from ds_store import DSStore

import build


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="nook-dmg-test-")
        self.addCleanup(self.temporary.cleanup)
        self.mount = Path(self.temporary.name)
        self.settings = build.image_settings(self.mount / "source/Nook.app", self.mount / "background.png")
        (self.mount / "Nook.app").mkdir()
        (self.mount / "Applications").symlink_to("/Applications")
        (self.mount / ".background.tiff").touch()
        (x, y), (width, height) = self.settings["window_rect"]
        with DSStore.open(str(self.mount / ".DS_Store"), "w+") as store:
            store["."]["bwsp"] = {
                "WindowBounds": f"{{{{{x}, {y}}}, {{{width}, {height}}}}}",
                "ShowToolbar": False, "ShowSidebar": False, "ShowStatusBar": False,
                "ShowPathbar": False, "ShowTabView": False,
            }
            store["."]["icvp"] = {
                "iconSize": self.settings["icon_size"], "arrangeBy": "none",
                "backgroundType": 2, "backgroundImageAlias": b"fixture",
            }
            for name, position in self.settings["icon_locations"].items():
                store[name]["Iloc"] = position
        self.bundle = {"CFBundleIdentifier": "com.oaimgo.nook", "CFBundleShortVersionString": "1.4.0"}
        mock = patch.object(build, "read_bundle", return_value=self.bundle)
        mock.start()
        self.addCleanup(mock.stop)

    def verify(self):
        build.verify_mounted(self.mount, self.settings, self.bundle)

    def testValidLayout(self):
        self.verify()
        _, (width, height) = self.settings["window_rect"]
        radius = self.settings["icon_size"] / 2
        for x, y in self.settings["icon_locations"].values():
            self.assertTrue(radius < x < width - radius)
            self.assertTrue(radius < y < height - radius - self.settings["text_size"])
        self.assertLess(self.settings["grid_spacing"], 100)
        self.assertNotIn("hide_extensions", self.settings)

    def testMissingDropTargetIsRejected(self):
        (self.mount / "Applications").unlink()
        with self.assertRaisesRegex(ValueError, "only Nook and Applications"):
            self.verify()

    def testFolderMasqueradingAsApplicationsIsRejected(self):
        (self.mount / "Applications").unlink()
        (self.mount / "Applications").mkdir()
        with self.assertRaisesRegex(ValueError, "real drop target"):
            self.verify()

    def testWrongDropDestinationIsRejected(self):
        (self.mount / "Applications").unlink()
        (self.mount / "Applications").symlink_to("/tmp")
        with self.assertRaisesRegex(ValueError, "real drop target"):
            self.verify()

    def testMissingRetinaBackgroundIsRejected(self):
        (self.mount / ".background.tiff").unlink()
        with self.assertRaisesRegex(ValueError, "Retina"):
            self.verify()

    def testMissingIconPositionIsRejected(self):
        with DSStore.open(str(self.mount / ".DS_Store"), "r+") as store:
            store["Applications"]["Iloc"] = (0, 0)
        with self.assertRaisesRegex(ValueError, "icon position"):
            self.verify()

    def testExistingImageIsNeverOverwritten(self):
        output = self.mount / "existing.dmg"
        output.write_bytes(b"keep this image")
        with self.assertRaisesRegex(ValueError, "Refusing to overwrite"):
            build.build(self.mount / "Nook.app", output)
        self.assertEqual(output.read_bytes(), b"keep this image")


if __name__ == "__main__":
    unittest.main()
