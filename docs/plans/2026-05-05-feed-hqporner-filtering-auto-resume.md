# HQPorner Feed, Advanced Feed Filtering, and Automatic Transfer Resume Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Add `hqporner.com` as a third Feed source, expand Feed filtering into composable granular filters, and automatically resume interrupted in-progress downloads/transfers after app relaunch without overwriting existing partial/local/seedbox files.

**Architecture:** Keep Feed source scraping isolated behind the existing `FeedScraper` protocol, but add richer `FeedItem` metadata and a reusable `FeedFilterState` so all sources share filtering/sorting behavior. For resume, distinguish three cases: queued work that never started, local partial direct downloads that can resume with HTTP Range, and remote seedbox transfers that must append/continue only when the source and destination support safe byte offsets; otherwise resume by writing to a new temp/final-safe path rather than overwriting a possibly valid partial remote file.

**Tech Stack:** Swift 5/SwiftUI, XCTest, URLSession, rclone, WebDAV, ffmpeg, UserDefaults queue persistence, existing VidDL `DownloadQueue`, `DownloadJobRunner`, `SeedboxManager`, and `Feed` components.

---

## Non-negotiable requirements and safety rules

1. Do not lose or overwrite partially transferred files.
2. On relaunch, `.downloading`, `.verifying`, and `.uploading` items with retry payloads should automatically restart/resume without user action.
3. For direct local downloads, prefer true append/resume using HTTP `Range` when possible.
4. For seedbox direct transfers, only append to an existing remote file when all of these are true:
   - remote size can be discovered,
   - source supports range requests from exactly that byte offset,
   - local retry payload still points at the same resolved media URL/headers,
   - remote size is less than expected total size,
   - existing remote path is the intended destination for the same queue item.
5. If safe append is not possible, do not overwrite. Use a conflict-safe filename such as `name (resumed).mp4` or a `.viddl-resume-<queueId>.part` staging name and only finalize after success.
6. WebDAV `PUT` is not an append API. Use WebDAV append only if the server supports a verified append/range extension. Otherwise use safe new/staging filename.
7. Keep retry/resume credentials secret-free. Continue not persisting Seedbox WebDAV password.
8. Commit existing untracked Feed files before or with this work; the current project references them.

---

## Phase 0: Commit/repro hygiene before coding

### Task 0.1: Capture current build-critical untracked Feed files

**Objective:** Make the repository reproducible before adding more Feed code.

**Files:**
- Add: `PMVDL/PMVDL/Feed/FeedItem.swift`
- Add: `PMVDL/PMVDL/Feed/FeedScraper.swift`
- Add: `PMVDL/PMVDL/Feed/FeedViewModel.swift`
- Add: `PMVDL/PMVDL/Feed/FeedCardView.swift`
- Add: `PMVDL/PMVDL/Feed/FeedView.swift`
- Add: `docs/SESSION_2026_05_05_UI_DOWNLOADS_SETTINGS_PRO.md`

**Steps:**
1. Run `git status --short` and confirm Feed files are untracked.
2. Run `xcodebuild -quiet -project PMVDL/PMVDL.xcodeproj -scheme PMVDL -configuration Debug -derivedDataPath /tmp/viddl-baseline test`.
3. If green, commit the existing WIP or at least stage the Feed files before modifying them further.

**Verification:**
- `git ls-files PMVDL/PMVDL/Feed/FeedView.swift` should print the file path after commit/stage.

---

## Phase 1: Model richer Feed metadata for hqporner and advanced filters

### Task 1.1: Extend `FeedItem` with optional metadata

**Objective:** Add source-agnostic fields needed by hqporner and granular filtering without breaking existing scrapers.

**Files:**
- Modify: `PMVDL/PMVDL/Feed/FeedItem.swift`
- Test: create `PMVDL/PMVDLTests/FeedFilterTests.swift`

**Implementation shape:**

Add optional fields with defaults through an initializer:

