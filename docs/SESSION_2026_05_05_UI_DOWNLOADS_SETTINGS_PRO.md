# Session Summary - 2026-05-05 UI, Downloads, Settings, Menu Bar, Pro Gates

## Scope

This session continued the VidDL refactor after the Home, Settings, and Library thumbnail work captured in `docs/SESSION_2026_05_05_REFACTOR_UI_THUMBNAILS_HOME.md`.

The main outcomes were:

- History, Library, Downloads, and Settings were brought into the same Liquid Glass marketplace UI system.
- The Downloads pause/resume path was fixed so a paused download does not immediately resume.
- The persistent menu bar icon was removed.
- Pro monetization Phase 1 and Phase 2 were implemented and verified.

## UI Overhauls

### History

`PMVDL/PMVDL/History/HistoryView.swift` was redesigned into a denser grouped list:

- Removed duplicate page header below the macOS toolbar.
- Replaced the plain search field with a glass search capsule.
- Added provider chips and stream type filtering.
- Grouped history entries and completed uploads by day.
- Replaced full repeated date strings with compact day headers and per-row times.
- Shortened raw URLs into host plus short path/id display.
- Added hover-revealed row actions.
- Added a confirmation dialog before clearing all history.

### Library

`PMVDL/PMVDL/LibraryView.swift` was redesigned into a grouped thumbnail grid:

- Removed duplicate page header.
- Added glass toolbar with search, source filters, sort menu, count badge, and refresh.
- Grouped cards by day.
- Cleaned display titles by stripping trailing filename/hash suffixes.
- Surfaced upload status through cloud badges.
- Restyled MP4/HLS badges.
- Added hover actions for media/source/re-extract/upload/delete.
- Added multi-select actions.
- Kept the SHA256 thumbnail cache path established earlier.

### Downloads

`PMVDL/PMVDL/DownloadQueueView.swift` was redesigned around active transfer status:

- Removed duplicate page header.
- Added glass toolbar with search, status filters, action menu, and count badge.
- Grouped rows by Active, Queued, Paused, Failed, and Done.
- Added status-tinted cards and a left status rail.
- Added pipeline-aware progress bar.
- Surfaced speed, ETA, downloaded bytes, and total bytes when available.
- Added prominent Retry for failed rows.
- Added failed-row inline error treatment and diagnostics sheet.
- Added multi-select bulk actions.

## Downloads Pause Fix

The pause bug was that the UI could mark a row paused while the underlying work kept emitting progress and state changes.

The fix spans:

- `PMVDL/PMVDL/DownloadQueue.swift`
- `PMVDL/PMVDL/Downloads/DownloadJobs.swift`
- `PMVDL/PMVDL/Downloads/DirectDownloader.swift`

Key behavior:

- `DownloadQueue.pause(_:)` now calls `DownloadJobRunner.shared.pause(queueId:)`.
- `DownloadQueue.remove(_:)` and `remove(id:)` cancel non-terminal jobs.
- `DownloadJobRunner` tracks running tasks, paused queue IDs, cancelled queue IDs, and per-run tokens.
- Progress events are ignored after pause/cancel.
- Resume uses saved retry payloads through `startResume`.
- Direct download delegate support can cancel the active `URLSessionTask`.

Durable lesson: queue state alone is not enough for pause semantics. The active worker must be cancelled or suppressed, and stale progress must be ignored.

## Settings Redesign

`PMVDL/PMVDL/Settings/SettingsView.swift` was moved fully away from `Form` styling.

Current structure:

- Glass jump toolbar for Cloud, Preferences, Pro, and Info.
- Capped-width centered scroll content.
- Single-card cloud destination sections for Mega, Google Drive, and Seedbox.
- Glass text fields instead of `.roundedBorder`.
- Styled notification rows.
- Download behavior and helper tool status in a unified preferences card.
- Pro card with concrete enforced benefits.
- Info card with version, extensions, update check, and About.

The Settings page owns its own spacing and no longer relies on outer `ContentView` padding.

## Menu Bar Icon Removal

`PMVDL/PMVDL/VidDLApp.swift` was changed so VidDL behaves like a normal Dock app:

- Removed `MenuBarExtra("VidDL", image: "menubarIcon")`.
- Deleted `MenuBarQuickView`.
- Changed `applicationShouldTerminateAfterLastWindowClosed(_:)` to return `true`.
- Deleted the dead `menubarIcon.imageset` asset directory.

