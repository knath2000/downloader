# Queue state revamp

## Implemented behavior

- Newly queued resolution and source-page rows remain dormant in `pending` and do not start automatically.
- Explicit `Start All` and per-row `Start Now` actions promote eligible rows into `waiting`.
- `waiting` is the scheduler-owned intermediate state. The runner admits waiting rows only while the configured concurrency limit has capacity, capped at five downloads.
- Paused and failed/retryable rows remain inactive until the user resumes or retries them; those actions promote them to `waiting`.
- Launch rehydration resumes interrupted active work represented by `waiting`, but does not auto-start dormant `pending` rows.
- Queue UI, Home queue, menu-bar counts, pipeline projection, sleep policy, and status formatting all understand `waiting` as distinct from dormant `pending`.

## Key implementation surfaces

- `PMVDL/PMVDL/Models.swift`: added `QueueStatus.waiting`.
- `PMVDL/PMVDL/Downloads/DownloadJobs.swift`: separated dormant queue insertion from scheduler registration and made admission capacity-aware.
- `PMVDL/PMVDL/DownloadQueue.swift`: retries/resumes and interrupted-work normalization use `waiting`; launch rehydration only considers waiting rows.
- `PMVDL/PMVDL/DownloadQueueView.swift` and `PMVDL/PMVDL/Home/HomeCompactQueue.swift`: expose `Start All`, `Start Now`, pause, and waiting-state presentation.

## Validation

External Xcode Debug build succeeded with:

```sh
xcodebuild -project PMVDL/PMVDL.xcodeproj -scheme PMVDL -configuration Debug \
  -derivedDataPath /tmp/pmv-queue-build CODE_SIGNING_ALLOWED=NO build
```

The resulting app was launched from `/tmp/pmv-queue-build/Build/Products/Debug/VidDL.app` for user testing.