```swift
struct FeedItem: Identifiable, Hashable {
    let id: String
    let title: String
    let url: String
    let thumbnailURL: String?
    let uploadDate: Date
    let viewCount: Int
    let siteName: String
    let studio: String?
    let durationSeconds: Int?
    let categories: [String]
    let tags: [String]
    let performers: [String]
    let qualityLabels: [String]
    let sourceKind: FeedSourceKind

    init(
        id: String,
        title: String,
        url: String,
        thumbnailURL: String?,
        uploadDate: Date,
        viewCount: Int,
        siteName: String,
        studio: String?,
        durationSeconds: Int? = nil,
        categories: [String] = [],
        tags: [String] = [],
        performers: [String] = [],
        qualityLabels: [String] = [],
        sourceKind: FeedSourceKind = .siteFeed
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.thumbnailURL = thumbnailURL
        self.uploadDate = uploadDate
        self.viewCount = viewCount
        self.siteName = siteName
        self.studio = studio
        self.durationSeconds = durationSeconds
        self.categories = categories
        self.tags = tags
        self.performers = performers
        self.qualityLabels = qualityLabels
        self.sourceKind = sourceKind
    }
}

enum FeedSourceKind: String, Hashable, CaseIterable, Identifiable {
    case siteFeed
    case linkList
    case searchResults

    var id: String { rawValue }
}
```

**Test cases:**
- Existing minimal constructor path still works.
- Optional arrays default to empty.
- Duration defaults to nil.

**Verification command:**

```sh
xcodebuild -quiet -project PMVDL/PMVDL.xcodeproj -scheme PMVDL -configuration Debug -derivedDataPath /tmp/viddl-feed-model test
```

---

### Task 1.2: Add reusable filter state and filter options

**Objective:** Replace single date-only filtering with composable filters.

**Files:**
- Modify: `PMVDL/PMVDL/Feed/FeedItem.swift`
- Test: `PMVDL/PMVDLTests/FeedFilterTests.swift`

**Implementation shape:**

Add:

```swift
struct FeedFilterState: Equatable {
    var date: FeedDateFilter = .today
    var query: String = ""
    var minViews: Int? = nil
    var minDurationSeconds: Int? = nil
    var maxDurationSeconds: Int? = nil
    var selectedSites: Set<String> = []
    var selectedStudios: Set<String> = []
    var selectedCategories: Set<String> = []
    var selectedTags: Set<String> = []
    var selectedQualityLabels: Set<String> = []
    var requireAllTags: Bool = false

    var isDefault: Bool { /* compare to default */ }
}
```

Add helper:

```swift
extension FeedFilterState {
    func matches(_ item: FeedItem, calendar: Calendar = .current, now: Date = Date()) -> Bool {
        guard date.matches(item.uploadDate, calendar: calendar, now: now) else { return false }
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let haystack = ([item.title, item.siteName, item.studio ?? ""] + item.categories + item.tags + item.performers + item.qualityLabels)
                .joined(separator: " ")
                .lowercased()
            guard haystack.contains(query.lowercased()) else { return false }
        }
        if let minViews, item.viewCount < minViews { return false }
        if let minDurationSeconds, (item.durationSeconds ?? -1) < minDurationSeconds { return false }
        if let maxDurationSeconds, (item.durationSeconds ?? Int.max) > maxDurationSeconds { return false }
        if !selectedSites.isEmpty, !selectedSites.contains(item.siteName) { return false }
        if !selectedStudios.isEmpty, !selectedStudios.contains(item.studio ?? "") { return false }
        if !selectedCategories.isEmpty, selectedCategories.isDisjoint(with: Set(item.categories)) { return false }
        if !selectedQualityLabels.isEmpty, selectedQualityLabels.isDisjoint(with: Set(item.qualityLabels)) { return false }
        if !selectedTags.isEmpty {
            let itemTags = Set(item.tags)
            if requireAllTags {
                guard selectedTags.isSubset(of: itemTags) else { return false }
            } else {
                guard !selectedTags.isDisjoint(with: itemTags) else { return false }
            }
        }
        return true
    }
}
```

**Test cases:**
- query matches title/category/tag/performer/studio.
- min/max duration work.
- min views works.
- site/studio/category/quality filters combine with AND semantics across filter groups.
- tag mode supports ANY and ALL.
- date filtering still works.

---

### Task 1.3: Expand date and sort modes

**Objective:** Add useful date and sort granularity.

**Files:**
- Modify: `PMVDL/PMVDL/Feed/FeedItem.swift`
- Test: `PMVDL/PMVDLTests/FeedFilterTests.swift`

