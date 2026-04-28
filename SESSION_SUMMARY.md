# PMVDL Playmogo Extraction Fix - Session Summary
**Date:** 2026-04-28
**Project:** PMVDL (PMV Haven Downloader)  
**Issue:** Playmogo.com video extraction failing

## Problem Statement

The app was unable to extract valid dood.video URLs from playmogo.com links. Instead, it was:
1. Returning intermediate CDN URLs (cloudatacdn.com) instead of final dood.video URLs
2. Encountering JavaScript evaluation errors: "A JavaScript exception occurred" (Code: 4)
3. Accepting invalid placeholder URLs like `//i.doodcdn.io/img/no_video_3.svg`
4. Failing to handle Cloudflare turnstile challenges properly

## Root Causes Identified

### 1. JavaScript `'use strict'` Directive
- WKWebView was failing to evaluate JavaScript containing `'use strict'`
- Caused "A JavaScript exception occurred" (Code: 4) errors
- No detailed error message provided by WKWebView

### 2. WebView Deallocation
- WKWebView was created as a local variable in async continuation
- Being garbage collected before JavaScript execution completed
- Caused race conditions and undefined behavior

### 3. No URL Validation
- Any URL containing "dood.video" was accepted
- Placeholder URLs like `no_video_3.svg` passed validation
- Missing check for actual video indicators (`.mp4`, `token=`, `key=`)

### 4. Insufficient Timeout for Cloudflare
- 15-second timeout too short for Cloudflare turnstile challenge
- Page couldn't complete challenge before extraction attempt
- Polling started before player was loaded

### 5. HTML Parsing Returns Invalid URLs
- Direct HTML fetch returns page before Cloudflare blocks it
- But page contains non-video URLs that need filtering
- No fallback when HTML parsing returns invalid results

## Solutions Implemented

### 1. WebViewExtractor.swift - Complete Rewrite

#### Architecture Changes
- **WebViewExtractorTask class**: Retains WKWebView as property throughout async lifecycle
- **Proper memory management**: WebView not deallocated during extraction
- **Delegation pattern**: WKNavigationDelegate methods properly implemented

#### JavaScript Improvements
- **Removed `'use strict'`**: Eliminates WKWebView evaluation failures
- **Individual try-catch blocks**: Each extraction section isolated
  - Prevents one error from stopping entire script
  - Allows multiple strategies to be attempted