Do not remove:

- `ClipboardManager`
- `AppStateManager.showMainWindow()`
- URL scheme handling in `AppDelegate`
- `.regular` activation policy

Those are still used outside the old menu bar UI.

## Pro Monetization - Phase 1

Phase 1 fixed the hollow Pro tier by wiring existing gates into actual behavior.

Changed files:

- `PMVDL/PMVDL/ProFeatureGate.swift`
- `PMVDL/PMVDL/LicenseManager.swift`
- `PMVDL/PMVDL/HomeView.swift`
- `PMVDL/PMVDL/CloudHub.swift`
- `PMVDL/PMVDL/DownloadQueue.swift`
- `PMVDL/PMVDL/UpgradeOverlay.swift`
- `PMVDL/PMVDL/Settings/SettingsView.swift`
- `PMVDL/PMVDL/IntentHandler.swift`

Current gates:

- Free download limit is now 3.
- Batch downloads above 5 items require Pro.
- Free concurrency is 2 downloads; Pro concurrency is 5.
- Multi-cloud simultaneous upload requires Pro.
- Upgrade copy now lists concrete enforced benefits.

Validation:

```sh
xcodebuild -quiet \
  -project PMVDL/PMVDL.xcodeproj \
  -scheme PMVDL \
  -configuration Debug \
  -derivedDataPath /tmp/viddl-pro-phase1 \
  build

xcodebuild -quiet \
  -project PMVDL/PMVDL.xcodeproj \
  -scheme PMVDL \
  -configuration Debug \
  -derivedDataPath /tmp/viddl-pro-phase1-test \
  test
```

Fresh app launched:

```sh
open -n /tmp/viddl-pro-phase1/Build/Products/Debug/VidDL.app
```

## Pro Monetization - Phase 2

Phase 2 gated already-existing advanced features and exposed the missing UI entry points.

Changed files:

- `PMVDL/PMVDL/ProFeatureGate.swift`
- `PMVDL/PMVDL/LicenseManager.swift`
- `PMVDL/PMVDL/DownloadManager.swift`
- `PMVDL/PMVDL/Downloads/YtDlpRunner.swift`
- `PMVDL/PMVDL/Downloads/DownloadJobs.swift`
- `PMVDL/PMVDL/HomeView.swift`
- `PMVDL/PMVDL/DownloadQueueView.swift`
- `PMVDL/PMVDL/LibraryView.swift`
- `PMVDL/PMVDL/Settings/SettingsView.swift`
- `PMVDL/PMVDL/CloudHub.swift`
- `PMVDL/PMVDL/VideoProcessor.swift`
- `PMVDL/PMVDL/UpgradeOverlay.swift`
- `PMVDL/PMVDL/ContentView.swift`

Current Phase 2 behavior:

- Audio-only downloads require Pro.
- Subtitle downloading requires Pro.
- Settings subtitle toggle opens the upgrade overlay for free users.
- Lower-level yt-dlp paths also refuse subtitle/audio behavior without Pro.
- Smart Upload Rules are visible in Settings and locked for free users.
- `CloudHub.resolveTargets` only applies upload rules for Pro users; free users use the default Mega route.
- Library context menus expose Pro Processing actions.
- Completed Downloads rows expose Pro Processing actions.
- Video processing uses the existing `VideoProcessor` backend through `VideoProcessingPreset` and `VideoProcessingLauncher`.

Processing presets currently exposed:

- Convert to MP4.
- Downscale to 720p.
- Optimize H.265.
- Extract Thumbnail.

Important boundary:

`VideoProcessor.swift` remains shared infrastructure. It must not be deleted even though the old Processing tab was removed.

Validation:

```sh
xcodebuild -quiet \
  -project PMVDL/PMVDL.xcodeproj \
  -scheme PMVDL \
  -configuration Debug \
  -derivedDataPath /tmp/viddl-pro-phase2 \
  build

xcodebuild -quiet \
  -project PMVDL/PMVDL.xcodeproj \
  -scheme PMVDL \
  -configuration Debug \
  -derivedDataPath /tmp/viddl-pro-phase2-test \
  test
```

Fresh app launched:

```sh
open -n /tmp/viddl-pro-phase2/Build/Products/Debug/VidDL.app
```

Latest launch observed:

