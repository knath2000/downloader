# Session 2026-05-08: Profile Images, Feed Download Badges, Home Queue Counts, and Files UX

## Summary

This session finished the AI Profile image/evidence follow-up, added downloaded-state awareness to Feed cards, made Home queue counts clearer, and upgraded the Files tab into a more Finder-like remote file browser.

The main outcomes were:

- Profile Top Performers can now show compact performer avatars from profile/headshot images with evidence thumbnail fallback.
- Feed cards can identify videos that are already in the Library and offer Open in Library from the context menu.
- Home now reports remaining, active, queued, and paused download counts instead of only showing visible queue rows.
- Files now supports multi-select, keyboard range/toggle selection, drag-to-folder moves, duplicate/move/info actions, right-click menus, double-click folder open, and a stable cleaned-up toolbar.

## Profile Images and Evidence

Profile generation now carries richer evidence into the model and UI:

- `ProfileEvidenceItem` includes thumbnail URL and referer fields.
- `ProfileStats.RankedEntry` includes optional image URL, referer, and source fields.
- Performer image resolution tries a performer/profile page `og:image` or `twitter:image` first, then falls back to the strongest matching evidence thumbnail.
- Evidence matching uses uploader names, scraper performers, and title-name signals.
- Repeated Library uploader signals are promoted when Grok classifies a high-count uploader as ignored but the evidence strongly indicates a recurring performer-like signal.
- Source-site names such as PornHub are filtered out of performer/studio rankings.

Important finding:

- Existing generated profiles do not automatically gain performer images because the persisted `ProfileResult` was created before the new image fields existed. Regenerating the profile runs the new resolver and stores the image fields.

## Feed Downloaded State

Feed now builds a lightweight downloaded index from `VideoLibrary.shared.items`:

- PornHub Feed items match Library rows by canonical `viewkey`.
- Non-PornHub Feed items match by normalized URL.
- Matched cards show a compact Downloaded badge on the thumbnail.
- The Feed card context menu includes Open in Library for matched items.
- Extract and Download remain enabled; downloaded state is informational.

## Home Queue Counts

`HomeCompactQueue` now summarizes real queue status:

- Remaining means non-terminal visible work: pending, downloading, verifying, uploading, processing, and paused.
- Active includes downloading, verifying, uploading, and processing.
- Queued is pending.
- Paused is shown only when nonzero.
- Completed and failed rows no longer inflate the remaining count.

The queue runner and queue progress path were also hardened so queued work can start through `DownloadJobRunner.shared.processNextIfNeeded()` and progress updates publish without excessive persistence churn.

## Files Browser

The Files tab was expanded from simple listing into a practical remote file browser:

- Single click selects a row.
- Command-click toggles selection.
- Shift-click selects ranges anchored like Finder.
- Command-clicking a selected item unselects it through Finder-style toggle behavior.
- Double-click opens folders.
- Files do not open on click; file open/download stays in the right-click context menu.
- Selected rows are indicated by row highlight only, with no checkbox/checkmark control.
- Dragging selected remote items onto a folder moves them; Option-drag copies.
- Dragging local files into the list uploads them to the current folder.
- Multi-item actions include duplicate, move, delete, info, and download/open.
- rclone and WebDAV clients support copy/move behavior for the new actions.
- The row ellipsis buttons and top Actions ellipsis were removed; actions now live in right-click context menus.
- Right-clicking a selected item targets the current selection; right-clicking an unselected item targets only that item.
- The top toolbar is now a fixed two-row layout so selecting files does not push the file list down.

## Validation

Focused validation run during the session:

```sh
xcodebuild test \
  -project PMVDL/PMVDL.xcodeproj \
  -scheme PMVDL \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/viddl-files-derived \
  -only-testing:VidDLTests/RemotePathTests \
  -only-testing:VidDLTests/RcloneRemoteFileParserTests \
  -only-testing:VidDLTests/WebDAVRemoteFileParserTests
```

Result: 17 tests passed, 0 failed.

Additional checks:

- `git diff --check` passed.
- Fresh debug builds were launched with `open -n /tmp/viddl-files-derived/Build/Products/Debug/VidDL.app` so the existing running VidDL process was not replaced.

## Follow-Up Notes

- Manual UI verification should focus on Files right-click semantics for selected versus unselected rows, drag-to-folder moves, and toolbar stability during selection.
- Profile avatars require regenerating the profile once after this build.
- The Feed downloaded badge intentionally remains informational and does not disable extraction.
