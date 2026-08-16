# LustreStudio Changelog

## Unreleased
- Rebranded the visible app, bundle, packaging, and licensing experience as LustreStudio while retaining compatibility identities and persisted paths
- Added a persistent macOS menu-bar download monitor with transfer progress, pause/resume, quick-open, and quit controls
- Added concurrent Google Drive and Seedbox transfers from a single extracted result
- Added local rotating-code activation for personal Pro use
- Polished Feed spacing, card density, and the top filter toolbar layout
- Gated Feed, Favorites, and Profile behind LustreStudio Pro
- Simplified Settings Cloud Destinations into one selector-driven setup section
- Removed legacy upload automation rules, updater integration, and companion-entrypoint scope
- Fixed AI Profile narrative rendering for flattened cached analysis text
- Redesigned Library as a hybrid activity timeline plus selected-item detail preview
- Added video, link, and upload detail actions directly in the Library preview panel
- Kept video bulk selection separate from timeline preview selection
- Added Library timeline tests for selected-entry fallback and video-only bulk selection
- Added AI Profile performer avatars with profile/headshot lookup and evidence thumbnail fallback
- Added Feed downloaded-state badges with Library matching by PornHub viewkey or normalized URL
- Added clearer Home download queue counts for remaining, active, queued, and paused work
- Expanded Files into a Finder-like remote browser with multi-select, drag move/copy, duplicate, move, info, and right-click actions
- Stabilized the Files toolbar so selection state does not push the file list down
- Moved extraction loading into the results sheet so Home content stays visible while extraction runs
- Embedded a compact download queue on Home and removed the standalone Downloads navigation route
- Added compact queue thumbnails, context actions, and completed-download thumbnail fixes
- Stabilized download job state by keeping `DownloadJobRunner` on the main actor
- Added native HQPorner extraction through the nested player iframe with referer-aware MP4 qualities
- Added Feed batch selection and batch extraction
- Added Feed hover preview scrub for HQPorner preview images
- Added site-capability-aware Feed filters and sort options
- Added lazy HQPorner detail-page date resolution
- Added site-specific Feed page theming for AllPornStream, OnlyFan420/Rentry, and HQPorner
- Added PornHub as a Feed source with persisted WKWebView cookie login
- Added PornHub section picker for Recommended, Hot, Subscriptions, Liked, Favorites, and Playlists
- Added PornHub flat-grid source-order rendering with orange site theming
- Added in-app PornHub uploader navigation through uploader `/videos` feeds
- Added PornHub hover MP4 previews from `data-mediabook` with matching playback headers
- Added live PornHub card parsing for `data-video-vkey`, thumbnails, views, duration, uploader, and relative upload dates
- Added user-facing setup documentation in `README.md`

- Added live extraction traces with provider-specific progress, results, pipeline stages, and failure reasons
- Preserved the primary page URL for queued work so delayed tasks refresh short-lived provider media URLs when they begin
- Hardened AllPornStream provider resolution for current MixDrop and DoodStream aliases, including independent provider outcomes
- Added a browser-compatible curl fallback for MixDrop mxcontent.net WebDAV transfers when macOS URLSession receives CDN 403 responses
- Kept OnlyFan420/Rentry feed scrolling and right-click menus responsive by avoiding page-wide badge and link scans
- Hardened Playmogo CloudAta transfers with browser-compatible range staging and invalid-response safeguards before WebDAV upload

## v2.0.0 (Apr 2026)
- Dual window + menu bar mode (no longer menubar-only)
- Library view with thumbnail caching
- Download queue management with pause/resume
- Notifications for upload and scrape status
- Keyboard shortcuts (⌘1-4 for navigation, ⌘N for extraction)
- Drag & drop support for URLs and video files
- Siri Shortcuts (3 intents)
- Pro licensing via Stripe ($0.99 one-time)
- Stream host support improvements
- AES-128 encrypted HLS handling now decrypts segments locally before muxing
- HLS queue progress now stays accurate through segment download, decrypt, and remux
- HLS manifests are surfaced down to 480p instead of being hidden by UI filtering
- Stream host extraction now captures tokenized Cloud CDN media URLs from WebView player activity and sends required headers through local, Mega, and GDrive direct downloads

## v1.2.0 (Apr 2026)
- Batch MP4 download to Mega
- Google Drive upload support via rclone
- Transfer polling view for Mega uploads

## v1.1.0 (Apr 2026)
- HLS resolution sorting (2160p → 360p → master)
- Clipboard auto-detection for video URLs
- Per-URL Mega and GDrive upload buttons

## v1.0.0 (Apr 2026)
- Initial release — menubar app
- Video page extraction via regex
- Mega upload support via megacmd CLI
- Standalone Python CLI companion (viddl.py)
