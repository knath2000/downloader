# Session 2026-07-09: Internal Feed Source Navigation and Shell Alignment

## Summary

Queue `Show Source` now opens the original video page in VidDL's controlled Feed browser instead of sending the selected media URL to Safari. The app shell titlebar fallback and Feed chrome spacing were also corrected after the mobile-shell layout pass.

## Source Navigation

- `Show Source` in both the Downloads view and Home compact queue calls `AppStateManager.openFeedSource(for:)`.
- The source URL is `retryPayload.resolution.result.url`, not the queue item's media URL, resolved final URL, or CDN URL.
- `FeedSourceNavigation` accepts only HTTP/HTTPS pages that match an existing `FeedBrowserSite.allows(_:)` policy. Unsupported or legacy items remain in-app and show a short transient message.
- `FeedNavigationRequest` carries a unique request, page URL, and selected Feed site through app state.
- `FeedView` consumes the request without letting normal site-change home navigation overwrite it. `PornHubBrowserViewModel` retains a pending URL until its `WKWebView` attaches, so cold Feed mounts reliably load the requested page.

## Shell and Feed Layout

- `WindowConfigurator` keeps the hidden transparent titlebar but uses the app's `#0A0A1A` midnight fallback background and an opaque window, preventing the traffic-light region from becoming visually transparent.
- Feed uses a 6-point top inset and an 8-point chrome-to-WebView gap. This keeps the site switcher and browser visually high while leaving enough titlebar clearance to avoid clipping.

## Verification

- `git diff --check` passed.
- Focused `xcrun swiftc -parse` passed for the touched app-shell and Feed files.
- Debug macOS build passed with the external Xcode at `/Volumes/MyPassport/Applications/Xcode.app/Contents/Developer`.
- New `PornHubBrowserTests` cover source-page selection over a CDN URL and unsupported-source rejection.
- A focused `xcodebuild test` attempt did not execute tests because the existing test build failed while copying/signing XCTest frameworks (`XCTestCore.framework` / `XCTestSupport.framework`). The app target build remains clean.
