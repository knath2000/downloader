# Session Summary - 2026-05-07 Feed, Home Queue, HQPorner, and Theming

## Scope

This session continued the VidDL Home, Feed, download queue, and HQPorner work. The main outcomes were:

- Moved extraction loading into the results sheet.
- Merged the Downloads queue into Home and removed the standalone Downloads navigation route.
- Added compact queue thumbnails and queue-row context actions.
- Fixed completed-download thumbnail fallback behavior.
- Stabilized download runner state with MainActor isolation.
- Preserved Feed state across tab switches.
- Added Feed hover preview scrub for HQPorner.
- Added a native HQPorner extractor.
- Preserved feed thumbnails through extraction into Library/download metadata.
- Added Feed batch selection and batch extract.
- Made Feed filtering/sorting site-capability aware.
- Resolved HQPorner dates lazily from detail pages.
- Added site-specific Feed page theming.

## Home and Downloads

The Home extraction flow now opens the results sheet immediately when extraction starts. The progress bar and shimmer loading cards render inside the modal while the Home page keeps its normal content visible. The existing extract button spinner remains as a secondary loading indicator.

Downloads were moved into Home with `HomeCompactQueue`:

- The queue appears between the URL input card and supported sources only when queue items exist.
- It shows active, queued, failed, and completed-summary rows.
- It delegates to `DownloadQueue.shared` for pause, resume, retry, remove, and clear-completed behavior.
- Failed rows expose retry instead of pause/resume.
- Completed rows can show local thumbnails and secondary actions through context menus.

The standalone Downloads nav destination and menu entry were removed. Any Library entry point that previously navigated to Downloads now routes to Home.

## Thumbnail Lessons

Completed Home queue thumbnails had several separate failure modes:

- Local thumbnail generation needed an async path that stores through `ThumbnailCache.shared.store(...)` so memory and disk cache are both populated.
- The async local generation path must use modern AVFoundation APIs: `await asset.load(.duration)` and `await generator.image(at:)`.
- The Home queue thumbnail waterfall must always try the feed `thumbnailURL`/`og:image` first, then broad cached frame identities, then local file frame generation, then remote stream frame generation.

This avoids black fallback rectangles and prevents an early cached first-frame image from permanently masking a better feed thumbnail.

## Download Runner Stability

`DownloadJobRunner` was made MainActor-isolated because it owns mutable task/token/pause/cancel state that is touched from UI actions, progress updates, and background tasks. Keeping all property access on the main actor prevents races in `runningTasks`, `runningTokens`, `pausedQueueIDs`, and `cancelledQueueIDs`.

## Feed State and Extraction

`FeedViewModel` is now a shared singleton and `ContentView` no longer forces detail-view teardown with `.id(appState.selectedDestination)`. This keeps loaded Feed data alive across tab switches.

Feed extraction now carries `pendingExtractThumbnailURL` through `AppStateManager`. When a feed card starts extraction, Home uses the feed thumbnail as a fallback if the extractor does not find a detail-page thumbnail. This is important for HQPorner pages that provide useful listing thumbnails but no `og:image`.

Batch selection was added to Feed:

- Right-click a card to select/deselect or select all visible.
- Selected cards show top-right badges.
- A bottom selection bar exposes clear and extract-selected actions.
- Batch extract sends newline-joined URLs through Home's existing multi-URL extraction path.

## Feed Hover Preview Scrub

AllPornStream preview scrub uses the site's multiple preview image URLs.

HQPorner preview scrub uses the listing-card `changeImage("URL", "ID")` URLs. These are extracted from each card segment and passed as `FeedItem.previewURLs`.

Rentry intentionally has no hover scrub because each item only exposes one image in the source HTML.

The card hover overlay was adjusted so the full dark Extract overlay does not cover scrub previews while the user is actively scrubbing.

## HQPorner Extraction and Dates

`HQPornerExtractor` was added and registered before generic fallback extractors. The extraction path:

- Fetches the HQPorner outer page.
- Extracts the nested `mydaddy.cc` iframe.
- Fetches the iframe with HQPorner referer context.
- Parses direct MP4 qualities and keeps referer/user-agent headers attached.

HQPorner feed dates are resolved lazily after initial feed load. Items start with approximate dates, then background tasks fetch detail pages and parse relative date text such as `today`, `yesterday`, `one week ago`, and `N days/weeks/months/years ago`.

Important parser detail:

```html
<li class="icon fa-calendar">today</li>
```

The regex must match `fa-calendar` in the `<li>` attributes and capture the text content. Matching `fa-calendar` inside the element body is wrong.

## Feed Filtering and Theming

Feed filters and sort modes now reflect source capabilities:

- AllPornStream: dates, views, studios.
- Rentry: dates, studios.
- HQPorner: dates, duration, quality labels.

Inert filters and sort modes are hidden or reset when switching sites.

The Feed page now has site-specific chrome through `FeedSiteTheme`:

- AllPornStream: teal cyan `#00BCD4`, dark blue-black background tint, `AllPornSTREAM` branding.
- Rentry / OnlyFan420: lime green `#7CB342`, dark olive background tint, `OnlyFan420` branding.
- HQPorner: hot pink `#FF6070`, dark charcoal-red tint, `HQPORNER` branding.

The theme affects page chrome only: header, toolbar, filter chips, day headers, load-more, selection, loading, empty, retry, and background tint. `FeedCardView` keeps existing per-studio tint logic.

## Documentation

The project now includes a user-facing `README.md` setup guide covering:

- macOS 14.0 minimum.
- DMG installation and Gatekeeper allowance.
- Required Homebrew dependencies: `yt-dlp` and `ffmpeg`.
- Optional MEGA, Google Drive, and seedbox setup.
- First-launch dependency checks.
- VidDL Pro licensing.
- `pmvdl://extract?url=<encoded-url>` local automation.

## Validation

Recent focused validation included:

```sh
git diff --check
xcodebuild build -project PMVDL/PMVDL.xcodeproj -scheme PMVDL -destination 'platform=macOS' -derivedDataPath /tmp/viddl-feed-site-theme-derived
```

The latest manual-test build was launched from:

```sh
/tmp/viddl-feed-site-theme-derived/Build/Products/Debug/VidDL.app
```

Latest observed launched PID for that build:

```text
5144
```

## Reusable Lessons

- Launch fresh debug builds from derived data when testing current source changes.
- Keep `FeedCardView` card tints separate from Feed page chrome theming.
- Prefer source-provided thumbnails over generated first-frame thumbnails when feed data has better art.
- Treat build success and git cleanliness as separate checks in this repo.
- Stage specific paths when committing because this repo often has a broad dirty tree.
