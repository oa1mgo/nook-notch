#!/usr/bin/env python3
"""Build and validate Nook's drag-to-install DMG without automating Finder."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

import dmgbuild
from ds_store import DSStore


ASSETS = Path(__file__).resolve().parent


def run(*args):
    return subprocess.run([str(arg) for arg in args], check=True, capture_output=True).stdout


def read_bundle(app):
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if info.get("CFBundleIdentifier") != "com.oaimgo.nook":
        raise ValueError("Expected the com.oaimgo.nook application bundle")
    if info.get("CFBundleExecutable") != "Nook" or not os.access(app / "Contents/MacOS/Nook", os.X_OK):
        raise ValueError("Nook.app has no runnable Nook executable")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    return info


def image_settings(app, background):
    layout = json.loads((ASSETS / "layout.json").read_text())
    return {
        "format": "UDZO",
        "filesystem": "HFS+",
        "files": [(str(app), "Nook.app")],
        "symlinks": {"Applications": "/Applications"},
        "icon": str(app / "Contents/Resources/AppIcon.icns"),
        "background": str(background),
        # Do not set hide_extensions: dmgbuild adds FinderInfo to the app,
        # which makes strict code-signature verification reject the bundle.
        "window_rect": ((200, 160), (layout["width"], layout["height"])),
        "icon_locations": {
            "Nook.app": (layout["appX"], layout["iconY"]),
            "Applications": (layout["applicationsX"], layout["iconY"]),
        },
        "icon_size": layout["iconSize"],
        "text_size": layout["textSize"],
        "default_view": "icon-view",
        "include_icon_view_settings": True,
        "include_list_view_settings": False,
        "arrange_by": None,
        # Finder rejects saved icon settings when this is 100 or greater.
        "grid_spacing": 90,
        "show_icon_preview": False,
        "show_status_bar": False,
        "show_tab_view": False,
        "show_toolbar": False,
        "show_pathbar": False,
        "show_sidebar": False,
    }


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify_background(*images):
    run("/usr/bin/xcrun", "swift", ASSETS / "validate-background.swift", ASSETS / "layout.json", *images)


def verify_mounted(mount, settings, source_info):
    require(sorted(path.name for path in mount.iterdir() if not path.name.startswith("."))
            == ["Applications", "Nook.app"], "DMG must show only Nook and Applications")
    applications = mount / "Applications"
    require(applications.is_symlink() and os.readlink(applications) == "/Applications",
            "Applications must be a real drop target pointing to /Applications")
    require(read_bundle(mount / "Nook.app") == source_info, "Packaged bundle metadata changed")
    require((mount / ".background.tiff").is_file(), "Missing Retina installer background")
    verify_background(mount / ".background.tiff")
    with DSStore.open(str(mount / ".DS_Store"), "r") as store:
        window = store["."]["bwsp"]
        (x, y), (width, height) = settings["window_rect"]
        require(window["WindowBounds"] == f"{{{{{x}, {y}}}, {{{width}, {height}}}}}",
                "Incorrect installer window bounds")
        for key in ["ShowToolbar", "ShowSidebar", "ShowStatusBar", "ShowPathbar", "ShowTabView"]:
            require(not window[key], f"Unexpected Finder chrome: {key}")
        icons = store["."]["icvp"]
        require(icons["iconSize"] == settings["icon_size"], "Incorrect icon size")
        require(icons["arrangeBy"] == "none", "Finder must not rearrange the installer")
        require(icons["backgroundType"] == 2 and icons["backgroundImageAlias"],
                "Finder background is not linked to the mounted volume")
        for name, position in settings["icon_locations"].items():
            require(store[name]["Iloc"] == position, f"Incorrect icon position: {name}")


def build(app, output):
    source_info = read_bundle(app)
    require(output.suffix.lower() == ".dmg", "Output must end in .dmg")
    require(not os.path.lexists(output), f"Refusing to overwrite existing output: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    # Only our temporary staging files are removed; never clean a caller directory.
    with tempfile.TemporaryDirectory(prefix="nook-dmg-", dir=output.parent) as temporary:
        staging = Path(temporary)
        print("Rendering installer background (1x and 2x)…", flush=True)
        run("/usr/bin/xcrun", "swift", ASSETS / "render-background.swift", ASSETS / "layout.json", staging)
        verify_background(staging / "background.png", staging / "background@2x.png")
        settings = image_settings(app, staging / "background.png")
        image = staging / "Nook.dmg"
        print("Building drag-to-install DMG…", flush=True)
        dmgbuild.build_dmg(str(image), "Nook", settings=settings)
        run("/usr/bin/hdiutil", "verify", image)
        mount = staging / "mount"
        mount.mkdir()
        run("/usr/bin/hdiutil", "attach", image, "-readonly", "-nobrowse", "-mountpoint", mount)
        try:
            verify_mounted(mount, settings, source_info)
        finally:
            # Detach only the exact staging mount created above, never /Volumes/Nook.
            run("/usr/bin/hdiutil", "detach", mount)
        # Same-volume exclusive publication: concurrent builds cannot overwrite it.
        os.link(image, output)
    print(f"Verified installer: {output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="Built Nook.app bundle")
    parser.add_argument("--output", type=Path, required=True, help="New output .dmg path (must not exist)")
    args = parser.parse_args()
    try:
        build(args.app.resolve(), args.output.absolute())
    except subprocess.CalledProcessError as error:
        parser.exit(1, error.stderr.decode(errors="replace") if error.stderr else str(error))
    except (OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