```text
/private/tmp/viddl-pro-phase2/Build/Products/Debug/VidDL.app/Contents/MacOS/VidDL
```

## Feed Tab And Source Scrapers

The Feed tab was added as a new sidebar destination between History and Library.

New files:

- `PMVDL/PMVDL/Feed/FeedItem.swift`
- `PMVDL/PMVDL/Feed/FeedScraper.swift`
- `PMVDL/PMVDL/Feed/FeedViewModel.swift`
- `PMVDL/PMVDL/Feed/FeedCardView.swift`
- `PMVDL/PMVDL/Feed/FeedView.swift`

Navigation wiring:

- `NavDestination.feed`
- `ContentView` detail branch for `FeedView`
- `Theme.destinationColor(_:)` feed color
- Navigate menu shortcut for Feed
- Xcode project source references for the new Feed files

### allpornstream.com

`AllPornStreamFeedScraper` uses the listing page JSON-LD `ItemList` for core metadata:

- title
- post URL
- upload date
- view count
- post id
- studio from bracketed title prefix

Important thumbnail finding:

- JSON-LD `thumbnailUrl` is usually a placeholder.
- Direct CDN image URLs can return HTTP 403 when loaded directly.
- Real thumbnails are in rendered card attributes such as `data-href`, `data-slug`, and `data-images`.
- The working fix is to extract the card image URL and return the allpornstream `/api/images` proxy URL.

Do not go back to searching for thumbnails around the JSON-LD occurrence of each post URL. That occurrence is separate from the rendered card markup and can miss the real image metadata.

### rentry.co/OnlyFan420

`RentryFeedScraper` was added as the second Feed source.

Behavior:

- Fetches `https://rentry.co/OnlyFan420`.
- Parses yellow date-section headers such as `06 May 2026`.
- Parses static table links inside each date section.
- Keeps only supported provider hosts:
  - `luluvid.com`
  - `luluvdo.com`
  - `lulustream.com`
  - `vidara.so`
  - `playmogo.com`
  - `doodstream.com`
  - `dood.wf`
- Filters ad links such as `clenchinfer.com`.
- Uses direct embedded thumbnail URLs, commonly `i.postimg.cc`.
- Sets `viewCount` to `0` because rentry does not provide view counts.
- Sets each item date to noon for the parsed date section because no per-item time is available.
- Parses simple studio prefixes like `Brazzers - Title` where present.

No extractor changes were needed. Feed extraction sends the provider URL directly into the existing Home extraction pipeline through:

- `AppStateManager.shared.pendingExtractURL`
- `AppStateManager.shared.pendingExtractShouldStart`
- `AppStateManager.shared.select(.home)`

UI details:

- The Feed site picker now includes both `allpornstream.com` and `rentry.co/OnlyFan420`.
- Changing the selected site refreshes the feed.
- Rentry is a single-page source, so pagination is disabled after page 1.
- Feed cards hide `0 views` for sources without view count metadata.

Validation:

```sh
xcodebuild -quiet \
  -project PMVDL/PMVDL.xcodeproj \
  -scheme PMVDL \
  -configuration Debug \
  -derivedDataPath /tmp/viddl-feed-rentry \
  build
```

Fresh app launched:

```sh
open -n /tmp/viddl-feed-rentry/Build/Products/Debug/VidDL.app
```

Latest launch observed:

```text
PID 23377
```

## Known Validation Noise

Builds and tests pass, but Xcode continues to emit existing warnings/noise:

- Sparkle signed binary stripping warnings.
- CoreMedia/AVFCore dyld symbol warnings.
- AccentColor asset catalog warning.
- Existing Swift warnings in older extractor/test code.

These were present before the Pro Phase 2 work and were not addressed in this pass.

## Durable Lessons

- Always launch VidDL from the freshly built derived-data app path when validating UI or lifecycle changes.
- Removing a UI tab does not imply similarly named infrastructure is dead.
- Pro gates should exist both at the UI affordance and at the lower-level execution boundary.
- Free-tier UI should not advertise features that are not actually enforced.
- Smart routing is already present through `CloudHub` and `UploadRule`; the UI only needed a thin Settings editor.
- macOS menu bar removal must also change last-window-close behavior, otherwise the app can keep running invisibly.
- For active downloads, pause must reach the job runner and transport layer; setting row state alone is insufficient.
