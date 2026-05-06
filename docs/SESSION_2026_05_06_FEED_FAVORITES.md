# Session Summary - 2026-05-06 Feed, Resume, and Favorites

## Scope

This session continued the VidDL Feed work after the initial Feed tab and `rentry.co/OnlyFan420` source were added.

The main outcomes were:

- Added `hqporner.com` as a Feed source.
- Expanded Feed metadata, filters, sorting, and layout.
- Added interrupted download auto-resume and no-overwrite resume behavior.
- Refined the Feed UI into a compact header, slimmer toolbar, active filter chips, responsive grid, and calmer cards.
- Added persistent Feed Favorites with a conditional Favorites sidebar tab.

## Feed Sources

### allpornstream.com

`AllPornStreamFeedScraper` remains the JSON-LD-backed source.

Durable thumbnail lesson:

- Listing JSON-LD thumbnail data is usually a placeholder.
- Real thumbnails are in the rendered card attributes.
- Direct CDN URLs can return 403.
- The reliable app path is to use the site `/api/images` proxy URL extracted from the card metadata.

### rentry.co/OnlyFan420

`RentryFeedScraper` parses the static table from `https://rentry.co/OnlyFan420`.

Behavior:

- Date headers are parsed from yellow section headings like `06 May 2026`.
- Supported provider links are kept; ad links are filtered out.
- Direct `i.postimg.cc` thumbnails are used.
- View count is `0` because the source does not provide views.
- Per-item time is unavailable, so items are dated at noon for their section.
- Pagination is disabled after page 1.

### hqporner.com

`HQPornerFeedScraper` was added behind the existing `FeedScraper` protocol.

Behavior:

- Page 1 fetches `https://hqporner.com/`.
- Later pages use `/hdporn/<page>`.
- Parser reads listing cards with post URL, stable id, title, thumbnail, duration, and quality labels.
- Default quality label is `HD` when visible richer labels are absent.
- URLs and protocol-relative thumbnails are normalized.

Tests:

- `PMVDL/PMVDLTests/HQPornerFeedScraperTests.swift`

## Feed Filtering and Presentation

`FeedItem` now carries richer optional metadata:

- `durationSeconds`
- `categories`
- `tags`
- `performers`
- `qualityLabels`
- `sourceKind`

`FeedFilterState` supports combined filters:

- date
- search query
- site
- studio
- category
- tag
- quality
- min views
- min/max duration
- any/all tag matching

`FeedSortMode` supports:

- newest
- oldest
- most viewed
- shortest
- longest
- title A-Z
- site then newest

UI changes:

- Feed now has a compact in-content header with source context, count, and refresh.
- Basic toolbar only handles site, search, date, sort, filters, and clear.
- Active filters render as removable chips.
- Advanced filters are grouped into Metrics, Source metadata, and Discovery.
- Loading uses a skeleton grid.
- Error state becomes a compact banner when stale items are still visible.
- Feed grid uses `FeedGridLayout` breakpoints for calmer responsive columns.
- Feed cards use lighter chrome, duration overlay, subtler studio badges, and hover Extract affordance.
- Cmd-R refresh and Cmd-F search focus were added.

Tests:

- `PMVDL/PMVDLTests/FeedFilterTests.swift`

## Auto-Resume and No-Overwrite Resume

Interrupted work is now handled distinctly from user-paused work.

`DownloadQueue` now:

- Converts interrupted in-progress items with retry payloads back to pending/resumable on launch.
- Marks interrupted items without retry payloads as failed with a clear message.
- Preserves user-paused, completed, and failed items.
- Calls `resumeInterruptedOnLaunch(seedboxWebdavPassword:)` from app bootstrap.

Direct downloads:

- Persist partial path and byte metadata.
- Use HTTP Range when resuming partial local files.
- Append only when the server returns partial content.
- If a server ignores Range and returns a full response, resume to a safe new filename instead of deleting or overwriting an existing partial.

Seedbox transfers:

- `SeedboxManager` can stat remote files.
- Interrupted seedbox transfers do not fake append.
- If a remote partial exists or append capability is not proven, resume uses a safe new filename instead of overwriting.

Tests:

- `PMVDL/PMVDLTests/DownloadQueueResumeTests.swift`

## Feed Favorites

Favorites are intentionally separate from `VideoLibrary`.

Reason:

- `VideoLibrary` represents extracted/downloaded items.
- Feed favorites are saved before extraction and may not have media URLs yet.

New app files:

- `PMVDL/PMVDL/Favorites/FeedFavoriteItem.swift`
- `PMVDL/PMVDL/Favorites/FeedFavoritesStore.swift`
- `PMVDL/PMVDL/Favorites/FavoritesDisplay.swift`
- `PMVDL/PMVDL/Favorites/FavoritesView.swift`
- `PMVDL/PMVDL/Favorites/FavoriteCardView.swift`

Behavior:

- Feed cards show a top-left heart button.
- Favorite identity is the normalized URL, currently whitespace-trimmed only.
- Favorites persist in `UserDefaults` key `feedFavorites`.
- Duplicate favorites are deduped by URL, keeping the newest `favoritedAt`.
- The Favorites sidebar tab is hidden until at least one favorite exists.
- Favorites has a sidebar badge with the saved count.
- If the last favorite is removed while viewing Favorites, the app routes back to Feed.
- Favorites is conditionally shown in the Navigate menu.
- Favorites page supports search, sort, extract, copy link, open source, and remove.
- `FeedFavoritesStore.shared.save()` is called on app termination.

Important interaction detail:

- `FeedCardView` no longer relies on an outer card `.onTapGesture` for extraction.
- The main card content is a plain extract `Button`.
- The heart button is a separate overlay, preventing heart clicks from also triggering extraction.

Tests:

- `PMVDL/PMVDLTests/FeedFavoritesTests.swift`

## Validation

Commands run successfully during this work:

```sh
xcodebuild -quiet \
  -project PMVDL/PMVDL.xcodeproj \
  -scheme PMVDL \
  -configuration Debug \
  -derivedDataPath /tmp/viddl-favorites-baseline-derived \
  test

xcodebuild -quiet \
  -project PMVDL/PMVDL.xcodeproj \
  -scheme PMVDL \
  -configuration Debug \
  -derivedDataPath /tmp/viddl-feed-favorites-tests \
  -only-testing:VidDLTests/FeedFavoritesTests \
  test

git diff --check

xcodebuild -quiet \
  -project PMVDL/PMVDL.xcodeproj \
  -scheme PMVDL \
  -configuration Debug \
  -derivedDataPath /tmp/viddl-favorites-final-derived \
  test

xcodebuild -quiet \
  -project PMVDL/PMVDL.xcodeproj \
  -scheme PMVDL \
  -configuration Debug \
  -derivedDataPath /tmp/viddl-favorites-visual-derived \
  build
```

Fresh app launched:

```sh
open -n /tmp/viddl-favorites-visual-derived/Build/Products/Debug/VidDL.app
```

Latest observed PID:

```text
50229
```

## Durable Lessons

- Feed discovery, Favorites, and Library are distinct product concepts and should remain separate stores.
- For Feed favorites, URL is the stable identity; scraper-specific ids are not durable enough.
- Conditional navigation should filter UI destinations, not remove enum cases.
- Do not shift keyboard shortcuts when conditional tabs appear.
- A nested control inside a tappable card should be modeled as separate `Button`s, not a parent gesture plus child gesture.
- For seedbox resume, true append must not be assumed for generic rclone/WebDAV paths.
