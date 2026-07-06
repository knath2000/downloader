# Session 2026-07-02: PornHub Browser Feed, Custom Context Menu, and Download Location

This session changed the PornHub Feed from a scraper-grid-first experience into a browser-first in-app PornHub surface while preserving VidDL actions.

## PornHub Browser Feed

`FeedView` now routes `pornhub.com` to `PornHubBrowserView`. Other feed sources continue to use the existing scraper-backed grid UI.

`PornHubBrowserView` wraps a `WKWebView` and provides browser chrome for:

- back and forward navigation
- reload / stop
- home
- address or search entry
- current page title / URL display
- recent in-memory pages
- external open and copy link
- Extract Current Page
- Favorite Page

The browser uses `WKWebsiteDataStore.default()` so it shares the PornHub login cookie store. Navigation completion syncs cookies back through `PornHubSessionManager`.

The first browser implementation could hang with an infinite spinner because SwiftUI updates were re-driving the web view load path. The fix was:

- make `PornHubBrowserWebView.updateNSView` a no-op
- ignore repeat web view attachment in the browser view model
- skip loading when the target URL matches the current URL

## Removed PornHub Feed Drawer

The bottom detected/feed-results drawer was removed after the desired UX shifted to browser plus VidDL overlay only.

Non-PornHub feed grids and existing card actions remain intact.

## Custom PornHub Right-Click Menu

The PornHub browser now injects a `contextmenu` user script into the `WKWebView`.

The script:

- finds the nearest clicked `a[href]`
- falls back to the current page URL
- extracts a title from anchor title, image alt text, anchor text, or document title
- prevents the default WebKit context menu
- sends URL, title, and click coordinates to Swift through `viddlContext`

Swift validates the URL as PornHub and presents a custom PornHub-themed menu with:

- Extract with VidDL
- Toggle Favorite
- Open in Library
- Open Here
- Copy Link
- Open Externally

Important implementation note: the final menu placement uses a borderless `NSPanel`, not `NSPopover`. The panel is positioned from WKWebView client coordinates converted into screen coordinates, then clamped to the visible screen. `NSPopover` placement drifted away from the cursor on PornHub thumbnails and should not be restored for this menu.

The `PornHubContextMenuWebView` subclass suppresses the default WebKit menu fallback through `menu(for:) -> nil`.

## Custom Download Location

Settings > Downloads now lets users select a custom download folder.

`DownloadPaths` now:

- stores the selected folder in `UserDefaults` under `customDownloadDirectory`
- exposes the resolved `downloadDir`
- falls back to `~/Downloads/VidDL`
- exposes helpers for setting and resetting the custom location

`SettingsView` now shows the active download path and provides:

- Browse
- Open
- Reset to Default

## Tests and Validation

Added or registered tests for:

- PornHub browser URL normalization and address/search behavior
- browser-detected PornHub feed item mapping
- custom download location storage and fallback behavior

Local validation available in this environment:

- `swiftc -parse PMVDL/PMVDL/Feed/PornHubBrowserView.swift`
- `git diff --check -- PMVDL/PMVDL/Feed/PornHubBrowserView.swift`

Full app build and QA are expected through Xcode.
