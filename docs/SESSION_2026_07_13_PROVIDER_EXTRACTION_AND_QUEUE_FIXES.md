# Provider extraction and download workflow fixes

## Provider extraction

- AllPornStream provider candidates are resolved through the native provider extractors before they are exposed in the extraction modal.
- A provider that fails extraction or does not produce a concrete media URL is omitted and cannot be downloaded or queued.
- The page's `status_code` metadata is treated as advisory only. It can be stale even when the provider is currently reachable.
- Current aliases used by the page are supported: `mxdrop.to` routes through MixDrop, and `ds2play.com` routes through the Dood/Playmogo extractor.
- Manual provider selection persists the selected URL in `DownloadRetryPayload`. Source refresh matches that URL or its stable provider page URL, preventing fallback to another provider such as StreamTape.
- Extraction failures remain in the extraction modal with their error text and retry action, including the case where every provider fails.

## Queue and download workflow

- Queue scheduling keeps the active-download limit filled when work is available and rehydrates retry payloads from the source page.
- Queued tasks can be paused in bulk with Pause All.
- Seedbox WebDAV password recovery falls back to the Keychain after relaunch so configured connections do not require re-entering the password.

## UI and lifecycle

- Library thumbnail work runs at lower task priority for smoother scrolling, and per-item hover menus were removed in favor of the existing right-click menu.
- Window frame persistence restores the previous window size when the app is reopened.

## Validation

The PMVDL Debug target built successfully with the external Xcode toolchain. The resulting app was launched for manual verification, and the provider extraction fix was confirmed working.

## Startup reliability

- Pending retryable queue rows are rehydrated into the scheduler on launch, and newly queued batch/source-page jobs are registered immediately so available download slots are filled.
- WebDAV startup reconnect waits for credential/license initialization, migrates legacy password storage, and falls back to the legacy value when necessary. A configured WebDAV seedbox therefore does not require opening Settings and re-running Test Connection after launch.

## Release artifact

Version 2.2.6 is packaged as a local unsigned, unnotarized DMG for personal use with `scripts/build-dmg.sh`.
