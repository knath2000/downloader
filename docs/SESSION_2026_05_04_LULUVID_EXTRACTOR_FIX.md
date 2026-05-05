# Session Summary — 2026-05-04 LuluVid/LuluStream Extractor Fix

## What Was Fixed

The LuluVid/LuluStream extractor was failing with `noSourceFound` even though the embed page still contained a playable video source. The confirmed working fix was to stop assuming the HLS URL is always hidden inside a Dean Edwards p.a.c.k.e.r `eval(...)` block.

Live Lulu embed pages can expose the JWPlayer HLS URL directly in script config. The extractor now scans the raw embed HTML for `.m3u8` first, then falls back to the existing packed-JS unpacker.

## Root Cause

Previous flow:

1. Resolve a file code from the incoming Lulu URL.
2. Fetch `https://luluvdo.com/e/<filecode>`.
3. Require `extractPackedBlock(...)` to find an `eval(function(p,a,c,k,e,d){...})` block.
4. Require `unpackPacker(...)` to decode that block.
5. Search only the decoded output for `.m3u8`.

Failure mode:

- Some current LuluVid/LuluStream embed pages put the JWPlayer `sources: [{ file: "https://...m3u8..." }]` value directly in the embed HTML.
- Those pages may not include the expected packed `eval(...)` block.
- The old code treated absence of the packed block as absence of a source, even when the HLS master playlist URL was present.

## Implementation

Changed `PMVDL/PMVDL/Extractors/LuluStreamExtractor.swift`:

- Added a source-discovery wrapper, `findHlsSource(_:)`.
- `findHlsSource(_:)` first calls `findM3u8InText(_:)` on the raw embed HTML.
- If no direct URL is found, it falls back to:
  - `extractPackedBlock(_:)`
  - `unpackPacker(_:)`
  - `findM3u8InText(_:)` on decoded JS
- Added `findHlsSourceForTesting(_:)` behind `#if DEBUG` so tests can validate source discovery without networking.

The extraction flow still preserves the Lulu-specific request context:

- Canonical embed URL: `https://luluvdo.com/e/<filecode>`
- Wrapper page for metadata: `https://luluvid.com/d/<filecode>`
- HLS request headers:
  - `Referer: <embedUrl>`
  - browser-like `User-Agent`
- Each returned HLS quality keeps:
  - per-quality headers
  - `sourcePageUrl: embedUrl`

## Test Coverage Added

Added `PMVDL/PMVDLTests/DownloadResolutionTests.swift` coverage for the important routing/header guarantees:

- `testDirectMP4UsesSourceLevelHeaders`
  - Confirms direct MP4 download resolution keeps source-level headers.
- `testHLSQualityKeepsPerQualityHeaders`
  - Confirms HLS quality selection keeps per-quality headers.
- `LuluStreamExtractorTests.testFindHlsSourceReadsDirectJWPlayerConfig`
  - Confirms direct JWPlayer config with `.m3u8` is detected without requiring `eval(...)`.
- `LuluStreamExtractorTests.testFindHlsSourceFallsBackToPackedConfig`
  - Confirms old packed-JS pages still work through the fallback path.

## Validation

- Built a Debug app using a clean derived-data path:

```sh
xcodebuild -project PMVDL/PMVDL.xcodeproj -scheme PMVDL -configuration Debug -derivedDataPath /tmp/viddl-run-derived build
```

- Launched the built app from:

```text
/tmp/viddl-run-derived/Build/Products/Debug/VidDL.app
```

- User acceptance test: the previously failing LuluVid link extracted video sources successfully after the direct-HLS-first fix.

## Durable Lessons

- For LuluVid/LuluStream, do not couple source discovery to a single obfuscation style.
- Prefer a layered extractor:
  1. Raw embed HTML `.m3u8` scan.
  2. Packed-JS decode fallback.
  3. HLS variant parsing with embed referer.
- Preserve headers and source page URL all the way through extraction, queue resolution, refresh, local HLS materialization, and cloud upload staging.
- When a provider changes page shape, add a network-free parser test for the new shape and keep a regression test for the old shape.

## Files Touched For This Fix

- `PMVDL/PMVDL/Extractors/LuluStreamExtractor.swift`
- `PMVDL/PMVDLTests/DownloadResolutionTests.swift`
- `PMVDL/Resources/LuluStream.md`
- `docs/SESSION_2026_05_04_LULUVID_EXTRACTOR_FIX.md`
