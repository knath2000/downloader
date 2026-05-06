# Feed Layout, Styling, and UI/UX Improvement Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Redesign the VidDL Feed page so it feels cleaner, more premium, more scannable, and easier to filter without losing the existing colorful glass marketplace identity.

**Architecture:** Keep the existing Feed data/model/scraper work intact. Refactor the Feed presentation into small SwiftUI components: a compact hero/header, a responsive filter bar, active filter chips, a better content grid, and richer video cards. Add pure layout/presentation helpers where possible so visual behavior can be tested without fragile screenshot tests.

**Tech Stack:** SwiftUI/macOS, existing `Theme`, `GlassComponents`, `FeedView`, `FeedCardView`, `FeedViewModel`, XCTest, Xcode scheme `PMVDL`.

---

## Screenshot diagnosis

From the attached Feed screenshot, the page is already functional and visually interesting, but it has several UX/layout problems:

1. Filter area consumes too much vertical space.
   - The large glass filter card takes nearly a quarter of the visible content height.
   - Controls are split across awkward rows with unused empty space.
   - The refresh button is visually stranded at the far lower-right of the filter card.

2. Visual hierarchy is unclear.
   - The system navigation title says only `Feed`, but the page itself does not have a strong in-content header explaining source, loaded count, and status.
   - Count badge `43 / 56` is useful but visually disconnected from the filtering controls.
   - The day header floats far below the filter panel, increasing perceived clutter.

3. Cards are attractive but too heavy.
   - The card border/glass effect is repeated strongly on every item, competing with thumbnails.
   - Titles are large and bold, producing dense text blocks and frequent truncation.
   - Metadata is too subtle compared with title weight.
   - Studio/source badges are bright and inconsistent in placement/weight, drawing attention away from thumbnails.

4. Grid rhythm can be improved.
   - Cards are close to the left edge relative to the oversized filter panel.
   - Adaptive minimum width of 240 makes many cards fit, but it creates a very busy wall of content on wide screens.
   - There is no explicit max content width or responsive column policy.

5. Filtering UX needs a better progressive disclosure model.
   - Basic filters should be fast and compact.
   - Advanced filters should feel like an expandable drawer, not part of the default visual weight.
   - Active filters should appear as removable chips so users can see why the feed count changed.

6. macOS polish opportunities.
   - Use `safeAreaInset`/sticky header behavior so filters stay accessible while scrolling.
   - Use keyboard shortcuts for refresh/search focus.
   - Add clearer hover/focus states and accessibility labels.
   - Respect reduced motion for hover scaling and transitions.

---

## Design direction

Target style: premium dark media browser, not a form-heavy settings page.

Keep:
- dark mesh/glass background,
- lavender Feed accent,
- colorful source/studio accents,
- responsive cards,
- hover-to-extract behavior,
- current filter capabilities.

Change:
- compress the top filter card,
- group controls by task,
- reduce borders/shadows on repeated cards,
- improve card typography and metadata hierarchy,
- add active filter chips,
- make grid spacing and columns intentional,
- add a proper loading/skeleton/empty/error visual language.

---

## Acceptance criteria

Visual acceptance:
1. At the screenshot window size, the filter/header area should be at least 35-45% shorter than the current design when advanced filters are collapsed.
2. Refresh should sit with the page/header actions, not stranded in empty space.
3. Cards should show thumbnails first, with title/metadata secondary.
4. Titles should be readable with less visual shouting.
5. The grid should feel evenly spaced and not crowded.
6. Active filters should be visible as chips and removable individually.
7. Empty/loading/error states should visually match the page design.
8. Layout should work at three widths:
   - narrow: around 900 pt detail width,
   - medium: around 1200-1500 pt,
   - wide: 1800+ pt.

Functional acceptance:
1. Existing feed loading, refresh, pagination, sorting, searching, and filtering continue working.
2. Clicking a card still extracts the URL and routes to Home.
3. Context menu actions still work.
4. Advanced filters remain accessible.
5. Reduced-motion users do not get hover scaling/animated transitions.
6. Full test suite still passes.

---

## Phase 0: Baseline safety and current state capture

### Task 0.1: Capture repo state before UI refactor

**Objective:** Avoid mixing the Feed UI refactor with unrelated WIP.

**Files:**
- Inspect only.

**Steps:**
1. Run:

```sh
git status --short
```

2. Confirm which Feed changes are already present.
3. If there are unrelated changes, do not modify them.