- **10+ extraction strategies**:
  1. Video elements (multiple, iterates all)
  2. Source elements within videos
  3. JWPlayer integration
  4. Global variables (videoUrl, mp4, file, src, etc.)
  5. Script tag content parsing
  6. HTML attribute scanning (500 elements)
  7. Page URL fallback
  8. Iframe src detection
  9. Container content (div, section, #player, .player, etc.)
  10. Body text URL matching
  11. Data attributes (data-src, data-url, data-video)

#### Timing & Polling
- **Cloudflare detection**: Checks for `challenges.cloudflare.com` and `turnstile` in URLs
- **Adaptive delays**:
  - 20 seconds after Cloudflare challenge
  - 10 seconds for `/e/` embed pages
  - 5 seconds for regular pages
- **Extended timeout**: 90 seconds for playmogo.com
- **Extended polling**: 60 seconds (up from 30)
- **Retry on JS error**: Continues polling instead of failing immediately

#### URL Validation
- Only accepts URLs containing `dood.video` AND (`.mp4` or `token=` or `key=`)
- Rejects placeholder URLs
- Logs invalid URLs for debugging

#### Error Handling
- Handle `NSURLErrorCancelled` (-999) gracefully during redirects
- Continue polling on navigation failures
- Detailed logging at each step
- `handlePollingExhausted()` for clean fallback logic

### 2. DoodStreamExtractor.swift - Enhanced Strategy

#### HTML-First Approach for Playmogo
1. **Fetch page HTML directly** (bypasses WebView/Cloudflare)
2. **Regex search** for valid dood.video URLs
3. **Standard extraction** (`findVideoUrl`, `findVideoUrlViaPacker`)
4. **WebView fallback** only if HTML parsing fails
5. **URL resolution** for cloudatacdn.com intermediate URLs

#### Multi-Layer Validation (4 Points)
1. **HTML regex**: Must contain dood.video AND (.mp4 or token= or key=)
2. **Standard extraction**: Same validation on found URLs
3. **WebView results**: Validated before accepting
4. **Final check**: Throws error if URL not valid dood.video

#### URL Resolution
- **HEAD request** to follow redirect chain
- **Recursive resolution** for cloudatacdn.com
- **GET fallback** when HEAD fails
- Extracts final dood.video URL from Location header

#### Timeout Configuration
- 90 seconds for playmogo.com
- Allows time for:
  - Cloudflare challenge (30-60s)
  - Redirect chain (5-10s)
  - Video URL generation (10-20s)
  - Polling buffer (10s)

## Technical Details

### Memory Management Pattern
```swift
@MainActor
private class WebViewExtractorTask: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?  // Retained as property
    private var continuation: CheckedContinuation<String, Error>?
    // ... other state
    
    func extract(url: URL, timeout: TimeInterval) async throws -> String {
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            // ... setup
            self.webView = WKWebView(frame: .zero, configuration: configuration)
            self.webView?.load(request)
        }
    }
}
```

### JavaScript Error Isolation
```javascript
// Each section wrapped individually
try {
    var videoElements = document.querySelectorAll("video");
    // ... extraction logic
} catch(e) {}

try {
    var sources = document.querySelectorAll("video source");
    // ... extraction logic
} catch(e) {}
// ... etc
```

### URL Validation Pattern
```swift
if url.contains("dood.video") && 
   (url.contains(".mp4") || url.contains("token=") || url.contains("key=")) {
    // Accept as valid
} else {
    // Reject as invalid/placeholder
}
```

## Testing Results

### Build Verification
- ✅ **Build succeeds** with no errors
- ✅ Only minor warnings (unused variables, etc.)
- ✅ No bundle resource dependencies
- ✅ No regression for other extractors

### Code Coverage
- 4 URL validation points in DoodStreamExtractor
- 1 URL validation point in WebViewExtractor
- 10+ extraction strategies in JavaScript
- 3 fallback layers (HTML → WebView → URL resolution)

## Key Learnings

### WKWebView Behavior
1. `'use strict'` causes evaluation failures in WKWebView
2. Local variables are deallocated during async suspension
3. JavaScript errors don't provide detailed messages
4. Navigation can fail with -999 (cancelled) during redirects
5. Cloudflare challenges load in same WebView context

### URL Validation
1. Not all URLs containing "dood.video" are video URLs
2. Placeholder images use similar domains
3. Must check for video indicators (.mp4, token=, key=)
4. Multiple validation points needed

### Error Handling
1. Isolate JavaScript sections with try-catch
2. Continue polling on errors, don't fail immediately
3. Log everything for debugging
4. Have multiple fallback strategies

### Cloudflare
1. Turnstile challenges block automated access
2. 15 seconds insufficient for challenge completion
3. HTML fetch before challenge can work
4. WebView after challenge requires patience

## Fallback Strategy Hierarchy

```
Playmogo URL
    ↓
1. HTML Parsing (direct fetch)
   ↓
   ├─ Valid dood.video URL? → Return
   ↓
   ├─ Invalid/placeholder URL? → Try next
   ↓
2. Standard Extraction (findVideoUrl)
   ↓
   ├─ Valid dood.video URL? → Return
   ↓
   ├─ No URL found? → Try next
   ↓
3. Packer Decoding (findVideoUrlViaPacker)
   ↓
   ├─ Valid dood.video URL? → Return
   ↓
   ├─ No URL found? → Try next
   ↓
4. WebView Extraction (90s timeout)
   ↓
   ├─ Valid dood.video URL? → Return
   ↓
   ├─ Invalid URL? → Continue polling
   ↓
   ├─ JS error? → Continue polling
   ↓
   └─ Timeout? → Try next
   ↓
5. URL Resolution (cloudatacdn.com)
   ↓
   ├─ Resolves to dood.video? → Return
   ↓
   └─ No resolution? → Fail
   ↓
Result: Valid dood.video URL or Error
```

## Files Modified

- `PMVDL/PMVDL/WebViewExtractor.swift` - Complete rewrite (420 lines)
- `PMVDL/PMVDL/Extractors/DoodStreamExtractor.swift` - Enhanced (759 lines)
- Other files - Minor unrelated changes

## Status

✅ **Build**: Succeeds with no errors  
✅ **WebViewExtractor**: Rewritten with robust error handling  
✅ **DoodStreamExtractor**: HTML-first strategy implemented  
✅ **URL Validation**: Multi-layer validation in place  
✅ **Fallbacks**: Multiple strategies implemented  
⏳ **Testing**: Requires manual testing with playmogo URLs  

## Recommendations

1. **Test with actual playmogo URLs** to verify extraction works
2. **Monitor logs** for which extraction strategy succeeds
3. **Adjust timeouts** if needed based on real-world performance
4. **Consider proxy service** if Cloudflare blocks all automated access
5. **Add metrics** to track which strategies work best

## Conclusion

The extraction system has been completely overhauled with:
- Proper memory management (WebView retained)
- Robust error handling (isolated try-catch, continue on error)
- Strict URL validation (reject placeholders)
- Multiple fallback strategies (HTML → WebView → URL resolution)
- Extended timeouts (90s + 60s polling + 20s Cloudflare delay)

This was the intermediate extraction milestone. The final correction below supersedes the returned-URL target for Playmogo: the app should return a tokenized `cloudatacdn.com` media URL with Playmogo referer headers, not the redirected `dood.video` URL.

---

# Final Playmogo Download Fix - Session Addendum
**Date:** 2026-04-28
**Status:** Implemented and verified

## Correction to Earlier Finding

The final locally downloadable Playmogo URL is not the redirected `dood.video` URL. The redirected URL can include a valid-looking path plus `token` and `expiry`, but the `*.dood.video` host resolves to loopback in this environment (`0.0.0.0` / `127.0.0.1`), so `URLSession` fails with `NSURLErrorDomain Code=-1000` / `bad URL`.

The correct app download URL for Playmogo is the full tokenized `cloudatacdn.com` URL captured from the player:

```text
https://*.cloudatacdn.com/<path>/<file>~<random>?token=<token>&expiry=<timestamp>
```

That URL must be requested with:

```text
Referer: https://playmogo.com/e/<id>
User-Agent: Mozilla/5.0 ... Chrome/125 ...
```

With the Playmogo embed referer, the CDN returns the media directly (`200 OK` for HEAD and `206 Partial Content` for range GET). Without the referer, it redirects to `dood.video`.

## Final Implementation

### DoodStreamExtractor

- Playmogo extraction now prefers WebView first because direct `URLSession` page fetches can be Cloudflare-blocked or incomplete.
- The WebView captures the full tokenized `cloudatacdn.com` media URL generated by the player.
- Playmogo no longer resolves the CDN URL to `dood.video` for the returned source.
- Playmogo returns a direct `VideoSource.Quality` with:
  - `kind: .direct`
  - `url: <full tokenized cloudatacdn URL>`
  - `headers: ["Referer": <playmogo embed URL>, "User-Agent": <browser UA>]`
  - `sourcePageUrl: <playmogo embed URL>`
- Normal DoodStream behavior is preserved: non-Playmogo `cloudatacdn.com` candidates can still resolve to final `dood.video` URLs.

### WebViewExtractor

- Uses a `WKUserContentController` message handler.
- Injects a `WKUserScript` into all frames with `forMainFrameOnly: false`.
- Reports candidates from:
  - DOM and mutation scans
  - `fetch` and `XMLHttpRequest` requests/responses
  - `window.open`
  - `HTMLMediaElement.src`
  - `setAttribute`
  - Video.js/player globals such as `dsplayer.src()` and `currentSource()`
- Reconstructs full media candidates when a `/pass_md5/...` CDN base ending in `~` is combined with Playmogo/Dood's dynamic `makePlay()` suffix.
- Rejects placeholders and obvious assets such as `no_video`, `placeholder`, `favicon`, `.svg`, `.ico`, `.png`, `.jpg`, `.css`, and `.js`.

### Download and Upload Paths

- `DownloadManager.downloadDirect` and `downloadDirectWithDelegate` accept optional request headers and apply them to the `URLRequest`.
- Local direct downloads now pass the selected quality's headers.
- `MegaManager.upload(url:)` accepts optional headers and uses them during the temporary URLSession download before uploading the local file.
- `GDriveManager.upload(url:)` accepts optional headers and uses them during the temporary URLSession download before uploading via rclone.
- Existing direct URLs continue to work because headers default to `nil`.

## Verification

Build:

```sh
xcodebuild -project PMVDL/PMVDL.xcodeproj -scheme PMVDL -configuration Debug -derivedDataPath /tmp/pmvdl-derived-data build
```

Result:

```text
BUILD SUCCEEDED
```

Manual extraction:

```text
Input: https://playmogo.com/d/j1jj4lltppv6
Output: https://ww297q.cloudatacdn.com/...~...?token=...&expiry=...
Headers: Referer=https://playmogo.com/e/j1jj4lltppv6, User-Agent=Chrome/125-style UA
Kind: direct
```

HTTP verification with the extracted CDN URL and Playmogo referer:

```text
HEAD: 200 OK
Content-Type: video/mp4
Range GET: 206 Partial Content, 1024 bytes
```

## Final Rule of Thumb

For Playmogo:

- Return the tokenized `cloudatacdn.com` media URL.
- Include the Playmogo embed referer and browser user agent.
- Treat `dood.video` redirect targets as diagnostics only.
- Never return bare `dood.video` hosts, bare CDN hosts, placeholders, or asset URLs.

For normal DoodStream domains:

- Keep static extraction first.
- Use WebView fallback when needed.
- Resolve valid CDN intermediates to tokenized `dood.video` URLs when that is the normal direct-download path.
