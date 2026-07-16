# LustreStudio Rebrand and Brand Assets

**Date:** 2026-07-16
**Project:** LustreStudio native macOS app (formerly VidDL)

## Product-name scope

- Renamed the visible application product and bundle display name to **LustreStudio**.
- Renamed user-facing labels in the app menu, menu bar, About window, upgrade flow, settings, Home, Feed, and transfer messaging.
- Xcode now builds `LustreStudio.app` and the test host points at the renamed executable.

## Compatibility intentionally retained

This is a visual/product rebrand, not an identity migration. Keep these stable unless a separate migration is planned:

- Bundle identifier: `com.pmvdl.app`
- URL scheme and existing persistent storage paths
- Cloud, keychain, app-group, and queue-history identities
- Internal target, source-folder, test-target, and compatibility names that still contain `VidDL` or `PMVDL`

## Stitch brand assets

Assets were reviewed in Stitch project `6772933059805177403`:

- **LustreStudio Red Light Logo Lockup** (`481667adc5cd4f1e9ce85920f5778e00`) informed the Home wordmark.
- **LustreStudio Club App Icon** (`ab92b65a17c0452a97820105c5336486`) informed the macOS app icon.

### Home logo

- Added `Assets.xcassets/LustreStudioLogo.imageset`.
- The source lockup was replaced with a transparent alpha version so it blends into the Home card rather than displaying a black rectangle.
- `HomeStitchCommandPanel` now centers the wordmark above the dependency-status pills; the redundant **Quick Extract** label and helper copy were removed.

### App icon

- Replaced every macOS `AppIcon.appiconset` size with the LustreStudio red-crystal artwork.
- The final icon has transparent outer corners. The rounded black tile and its red perimeter remain; only the unwanted square exterior canvas was removed.
- All app-icon PNGs now carry alpha, which prevents the Dock from showing dark square corners around the rounded tile.

## Validation and latest Debug bundles

- `git diff --check`
- Focused `swiftc -parse` validation for `HomeURLInputCard.swift`
- Unsigned Debug builds used the mounted Xcode runtime and a serial legacy-build invocation:

```sh
DEVELOPER_DIR=/Volumes/MyPassport/Applications/Xcode.app/Contents/Developer \
xcodebuild -UseModernBuildSystem=NO -jobs 1 \
  -project PMVDL/PMVDL.xcodeproj -scheme PMVDL -configuration Debug \
  -derivedDataPath /tmp/lustrestudio-icon-alpha-0716 \
  CODE_SIGNING_ALLOWED=NO build
```

- Latest verified bundle:

```text
/tmp/lustrestudio-icon-alpha-0716/Build/Products/Debug/LustreStudio.app
```

The app was opened from that bundle after the build succeeded.
