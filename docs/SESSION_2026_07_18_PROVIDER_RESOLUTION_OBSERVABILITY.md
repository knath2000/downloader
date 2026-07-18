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

## Validation

- `git diff --check`
- `xcodebuild -project PMVDL/PMVDL.xcodeproj -scheme PMVDL -configuration Debug -derivedDataPath /tmp/lustrestudio-vide0-direct-route build`
- Fresh Debug bundle: `/tmp/lustrestudio-vide0-direct-route/Build/Products/Debug/LustreStudio.app`

The scheme does not include `PMVDLTests`, so targeted `xcodebuild test` cannot be executed through this scheme. The production target compiled successfully.