**Date modes to add:**
- today
- yesterday
- last3Days
- thisWeek
- last7Days
- thisMonth
- all

**Sort modes to add:**
- newest
- oldest
- mostViewed
- shortest
- longest
- titleAZ
- siteThenNewest

**Test cases:**
- last3Days excludes day 4.
- last7Days excludes day 8.
- thisMonth is calendar-month based.
- shortest/longest place nil durations last.

---

## Phase 2: Add hqporner.com Feed scraper

### Task 2.1: Add fixture-driven parser tests for hqporner listing cards

**Objective:** Lock down parsing before implementing network fetch.

**Files:**
- Create: `PMVDL/PMVDLTests/HQPornerFeedScraperTests.swift`
- Add fixture string inline in the test, not as a separate fixture file initially.

**Known observed listing shape as of 2026-05-05:**
- Listing URL: `https://hqporner.com/`
- Cards use links like `/hdporn/126118-lets_dare_to_e_more_than_this.html`.
- Thumbnail uses `img id="cover_126118" src="//fastporndelivery.hqporner.com/imgs/..._main.jpg"`.
- Title appears in both image `alt` and `h3.meta-data-title`.
- Duration appears as `span class="icon fa-clock-o meta-data">28m 8s</span>`.
- Pagination likely uses page path/query; verify during implementation with live fetch.

**Test expectations:**
- id: `hqporner-126118`
- title: `let's dare to e more than this`
- url: `https://hqporner.com/hdporn/126118-lets_dare_to_e_more_than_this.html`
- thumbnail: `https://fastporndelivery.hqporner.com/imgs/6/34/72d97dd8f1a94ff_main.jpg`
- durationSeconds: `1688`
- siteName: `hqporner.com`
- qualityLabels includes at least `HD`; if visible markers like `4K`/`60FPS` appear, parse them too.

---

### Task 2.2: Implement `HQPornerFeedScraper`

**Objective:** Fetch and parse hqporner pages behind the existing `FeedScraper` protocol.

**Files:**
- Modify: `PMVDL/PMVDL/Feed/FeedScraper.swift`
- Test: `PMVDL/PMVDLTests/HQPornerFeedScraperTests.swift`

**Implementation notes:**
- Add `struct HQPornerFeedScraper: FeedScraper`.
- `supportedHost = "hqporner.com"`.
- Use Chrome user agent from `NetworkConstants.chromeUserAgent`.
- Use `https://hqporner.com/` for page 1.
- Verify page 2 path live. Likely candidates to test in implementation:
  - `https://hqporner.com/2`
  - `https://hqporner.com/?page=2`
  - pagination links in fetched HTML.
- Prefer parsing the next page URL from pagination markup rather than hardcoding if possible.
- Use protocol-relative URL normalization:

```swift
private static func absoluteURL(_ raw: String, base: URL) -> String? {
    if raw.hasPrefix("//") { return "https:" + raw }
    return URL(string: raw, relativeTo: base)?.absoluteString
}
```

**Parser approach:**
- Split listing into card-ish segments around `<section class="box feature">`.
- Keep only segments containing `/hdporn/`.
- Extract first post link by regex `href="(/hdporn/[^"]+)"`.
- Extract id from `/hdporn/(\d+)-`.
- Extract title from `meta-data-title` anchor first, image alt second.
- Extract thumbnail from `img id="cover_..." src="..."`.
- Extract duration from `fa-clock-o meta-data">...<` using `durationSeconds(from:)`.
- Set `uploadDate` to `Date()` if listing does not expose exact date. If detail pages expose dates cheaply, leave detail fetch out of Phase 1 to avoid N+1 requests.
- Set `viewCount = 0` unless listing exposes views.
- Set `sourceKind = .siteFeed`.

**Important:** hqporner page fetch may require certificate workaround in local CLI because curl saw a self-signed certificate chain. The app should use normal URLSession TLS; do not disable TLS validation in app code. If URLSession fails in-app, document the failure and revisit only with a deliberate security decision.

---

### Task 2.3: Wire hqporner into Feed source selection

**Objective:** Make hqporner selectable in the Feed UI.

