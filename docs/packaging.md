# Nook DMG packaging

## Installer layout

The installer uses a compact **480 × 280** Finder icon-view window: Nook on the
left and an actual symbolic link to `/Applications` on the right. Finder draws
its native background, scalable icons, and readable labels; there is no bitmap,
decorative arrow, or rasterized instruction text. Sidebar, toolbar, tabs, path
bar, and status bar are configured hidden. Only the two installation items are
visible. Drag Nook onto Applications, then open it from the Applications folder.

`tools/dmg/layout.json` is the shared source of truth for the point-sized window
and icon coordinates. `background: None` produces `backgroundType: 0` with no
image alias. The old renderer, image validator, and raster tests have been
removed; Retina bitmap/DPI selection is no longer part of packaging. There is no
background-image or Python dependency in the Nook application.

The old release workflow passed the app directly to `hdiutil create`, without an
Applications link or saved Finder layout. The release workflow now calls the same
validated packaging entrypoint used locally.

## Build locally

Requires macOS, Xcode selected with `xcode-select` or `DEVELOPER_DIR`, Python 3.10+
(CI uses 3.12), and an already-built Nook app. For example:

```sh
xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Release \
  -destination 'generic/platform=macOS' ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  -derivedDataPath build/ReleaseValidation build

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
- No `.background*` artwork exists on the volume, and Finder metadata selects
  the native background without any stale image alias.
- Finder window dimensions, hidden chrome, icon sizes, and both positions match
  the layout; automatic icon rearrangement is disabled. Icon labels are below
  the icons at the configured font size, and both scroll offsets are zero.

The image is detached after validation. Mount the final DMG to visually inspect
the Finder window, check the native icon labels and spacing, and open its
Applications shortcut. Do not overwrite an installed app just to test the layout.

Do not use dmgbuild's `hide_extensions` on `Nook.app`: it attaches FinderInfo to
the app and fails strict signature validation. Preserve the signed bundle rather
than rewriting its attributes for a cosmetic filename change.

The 16 packaging unit tests reject missing/wrong Applications links, unexpected
files, background artwork/directories, picture/color metadata, stale image
aliases, incorrect positions/labels, oversized windows, visible toolbars,
unsupported grids, nonzero scroll offsets, rearrangement, and output overwrites.
Release CI runs these tests and validates the actual mounted DMG before upload.

## Universal release builds (1.5.0)

Use the generic macOS destination and explicit `arm64 x86_64` architectures for
distribution. A current-Mac destination can produce an arm64-only application
even when the project's Release settings list both architectures. The release
workflow now requires the built app version to match the tag and verifies both
architectures with `lipo -verify_arch arm64 x86_64` before packaging. The bundled
MediaRemoteAdapter also contains both architectures. Local app tests and launch
checks run on Apple Silicon; the architecture check does not claim an Intel
hardware runtime test.

## Retina scaling fix (2026-09-14)

The 1.4.1 renderer assigned the bitmap a logical `size` of 600 × 360 points and
then manually scaled its graphics context by the representation's pixel scale.
`NSGraphicsContext(bitmapImageRep:)` already accounts for that logical size: on a
2x representation, the extra transform made artwork effectively 4x, shifting and
cropping the title, arrow, and footer. The PNG/TIFF dimensions and DPI were still
correct, so the previous presence-only background check missed the defect.

The first 1.4.2 package removed that redundant transform. Its 1x/2x raster
comparison passed (mean difference 0.0026, threshold 0.008), as did the local
standard-density Finder check. Nevertheless the user still saw enlarged artwork
on another display. Those tests did not prove Finder's presentation on that
display, and the precise remaining cause was not reproduced locally.

**Superseded in republished 1.4.2, build 2:** the user approved a simpler window.
Remove the entire image-background path instead of making another DPI adjustment.
The new DMG passes all 16 packaging tests, checksum, bundle/signature-integrity,
Applications-link, native-background, and Finder-metadata checks. Freshly
double-clicking it shows the two items in the intended 480 × 280 window. The
actual window screenshot is `readme/img_nook_installer_native.jpg`. Physical
Retina/mixed-monitor hardware is still unavailable; no display settings or
installed applications were changed during validation.

Finder's disk-image window is a saved **point-sized icon layout**, not a responsive
web page. Opening the volume inside an already-open Finder window can inherit that
window's toolbar and dimensions; use a fresh DMG open for first-install layout
checks. This fix does not claim to control arbitrary user-resized Finder windows.
The validated local replacement is `build/Release142Replacement/Nook-1.4.2.dmg`
(ignored). The GitHub workflow builds and verifies its own artifact from the
updated main commit before publishing it.

## Distribution boundary

The installer change does not change app entitlements, configure Developer ID
signing/notarization, or bypass Gatekeeper. Local ad-hoc signatures
can pass integrity validation without being trusted Developer ID distribution
signatures. At the user's explicit request, the old GitHub 1.4.2 release/asset is
replaced after validating the new package, and `release/1.4.2` is moved to the
new main commit. The app marketing version stays 1.4.2; `CFBundleVersion` becomes
2 in both app configurations to distinguish the rebuild. This release also
includes the [adaptive Music Glow tail](specs/2026-09-14-music-glow-adaptive-release.md).
People who downloaded the earlier installer need to download it again.

The pinned packaging-only dependencies and hashes live in
`tools/dmg/requirements.txt`. [dmgbuild](https://github.com/dmgbuild/dmgbuild)
writes the Finder metadata without needing a GUI session, so CI does not require
Finder automation permission. See its [settings reference](https://dmgbuild.readthedocs.io/en/latest/settings.html).