**Expected:** You understand whether the current advanced filter/hqporner work is committed, staged, or untracked.

---

### Task 0.2: Run baseline build/test

**Objective:** Prove the app is healthy before visual changes.

**Command:**

```sh
xcodebuild -quiet \
  -project PMVDL/PMVDL.xcodeproj \
  -scheme PMVDL \
  -configuration Debug \
  -derivedDataPath /tmp/viddl-feed-ui-baseline-derived \
  test
```

**Expected:** PASS. Existing macOS/Xcode warnings are acceptable if no test failures occur.

---

## Phase 1: Add layout constants and presentation helpers

### Task 1.1: Add local Feed layout tokens

**Objective:** Stop scattering magic spacing/card sizes through `FeedView.swift` and `FeedCardView.swift`.

**Files:**
- Modify: `PMVDL/PMVDL/Feed/FeedView.swift`
- Modify: `PMVDL/PMVDL/Feed/FeedCardView.swift`

**Implementation:**
Add a private enum near the top of `FeedView.swift`:

```swift
private enum FeedLayout {
    static let contentMaxWidth: CGFloat = 1760
    static let outerSpacing: CGFloat = 16
    static let sectionSpacing: CGFloat = 18
    static let toolbarCornerRadius: CGFloat = 18
    static let cardCornerRadius: CGFloat = 16
    static let cardMinWidth: CGFloat = 285
    static let cardIdealWidth: CGFloat = 320
    static let gridSpacing: CGFloat = 18
    static let compactControlHeight: CGFloat = 34
    static let headerHeight: CGFloat = 58
}
```

Add a matching private card enum in `FeedCardView.swift`:

```swift
private enum FeedCardLayout {
    static let cornerRadius: CGFloat = 16
    static let thumbnailRadius: CGFloat = 13
    static let padding: CGFloat = 10
    static let titleFontSize: CGFloat = 13
    static let titleLineLimit = 2
}
```

**Verification:**
- Build succeeds.
- No visual change required yet.

---

### Task 1.2: Add pure layout column helper

**Objective:** Make the grid responsive intentionally rather than relying only on `GridItem(.adaptive(minimum: 240))`.

**Files:**
- Modify: `PMVDL/PMVDL/Feed/FeedView.swift`
- Test: create or modify `PMVDL/PMVDLTests/FeedLayoutTests.swift`

**Implementation:**
Add a small pure helper:

```swift
struct FeedGridLayout: Equatable {
    let availableWidth: CGFloat

    var columnMinWidth: CGFloat {
        switch availableWidth {
        case ..<980: return 260
        case ..<1350: return 285
        case ..<1700: return 305
        default: return 320
        }
    }

    var spacing: CGFloat {
        availableWidth < 980 ? 12 : 18
    }
}
```

If `CGFloat` tests are annoying in XCTest, put this in a tiny internal helper file:

- Create: `PMVDL/PMVDL/Feed/FeedLayout.swift`

and add it to the app target.

**Tests:**

```swift
func testFeedGridLayoutUsesWiderCardsOnLargeScreens() {
    XCTAssertEqual(FeedGridLayout(availableWidth: 900).columnMinWidth, 260)
    XCTAssertEqual(FeedGridLayout(availableWidth: 1500).columnMinWidth, 305)
    XCTAssertEqual(FeedGridLayout(availableWidth: 1900).columnMinWidth, 320)
}
```

**Verification command:**

```sh
xcodebuild -quiet -project PMVDL/PMVDL.xcodeproj -scheme PMVDL -configuration Debug -derivedDataPath /tmp/viddl-feed-layout-tests test
```

---

## Phase 2: Replace the oversized filter slab with a compact page header

### Task 2.1: Create `FeedPageHeader`

**Objective:** Give the page a clear in-content header with source, count, refresh, and loading status.

**Files:**
- Modify: `PMVDL/PMVDL/Feed/FeedView.swift`

**Implementation:**
Add a private component:

