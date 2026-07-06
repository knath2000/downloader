# Session 2026-07-03: Browser Feeds, AllPornStream Extraction, and Remote Server Setup

## Summary

This session continued the SwiftUI VidDL browser-first feed work and upgraded Settings cloud setup. PornHub, HQPorner, and AllPornStream now use embedded browser-first feed surfaces with VidDL overlay actions. AllPornStream right-click extraction was repaired by resolving the actual post URL before extraction. Settings gained guided rclone setup for Google Drive and a new SFTP-backed Remote Server flow with an interactive remote folder picker.

## Browser Feed Work

- `PornHubBrowserView` is now the shared browser surface for PornHub, HQPorner, and AllPornStream feed sources.
- PornHub's old bottom feed/results section was removed so the browser and VidDL overlay actions are the primary experience.
- The removed feed filter/header was replaced by site selection in the browser bar so users can still switch between browser-backed feed sources.
- The custom right-click menu is a styled borderless `NSPanel`, not the default WebKit context menu.
- Right-click positioning uses converted web view client coordinates so the menu appears next to the cursor.
- Page/current-item actions remain routed through existing VidDL extraction, favorite, copy, and downloaded-state pathways.

## AllPornStream Fixes

- The embedded browser context script no longer falls back to `https://allpornstream.com/` when right-clicking a thumbnail/card.
- Context URL resolution now prefers:
  - nearest video anchor,
  - card `data-href`,
  - descendant `/post/` link,
  - PornHub/HQPorner selectors,
  - current page only as final fallback.
- The live regression case was `Glowing Desires Mia James`, whose actual post URL is:
  `https://allpornstream.com/post/d3c68614-e741-4a28-81dc-ff0b7afb0a73/glowing-desire-mia-james-soaking-it-up-07-02-2026`.
- The AllPornStream extractor fallback parses inline `video_urls` payloads, and `miiixdrop.net` is supported as a MixDrop mirror.

## Settings and Remote Setup

- Settings > Download Options supports browsing for a custom local download location.
- Google Drive setup is guided through `RcloneRemoteSetupViewModel`, detects missing rclone/existing remotes, launches rclone OAuth, verifies the remote, and keeps manual fallback commands.
- The Settings cloud destination formerly shown as Seedbox is now presented as Remote Server, while internal `seedbox*` keys and `.seedbox` target remain for compatibility.
- Remote Server setup creates rclone SFTP remotes from host, port, username, and either SSH key or password auth.
- Password auth uses rclone `--obscure`; VidDL does not persist the password in its own settings.
- After SFTP connection, the wizard opens an in-app folder picker to choose the upload folder instead of requiring a path up front.
- The SFTP picker uses `remote:/` absolute addressing so logging in as `root` can browse the server filesystem root `/`, not only the login home directory `/root`.

## Implementation Notes

- `RemotePath.rclonePath` preserves legacy `remote:` behavior for existing file-manager/upload paths.
- `RemotePath.rcloneAbsolutePath` and `RemotePath.rcloneAbsoluteFile` format `remote:/...` paths for SFTP absolute-root browsing.
- `RcloneRemoteFileClient` has `usesAbsoluteRemotePaths` for the Settings SFTP folder picker.
- `RcloneRemoteSetupCommandBuilder.sftpVerifyArguments` verifies with `lsjson server:/ --max-depth 1`.
- The user manually builds/tests in Xcode. Shell validation was limited to `xcrun swiftc -parse ...` and `git diff --check ...`; `xcodebuild` could not run because the shell uses Command Line Tools instead of full Xcode.

## Tests Added or Updated

- Browser context resolver tests cover AllPornStream card/title URL resolution and current-page fallback.
- AllPornStream extraction tests cover inline `video_urls` and `miiixdrop.net`.
- Rclone setup tests cover Google Drive and SFTP command builders, SFTP key/password auth, root verification, success/failure states.
- Remote path tests cover legacy `remote:` formatting and new absolute `remote:/` formatting.
- Settings dependency tests cover Remote Server wording without breaking WebDAV fallback state.

## Later Feed Browser and Selection Work

- Rentry and Eporner were added to the browser-backed feed surface alongside PornHub, HQPorner, and AllPornStream.
- Rentry home resolves to `https://rentry.co/OnlyFan420`; Eporner home follows the selected Eporner section or active uploader `/videos`.
- Browser context detection now recognizes Eporner `/video-...` URLs and Rentry provider links for Lulu/LuluStream, Vidara, Playmogo, and Dood-style hosts.
- The custom browser right-click menu gained Select/Deselect while preserving Extract, Favorite, Open Library, Open Here, Copy, and Open External actions.
- Feed selection moved from per-page `selectedItemIDs` to a session-scoped `[normalizedURL: FeedItem]` store.
- Selected videos persist across site switches and section changes until Extract Selected or Clear Selection.
- Select All Visible now adds visible items to the global selection instead of replacing selections from other sites.
- Extract Selected sends all selected URLs joined by newlines and then clears the session selection.

## Google Drive Streaming Downloads

- Google Drive queue jobs no longer need a strict download-then-upload pipeline for direct MP4 jobs.
- `GDriveManager` now has streaming APIs that pipe URLSession chunks into `rclone rcat <remote>:<path>/<file>`.
- Safe HLS Google Drive jobs can pipe ffmpeg stdout into `rclone rcat`, matching the Remote Server/seedbox streaming approach.
- Direct MP4 Google Drive jobs report `Transferring to Google Drive...` instead of a separate download/upload split.
- HLS from known fragile providers such as Lulu/Vidara still materializes locally first, preserving the existing safer fallback.
- yt-dlp, audio, and Library uploads of already-local files still use local-file upload paths because those workflows naturally produce local files.
- Streaming jobs cannot run `VideoProcessor.verifyForUpload` before upload because no completed local MP4 exists; validation relies on source HTTP checks, progress, rclone exit status, and final remote path recording.

## Playmogo and Vidara Extraction Fixes

- `VidaraExtractor` now accepts `/d/<filecode>` in addition to `/v/<filecode>` and `/e/<filecode>`.
- `ProviderLinkExtractor` treats `vidara.so` and subdomains as resolvable provider URLs.
- `DownloadResolver` recognizes Vidara as a provider host, so unresolved Vidara page qualities retry through `ScraperEngine.extract` instead of drifting into yt-dlp fallback.
- `DoodStreamExtractor` keeps Playmogo header-protected by exposing the CDN URL only through `VideoSource.Quality`, not `mp4`.
- Playmogo pass/token parsing is more tolerant of `.get`, `$.ajax({ url: ... })`, `fetch`, minified whitespace, renamed random-string variables, and escaped `cloudatacdn.com` URLs.
- Playmogo `/d/<id>` links normalize to `/e/<id>` before extraction, so Referer headers point at the playable embed page.

## Later Validation Notes

- Targeted `xcrun swiftc -parse` checks passed for the changed browser/feed/extractor/download files.
- Full app `xcrun swiftc -typecheck $(rg --files PMVDL/PMVDL -g '*.swift')` passed after the Google Drive and provider-extractor changes, with only existing warnings.
- Raw `swiftc` test typechecking cannot import `XCTest` in this shell setup, so the full test suite remains an Xcode validation step.
