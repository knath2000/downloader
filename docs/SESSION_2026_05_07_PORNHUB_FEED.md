# Session Summary - 2026-05-07 PornHub Feed, Login, and Preview

## Scope

This session added PornHub as a first-class Feed source with native login, section switching, in-app uploader navigation, and hover video previews.

The implemented source is `pornhub.com`. It uses the same Feed card surface as the other sources but has its own orange site theme, flat source-order grid, section picker, and login banner.

## Files Touched

- `PMVDL/PMVDL/Feed/FeedItem.swift`
- `PMVDL/PMVDL/Feed/FeedScraper.swift`
- `PMVDL/PMVDL/Feed/FeedViewModel.swift`
- `PMVDL/PMVDL/Feed/FeedView.swift`
- `PMVDL/PMVDL/Feed/FeedCardView.swift`
- `PMVDL/PMVDL/Feed/PornHubSessionManager.swift`
- `PMVDL/PMVDL/Feed/PornHubLoginView.swift`
- `PMVDL/PMVDL.xcodeproj/project.pbxproj`

## Login And Sections

`PornHubSessionManager` is the cookie bridge between the login web view and feed requests:

- `WKWebsiteDataStore.default().httpCookieStore` is the source of cookies after login.
- Matching PornHub cookies are copied into `HTTPCookieStorage.shared`.
- Cookie properties are persisted in `UserDefaults` under `pornhubCookies`.
- Login state is detected by the PornHub `il` cookie.
- Logout removes PornHub cookies from both shared storage and the WKWebView store.

`PornHubLoginView` opens `https://www.pornhub.com/login` in a `WKWebView`. When navigation completes on a PornHub URL that is no longer `/login`, it syncs cookies and dismisses.

`PornHubSection` currently supports:

- Recommended: `https://www.pornhub.com/recommended`
- Hot: `https://www.pornhub.com/video?o=ht`
- Subscriptions: `https://www.pornhub.com/subscriptions`
- Liked: `https://www.pornhub.com/likedvideos`
- Favorites: `https://www.pornhub.com/users/favorites`
- Playlists: `https://www.pornhub.com/playlists`

Recommended and Hot can load without login. The personal sections are gated when the saved PornHub session is not present.

## Feed Model And UI

`FeedItem` now includes:

- `studioURL` for uploader click-through.
- `previewVideoURL` for PornHub mediabook MP4 previews.

`FeedSiteCapabilities` now includes `groupsByDate`. Existing sources keep `groupsByDate: true`; PornHub uses `groupsByDate: false` so the feed preserves PornHub's newest-first site order instead of regrouping cards into date sections.

`FeedSiteTheme.pornhub` uses:

- Accent: `#FF9000`
- Background tint: `#1A0F00`
- Logo split: `Porn` + `Hub`

`FeedView` now shows a PornHub section picker and login banner only when `pornhub.com` is selected. Switching away from PornHub clears active uploader navigation. Switching to PornHub forces `.newest` sorting to preserve source order.

## Parser Lessons

The working PornHub feed scraper uses `pcVideoListItem` cards. The confirmed live-card fields are:

- Viewkey: `data-video-vkey`
- Title: `title` on the `/view_video.php` link
- Thumbnail: `data-image`, then `data-mediumthumb`, then a `phncdn.com` image `src`
- Hover MP4: `data-mediabook`
- Duration: `<var class="duration">...`
- Views: `<span class="views"><var>...`
- Uploader: `/model/`, `/pornstar/`, `/channels/`, or `/user/` links
- Upload date: `<var class="added">...`

Important corrections:

- `/video/subscriptions` returned 404 and should not be used.
- Viewkeys are alphanumeric without a `ph` prefix.
- Feed requests explicitly build a `Cookie` header from PornHub cookies because automatic URLSession cookie matching was unreliable across `.pornhub.com` and `www.pornhub.com`.
- `data-mediabook` should be HTML-decoded and kept as a fully-qualified URL string. Sending it through the shared `absoluteURL` helper can drop signed Akamai URLs.

## Uploader Navigation

Clicking a PornHub uploader badge now navigates inside the app:

- `FeedViewModel.navigateToPornHubUploader(url:name:)` stores the uploader URL and name, then refreshes.
- `PornHubFeedScraper.fetchHTML` fetches the uploader's `/videos` page while uploader state is active.
- `PornHubSectionPicker` switches to a compact Back row with the uploader name.
- Back clears uploader state and reloads the selected PornHub section.

This replaced the browser-opening uploader behavior.

## Hover Video Preview

PornHub cards use `previewVideoURL` from `data-mediabook` for hover previews.

`PornHubVideoPreview` uses SwiftUI `VideoPlayer` with an `AVURLAsset` configured with:

- `User-Agent: NetworkConstants.chromeUserAgent`
- `Referer: https://www.pornhub.com/`

This matters because PornHub's Akamai `hdnea` media URLs appear to validate against the request fingerprint. AVPlayer's default CFNetwork headers can fail where curl and the initial page fetch succeed.

The player is muted, loops at end, and is torn down on disappear so hover exit returns to the thumbnail. Non-PornHub card scrub previews remain unchanged.

## Verification

The latest verification for this work used:

```sh
git diff --check
xcodebuild build -project PMVDL/PMVDL.xcodeproj -scheme PMVDL -destination 'platform=macOS' -derivedDataPath /tmp/viddl-pornhub-derived
```

The fresh debug build was launched from:

```sh
/tmp/viddl-pornhub-derived/Build/Products/Debug/VidDL.app
```

## Reusable Lessons

- Keep provider sessions explicit when authenticated scraping crosses WebKit and URLSession.
- Parse live card attributes first; PornHub's current feed cards do not use older `ph...` viewkey assumptions.
- For signed CDN hover media, preserve the original URL string and match request headers between page fetch and media playback.
- In-app source navigation is cleaner when it reuses `FeedViewModel.shared` and the existing refresh pipeline.
- Use feed capabilities for layout behavior, not just filters and sort modes.