**Files:**
- Modify: `PMVDL/PMVDL/Feed/FeedViewModel.swift`
- Modify: `PMVDL/PMVDL/Feed/FeedView.swift`

**Steps:**
1. Add `HQPornerFeedScraper.supportedHost` to the site picker.
2. Add a `case HQPornerFeedScraper.supportedHost` branch in `scraper()`.
3. Confirm pagination is enabled for hqporner unless parser proves it is single-page.
4. Keep rentry pagination disabled after page 1.

**Verification:**
- Select hqporner in Feed.
- Refresh loads cards.
- Click Extract on a card sends the hqporner URL to Home.
- If existing extractors cannot process hqporner detail pages, it should route through `YtDlpExtractor` fallback. If yt-dlp cannot extract hqporner, create a separate extractor plan; do not mix that into this Feed plan unless discovered during validation.

---

## Phase 3: Advanced filtering UI

### Task 3.1: Update `FeedViewModel` to use `FeedFilterState`

**Objective:** Move filtering logic out of `FeedViewModel.filteredItems` into the new reusable filter state.

**Files:**
- Modify: `PMVDL/PMVDL/Feed/FeedViewModel.swift`
- Test: existing/new Feed tests

**Implementation shape:**
- Replace `@Published var dateFilter` with `@Published var filters = FeedFilterState()`.
- Keep temporary computed compatibility if helpful:

```swift
var dateFilter: FeedDateFilter {
    get { filters.date }
    set { filters.date = newValue }
}
```

- `filteredItems` should be:

```swift
let filtered = items.filter { filters.matches($0) }
return sortMode.sort(filtered)
```

- Update pagination cutoff logic to use `filters.date`.

---

### Task 3.2: Add available filter facets from loaded items

**Objective:** Generate filter chips/menus from currently loaded feed metadata.

**Files:**
- Modify: `PMVDL/PMVDL/Feed/FeedViewModel.swift`

**Add computed properties:**
- `availableSites: [String]`
- `availableStudios: [String]`
- `availableCategories: [String]`
- `availableTags: [String]`
- `availableQualityLabels: [String]`
- `activeFilterCount: Int`

**Rules:**
- Sort alphabetically except quality labels, which should use preferred order: 4K, 2160p, 1440p, 1080p, 720p, 60FPS, HD.
- Limit long tag menus initially to top 30 by frequency to avoid huge menus.

---

### Task 3.3: Redesign Feed toolbar into compact filters plus expandable advanced panel

**Objective:** Preserve the current clean toolbar while adding granular combinations.

**Files:**
- Modify: `PMVDL/PMVDL/Feed/FeedView.swift`

**UI design:**
- Top toolbar row:
  - Site picker
  - Search field
  - Date picker
  - Sort picker
  - Filters button with badge, e.g. `Filters (3)`
  - Count badge
  - Refresh
- Advanced filters panel, shown below toolbar when toggled:
  - Min views segmented/menu: Any, 1K+, 10K+, 100K+, 1M+
  - Duration menu: Any, Short < 10m, 10-30m, 30m+, Custom min/max later
  - Quality chips: 4K, 1080p, 720p, 60FPS, HD
  - Site chips if multiple sources are loaded
  - Studio chips
  - Category chips
  - Tag chips with ANY/ALL toggle
  - Clear All button

**YAGNI boundary:** Do not build a full custom query language. Implement composable UI controls backed by `FeedFilterState`.

**Visual verification:**
- Narrow window uses vertical layout and does not clip controls.
- Advanced panel can be collapsed.
- Active filter badge changes immediately.
- Empty state offers Clear Filters.

---

### Task 3.4: Update card display for duration and metadata

**Objective:** Surface the new metadata so filters feel discoverable.

**Files:**
- Modify: `PMVDL/PMVDL/Feed/FeedCardView.swift`

**Add to card:**
- Duration pill if `durationSeconds != nil`.
- Quality pill if `qualityLabels` non-empty.
- Studio/category/tag line, capped to 2-3 chips.
- Continue hiding `0 views` for sources without view counts.

---

## Phase 4: Auto-resume queue semantics after app relaunch

### Task 4.1: Add explicit interrupted state classification

**Objective:** Preserve the fact that a job was interrupted by app termination, not user-paused.