```swift
private struct FeedPageHeader: View {
    let selectedSite: String
    let visibleCount: Int
    let totalCount: Int
    let isLoading: Bool
    let refreshAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(Theme.lavender)
                    Text("Feed")
                        .font(.system(.title2, design: .rounded).weight(.black))
                        .foregroundStyle(Theme.textPrimary)
                }

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            FeedCountBadge(count: visibleCount, total: totalCount)

            Button(action: refreshAction) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.75)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.lavender)
            .controlSize(.small)
            .disabled(isLoading)
            .keyboardShortcut("r", modifiers: [.command])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassCard(tint: Theme.lavender.opacity(0.14), cornerRadius: FeedLayout.toolbarCornerRadius)
    }

    private var subtitle: String {
        let countText = totalCount == visibleCount ? "\(totalCount) videos" : "\(visibleCount) of \(totalCount) videos"
        return "\(selectedSite) · \(countText)"
    }
}
```

**Then:** Remove refresh/count from `FeedToolbar` or pass them only to `FeedPageHeader`.

**Why:** The screenshot currently has count and refresh trapped inside the filter panel. This makes the filter panel too tall and visually odd.

---

### Task 2.2: Split `FeedToolbar` into basic controls only

**Objective:** Make the default collapsed filter row compact and focused.

**Files:**
- Modify: `PMVDL/PMVDL/Feed/FeedView.swift`

**Change FeedToolbar inputs:**
Remove from `FeedToolbar`:
- `visibleCount`
- `totalCount`
- `isLoading`
- `refreshAction`

Keep:
- selected site
- search
- date
- sort
- advanced filters toggle
- clear filters

**New collapsed layout:**

```swift
private var horizontal: some View {
    HStack(spacing: 10) {
        sitePicker
            .layoutPriority(2)
        searchField
            .layoutPriority(3)
        datePicker
        sortPicker
        filterToggle
        clearButton
    }
}
```

**Style:**
- Reduce vertical padding from 10 to 8.
- Reduce glass tint opacity slightly.
- Use corner radius 16-18.
- Avoid large blank areas.

**Expected visual result:** The toolbar is one tidy row under the page header, not a large empty panel.

---

### Task 2.3: Add active filter chips row

**Objective:** Make filter state visible and removable without opening Advanced Filters.

**Files:**
- Modify: `PMVDL/PMVDL/Feed/FeedView.swift`
- Modify: `PMVDL/PMVDL/Feed/FeedItem.swift` only if helper names are needed

**Implementation:**
Add to `FeedFilterState`:

```swift
struct FeedActiveFilterChip: Identifiable, Equatable {
    let id: String
    let title: String
}

extension FeedFilterState {
    var activeChips: [FeedActiveFilterChip] {
        var chips: [FeedActiveFilterChip] = []
        if date != .today { chips.append(.init(id: "date", title: date.title)) }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { chips.append(.init(id: "query", title: "Search: \(q)")) }
        if let minViews { chips.append(.init(id: "views", title: "\(FeedDisplay.viewCount(minViews))+")) }
        if minDurationSeconds != nil || maxDurationSeconds != nil { chips.append(.init(id: "duration", title: durationChipTitle)) }
        chips.append(contentsOf: selectedQualityLabels.sorted().map { .init(id: "quality:\($0)", title: $0) })
        chips.append(contentsOf: selectedStudios.sorted().map { .init(id: "studio:\($0)", title: $0) })
        chips.append(contentsOf: selectedCategories.sorted().map { .init(id: "category:\($0)", title: $0) })
        chips.append(contentsOf: selectedTags.sorted().map { .init(id: "tag:\($0)", title: "#\($0)") })
        return chips
    }
}
```

Add a removal method to `FeedViewModel` or `FeedFilterState`:

```swift
func removeFilterChip(id: String) {
    // switch on prefixes and remove the matching filter
}
```

**UI:**
Create:

```swift
private struct FeedActiveFiltersRow: View {
    let chips: [FeedActiveFilterChip]
    let remove: (String) -> Void
    let clearAll: () -> Void
    // horizontal ScrollView of pill buttons with xmark
}
```

Show this row only when `!filters.activeChips.isEmpty`.

**Test:**
- Add tests for `activeChips` and chip removal mapping.

---

## Phase 3: Improve the main content layout

### Task 3.1: Cap content width and center the feed area

**Objective:** Prevent the page from feeling stretched at very wide macOS window sizes.

**Files:**
- Modify: `PMVDL/PMVDL/Feed/FeedView.swift`

**Implementation:**
Wrap the main Feed body in a content container:

