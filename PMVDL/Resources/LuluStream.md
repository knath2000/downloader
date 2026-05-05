# LuluStream Extraction Notes

This document captures the working implementation and the failure modes that were debugged while adding support for LuluVid/LuluVdo/LuluStream URLs.

## Supported URL shapes

- `https://luluvid.com/d/<code>`
- `https://luluvdo.com/<code>`
- `https://luluvdo.com/e/<code>`
- `https://lulustream.com/d/<code>_h`

## Extraction flow

1. Resolve the page to a file code.
2. Fetch the wrapper page for metadata like title and thumbnail.
3. Fetch the embed page.
4. Search the raw embed HTML for a JWPlayer `.m3u8` source first.
5. If no direct HLS URL is present, decode the packed JWPlayer script and search the decoded config.
6. Extract the signed HLS master playlist URL.
7. Carry the embed-page `Referer` and browser `User-Agent` through to download time.
8. Refresh the HLS URL again at download time if needed.

## 2026-05-04 extractor update

The latest confirmed LuluVid failure was not a downloader or header issue. Source extraction failed because the implementation required a p.a.c.k.e.r `eval(...)` block before it would look for HLS. The live embed page instead exposed the JWPlayer HLS URL directly in script config.

The working extractor now uses a layered source-discovery strategy:

1. `findM3u8InText(_:)` on the raw embed HTML.
2. `extractPackedBlock(_:)` + `unpackPacker(_:)` only as a fallback.
3. `findM3u8InText(_:)` on decoded packed JS.

Regression coverage lives in `PMVDL/PMVDLTests/DownloadResolutionTests.swift`:

- Direct JWPlayer config with `.m3u8` and no `eval(...)`.
- Packed config fallback for older embed shapes.
- Per-quality HLS headers preserved through download resolution.

## What broke during implementation

- Treating the embed page as a generic `yt-dlp` site produced `Unsupported URL`.
- Hiding non-numeric HLS labels in the UI made LuluStream look empty when it only returned `master`.
- Downloading the `.m3u8` directly caused the app to upload the manifest instead of the video.
- Remote ffmpeg fetches failed with `ffmpeg error 8` on LuluStream because the stream required tighter request context and a local materialization path.
- ffmpeg concat/mux failures on encrypted HLS were ultimately caused by trying to pass the encrypted stream through ffmpeg decryption instead of decrypting segments in-app.

## Final working download path

- Download encrypted segments with `URLSession`.
- Validate that the response is real media, not HTML or a poisoned error body.
- Download the AES-128 key.
- Decrypt each segment locally with the playlist IV or sequence-derived IV.
- Concatenate decrypted transport streams with the existing mux path.
- Upload only the final MP4 to Mega or Google Drive.

## Important implementation detail

- The local encrypted HLS mux path must keep the source page URL and headers attached to the quality entry.
- For LuluStream, the app should prefer the extracted HLS URL as the primary download input and only refresh from the embed page as a fallback.
- The UI should fail open for nonnumeric HLS labels so LuluStream can still render when only `master` is exposed.

## Verification

- Local download: OK
- Mega upload: OK
- Google Drive upload: OK
- Queue progress: OK
- HLS manifest upload prevention: OK
