# Session 2026-07-05: Stitch Extraction Modal

## Summary

The Home extraction results sheet was redesigned into a Stitch-style modal command panel. The behavior is unchanged: Home extraction still opens the modal, results still persist to Library/History, per-result download/send actions use the same `startDownload` path, retry still uses the same retry path, and batch download still uses the existing batch flow.

## Implementation

- Added `Home/ExtractionModalView.swift`.
- Replaced the old `Extraction Results` sheet body in `HomeView` with `ExtractionModalView`.
- Added `ExtractionModalView.swift` to the Xcode target in `PMVDL.xcodeproj`.
- Added an in-modal Add URL field that validates one URL, appends it to Home URL text, and extracts that additional URL without clearing existing results.
- Restyled extraction results as large media rows with thumbnail, title, status badge, progress line, quality picker, destination picker, primary download action, and copy action.
- Failed rows remain visible with error text and Retry.
- Loading state uses the same modal shell with placeholder rows.

## Verification

```sh
git diff --check -- PMVDL/PMVDL/HomeView.swift PMVDL/PMVDL/Home/ExtractionModalView.swift PMVDL/PMVDL.xcodeproj/project.pbxproj
xcrun swiftc -parse PMVDL/PMVDL/HomeView.swift PMVDL/PMVDL/Home/ExtractionModalView.swift PMVDL/PMVDL/Home/VideoResultPresentation.swift PMVDL/PMVDL/Home/BatchDownloadBar.swift PMVDL/PMVDL/Home/HomeURLInputModel.swift PMVDL/PMVDL/Home/VideoResultCard.swift
xcrun swiftc -parse $(rg --files PMVDL/PMVDL -g '*.swift')
DEVELOPER_DIR=/Volumes/MyPassport/Applications/Xcode.app/Contents/Developer xcodebuild -project PMVDL/PMVDL.xcodeproj -scheme PMVDL -configuration Debug -derivedDataPath /tmp/viddl-extraction-modal-build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' build
```

Result: Debug build succeeded.