```swift
var body: some View {
    GeometryReader { geometry in
        ScrollViewReader { _ in
            VStack(spacing: FeedLayout.outerSpacing) {
                FeedPageHeader(...)
                FeedToolbar(...)
                if !model.filters.activeChips.isEmpty { FeedActiveFiltersRow(...) }
                content(availableWidth: min(geometry.size.width, FeedLayout.contentMaxWidth))
            }
            .frame(maxWidth: FeedLayout.contentMaxWidth, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
    .task { await model.loadInitial() }
}
```

If nesting a `ScrollView` inside this creates issues, keep only the existing content `ScrollView` and cap widths inside its content.

**Acceptance:** On wide windows, content remains centered and does not sprawl endlessly.

---

### Task 3.2: Use `GeometryReader` for grid columns

**Objective:** Make card width/spacing adapt smoothly to window size.

**Files:**
- Modify: `PMVDL/PMVDL/Feed/FeedView.swift`

**Implementation idea:**

```swift
private func gridColumns(for width: CGFloat) -> [GridItem] {
    let layout = FeedGridLayout(availableWidth: width)
    return [GridItem(.adaptive(minimum: layout.columnMinWidth), spacing: layout.spacing)]
}
```

Use in content:

```swift
GeometryReader { proxy in
    let width = min(proxy.size.width, FeedLayout.contentMaxWidth)
    LazyVGrid(
        columns: gridColumns(for: width),
        alignment: .leading,
        spacing: FeedGridLayout(availableWidth: width).spacing
    ) { ... }
}
```

If `GeometryReader` inside `ScrollView` causes zero-height behavior, use a lightweight `ViewThatFits` with fixed breakpoints instead.

**Acceptance:**
- Narrow: 2-3 columns depending width.
- Medium: 3-4 columns.
- Wide: 4-5 larger cards, not a tiny-card wall.

---

### Task 3.3: Tighten section/day header spacing

**Objective:** Reduce the floating day badge gap visible in the screenshot.

**Files:**
- Modify: `PMVDL/PMVDL/Feed/FeedView.swift`

**Changes:**
- Change `LazyVStack` section spacing from 18 to 14.
- Make `FeedDayHeader` more subtle and full-row aligned.
- Use top padding 0 after the toolbar/active chips.

**New `FeedDayHeader` style:**

```swift
private struct FeedDayHeader: View {
    let date: Date
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Label("\(FeedDisplay.dayLabel(for: date))", systemImage: "calendar")
                .font(.caption.weight(.bold))
            Text("\(count) videos")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            Rectangle()
                .fill(Theme.lavender.opacity(0.18))
                .frame(height: 1)
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(.vertical, 4)
        .background(.clear)
    }
}
```

**Acceptance:** Day grouping still exists but no longer looks like a separate floating control.

---

## Phase 4: Redesign cards for scanability

### Task 4.1: Reduce repeated card chrome

**Objective:** Make thumbnails/content the focus, not borders and shadows.

**Files:**
- Modify: `PMVDL/PMVDL/Feed/FeedCardView.swift`

**Changes:**
- Use a subtler background than current `glassCard(tint: Theme.lavender.opacity(0.18))`.
- Reduce shadow intensity for every card.
- Add stronger hover border only when hovered.

**Implementation option:** Replace direct `.glassCard` with a local card background:

```swift
.background(
    RoundedRectangle(cornerRadius: FeedCardLayout.cornerRadius)
        .fill(.ultraThinMaterial.opacity(0.75))
        .overlay(
            RoundedRectangle(cornerRadius: FeedCardLayout.cornerRadius)
                .fill(tint.opacity(isHovered ? 0.16 : 0.08))
        )
)
.overlay(
    RoundedRectangle(cornerRadius: FeedCardLayout.cornerRadius)
        .strokeBorder(
            isHovered ? tint.opacity(0.55) : .white.opacity(0.12),
            lineWidth: isHovered ? 1.2 : 0.8
        )
)
.shadow(color: .black.opacity(isHovered ? 0.38 : 0.22), radius: isHovered ? 16 : 8, x: 0, y: isHovered ? 8 : 4)
```

**Acceptance:** The grid feels calmer while hover still gives clear affordance.

---

### Task 4.2: Improve card typography hierarchy

**Objective:** Make titles readable without dominating the thumbnail grid.

**Files:**
- Modify: `PMVDL/PMVDL/Feed/FeedCardView.swift`

**Changes:**
- Title:
  - Use `.font(.system(size: 12.5 or 13, weight: .semibold))` instead of heavy bold.
  - Keep 2 lines.
  - Use tighter line spacing if needed.
