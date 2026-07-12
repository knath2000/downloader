# Session 2026-07-12: Personal Pro License, Feed Download State, Multi-Destination Transfers, and Menu Bar

## Personal Pro activation

- Replaced the personal-use Stripe/Worker activation path with a local activation-code flow.
- A valid bootstrap or previously rotated code activates Pro on this Mac, rotates to a replacement recovery code, and shows that replacement once for safekeeping.
- The active state and recovery-code hash are stored in Keychain-backed secure storage. Deactivating Pro keeps the code available for later reactivation.

## Feed downloaded state

- Feed browser cards now receive the Library download index and show a green check badge when the matching video has already been downloaded.
- Matching supports normalized source URLs and PornHub view keys so CDN URLs are not mistaken for the original page.

## Multi-destination transfers

- Home and extraction-result controls include a Multiple destination picker for Google Drive and Seedbox.
- Selecting both creates independent queue jobs from the same resolved source. Each destination keeps its own progress, error, retry, and completion state while the existing Pro queue concurrency limit controls parallel execution.

## Persistent menu bar controls

- VidDL now stays resident after its last main window closes and exposes a native macOS menu-bar icon.
- The icon fills while transfers are active. Its menu shows aggregate progress, up to three active transfers, queued and failed counts, pause/resume controls, open-app/downloads actions, and an explicit Quit action.
- Main-window reopening now brings the existing app window forward from the menu-bar flow.

## Version and validation

- `CFBundleShortVersionString` is `2.2.4` with build `5`.
- Verified with `git diff --check`, focused Swift parsing, and an unsigned Debug macOS build using `/Volumes/MyPassport/Applications/Xcode.app/Contents/Developer`.
