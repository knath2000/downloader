# DoodStream/Playmogo Resolution and Verification Fallback

**Date:** 2026-07-17
**Project:** LustreStudio native macOS app

## Confirmed provider chain

The AllPornStream post used for validation is:

`https://allpornstream.com/post/270a0791-1a9b-45be-8f13-9de24569b6c3/blacked-raw-gypsy-rose-blonde-hottie-squirts-all-over-his-bbc-07-10-2025`

The live payload exposes the DoodStream provider as:

- Embed URL: `https://vide0.net/e/hxptj42uoxb0`
- Watch/download URL: `https://vide0.net/d/hxptj42uoxb0`
- Redirect target: `https://playmogo.com/e/hxptj42uoxb0`

Playmogo's page generates a dynamic `/pass_md5/...` request. The response is a fresh `ok148lo.cloudatacdn.com` base URL. The player appends a random ten-character suffix and `?token=...&expiry=...` to form the playable/downloadable MP4 URL.

The CloudAta URL must be retained as-is with the Playmogo `Referer` and Chrome user-agent headers. Following the CloudAta URL to a `dood.video` hostname is not a valid extraction path for this provider and can produce a connection error. Generated URLs are short-lived and must be regenerated for each extraction/download attempt.

## Implemented fixes

- Route AllPornStream entries whose provider identity is DoodStream through `DoodStreamExtractor`, even when the host is a newly rotated alias.
- Add `vide0.net`, `playmogo.com`, and `ds2play.com` provider support and preserve provider metadata through source refresh/download resolution.
- Rewrite `vide0.net` `/d/` and `/e/` URLs to the equivalent Playmogo embed before fetching, avoiding the failing provider TLS/redirect path.
- Correct Playmogo token parsing for the live player form `"?token=...&expiry="`; the previous expression incorrectly required characters before `?token=`.
- Keep Playmogo CloudAta URLs as direct quality entries with `Referer` and user-agent headers instead of resolving them to `dood.video`.
- Add a manual verification coordinator and pane for cases where WebKit/Cloudflare still requires an interactive browser challenge. The pane supports reload, explicit Google Chrome for Testing launch, Continue Extraction, and cancellation.
- The verification pane remains a fallback, not the normal path. When the challenge is solved, retrying the failed extraction returns the provider quality rows correctly.

## Validation

- Live inspection confirmed the provider chain and a fresh CloudAta URL returning `200 video/mp4` when requested with the correct referer/user-agent.
- Debug builds completed with the external Xcode toolchain and the latest `LustreStudio.app` bundle was launched for manual testing.
- User confirmed the final behavior: the verification pane can display Cloudflare when required, and Continue Extraction produces the expected extraction results after verification.
