# Session 2026-05-09: Feed Lazy Loading, PornHub Subscriptions, Profile Links, Download Refresh, and Home Controls

## Summary

This session shipped a connected Feed/Profile/Home/Settings update for VidDL:

- Feed pages now lazy-load across supported feed sites with viewport-triggered prefetch.
- PornHub Subscriptions now has visible in-tab uploader navigation instead of relying on a wide-window side rail.
- Profile Top Performers can link back into PornHub uploader pages when the profile evidence proves a PornHub uploader URL.
- PornHub direct downloads refresh stale signed CDN URLs at download start, fixing `Source URL returned HTTP 472`.
- Feed scrolling and PornHub hover previews were tuned to reduce scroll stutter.
- Home now has a Resume All button for paused downloads.
- Settings now has a persisted Prevent sleep while running option.

## Feed Lazy Loading and Smoother Scrolling

Feed pagination now works through the shared feed view model instead of only first-page loading:

- `FeedViewModel.loadMore()` advances the current page for each site scraper.
- `loadMoreMatchingCurrentFilters(pageBudget:)` can keep loading a few pages when current filters hide the newly fetched page.
- `prefetchMoreIfNeeded(appearedItemID:threshold:pageBudget:)` triggers pagination when visible items approach the end of the current result set.
- `FeedGridLayout.prefetchItemThreshold` scales the trigger threshold with the estimated column count.
- Source-order PornHub contexts, such as uploader videos and login-backed sections, preserve feed order instead of forcing date-sort assumptions.
- Stale login gating no longer blocks an uploader page just because the previous PornHub section required login.

Scrolling smoothness improvements:

- Feed tracks active scrolling and disables hover elevation animation during scroll.
- PornHub video previews wait briefly before activation.
- Preview work is canceled when scrolling starts, rows disappear, or hover ends.
- One shared `FeedPreviewCoordinator` keeps only one active preview URL at a time.
- Preview thumbnail prefetch is canceled when no longer useful and cached at reduced pixel sizes.
- Derived feed state is rebuilt explicitly so filters, buckets, facets, and profile-match reasons do not recompute through heavy view reads.

## PornHub Subscriptions

Feed > PornHub > Subscriptions now shows a names-only subscription picker inside the tab content when:

- the user is logged in,
- `selectedPornHubSection == .subscriptions`,
- and no specific uploader page is active.

The existing side rail remains available for wide layouts, but subscriptions are no longer hidden below wide breakpoints. Clicking a subscription calls the same uploader navigation path used elsewhere in Feed.

Subscription parsing was tightened:

- Normalizes uploader URLs to `/model/...`, `/pornstar/...`, `/channels/...`, and allowed `/user/...` pages.
- Removes trailing `/videos` and query state from uploader URLs.
- Rejects account/navigation paths such as `/user/discover`, `/user/search`, `/user/edit`, and `/user/logout`.
- Rejects generic labels like `Avatar`, `Channel Avatar`, `Model Avatar`, `Videos`, `Playlists`, `Photos`, and `GIFs`.
- Deduplicates by normalized uploader URL and keeps the strongest display name.

## Profile Performer Links

`ProfileStats.RankedEntry` now carries optional `profileURL` and `profileReferer` fields. They decode as optional, so old cached profile JSON remains compatible.

During profile enrichment, PornHub uploader evidence can persist a normalized uploader URL onto matching top performers. `ProfileView` renders a performer as clickable only when the profile URL normalizes to a PornHub model, pornstar, channel, or allowed user URL.

Clicking a backed performer:

- configures Feed for PornHub,
- clears incompatible filters and return state,
- selects a non-login-gated section,
- navigates to the uploader page,
- refreshes the feed,
- and selects the Feed tab.

Ambiguous title-only performers remain plain text.

## PornHub HTTP 472 Download Fix

The `Source URL returned HTTP 472` issue was traced to stale PornHub CDN media URLs. The direct media URLs can be signed and short-lived; a URL that was valid when extracted can later become invalid even though the original PornHub video page still works.

The fix refreshes PornHub-backed resolutions at download start:

- `DownloadResolver.needsDownloadTimeRefresh(_:)` detects PornHub-backed resolutions from the request, result URL, source page URL, site name, or quality source-page URLs.
- `DownloadResolver.refreshForDownloadIfNeeded(_:)` re-extracts from the original PornHub page and selects the refreshed quality matching the originally selected label/kind/height when possible.
- `DownloadJobRunner` performs this refresh after destination validation and before pro-feature validation and job creation.
- The retry payload used to run the job is rebuilt with the refreshed resolution.
- `YtDlpExtractor` now preserves source-level headers for its selected best URL, including Referer and User-Agent context.
- Failed refreshes return a readable `PornHub source expired; refresh the video and try again.` error.

## Home and Settings

Home queue:

- `HomeCompactQueue` shows a Resume All button when paused downloads exist.
- The button resumes all paused rows with retry payloads through `DownloadJobRunner.startResume`.
- Current seedbox WebDAV credentials are injected at resume time.
- Audio-only rows that require Pro still trigger the existing upgrade flow.

Settings:

- Download Options now includes `Prevent sleep while running`.
- The setting is persisted under `preventSleepWhileRunning`.
- `SleepPreventionManager` starts at app launch and observes `DownloadQueue` plus `UserDefaults`.
- It holds a `ProcessInfo` activity with `.idleSystemSleepDisabled` only while the setting is enabled and queue work is actively downloading, verifying, uploading, or processing.
- Pending, paused, completed, and failed rows do not keep the Mac awake.

## Validation

Focused tests and checks run during the session:

```sh
xcodebuild test \
  -project PMVDL/PMVDL.xcodeproj \
  -scheme PMVDL \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/viddl-pornhub-refresh-derived \
  -only-testing:VidDLTests/DownloadResolutionTests
```

Result: 8 tests passed, 0 failed.

```sh
xcodebuild test \
  -project PMVDL/PMVDL.xcodeproj \
  -scheme PMVDL \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/viddl-home-sleep-derived \
  -only-testing:VidDLTests/DownloadQueueProjectionTests
```

Result: 10 tests passed, 0 failed.

Additional checks:

- `git diff --check` passed.
- Debug builds succeeded with `xcodebuild build`.
- Fresh debug bundles were launched with `open -n` from derived data so existing VidDL processes were not killed.

## Follow-Up Notes

- Manual QA should verify Feed > PornHub > Subscriptions in both narrow and wide windows.
- Manual QA should click a Profile Top Performer backed by PornHub evidence and confirm Feed opens the correct uploader page.
- Manual QA should verify PornHub downloads from an older extracted URL now refresh before download and no longer fail with HTTP 472.
- Manual QA should pause several queue rows, use Home Resume All, and confirm only resumable rows restart.
- Manual QA should enable Prevent sleep while running and confirm macOS stays awake only while active jobs are running.
