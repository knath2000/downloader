# Feed and CDN Transfer Reliability

**Date:** 2026-07-19  
**Project:** LustreStudio native macOS app

## OnlyFan420/Rentry Feed browser

The OnlyFan420 page is a single Rentry document containing roughly one thousand provider links and image thumbnails. Two browser integrations scaled with the entire document and caused severe UI delay:

- The downloaded-state decorator watched DOM mutations and repeatedly traversed every provider link to add badges.
- The custom context-menu handler could search the enclosing page-wide article/table to rediscover one clicked video URL.

The Rentry browser now skips downloaded-state badge decoration and resolves a right-click from the clicked provider anchor only. The event handler is installed at document start. This removes page-wide work from Rentry scrolling and context-menu presentation while preserving the custom menu for Playmogo, Lulu, Vidara, and Dood links.

## Playmogo / CloudAta transfers

Playmogo pages may be Cloudflare challenged outside a verified browser session. Their player creates a short-lived CloudAta media URL using a dynamic `/pass_md5/...` response, a random suffix, and a token/expiry query. Browser video delivery sends a referer-aware initial byte-range request.

The native WebDAV path previously accepted any non-empty HTTP-successful body. A CloudAta error response could therefore be uploaded and reported as completed; the observed server object was 14 bytes.

The transfer path now:

- retains Playmogo Referer, Chrome user-agent, Accept, and Accept-Language headers;
- treats `cloudatacdn.com` like `mxcontent.net` as a range-required CDN;
- stages range-required sources through curl HTTP/1.1 with `Range: bytes=0-` before WebDAV upload;
- rejects HTML, JSON, XML, and bodies below 1 KiB before an upload can be marked successful.

This keeps browser-compatible request semantics at the CDN boundary and converts invalid provider responses into a source-transfer failure instead of a corrupt completed upload. Existing tiny remote files are intentionally not deleted automatically.

## Queue semantics reaffirmed

Persisted queue rows store the original page URL and preferred quality label only. Waiting, manual start, retry, resume, and launch-rehydrated work re-extract the primary page URL automatically before transfer; no user intervention is required. Immediate downloads may use the in-memory extraction result.

## Validation

- `git diff --check`
- Debug production-target builds completed with `CODE_SIGNING_ALLOWED=NO`.
- The last test bundle was opened with `open -n`, preserving existing LustreStudio instances and active downloads.
