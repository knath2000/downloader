# Session 2026-07-06: Feed Browser Polish, Modal Settings, App Shell, and VidDL 2.2.1 DMG

## Summary

This session completed the current Lustre/Obsidian pass for Feed, Settings, and the app shell, kept packaging on the unsigned personal-use path, and prepared VidDL `2.2.1`.

## Feed Browser

- Feed is now browser-only in active UI. The legacy scraper grid path, grid toolbar/filter UI, grid skeleton/empty/error UI, `FeedGridLayout`, grid layout test, and grid card target reference were removed.
- The Feed browser multi-select action pane was restored as a compact bottom overlay inside the browser surface, positioned above the floating app tab switcher.
- Right-click Select/Deselect still toggles session-scoped `FeedItem` selection. Clear empties selection, and Extract Selected sends newline-joined URLs to Home before clearing selection.
- Lightweight browser motion was added for the selection pane, button press feedback, page loading mask, and state transitions while respecting reduced-effects/performance gates.
- After the larger collapsible navigation pill landed, Feed now receives the current app-shell bottom chrome inset and positions the selection action pane above either the expanded nav or collapsed hamburger-only pill with a small breathing gap.
- Feed selection is now held in a private session-scoped store instead of transient local `FeedView` state. Selected videos persist when switching away from Feed and returning during the same app session, then clear only through Clear, Extract Selected handoff, or app exit.

## Settings

- Settings is now a modal-first surface. The landing page shows five compact tiles: Cloud Destination, Notifications, Downloads & Helpers, VidDL Pro, and About.
- Each tile opens through the shared `AppModalOverlay` and keeps the detailed controls out of the primary page.
- Existing behavior was preserved for Google Drive setup, dependency checks, notification toggles, subtitle Pro gating, sleep prevention, download folder browse/open/reset, Pro purchase/activation/deactivation, and About.
- The Settings page follows the current Lustre/Obsidian direction: dark neutral surfaces, subtle borders, compact typography, restrained semantic status chips, and no nested card-heavy primary page.

## App Shell

- Cold tab opening now separates tab selection from first-time heavy tab construction. The selected tab updates immediately, a lightweight placeholder renders first, and the real tab mounts shortly after the first frame.
- Inactive tabs remain unmounted by default so hidden `WKWebView` instances and other heavy surfaces do not run on older Intel hardware.
- A delayed startup warmup touches only cheap shared stores: `VideoLibrary`, `HistoryManager`, `FeedFavoritesStore`, `FeedViewModel`, and `SettingsDependencyStore`. It does not preload WebViews, start feed network loads, or run dependency subprocess checks.
- The bottom navigation pill is larger and more tactile. It starts expanded each launch, includes a leading hamburger button, and toggles to a session-only hamburger-only condensed state.
- The expanded nav keeps all destinations, locked/feed indicators, and the Home queue badge. The condensed state intentionally hides navigation items and badges until expanded again.
- Content and tab-opening placeholders now receive a bottom inset based on the expanded or collapsed pill height, preventing primary controls from sitting underneath the floating navigation.

## Extraction Loading and Result Performance

- Multi-URL extraction now presents one aggregate loading pane while extraction is in progress and no results are ready, instead of rendering three simultaneous skeleton panes.
- The Home loading state mirrors the modal behavior with one loading card.
- Completed extraction rows in the results modal were made lighter for large batches: stable row models, precomputed presentation data, less per-row visual work, no extra row identity churn, and lightweight thumbnails for larger completed result sets.
- Existing extraction behavior was preserved: retry, Add URL, quality picker, target picker, copy URL, local download, cloud upload actions, and batch download still flow through the existing callbacks.

## Packaging

- `CFBundleShortVersionString` was bumped to `2.2.1`; the build number remains `5`.
- The only active packaging path remains `bash scripts/build-dmg.sh`, which builds an unsigned Debug app with external Xcode and wraps it in an unsigned, unnotarized local DMG.
- The generated artifact is `VidDL-2.2.1-build5-unsigned.dmg`.

## Verification

- `git diff --check`
- Focused Swift parse for changed Feed/Settings/App Shell files during implementation.
- Unsigned Debug `xcodebuild` with:

```sh
DEVELOPER_DIR=/Volumes/MyPassport/Applications/Xcode.app/Contents/Developer xcodebuild -project PMVDL/PMVDL.xcodeproj -scheme PMVDL -configuration Debug -derivedDataPath /tmp/viddl-settings-modal-redesign CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' build
```

- Recurring unrelated warnings remain in existing files and asset catalog setup, including the missing `AccentColor` asset warning.
- `bash scripts/build-dmg.sh` succeeded for VidDL `2.2.1` build `5`.
- `hdiutil verify VidDL-2.2.1-build5-unsigned.dmg` passed with a valid checksum.
- The built app bundle contains `Contents/MacOS/VidDL` and reports `CFBundleShortVersionString=2.2.1`, `CFBundleVersion=5`.
- Cold-tab and collapsible-nav validation used:

```sh
DEVELOPER_DIR=/Volumes/MyPassport/Applications/Xcode.app/Contents/Developer xcrun swiftc -parse PMVDL/PMVDL/ContentView.swift
DEVELOPER_DIR=/Volumes/MyPassport/Applications/Xcode.app/Contents/Developer xcodebuild -project PMVDL/PMVDL.xcodeproj -scheme PMVDL -configuration Debug -derivedDataPath /tmp/viddl-collapsible-nav CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' build
```

- Feed selection/loading/performance follow-up validation used:

```sh
DEVELOPER_DIR=/Volumes/MyPassport/Applications/Xcode.app/Contents/Developer xcrun swiftc -parse PMVDL/PMVDL/ContentView.swift PMVDL/PMVDL/Feed/FeedView.swift PMVDL/PMVDL/HomeView.swift PMVDL/PMVDL/Home/ExtractionModalView.swift
DEVELOPER_DIR=/Volumes/MyPassport/Applications/Xcode.app/Contents/Developer xcodebuild -project PMVDL/PMVDL.xcodeproj -scheme PMVDL -configuration Debug -derivedDataPath /tmp/viddl-feed-selection-loading-polish CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' build
```
