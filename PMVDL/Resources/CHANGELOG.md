# VidDL Changelog

## v2.0.0 (Apr 2026)
- Dual window + menu bar mode (no longer menubar-only)
- Library view with thumbnail caching
- Download queue management with pause/resume
- Notifications for upload and scrape status
- Keyboard shortcuts (⌘1-4 for navigation, ⌘N for extraction)
- Drag & drop support for URLs and video files
- Safari extension for one-click extraction
- Share extension (system share sheet)
- Siri Shortcuts (3 intents)
- Sparkle auto-update integration
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