**Files:**
- Modify: `PMVDL/PMVDL/Models.swift`
- Modify: `PMVDL/PMVDL/DownloadQueue.swift`
- Test: `PMVDL/PMVDLTests/DownloadQueueResumeTests.swift`

**Implementation option:**
Add to `QueueStatus`:

```swift
case interrupted
```

or avoid migration risk by reusing `.pending` plus `statusMessage = "Resuming after app restart…"`. Preferred: add `interrupted` only if Codable migration is straightforward.

**Queue init behavior should become:**
- `.downloading`, `.verifying`, `.uploading` with retry payload -> `.pending`, message `Resuming after app restart…`.
- `.downloading`, `.verifying`, `.uploading` without retry payload -> `.failed("Interrupted and cannot resume because retry metadata is missing.")`.
- `.paused` remains paused.
- `.failed` remains failed.
- `.completed` remains completed.

**Test cases:**
- in-progress with retry payload becomes pending/resumable.
- in-progress without payload becomes failed.
- paused remains paused.
- completed remains completed.

---

### Task 4.2: Start pending interrupted jobs automatically after app bootstrap

**Objective:** Actually restart work after relaunch; current code resets some statuses but does not reliably call the runner.

**Files:**
- Modify: `PMVDL/PMVDL/DownloadQueue.swift`
- Modify: `PMVDL/PMVDL/VidDLApp.swift`
- Modify: `PMVDL/PMVDL/Downloads/DownloadJobs.swift` if runner entry point is needed

**Implementation shape:**
- Add a method:

```swift
@MainActor
func resumeInterruptedOnLaunch() {
    let resumable = queue.filter { item in
        item.status == .pending && item.retryPayload != nil && item.statusMessage?.contains("restart") == true
    }
    guard !resumable.isEmpty else { return }
    processNextIfNeeded()
}
```

- Call it after app initialization, preferably in `AppDelegate.applicationDidFinishLaunching` after `LicenseManager.bootstrap()` starts:

```swift
Task { @MainActor in
    DownloadQueue.shared.resumeInterruptedOnLaunch()
}
```

**Important:** Do not resume user-paused rows.

**Test:** Unit test the queue selection logic. Manual integration test by killing app during a seeded direct/local or seedbox test transfer.

---

## Phase 5: True append/resume for local direct downloads

### Task 5.1: Persist partial local path and byte counts

**Objective:** Give local direct downloads enough state to resume with Range.

**Files:**
- Modify: `PMVDL/PMVDL/Models.swift`
- Modify: `PMVDL/PMVDL/Downloads/DirectDownloader.swift`
- Modify: `PMVDL/PMVDL/DownloadQueue.swift`
- Test: `PMVDL/PMVDLTests/DownloadResumeStateTests.swift`

**Add fields to `DownloadQueueItem`:**
- `partialLocalPath: String?`
- `expectedTotalBytes: Int64?`
- `supportsByteRange: Bool?`
- `resumeStrategy: DownloadResumeStrategy?`

**Add enum:**

```swift
enum DownloadResumeStrategy: String, Codable, Equatable {
    case restartSafeNewFile
    case appendLocalRange
    case appendSeedboxRange
    case remoteSafeNewFile
}
```

**Behavior:**
- On direct local download start, compute destination path and store it as `partialLocalPath` before network transfer starts.
- Progress updates should persist `bytesDownloaded` and `totalBytes` often enough to survive termination.

---

### Task 5.2: Replace URLSessionDownloadTask move-at-end with appendable data task for resumable direct downloads

**Objective:** Avoid losing partial data hidden in URLSession temp files.

**Files:**
- Modify: `PMVDL/PMVDL/Downloads/DirectDownloader.swift`
- Test: add focused tests around request construction and append policy. Avoid brittle live-network tests.

**Implementation approach:**
- For queue-backed direct downloads, use `URLSessionDataTask` or async bytes to write chunks directly to a destination file.
- If destination exists and has size > 0, send:

```http
Range: bytes=<existingSize>-
```

- If response is 206 Partial Content, append to file.
- If response is 200 OK despite Range request, do not overwrite. Choose a safe new filename and restart there.
- If existing size equals expected total, verify and complete.
- If existing size > expected total, choose a safe new filename.

