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
        self.settings = build.image_settings(self.mount / "source/Nook.app")
        (self.mount / "Nook.app").mkdir()
        (self.mount / "Applications").symlink_to("/Applications")
        (x, y), (width, height) = self.settings["window_rect"]
        with DSStore.open(str(self.mount / ".DS_Store"), "w+") as store:
            store["."]["bwsp"] = {
                "WindowBounds": f"{{{{{x}, {y}}}, {{{width}, {height}}}}}",
                "ShowToolbar": False, "ShowSidebar": False, "ShowStatusBar": False,
                "ShowPathbar": False, "ShowTabView": False,
            }
            store["."]["icvp"] = {
                "iconSize": self.settings["icon_size"], "arrangeBy": "none",
                "backgroundType": 0,
                "textSize": self.settings["text_size"], "labelOnBottom": True,
                "scrollPositionX": 0, "scrollPositionY": 0,
                "gridSpacing": self.settings["grid_spacing"],
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
        self.assertIsNone(self.settings["background"])
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

    def testRasterBackgroundIsRejectedEvenIfNotReferenced(self):
        (self.mount / ".background.tiff").touch()
        with self.assertRaisesRegex(ValueError, "background artwork"):
            self.verify()

    def testBackgroundDirectoryIsRejected(self):
        (self.mount / ".background").mkdir()
        with self.assertRaisesRegex(ValueError, "background artwork"):
            self.verify()

    def testPictureOrColorBackgroundMetadataIsRejected(self):
        for kind in [1, 2]:
            with self.subTest(kind=kind):
                self.set_icon_options(backgroundType=kind)
                with self.assertRaisesRegex(ValueError, "native background"):
                    self.verify()

    def testStaleImageAliasIsRejectedEvenWithNativeBackground(self):
        self.set_icon_options(backgroundImageAlias=b"old-image")
        with self.assertRaisesRegex(ValueError, "native background"):
            self.verify()

    def testScrollOffsetIsRejected(self):
        for axis in ["scrollPositionX", "scrollPositionY"]:
            with self.subTest(axis=axis):
                self.set_icon_options(**({"scrollPositionX": 0, "scrollPositionY": 0} | {axis: 100}))
                with self.assertRaisesRegex(ValueError, "scroll offset"):
                    self.verify()

    def testUnreadableLabelsAreRejected(self):
        self.set_icon_options(textSize=8)
        with self.assertRaisesRegex(ValueError, "native icon labels"):
            self.verify()
        self.set_icon_options(textSize=self.settings["text_size"], labelOnBottom=False)
        with self.assertRaisesRegex(ValueError, "native icon labels"):
            self.verify()

    def testAutomaticArrangementIsRejected(self):
        self.set_icon_options(arrangeBy="name")
        with self.assertRaisesRegex(ValueError, "rearrange"):
            self.verify()

    def testUnsupportedGridIsRejected(self):
        self.set_icon_options(gridSpacing=100)
        with self.assertRaisesRegex(ValueError, "icon grid"):
            self.verify()

    def testUnexpectedVisibleFileIsRejected(self):
        (self.mount / "background.png").touch()
        with self.assertRaisesRegex(ValueError, "only Nook and Applications"):
            self.verify()

    def testLargeWindowOrVisibleToolbarIsRejected(self):
        for changes in [{"WindowBounds": "{{200, 160}, {960, 560}}"}, {"ShowToolbar": True}]:
            with self.subTest(changes=changes):
                with DSStore.open(str(self.mount / ".DS_Store"), "r+") as store:
                    window = store["."]["bwsp"]
                    original = dict(window)
                    window.update(changes)
                    store["."]["bwsp"] = window
                with self.assertRaisesRegex(ValueError, "window bounds|Finder chrome"):
                    self.verify()
                with DSStore.open(str(self.mount / ".DS_Store"), "r+") as store:
                    store["."]["bwsp"] = original

    def set_icon_options(self, **changes):
        with DSStore.open(str(self.mount / ".DS_Store"), "r+") as store:
            icons = store["."]["icvp"]
            icons.update(changes)
            store["."]["icvp"] = icons

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