- Metadata:
  - Add icons for views/time/duration if present.
  - Increase contrast slightly from `Theme.textSecondary` to `Theme.textSecondary.opacity(0.95)` or a mixed color.
- Chips:
  - Move duration into thumbnail bottom-left overlay instead of text metadata chips.
  - Keep only 1-2 category/quality chips below title.

**Implementation:**
- Add `durationOverlay` inside `thumbnailArea` at `.bottomLeading`.
- Keep studio badge at `.topTrailing`, but reduce size/opacity.

**Acceptance:** A user can scan thumbnails first, then title, then metadata.

---

### Task 4.3: Add persistent quick action affordance on hover/focus

**Objective:** Make it clearer that card click extracts, without requiring discovery.

**Files:**
- Modify: `PMVDL/PMVDL/Feed/FeedCardView.swift`

**Current:** Hover overlay with `Extract` at the bottom.

**Improve:**
- Use a top-left or centered overlay button with a translucent dark scrim only on hover.
- Add secondary tiny icons for Copy/Open in context menu only; do not clutter card.
- Add `.focusable()` and keyboard `Return` extraction if feasible.

**Implementation:**
```swift
.onTapGesture(perform: extract)
.accessibilityAction(named: "Extract", extract)
```

Optionally:
```swift
.focusable()
.onKeyPress(.return) { extract(); return .handled }
```
Only use `onKeyPress` if supported by the deployment target.

---

### Task 4.4: Make source/studio colors more consistent

**Objective:** Reduce random neon noise while retaining source identification.

**Files:**
- Modify: `PMVDL/PMVDL/Feed/FeedCardView.swift`

**Current:** `FeedStudioTint` picks from many bright colors based on hash.

**Change:**
- Use site/source color as main card accent.
- Use studio label as text inside a neutral/translucent pill, with a small color dot.
- Keep random tint only if it is important for visual variety, but lower opacity.

**Implementation option:**
```swift
private var studioBadge: some View {
    HStack(spacing: 5) {
        Circle().fill(tint).frame(width: 6, height: 6)
        Text(studio)
    }
    .font(.system(size: 9, weight: .bold, design: .rounded))
    .foregroundStyle(.white)
    .padding(.horizontal, 7)
    .padding(.vertical, 4)
    .background(.black.opacity(0.36), in: Capsule())
}
```

**Acceptance:** Badges identify source but do not overpower thumbnails.

---

## Phase 5: Redesign advanced filters as a drawer

### Task 5.1: Make Advanced Filters visually separate and lighter

**Objective:** Advanced filters should feel optional, not part of the primary page mass.

**Files:**
- Modify: `PMVDL/PMVDL/Feed/FeedView.swift`

**Changes:**
- Give `FeedAdvancedFilterPanel` a separate card/drawer background below the toolbar.
- Use `DisclosureGroup`-like header or animated panel with title `Advanced filters` and a one-line summary.
- Avoid nesting too many glass/capsule controls with equal visual weight.

**Implementation:**
```swift
FeedAdvancedFilterPanel(...)
    .padding(12)
    .background(Theme.surface1.opacity(0.34), in: RoundedRectangle(cornerRadius: 16))
    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.lavender.opacity(0.16), lineWidth: 0.8))
```

**Acceptance:** Opening advanced filters should expand a tidy drawer, not recreate the large slab from the screenshot.

---

### Task 5.2: Group advanced filters into sections

**Objective:** Make the filter panel easier to parse.

**Files:**
- Modify: `PMVDL/PMVDL/Feed/FeedView.swift`

**Groups:**
1. Metrics:
   - views
   - duration
2. Source metadata:
   - quality
   - studio
3. Discovery:
   - category
   - tags
   - ANY/ALL toggle for selected tags

**Implementation:**
Create small local component:

```swift
private struct FeedFilterSection<Content: View>: View {
    let title: String
    let icon: String
    let content: Content

    init(_ title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
            content
        }
    }
}
```

**Acceptance:** Users can find filters by mental category, not by a long sequence of rows.

---

### Task 5.3: Improve chip overflow behavior

**Objective:** Prevent long chip rows from becoming hidden horizontal strips.

**Files:**
- Modify: `PMVDL/PMVDL/Feed/FeedView.swift`

**Change:**
- For advanced filters, use `LazyVGrid` with adaptive chips instead of horizontal scroll where possible.
- Use a `Show more` affordance if there are more than the limit.