**Safety:** Never call `removeItem(at: destURL)` during resume. Current code removes destination before moving URLSession temp file; that must not be used for resumable queue downloads.

---

## Phase 6: Safe seedbox resume/append

### Task 6.1: Add remote stat helpers for seedbox destinations

**Objective:** Determine whether an existing remote partial file can be appended to safely.

**Files:**
- Modify: `PMVDL/PMVDL/SeedboxManager.swift`
- Test: `PMVDL/PMVDLTests/SeedboxResumePolicyTests.swift`

**Add helpers:**
- `remoteSize(filename:) async throws -> Int64?`
- rclone mode: use `rclone size --json remote:path/file` or `rclone lsf --format sp remote:path`.
- WebDAV mode: use `HEAD` against destination URL and read `Content-Length`.

**Test with mocked command runner if possible:**
- rclone JSON size parses.
- WebDAV HEAD 200 parses content length.
- missing remote returns nil.

---

### Task 6.2: Add source range validation helper

**Objective:** Confirm source supports resuming from the remote byte offset before appending.

**Files:**
- Modify: `PMVDL/PMVDL/SeedboxManager.swift`
- Test: `PMVDL/PMVDLTests/SeedboxResumePolicyTests.swift`

**Helper behavior:**
- Send `GET` or `HEAD` with `Range: bytes=<offset>-<offset>`.
- Accept only `206 Partial Content` with a `Content-Range` starting at the requested offset.
- If source rejects range or returns `200`, do not append.

---

### Task 6.3: Implement rclone append resume for direct seedbox transfers only

**Objective:** Continue a remote partial file without overwriting when safe.

**Files:**
- Modify: `PMVDL/PMVDL/SeedboxManager.swift`
- Modify: `PMVDL/PMVDL/Downloads/DownloadJobs.swift`

**Approach for rclone remotes:**
- Existing direct seedbox path uses `rclone rcat destination`, which overwrites/replaces the destination stream.
- To append, do not use bare `rcat destination` against an existing partial file unless rclone guarantees append for that remote, which it generally does not.
- Safer implementation:
  1. If remote partial exists and source supports Range, stream the remaining bytes into a local temp part file or remote temp object named `.viddl-resume-<queueId>-tail.part`.
  2. If the remote shell supports server-side concat, use it only if verified. Most generic rclone remotes do not.
  3. Practical YAGNI v1: for rclone seedbox, use safe new filename on restart unless a local partial exists. This avoids overwrite and is correct.

**Recommended v1 behavior:**
- For seedbox rclone direct transfers interrupted mid-stream:
  - detect existing remote size;
  - if existing remote is partial, leave it in place;
  - restart to `filename.resumed.<shortQueueId>.mp4` or `filename (resumed).mp4`;
  - record status message: `Existing partial found; resumed to a new file to avoid overwrite.`

**Recommended v2 behavior after v1 is stable:**
- Add true append only for WebDAV servers or remotes where append/concat capability is explicitly detected.

**Why:** Generic remote append with rclone is not universally safe. Correctness beats pretending to resume while corrupting remote files.

---

### Task 6.4: Implement WebDAV safe resume policy

**Objective:** Avoid overwriting WebDAV partials and only append when explicitly supported.

**Files:**
- Modify: `PMVDL/PMVDL/SeedboxManager.swift`

**V1 behavior:**
- On relaunch with existing WebDAV destination:
  - HEAD destination.
  - If absent, upload normally.
  - If present and incomplete, do not overwrite. Use safe new filename.
  - If complete, mark completed after optional verification.
- Do not use PUT to same URL for resume; PUT overwrites.

**Optional future V2:**
- Add support for server-specific append extensions only after identifying the exact seedbox WebDAV implementation.

---

### Task 6.5: Update user-facing queue messages for resume decisions

**Objective:** Make resume behavior understandable.

**Files:**
- Modify: `PMVDL/PMVDL/DownloadQueueView.swift`
- Modify: `PMVDL/PMVDL/Downloads/DownloadJobs.swift`

**Messages:**
- `Resuming after app restart…`
- `Appending local partial… 42%`
- `Existing seedbox partial found; continuing to a safe new file…`
- `Remote file already complete.`
- `Cannot safely append; restarting without overwriting existing partial.`

