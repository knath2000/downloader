# Local/Mega Destination Removal and Maintainability Refactor

Date: 2026-08-23

## Objective

Remove Seedbox, Google Drive, and every rclone-backed destination from the app. Keep Local and Mega as the only supported destinations, while safely loading older persisted queues and historical library records.

## Achieved

- Removed the Seedbox, Google Drive, WebDAV, remote-file, and rclone service implementations.
- Removed the corresponding download jobs, settings screens, dependency stores, folder pickers, remote-file UI, and Xcode project references.
- Removed Google Drive and Seedbox controls from Home, Library, Watchlist, Feed, Settings, intents, Agent integration, and cloud-sync preference handling.
- Restricted new-job destination enumeration to Local and Mega.
- Kept legacy `CloudTarget` cases and persisted context fields decodable for backward compatibility; they are not offered for new work.
- Added queue migration: persisted unsupported destination items become failed terminal items with retry and automatic-retry state cleared, while preserving their metadata for history.
- Prevented legacy Agent jobs with `gdrive:` destinations from being projected back into the active queue.
- Cleared obsolete destination preferences and the legacy Seedbox password from secure storage at startup.
- Removed obsolete rclone/WebDAV/GDrive/Seedbox tests and updated destination-policy/migration coverage.
- Simplified destination-dependent UI and documentation to Local/Mega terminology.
- Added `PRODUCT_MODULE_NAME = VidDL` to the test configuration so existing `@testable import VidDL` declarations match the visible LustreStudio product identity.

## Validation

- Production Debug build passed with Xcode at `/Volumes/WD/Applications/Xcode.app/Contents/Developer` and unsigned Debug output.
- `git diff --check` passed.
- Project references were checked to ensure removed service and remote-file symbols are no longer present.
- Full test-target compilation is still blocked by unrelated pre-existing test drift:
  - `LibraryThumbnailResolverTests` needs current `favoriteItems` initializer arguments.
  - `ProfileNarrativeFormatterTests` references formatter types unavailable in the current target.
- Remaining compiler warnings are existing deprecations/unused values outside this migration.

## Deliberate compatibility behavior

Historical library entries may still display old destination labels because those records are retained as history. Legacy enum cases and decoding fields remain intentionally, but operational paths reject or terminally migrate those destinations.

## Remaining work

1. Repair or remove the unrelated stale tests so the complete test target compiles and executes.
2. Remove now-unused Seedbox password parameters and legacy destination fields from active download-runner plumbing after confirming no older queue decoder or migration path depends on their public shape.
3. Decide whether historical destination labels should remain visible or be normalized to “Removed destination” in Library/History views.
4. Address the existing compiler warnings incrementally, especially deprecated WebKit JavaScript APIs and unused values.
5. Run the complete test suite and package a fresh unsigned DMG after the test-target cleanup.

## Scope notes

No commit or push was performed. The worktree intentionally contains the implementation changes for review.
