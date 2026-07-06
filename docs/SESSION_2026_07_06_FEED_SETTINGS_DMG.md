# Session 2026-07-06: Feed Browser Polish, Modal Settings, and VidDL 2.2.1 DMG

## Summary

This session completed the current Lustre/Obsidian pass for Feed and Settings, kept packaging on the unsigned personal-use path, and prepared VidDL `2.2.1`.

## Feed Browser

- Feed is now browser-only in active UI. The legacy scraper grid path, grid toolbar/filter UI, grid skeleton/empty/error UI, `FeedGridLayout`, grid layout test, and grid card target reference were removed.
- The Feed browser multi-select action pane was restored as a compact bottom overlay inside the browser surface, positioned above the floating app tab switcher.
- Right-click Select/Deselect still toggles session-scoped `FeedItem` selection. Clear empties selection, and Extract Selected sends newline-joined URLs to Home before clearing selection.
- Lightweight browser motion was added for the selection pane, button press feedback, page loading mask, and state transitions while respecting reduced-effects/performance gates.

## Settings

- Settings is now a modal-first surface. The landing page shows five compact tiles: Cloud Destination, Notifications, Downloads & Helpers, VidDL Pro, and About.
- Each tile opens through the shared `AppModalOverlay` and keeps the detailed controls out of the primary page.
- Existing behavior was preserved for Google Drive setup, dependency checks, notification toggles, subtitle Pro gating, sleep prevention, download folder browse/open/reset, Pro purchase/activation/deactivation, and About.
- The Settings page follows the current Lustre/Obsidian direction: dark neutral surfaces, subtle borders, compact typography, restrained semantic status chips, and no nested card-heavy primary page.

## Packaging

- `CFBundleShortVersionString` was bumped to `2.2.1`; the build number remains `5`.
- The only active packaging path remains `bash scripts/build-dmg.sh`, which builds an unsigned Debug app with external Xcode and wraps it in an unsigned, unnotarized local DMG.
- The generated artifact is `VidDL-2.2.1-build5-unsigned.dmg`.

## Verification

- `git diff --check`
- Focused Swift parse for changed Feed/Settings files during implementation.
- Unsigned Debug `xcodebuild` with:

```sh
DEVELOPER_DIR=/Volumes/MyPassport/Applications/Xcode.app/Contents/Developer xcodebuild -project PMVDL/PMVDL.xcodeproj -scheme PMVDL -configuration Debug -derivedDataPath /tmp/viddl-settings-modal-redesign CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' build
```

- Recurring unrelated warnings remain in existing files and asset catalog setup, including the missing `AccentColor` asset warning.
- `bash scripts/build-dmg.sh` succeeded for VidDL `2.2.1` build `5`.
- `hdiutil verify VidDL-2.2.1-build5-unsigned.dmg` passed with a valid checksum.
- The built app bundle contains `Contents/MacOS/VidDL` and reports `CFBundleShortVersionString=2.2.1`, `CFBundleVersion=5`.