**YAGNI v1:** Keep the existing limit, but show `+N more` disabled chip so users know additional values exist.

**Example:**
```swift
if values.count > limit {
    Text("+\(values.count - limit) more")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Theme.surface2.opacity(0.55), in: Capsule())
}
```

---

## Phase 6: Improve loading, empty, and error states

### Task 6.1: Replace plain loading with skeleton grid

**Objective:** Make loading feel like the Feed page, not a generic spinner.

**Files:**
- Modify: `PMVDL/PMVDL/Feed/FeedView.swift`

**Implementation:**
Create:

```swift
private struct FeedSkeletonGrid: View {
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 285), spacing: 18)], spacing: 18) {
            ForEach(0..<8, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 13)
                        .fill(.white.opacity(0.08))
                        .aspectRatio(16/9, contentMode: .fit)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.white.opacity(0.08))
                        .frame(height: 12)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.white.opacity(0.05))
                        .frame(width: 120, height: 10)
                }
                .padding(10)
                .glassCard(tint: Theme.lavender.opacity(0.08), cornerRadius: 16)
            }
        }
        .redacted(reason: .placeholder)
    }
}
```

Gate shimmer/animation with reduced motion if adding shimmer.

---

### Task 6.2: Improve empty state actions

**Objective:** Empty state should explain whether filters or source caused it.

**Files:**
- Modify: `PMVDL/PMVDL/Feed/FeedView.swift`

**Changes:**
- If filters are active, show:
  - `No matches for these filters`
  - `Clear filters`
  - `Load more from source` if `hasMore`
- If no items loaded, show:
  - `No feed items loaded`
  - `Refresh`

**Implementation:** Pass `hasMore`, `loadMore`, and `refresh` into the empty state if needed.

---

### Task 6.3: Improve error state placement

**Objective:** Errors should appear in the content area but not look like a full app crash.

**Files:**
- Modify: `PMVDL/PMVDL/Feed/FeedView.swift`

**Changes:**
- Add compact error banner under header when `error != nil && !items.isEmpty`.
- Keep full error state only when there are zero items.

**Acceptance:** If refresh fails after previous items loaded, users can keep browsing old items.

---

## Phase 7: macOS interaction polish

### Task 7.1: Add search keyboard focus and shortcuts

**Objective:** Make Feed faster to operate from keyboard.

**Files:**
- Modify: `PMVDL/PMVDL/Feed/FeedView.swift`

**Implementation:**
- Add `@FocusState private var searchFocused: Bool` to `FeedToolbar` or parent.
- Apply `.focused($searchFocused)` to search field.
- Add keyboard shortcuts:
  - Cmd+F focuses search.
  - Cmd+R refreshes.
  - Escape clears search if focused, or collapses advanced filters.

Only implement shortcuts that compile cleanly on macOS 14.

---

### Task 7.2: Improve accessibility labels and hints

**Objective:** Make the redesigned Feed usable with VoiceOver and keyboard navigation.

**Files:**
- Modify: `PMVDL/PMVDL/Feed/FeedView.swift`
- Modify: `PMVDL/PMVDL/Feed/FeedCardView.swift`

**Add:**
- Toolbar controls have labels/hints.
- Count badge says `43 visible out of 56 loaded videos`.
- Card says source/studio/title/views/time/duration.
- Extract action is exposed as an accessibility action.
- Active filter chip remove buttons say `Remove filter: X`.

---

### Task 7.3: Respect reduced motion everywhere in Feed

**Objective:** Avoid animated hover/transitions for users who request reduced motion.

**Files:**
- Modify: `PMVDL/PMVDL/Feed/FeedView.swift`
- Modify: `PMVDL/PMVDL/Feed/FeedCardView.swift`

**Changes:**
- `FeedCardView` already reads `accessibilityReduceMotion`; keep that.
- Use the same environment value for advanced filter transitions and skeleton shimmer.
- If reduced motion is true, use `.transition(.opacity)` or no transition.

---

## Phase 8: Optional visual theme refinements

### Task 8.1: Add Feed-specific semantic colors to `Theme`

**Objective:** Avoid hardcoding lavender opacity everywhere.

**Files:**
- Modify: `PMVDL/PMVDL/Theme.swift`

**Implementation:**
Add names that reflect intent:

```swift
static let feedAccent = lavender
static let feedSurfaceTint = lavender.opacity(0.12)
static let feedBorder = lavender.opacity(0.20)
```

