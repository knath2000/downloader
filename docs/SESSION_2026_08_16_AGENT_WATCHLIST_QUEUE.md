# LustreStudio Agent, Watchlist, and Queue Reliability

Date: 2026-08-16

## Accepted behavior

- New Local and Google Drive downloads are owned by the persistent per-user Lustre Agent and continue after LustreStudio quits.
- LustreStudio projects every job returned by Agent `/v1/jobs`, including jobs created by LustreCLI or its web application.
- `ScraperEngine` and browser-assisted extraction remain available for providers that require foreground verification.
- Agent polling, health checks, entitlement synchronization, and job fetching run off the main actor to avoid cursor-driven UI stalls.
- The active-download modal and compact queue retain FIFO creation order instead of sorting by changing progress.
- Agent job removal is durable and idempotent. LustreStudio suppresses duplicate delete requests, treats an already-missing row as removed, and the Agent returns HTTP 404 for a missing job.
- Retrying a locally projected Agent job that no longer exists recreates the same job ID from its stored source URL, title, quality label, and Local or Google Drive destination.
- Failed Agent jobs are retained until the user explicitly removes them.

## Watchlist and Feed

- Watchlist is a local Application Support-backed feature, starts empty, and does not import or alter Favorites.
- It supports watched state, search/filter/sort/grouping, multi-select, ordered three-at-a-time extraction, and Agent-backed batch downloads.
- Watchlist controls use the compact Library-style button treatment.
- Feed-to-Watchlist saves the source title rather than the preview-image label.
- Feed cards provide an in-place context-menu extraction action that resolves links through the Agent without leaving Feed.

## Destination policy

- Local and Google Drive are the only destinations available for new work.
- Mega, Seedbox, WebDAV, and SFTP entry points are hidden through the centralized availability policy.
- Legacy implementations, credentials, settings, history, Library metadata, and existing queue records remain preserved.

## Relevant commits

LustreStudio:

- `f2216d9` — Agent-owned downloads, Watchlist, and destination simplification.
- `01f891b` — project existing Agent jobs in LustreStudio.
- `a6af7bc` — Watchlist styling/title fixes and transfer reliability.
- `d00e210` — move Agent polling off the main thread.
- `d58ffaf` — show Agent extraction links in Feed.
- `76efbc0`, `e609d21`, `bd3be31` — durable and idempotent Agent removal compatibility.
- `d3aa823` — stable active queue order.
- `004a9f2` — restore missing Agent jobs during retry.

Lustre Agent:

- `3b81129` — durable LustreStudio transfer contract.
- `86f2b1f` — durable job removal.
- `4657f47` — missing job removal returns HTTP 404.

## Validation and release

- Focused Agent `JobStoreTests`: 6 passed.
- LustreStudio unsigned Debug builds succeeded after the removal and retry fixes.
- Agent release runtime linked successfully and was embedded from pinned revision `4657f47fe81d05e68ec56f4a2e51e2f74fb393f7`.
- Latest verified installer: `LustreStudio-2.2.7-build10-004a9f2-unsigned.dmg`.
- SHA-256: `7562ee59c6f6d8e2db7d7a882aa0b4bc02b2938ba06d282d6962f2ae4a4188e4`.
- The installer is unsigned and unnotarized for personal manual testing.
- No remote push was performed for these latest commits.

## 2026-08-17 — Titles, extraction actions, ETAs, and authoritative queue priority

### Accepted behavior

- Pro accounts run at most three concurrent active downloads.
- Extraction cards show the known video title immediately while extraction is running. Failed extraction and download rows retain that title instead of degrading to a provider hostname such as `playmogo.com`.
- Feed-originated queueing treats the visible Feed card title as authoritative when the provider page supplies no useful title. OnlyFan420-style link text is captured as an additional fallback.
- Watchlist cards again expose an explicit **Extract Links** action for each video.
- The Home active-download summary shows a total ETA when every active transfer has sufficient metrics. Because downloads run concurrently, total ETA is the longest remaining active duration, not the sum.
- The active-download modal shows an individual ETA for each measurable task.
- The queued-download modal sorts eligible jobs by persisted queue priority, displays `#1`, `#2`, and subsequent positions, and provides per-row controls to increase or decrease priority.
- Queue order is authoritative end to end. LustreStudio updates the Agent through `/v1/jobs/order`; the Agent persists `queuePriority` in each durable job and fills available download slots by priority, then creation time and UUID as deterministic tie-breakers.
- New Agent jobs receive the next priority. Retry and resume retain the existing job priority. Paused, failed, cancelled, completed, and verification-required jobs do not consume a queued priority position.
- **Start Now** remains an explicit exceptional action that bypasses normal scheduling.

### Relevant commits

LustreStudio:

- `f542828` — cap concurrent downloads at three.
- `001a286` — preserve titles, restore Watchlist extraction, prefer Feed titles, and show total/individual ETAs.
- `e3b583f` — display, edit, persist, and synchronize queue priority.

Lustre Agent:

- `cfed14f` — persist queue priority and schedule queued jobs by that order.

### Validation and release

- LustreStudio unsigned Debug builds succeeded with Xcode at `/Volumes/WD/Applications/Xcode.app`.
- The Agent Debug and release builds succeeded. The local Swift test command could not load `XCTest` from the selected toolchain, so no test-pass claim is made for that invocation.
- The pinned Agent revision is `cfed14f7eb704b95536cc87f593ef0828513dae1`.
- Verified installer: `LustreStudio-2.2.7-build10-unsigned.dmg`.
- SHA-256: `ae80b342b053f889a39318ec672ef894868b673f8c7bd435d201545617d4b9e9`.
- `hdiutil verify` reported a valid image. The bundled app is an unsigned, unnotarized x86_64 build for personal local installation.
- No remote push was performed.