---

## Phase 7: Integration and validation

### Task 7.1: Add tests for hqporner and filters

**Command:**

```sh
xcodebuild -quiet \
  -project PMVDL/PMVDL.xcodeproj \
  -scheme PMVDL \
  -configuration Debug \
  -derivedDataPath /tmp/viddl-feed-hqporner-tests \
  test
```

**Expected:** PASS with new tests covering:
- hqporner card parsing,
- URL normalization,
- duration parsing,
- filter combinations,
- sort modes.

---

### Task 7.2: Add tests for resume policy

**Command:**

```sh
xcodebuild -quiet \
  -project PMVDL/PMVDL.xcodeproj \
  -scheme PMVDL \
  -configuration Debug \
  -derivedDataPath /tmp/viddl-resume-tests \
  test
```

**Expected:** PASS with tests covering:
- interrupted queue status migration,
- auto-resume candidate selection,
- paused rows not auto-resumed,
- local Range request construction,
- seedbox remote-size parse,
- seedbox safe-new-file fallback.

---

### Task 7.3: Manual QA for Feed

**Steps:**
1. Build fresh app:

```sh
xcodebuild -quiet -project PMVDL/PMVDL.xcodeproj -scheme PMVDL -configuration Debug -derivedDataPath /tmp/viddl-feed-hqporner build
open -n /tmp/viddl-feed-hqporner/Build/Products/Debug/VidDL.app
```

2. Open Feed.
3. Select `hqporner.com`.
4. Confirm cards load with title, thumbnail, duration.
5. Try filters:
   - search title text,
   - duration < 10m,
   - duration 10-30m,
   - quality HD/4K if available,
   - tag ANY and ALL where tags exist,
   - combine site + duration + search.
6. Click Extract on an hqporner item and confirm Home receives the URL.

---

### Task 7.4: Manual QA for auto-resume

**Local direct resume:**
1. Start a large direct local download.
2. Force quit app mid-download.
3. Reopen app from fresh derived-data bundle.
4. Confirm the queue row moves to pending/downloading automatically.
5. Confirm file grows from existing partial size, not from zero.
6. Confirm completed file verifies.

**Seedbox safe resume:**
1. Start a large direct seedbox transfer.
2. Force quit app mid-transfer.
3. Reopen app.
4. Confirm row auto-starts.
5. Confirm existing remote partial is not overwritten.
6. Confirm behavior is one of:
   - true append only if explicitly implemented and verified; or
   - safe new resumed filename is created and queue explains why.

**Paused control:**
1. Start a download.
2. Press Pause.
3. Quit and reopen.
4. Confirm it remains paused and does not auto-resume.

---

## Suggested commit sequence

1. `chore: commit existing feed work`
2. `test: add feed filter coverage`
3. `feat: add rich feed filter model`
4. `feat: add hqporner feed scraper`
5. `feat: add advanced feed filters UI`
6. `test: add download resume policy coverage`
7. `feat: auto-resume interrupted queue items on launch`
8. `feat: resume local direct downloads with byte ranges`
9. `feat: protect seedbox resume from overwriting partial files`
10. `docs: document feed and resume behavior`

---

## Open questions to resolve during implementation

1. hqporner pagination URL shape must be verified from live HTML pagination links.
2. Whether hqporner detail pages extract through existing `YtDlpExtractor`. If not, plan a separate native extractor or yt-dlp handling fix.
3. Exact seedbox backend capabilities. Generic rclone/WebDAV should default to safe non-overwrite behavior; true append needs capability proof.
4. Whether to add `QueueStatus.interrupted` or preserve Codable compatibility with `.pending` + status message.

---

## Final verification checklist

Run:

```sh
git diff --check
python3 viddl.py --help
xcodebuild -quiet -project PMVDL/PMVDL.xcodeproj -scheme PMVDL -configuration Debug -derivedDataPath /tmp/viddl-final-feed-resume test
```

Expected:
- No whitespace errors.
- CLI help still works.
- Full test suite passes.
- Manual Feed QA passes for all three sources.
- Manual interrupted local download resumes or safely restarts without overwrite.
- Manual interrupted seedbox transfer auto-restarts and never overwrites the existing remote partial.
