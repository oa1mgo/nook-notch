# Nook DMG packaging

## Installer layout

The installer uses a compact 600 × 360 Finder icon-view window: Nook on the left,
an actual symbolic link to `/Applications` on the right, and a drag arrow between
them. Sidebar, toolbar, tabs, path bar, and status bar are hidden. Only the two
installation items are visible; supporting artwork and Finder metadata are hidden.

`tools/dmg/layout.json` is the shared source of truth for the window and icon
coordinates. `render-background.swift` creates 1x and 2x backgrounds using AppKit
at build time; the background does not contain fake app or folder icons. Finder
draws the real interactive items. No background-image or Python dependency is
added to the Nook application.

The old release workflow passed the app directly to `hdiutil create`, without an
Applications link or saved Finder layout. The release workflow now calls the same
validated packaging entrypoint used locally.

## Build locally

Requires macOS, Xcode selected with `xcode-select` or `DEVELOPER_DIR`, Python 3.10+
(CI uses 3.12), and an already-built Nook app. For example:

```sh
xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build/ReleaseValidation build

python3 -m venv build/DMGTools
build/DMGTools/bin/python -m pip install --require-hashes --only-binary=:all: \
  -r tools/dmg/requirements.txt
build/DMGTools/bin/python -m unittest discover -s tools/dmg -p 'test_*.py'
build/DMGTools/bin/python tools/dmg/build.py \
  --app build/ReleaseValidation/Build/Products/Release/Nook.app \
  --output build/Nook-installer.dmg
```

Output must not already exist; select a new filename when iterating. The builder
never deletes an existing installer or changes the source app. It stages files in
its own temporary directory next to the output, validates the result, then
publishes it exclusively. It does not install Nook into `/Applications`.

## Validation

Every packaging run verifies the source app signature, the compressed disk-image
checksum, and the mounted read-only result:

- Visible items are exactly `Nook.app` and `Applications`.
- The Applications item is a symlink to `/Applications`, not an empty folder.
- App bundle metadata and code-signature verification survive packaging.
- The Retina background is present and referenced in Finder metadata.
- Both PNG sources and the packaged TIFF contain matching 1x/2x artwork at
  600 × 360 logical points (600 × 360 / 1200 × 720 pixels). The validator compares
  their pixels at a common logical size, allowing normal font antialiasing.
- Finder window dimensions, hidden chrome, icon sizes, and both positions match
  the layout; automatic icon rearrangement is disabled.

The image is detached after validation. Mount the final DMG to visually inspect
the Finder window, check the icon labels and arrow alignment, and open its
Applications shortcut. Do not overwrite an installed app just to test the layout.

Do not use dmgbuild's `hide_extensions` on `Nook.app`: it attaches FinderInfo to
the app and fails strict signature validation. Preserve the signed bundle rather
than rewriting its attributes for a cosmetic filename change.

The packaging unit tests reject missing/wrong Applications links, missing artwork,
incorrect icon positions, and output overwrites. The real AppKit rendering tests
also cover matching PNG/TIFF representations, missing Retina data, and duplicate
representations. Release CI runs all 11 tests and the mounted-image checks before
uploading the DMG.

## Retina scaling fix (2026-09-14)

The 1.4.1 renderer assigned the bitmap a logical `size` of 600 × 360 points and
then manually scaled its graphics context by the representation's pixel scale.
`NSGraphicsContext(bitmapImageRep:)` already accounts for that logical size: on a
2x representation, the extra transform made artwork effectively 4x, shifting and
cropping the title, arrow, and footer. The PNG/TIFF dimensions and DPI were still
correct, so the previous presence-only background check missed the defect.

The renderer now only flips logical coordinates; AppKit owns the backing-scale
transform. The existing 1x PNG is byte-for-byte unchanged, and 2x matches its
layout. `validate-background.swift` checks dimensions, logical size/DPI, both
representations, and mean RGB difference after normalizing resolution. The old
renderer fails the new PNG and TIFF regression tests (difference 0.0254); the
fixed images pass (0.0026, allowed < 0.008). Validation runs before packaging and
again on the actual mounted TIFF.

Local validation: 11 tests pass, and a freshly built DMG passes checksum, bundle,
signature-integrity, Applications-symlink, Finder-metadata, and artwork checks.
Double-clicking the DMG on the attached 1920 × 1080 standard-density display
opens the intended 600 × 360 Finder window; its Applications shortcut opens the
real folder. Retina is verified through actual 2x raster/packaged-image data;
physical Retina and mixed-monitor drag checks were not available on this host.
Display settings were not changed, and no installed app was overwritten.

Finder's disk-image window is a saved **point-sized icon layout**, not a responsive
web page. Opening the volume inside an already-open Finder window can inherit that
window's toolbar and dimensions; use a fresh DMG open for first-install layout
checks. This fix does not claim to control arbitrary user-resized Finder windows.
The generated preview is `build/DMGDisplayValidation/Nook-display-fix.dmg` (ignored),
not a replacement for the already-published 1.4.1 asset.

## Distribution boundary

This only changes the installer presentation and packaging checks. It does not
change app entitlements, configure Developer ID signing/notarization, bypass
Gatekeeper, bump the app version, or create a release tag. Local ad-hoc signatures
can pass integrity validation without being trusted Developer ID distribution
signatures. A new release must still follow the existing version/tag workflow;
already-published DMGs are not modified by this change.

The pinned packaging-only dependencies and hashes live in
`tools/dmg/requirements.txt`. [dmgbuild](https://github.com/dmgbuild/dmgbuild)
writes the Finder metadata without needing a GUI session, so CI does not require
Finder automation permission. See its [settings reference](https://dmgbuild.readthedocs.io/en/latest/settings.html).
