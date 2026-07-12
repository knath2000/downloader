# Session 2026-07-12: Modular Refactor and WebDAV Folder Picker

## Refactor boundaries

- Feed scraping now has a compact shared protocol/model file plus one provider file each for AllPornStream, PornHub, Rentry, HQPorner, and Eporner.
- Download jobs now isolate local, Mega, Google Drive, and Seedbox implementations from the shared queue/job runner.
- Home compact queue presentation keeps coordination in `HomeCompactQueue.swift`; completed and active row surfaces live in `HomeCompactQueueRows.swift`.
- Settings keeps modal state and settings actions in `SettingsView.swift`; reusable cards, controls, tiles, and setup surfaces live in `SettingsComponents.swift`.
- Library timeline models, filtering, formatting, pipeline display, download-context helpers, and thumbnail storage now live in `LibraryTimeline.swift`, leaving `LibraryView.swift` focused on the main presentation and interaction shell.

## WebDAV folder picker

- After a successful WebDAV connection test, Settings exposes a Browse folders action.
- `WebDAVFolderPickerView` reuses the existing WebDAV remote-file client and presents a Finder-style folder browser with path display, parent navigation, refresh, and a Use This Folder confirmation.
- The selected remote directory writes back to the Seedbox upload path. The picker carries the configured self-signed certificate option through to the WebDAV client.

## Validation

- `git diff --check`
- Focused Swift parsing for the extracted Feed, Download, Home, Settings, Library, and WebDAV picker files
- External-Xcode unsigned Debug build with `DEVELOPER_DIR=/Volumes/MyPassport/Applications/Xcode.app/Contents/Developer`
- Final result: `** BUILD SUCCEEDED **` at `/tmp/viddl-refactor-final/Build/Products/Debug/VidDL.app`

## Follow-up

- The refactor deliberately leaves Pro/license policy unchanged. Any additional licensing hardening should be a separate backend-plus-client release.