**Caution:** If Swift complains because static lets with opacity return different types or are evaluated oddly, keep these as functions:

```swift
static func feedSurfaceTint(_ opacity: Double = 0.12) -> Color {
    lavender.opacity(opacity)
}
```

**Acceptance:** Feed styling reads semantically and remains easy to tune.

---

### Task 8.2: Add reusable pill/control styles if duplication grows

**Objective:** Keep Feed UI DRY after the redesign.

**Files:**
- Modify: `PMVDL/PMVDL/GlassComponents.swift` only if useful
- Otherwise keep local private components in `FeedView.swift`

**YAGNI rule:** Do not promote a component to `GlassComponents.swift` unless used outside Feed or repeated more than twice.

Candidate shared components:
- `GlassPill`
- `GlassSearchField`
- `ActiveFilterChip`

---

## Phase 9: Verification and QA

### Task 9.1: Run formatting/diff checks

**Command:**

```sh
git diff --check
```

**Expected:** No whitespace errors.

---

### Task 9.2: Run full tests

**Command:**

```sh
xcodebuild -quiet \
  -project PMVDL/PMVDL.xcodeproj \
  -scheme PMVDL \
  -configuration Debug \
  -derivedDataPath /tmp/viddl-feed-ui-final-derived \
  test
```

**Expected:** PASS.

---

### Task 9.3: Build and launch for manual visual QA

**Command:**

```sh
xcodebuild -quiet \
  -project PMVDL/PMVDL.xcodeproj \
  -scheme PMVDL \
  -configuration Debug \
  -derivedDataPath /tmp/viddl-feed-ui-visual-derived \
  build

pkill -x VidDL || true
open -n /tmp/viddl-feed-ui-visual-derived/Build/Products/Debug/VidDL.app
```

**Manual QA checklist:**

Collapsed Feed view:
- Header is compact and informative.
- Refresh/count sit in header.
- Toolbar is one compact row on wide/medium windows.
- Filter card no longer dominates the page.
- Day header sits close to grid.
- Grid cards are evenly spaced.
- Thumbnails dominate cards.
- Titles are readable and less visually heavy.
- Metadata is visible but secondary.

Advanced filters:
- Panel opens smoothly.
- Panel is grouped into Metrics / Source metadata / Discovery.
- Active filter chips appear after selecting filters.
- Removing chips updates result count immediately.
- Clear All works.

Responsive widths:
- Narrow detail width: controls wrap cleanly, cards remain readable.
- Medium width: 3-4 columns look balanced.
- Wide width: content is capped/centered and not stretched.

Behavior:
- Refresh works.
- Load More works.
- Search works.
- Date/sort/site pickers work.
- Card click still extracts to Home.
- Context menu Copy/Open/Extract still works.
- Loading/empty/error states look intentional.

Accessibility/reduced motion:
- VoiceOver labels are meaningful.
- Keyboard shortcuts work if implemented.
- Reduced Motion disables hover scaling/shimmer-like animation.

---

## Suggested implementation order and commits

1. `chore: add feed layout tokens`
2. `test: add feed layout helper tests`
3. `feat: add compact feed page header`
4. `refactor: simplify feed toolbar layout`
5. `feat: add active feed filter chips`
6. `feat: improve feed grid responsiveness`
7. `style: refine feed card visual hierarchy`
8. `style: redesign advanced feed filters drawer`
9. `style: improve feed loading empty and error states`
10. `feat: add feed keyboard and accessibility polish`
11. `test: verify feed ui presentation helpers`

---

## What not to do in this pass

1. Do not rewrite the Feed scraper/data pipeline.
2. Do not change filtering semantics beyond chip removal/visibility.
3. Do not add a new design system unrelated to existing `Theme` and `GlassComponents`.
4. Do not introduce heavy screenshot-testing infrastructure yet.
5. Do not use macOS 15/26-only APIs unless guarded by availability checks.
6. Do not remove the colorful VidDL identity; tune it so content is easier to scan.

---

## Final expected result

The Feed page should feel like a polished media discovery grid:

- top header: compact, informative, actionable;
- basic filters: one clean row;
- advanced filters: tucked into a purposeful drawer;
- active filters: visible as removable chips;
- content grid: calmer, better spaced, responsive;
- cards: thumbnail-first, readable, less noisy;
- states/interactions: clear, accessible, macOS-native.
