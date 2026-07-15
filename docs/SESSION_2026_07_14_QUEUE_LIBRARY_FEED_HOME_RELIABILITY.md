# Queue, Library, Feed, Home, and Reliability

**Date:** 2026-07-14
**Project:** VidDL native macOS app

## Completed product milestones

### Queue and transfer clarity

- Queue rows now retain a compact activity history, expose transfer capacity, and distinguish ready, waiting, active, verification, completed, and failed work.
- Seedbox rows report aggregate direct-stream upload throughput and verify the remote file before completion.
- WebDAV uploads use a larger streaming buffer, cache validated remote directories, and support a Pro-only parallel-transfer preference of five through eight transfers. The expanded limit applies only to WebDAV Seedbox work; other destinations retain the normal queue cap.

### Library organization and verification

- Library items can carry tags and a collection name without breaking existing stored items.
- Added scopes for all items, remote copies, unfiled items, and possible duplicates.
- Added remote-copy verification across local files, Mega, Google Drive, and the configured Seedbox destination.
- Added lightweight organization editing and retained re-extraction as the recovery action.

### Controlled-native Feed

- Feed remains an in-app, supported-site viewer rather than a generic browser.
- The Feed right-click surface keeps selection, extraction, favorites, and Library handoff. Generic external-browser and raw URL-copy actions were removed.
- Library handoff is shown only when the original page is already represented in the local Library index.

### Faster Home extraction

- An empty Home command panel now offers **Paste & Extract**, which pulls a clipboard URL and starts extraction in one action.
- When URLs are already entered, the action remains **Extract**.
- Successful extraction now leads users to **Review Downloads**, while destination choices remain in the existing extraction modal.
- Multi-URL extraction is capped at three concurrent sources. The extractor completes URLs 1-3 before starting 4-6, and reports the active batch plus the completed total without changing result order or per-row error handling.

### Reliability hardening

- Queue work keeps restartable original-page retry payloads and refreshes the source before rerunning.
- Temporary connection, timeout, and retryable HTTP failures automatically retry at most twice: after three seconds, then eight seconds.
- Authentication, configuration, and permanent source failures remain explicit terminal failures.
- Scheduled retry state is persisted, obeys queue capacity after relaunch, and is cancellable by Pause, Cancel, or Start Now.
- Focused queue tests cover retry eligibility and scheduled retry state.

## Validation

- `git diff --check`
- Focused Swift parse for queue, runner, model, and queue-test sources
- Debug build:

  ```sh
  xcodebuild -project PMVDL/PMVDL.xcodeproj -scheme PMVDL -configuration Debug \
    -derivedDataPath /tmp/viddl-reliability-0714 build
  ```

The resulting Debug app is at `/tmp/viddl-reliability-0714/Build/Products/Debug/VidDL.app`.

The broad XCTest run remains outside this session's validation baseline because the existing ProfileNarrativeFormatter test-source issue prevents the test target from compiling.

## Version and local package

- `PMVDL/PMVDL/Info.plist` now targets version `2.2.7`, build `5`.
- The unsigned local package was built from the fresh Debug bundle and verified with `hdiutil verify`:

  ```text
  VidDL-2.2.7-build5-unsigned.dmg
  ```

- The current extraction-batching Debug bundle is `/tmp/viddl-extraction-batches-0714/Build/Products/Debug/VidDL.app`.
