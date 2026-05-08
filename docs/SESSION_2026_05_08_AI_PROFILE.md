# Session 2026-05-08: AI Profile, Profile Match, and PornHub Uploader Evidence

## Summary

Built a new AI-powered Profile surface for VidDL that aggregates saved Feed favorites, live PornHub Liked/Favorites data, and Library download history, then sends the evidence to xAI Grok 4.3 for a structured taste profile. Also added a Feed Profile Match sort mode that uses the generated profile to rank current feed videos and explain each match under the card.

The session stopped with one unresolved issue: the new Library uploader backfill path did not catch the repeated PornHub uploader case in user testing. The concrete missed uploader was `niquuiok`.

## Implemented

- Added the Profile tab and UI:
  - `PMVDL/PMVDL/Profile/ProfileView.swift`
  - `PMVDL/PMVDL/Profile/ProfileViewModel.swift`
  - `PMVDL/PMVDL/Profile/XAIClient.swift`
- Registered the new nav destination, route, project sources, and settings entry.
- Added Settings -> AI Profile with `xaiAPIKey` storage and a Generate Profile shortcut.
- Changed profile generation from local semantic counting to a Grok-curated structured JSON response:
  - local app builds `ProfileGenerationInput`
  - Grok returns `narrativeMarkdown`, top performers, categories, tags, studios, and preferred quality
  - sites/domains are excluded from profile stats and Feed matching
- Added Feed `Profile Match` sorting:
  - scores current feed items using `ProfileStats`
  - matches performers both from structured metadata and title text
  - shows zero videos when no items match
  - shows match reasons as subtext under each card
- Removed the green hover Extract button from feed cards because it conflicted with PornHub hover previews.
- Restored PornHub uploader badge/icon click behavior on feed cards.
- Extended PornHub scraping for profile signals:
  - categories
  - tags
  - performers
  - uploader URL and uploader classification hints
- Added Library uploader metadata plumbing:
  - `VideoSource.uploaderURL`
  - `LibraryItem.uploaderName`
  - `LibraryItem.uploaderURL`
  - `LibraryItem.sourceSiteName`
  - CloudKit sync for the new fields
  - Home and DownloadQueue Library insertions preserve uploader metadata from `VideoSource`

## Important Findings

- The profile originally missed repeated PornHub uploaders in Library history because `LibraryItem` only persisted title, URL, media URLs, thumbnail, and timestamp.
- `VideoSource` already had an `uploader` field, and `YtDlpExtractor` parsed `uploader`, but the Library insertion paths dropped it.
- Existing PornHub Library rows therefore reached Grok as title-only evidence.
- The concrete missed case was `niquuiok`.
  - Multiple PornHub Library rows had `yt-dlp` metadata `uploader = niquuiok`.
  - Only one title visibly contained `Niquui`, so title-only inference was insufficient.
- PornHub `yt-dlp` metadata often returns `uploader` without `uploader_url`, so `uploaderName` should be treated as sufficient structured evidence.

## Unresolved Issue

The final attempted fix did not work in user testing. The next investigation should start by proving where the failure is:

1. Confirm the running app is the fresh derived-data build, not an older process.
2. Regenerate the profile once.
3. Inspect `defaults` for `videoLibrary` and check whether PornHub rows now contain `uploaderName = niquuiok`.
4. If Library rows are not updated, trace `ProfileViewModel.backfilledLibraryItems`.
5. If Library rows are updated, inspect the actual `ProfileGenerationInput` payload and confirm `Download History` items include `uploaderName`.
6. If payload is correct, tighten the Grok prompt/schema or add local deterministic uploader frequency as evidence alongside raw items.

## Verification

- `xcodebuild build -project PMVDL/PMVDL.xcodeproj -scheme PMVDL -destination 'platform=macOS' -derivedDataPath /tmp/viddl-profile-derived` passed during the session.
- `git diff --check` passed.
- Fresh debug builds were launched with `open -n /tmp/viddl-profile-derived/Build/Products/Debug/VidDL.app` to avoid killing an existing VidDL process with an upload in progress.
