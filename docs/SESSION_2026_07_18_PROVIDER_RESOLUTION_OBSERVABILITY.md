# Provider Resolution Observability and Browser-Only MixDrop Fallback

**Date:** 2026-07-18
**Project:** LustreStudio native macOS app

## Resolution observability

Extraction results now show the resolver path used for the selected source. `VideoSource` and its qualities carry an optional resolution-method value, which is preserved while AllPornStream provider qualities are flattened into the result list.

Current labels include:

- `Static page parser`
- `Static Playmogo resolver`
- `Static MixDrop resolver`
- `WebView media capture`
- `yt-dlp`
- `Direct stream`

The result modal and compact result rows display `Resolved via …`. This distinguishes a normal static result from a browser/WebKit fallback and makes provider diagnosis visible without exposing the raw provider domain in the UI.

## DoodStream and Playmogo hardening

AllPornStream records marked `hosting_provider = DOODSTREAM` are now treated as trusted provider identity, not as a frozen hostname allowlist. The resolver canonically routes those records through Playmogo even when the advertised Dood alias is new or misspelled, including the observed `dooodster.com` form.

For Playmogo `/d/` pages, the extractor retains the landing page, finds its `/e/` iframe, fetches the actual player, then resolves the dynamic `/pass_md5/...` response into the short-lived CloudAta MP4 URL. The direct CloudAta URL is retained with Playmogo Referer and Chrome user-agent headers.

The manual verification pane remains available only for a positively detected Cloudflare challenge. Resolver failures, unavailable aliases, and ordinary missing-video responses no longer trigger it.

## MixDrop browser-only fallback

The live AllPornStream post below exposed stale StreamTape and Dood provider records but a live MixDrop player:

`https://allpornstream.com/post/65b26e13c0d43545ad05dd4b/brazzers-exxtra-miss-raquel-stop-spying-on-the-nanny-01-25-2024`

Terminal inspection found:

- StreamTape returned `404`.
- The Dood/Playmogo record was marked `404` by AllPornStream; even though it could form a syntactically valid CDN request, it was not the browser-playable source.
- MixDrop was the only working browser container and was marked `200` by the provider metadata.
- Normal terminal/static requests to `mxdrop.to` and observed rotating aliases failed their TLS connection, while the browser player could load the media.

`MixDropExtractor` therefore keeps its fast static parser first and falls back to `WKWebView` media capture only if the page request or static parsing fails. WebView capture now accepts only validated `mxcontent.net` MP4 URLs and returns the MixDrop Referer plus Chrome user-agent headers. The discovered `miiiixdrop.net` alias is also recognized for direct inputs and provider routing.

## Provider progress and MixDrop transfer compatibility

The extraction modal now retains a per-URL trace while work is in progress and after it completes. It reports page parsing, discovered providers, the provider currently resolving, each provider's result, and a deterministic summary across all providers. Terminal extraction and download failures identify the failing source, pipeline stage, and reason.

For AllPornStream provider posts, StreamTape, MixDrop, and DoodStream are resolved independently with a bounded provider timeout. A failed provider no longer hides the result from the other providers or blocks a viable MixDrop source.

Manual validation against a live MixDrop mxcontent.net MP4 established a transport-specific distinction:

- HEAD returns a valid MP4 content length.
- A browser-compatible curl request using HTTP/1.1 and Range: bytes=0- returns 206 Partial Content.
- The same request issued through macOS URLSession returns 403.

Seedbox WebDAV transfers now route mxcontent.net media through curl with the proven HTTP/1.1 range request, stage it locally, then upload the staged file to WebDAV. This bypasses the CDN behavior that rejects the native Foundation client while preserving the existing direct streaming path for other hosts.

## Validation

- `git diff --check`
- `xcodebuild -project PMVDL/PMVDL.xcodeproj -scheme PMVDL -configuration Debug -derivedDataPath /tmp/lustrestudio-vide0-direct-route build`
- Fresh Debug bundle: `/tmp/lustrestudio-vide0-direct-route/Build/Products/Debug/LustreStudio.app`

The scheme does not include `PMVDLTests`, so targeted `xcodebuild test` cannot be executed through this scheme. The production target compiled successfully.
