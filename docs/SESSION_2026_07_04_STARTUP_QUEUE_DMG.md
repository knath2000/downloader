# Session 2026-07-04: Home Queue Detail Work, Launch Deadlock Fix, and Local Unsigned DMG

## Summary

This session continued native VidDL Home queue presentation work, fixed an Xcode launch hang caused by singleton initialization deadlock, and produced a local unsigned, unnotarized DMG from an unsigned Debug build using the external Xcode install at `/Volumes/MyPassport/Applications/Xcode.app`.

## Home Queue Detail Work

- `DownloadStatusFormatting` gained Home-focused presentation helpers for queue rows:
  - `stageLabel(for:)`
  - `transferLocation(for:)`
  - `homeDetailLine(for:)`
  - `failureMessage(for:)`
- `HomeCompactQueueRow` now shows:
  - queue stage chip,
  - destination/location line,
  - richer transfer metrics,
  - inline failure text for failed rows,
  - expanded accessibility/help text.
- Focused tests were added in `PMVDLTests/DownloadQueueProjectionTests.swift` for:
  - remote location formatting,
  - completed final-path display,
  - failure message preference,
  - Home detail formatting behavior.

## Launch Hang Root Cause

- Xcode launch was hanging with `_dispatch_once_wait` during startup.
- The attached stack showed a recursive singleton cycle:
  - `ContentView` eagerly touched `DownloadQueue.shared`,
  - `DownloadQueue` init/save triggered `LibraryPipelineStore.shared.rebuild(...)`,
  - `LibraryPipelineStore` initialization paths reached `VideoLibrary.shared` and `HistoryManager.shared`,
  - those stores called back into `LibraryPipelineStore` during their own `load()` work.
- The deadlock was not a generic SwiftUI issue; it was a startup reentrancy problem between `DownloadQueue`, `VideoLibrary`, `HistoryManager`, and `LibraryPipelineStore`.

## Launch Fix

- `DownloadQueue.init()` no longer performs a full pipeline rebuild when it only needs to persist normalized interrupted items on launch.
- `DownloadQueue.save()` now uses a dedicated queue snapshot persist path plus explicit pipeline rebuild.
- `VideoLibrary.load()` no longer rebuilds pipeline state during singleton initialization.
- `HistoryManager.load()` no longer rebuilds pipeline state during singleton initialization.
- `LibraryPipelineStore` now rebuilds from cached inputs and exposes deferred hydration instead of reaching back into other stores during initialization.
- `VidDLApp` now defers:
  - `LibraryPipelineStore.shared.hydrateFromStores(...)`
  - `SleepPreventionManager.shared.start()`
  - `DownloadQueue.shared.resumeInterruptedOnLaunch(...)`
  until after launch begins settling on the main actor.

## Local DMG Build

- Signed/notarized packaging has been removed from the active project because this app is for personal local use.
- `scripts/build-dmg.sh` is the single supported packaging command and now produces an unsigned, unnotarized local DMG:
  1. `DEVELOPER_DIR=/Volumes/MyPassport/Applications/Xcode.app/Contents/Developer`
  2. unsigned `xcodebuild` Debug build with `CODE_SIGNING_ALLOWED=NO`
  3. `hdiutil create` using a staging folder containing `VidDL.app` and an `Applications` symlink
- The external Xcode app provided a working `xcodebuild`; the shell did not have `xcrun` under that Xcode path.
- Output artifact:
  - `VidDL-<version>-build<build>-unsigned.dmg`

## Validation

- `git diff --check` passed for the launch-fix file set.
- `xcrun swiftc -parse` passed for:
  - `PMVDL/PMVDL/VidDLApp.swift`
  - `PMVDL/PMVDL/DownloadQueue.swift`
  - `PMVDL/PMVDL/VideoLibrary.swift`
  - `PMVDL/PMVDL/History/HistoryManager.swift`
  - `PMVDL/PMVDL/LibraryPipelineStore.swift`
- Unsigned Debug build succeeded with:
  - `DEVELOPER_DIR=/Volumes/MyPassport/Applications/Xcode.app/Contents/Developer xcodebuild -project PMVDL/PMVDL.xcodeproj -scheme PMVDL -configuration Debug -derivedDataPath /tmp/viddl-local-dmg-debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' build`
- The resulting app is unsigned:
  - `codesign -dv /tmp/viddl-local-dmg-debug/Build/Products/Debug/VidDL.app`
  - reported `code object is not signed at all`

## Notes

- The local DMG is intended for direct local use, not distribution.
- Because the app is unsigned and unnotarized, Gatekeeper will treat it as an unidentified developer build.
