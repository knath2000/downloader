# Session 2026-07-05: UI Polish, Stitch Direction, and Packaging

## Summary

This session moved VidDL toward a cleaner macOS utility experience while preserving app behavior. The main product direction is a darker, quieter "Lustre/Obsidian utility" visual system with modal-first organization for secondary information and screen-by-screen redesigns instead of a single broad rewrite.

## Settings

- Cloud Destinations was simplified by removing Mega and Server options from the visible settings flow.
- The Files tab was removed from the app navigation.
- The Settings top header/navbar was removed because the settings surface is small enough to stand alone.

## Feed Browser

- PornHub and Eporner feed filter bars were removed where they created unnecessary top-page clutter.
- The Feed browser was reframed as a controlled feed viewer, not a general browser.
- The editable URL/address bar, recent/history menu, copy URL, and top-level open-external controls were removed from the browser chrome.
- Site-contained navigation was kept: normal in-WebView browsing is allowed inside the selected feed site, while unrelated external-domain navigation is blocked.
- Login notice banners for PornHub and Eporner were removed. Users can still log in directly through the embedded website, and cookie/session syncing remains intact.
- "Open Here" was removed from the custom right-click menu while preserving VidDL actions such as select/deselect, extract, favorite, open in Library, copy link, and batch selected extraction.

## Home

- Active downloads became the primary Home state: queue first, URL input secondary, supported sources hidden while downloads are active.
- `HomeCompactQueue` gained stronger active queue hierarchy: active/remaining counts, aggregate progress, clearer rows, destination/stage chips, larger thumbnails, calmer controls, and red reserved for actual failures.
- Completed-only downloads now behave as a successful handoff instead of an active queue:
  - URL input returns to primary placement.
  - Completed downloads show a compact success summary by default.
  - Detailed completed rows stay behind Show Details.
  - Popular/supported sources return when no active downloads are running.
- Stitch correction: the Stitch-style Home command panel must apply to all no-active-download states, not just truly empty idle. Completed-only Home should look like idle Home plus a compact success strip.
- The corrected no-active Home target is one centered glass command panel containing title/subtitle, dependency pills, large URL editor, Paste/Clear/Extract actions, optional completed/results strips, and four supported platform cards.

## Stitch Design Direction

- Stitch output is useful as design inspiration, especially for Home and modal-first organization, but should not be treated as business logic or an exact implementation source.
- The design direction is "Lustre/Obsidian utility":
  - darker neutral surfaces,
  - subtler borders,
  - reduced glow,
  - calmer semantic status colors,
  - compact typography,
  - cleaner bottom nav active states,
  - less multi-hue decoration.
- Secondary details, setup explanations, dependency commands, results review, queue diagnostics, and metadata-heavy content should move into sheets/popovers over time.
- Primary flows stay inline: paste/extract, queue progress, feed browsing, library selection, and essential settings.

## Packaging

- Active packaging is unsigned and unnotarized only; the signed/notarized release pipeline was intentionally removed for personal local use.
- Use `bash scripts/build-dmg.sh` to build the current app and create `VidDL-<version>-build<build>-unsigned.dmg`.
- The reliable local build path uses the external Xcode developer directory at `/Volumes/MyPassport/Applications/Xcode.app/Contents/Developer`.

## Verification Pattern

Use this validation sequence for UI changes in the native SwiftUI app:

```sh
git diff --check -- <touched files>
xcrun swiftc -parse <focused touched Swift files>
xcrun swiftc -parse $(rg --files PMVDL/PMVDL -g '*.swift')
DEVELOPER_DIR=/Volumes/MyPassport/Applications/Xcode.app/Contents/Developer xcodebuild -project PMVDL/PMVDL.xcodeproj -scheme PMVDL -configuration Debug -derivedDataPath /tmp/<build-dir> CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' build
```

Known recurring warnings are currently unrelated to these UI changes, including warnings in `DropHandler.swift`, `WebViewExtractor.swift`, `LuluStreamExtractor.swift`, `CloudSyncScheduler.swift`, and `ThumbnailCache.swift`.
