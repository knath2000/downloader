# Session 2026-07-05: Stitch Home Correction

## Summary

The initial Stitch-inspired pass only changed the truly empty Home state. The screenshot review showed the visible Home was a completed-download state, so it still rendered the old hero/status card, old paste card, separate completed summary, and circular source rail. The corrected implementation makes the Stitch command panel the default for all no-active-download Home states.

## Home Behavior

- Active downloads still use the queue-first Home layout.
- No-active-download states now use one centered Stitch-style command panel:
  - empty idle
  - pasted URLs with no active downloads
  - completed-only downloads
  - completed downloads with extraction results
- The old separate `HomeHeroHeader` is no longer shown for no-active states.
- Completed downloads render as an embedded success strip inside the command panel, preserving Open Library, Show Details, and Clear All.
- Results Ready renders inside the same panel instead of becoming another competing external banner.
- Supported sources were changed from the circular icon rail to four larger platform cards: Video Hosts, Audio Streams, Social Media, and Generic Web.

## Implementation Notes

- `HomeView` now branches around active downloads versus no-active downloads instead of treating completed-only as a separate old-layout stack.
- `HomeStitchCommandPanel` owns the no-active command surface, including title, dependency pills, URL editor, actions, supported platform cards, and injected completed/results content.
- `HomeCompactQueue` supports an embedded mode for completed summaries so the success strip can live inside the Stitch panel without adding another outer glass card.
- The behavior and stores were preserved: extraction, paste, drag/drop, keyboard shortcut, queue persistence, completed clearing, and Library navigation are unchanged.

## Verification

```sh
git diff --check -- PMVDL/PMVDL/HomeView.swift PMVDL/PMVDL/Home/HomeURLInputCard.swift PMVDL/PMVDL/Home/HomeCompactQueue.swift
xcrun swiftc -parse PMVDL/PMVDL/HomeView.swift PMVDL/PMVDL/Home/HomeURLInputCard.swift PMVDL/PMVDL/Home/HomeCompactQueue.swift
xcrun swiftc -parse $(rg --files PMVDL/PMVDL -g '*.swift')
DEVELOPER_DIR=/Volumes/MyPassport/Applications/Xcode.app/Contents/Developer xcodebuild -project PMVDL/PMVDL.xcodeproj -scheme PMVDL -configuration Debug -derivedDataPath /tmp/viddl-stitch-home-correction-build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' build
```

Result: Debug build succeeded.
