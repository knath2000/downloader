# PMVDL Project Progress - UI & State Clarity Improvements

**Date:** 2026-08-27  
**Branch:** main  
**Xcode:** 26.3 (external, x86_64 architecture)  
**Build Status:** ✅ Compiling Successfully

---

## ✅ COMPLETED: Top 3 Highest Impact Audit Items

### 1. Unified EmptyStateView Component
**File:** `PMVDL/PMVDL/EmptyStateView.swift`  
- Reusable `EmptyStateView` struct with configurable icon, title, message, action button
- 10 convenience factories: `.libraryEmpty()`, `.watchlistEmpty()`, `.favoritesEmpty()`, `.downloadsEmpty()`, `.historyEmpty()`, `.feedEmpty()`, `.searchNoResults()`, `.favoritesNoResults()`, `.generic()`, `.custom()`
- Consistent glass card styling with theme-aware colors
- Replaced all ad-hoc empty states across LibraryView, Watchlist, FavoritesView, DownloadQueueView, HistoryView, FeedView

### 2. Toast Queue System
**File:** `PMVDL/PMVDL/ToastQueue.swift`  
- `ToastQueue` singleton with thread-safe `@MainActor` queue management
- `Toast` model with `ToastType` enum: `.success`, `.error`, `.info`, `.warning`, `.progress`
- Spring animations (`.spring(response: 0.35, dampingFraction: 0.85)`)
- Auto-dismiss with configurable duration, progress toasts persist until manual dismiss
- `ToastQueueView` overlay for ContentView integration
- Replaced all `transientMessage` usage in AgentIntegration, PornHubBrowserView, Watchlist, AppStateManager, HomeURLInputCard

### 3. SelectionManager for Multi-Select
**File:** `PMVDL/PMVDL/SelectionManager.swift`  
- Centralized `@MainActor` ObservableObject with per-context isolation
- `SelectionContext` enum: `.library`, `.watchlist`, `.favorites`, `.downloads`, `.history`, `.feed`
- **String-based IDs** for universal compatibility across UUID/String model types
- Range selection with Cmd/Shift-click via `NSEvent.modifierFlags`
- Binding helpers for Toggle/Checkbox integration: `binding(for:in:)`
- Full API: `selection(for:)`, `select(_:in:)`, `deselect(_:in:)`, `toggle(_:in:)`, `selectAll(_:in:)`, `deselectAll(in:)`, `selectRange(from:to:in:context:)`, `handleClick(id:in:context:modifierFlags:)`, `clear(context:)`

---

## ✅ SELECTION MANAGER INTEGRATION - ALL VIEWS COMPLETE

| View | Status | Key Changes |
|------|--------|-------------|
| **LibraryView** | ✅ Complete | Replaced local `@State selection: Set<UUID>` with `SelectionManager.shared`, updated selectionBar, `toggleVideoSelection`, `isBulkSelected`, `deleteSelectedItems` |
| **Watchlist.swift** | ✅ Complete | Replaced local selection, updated `batchBar`, row checkbox binding using `item.id.uuidString` |
| **Favorites/FavoritesView** | ✅ Complete | Added SelectionManager, `selection` computed property (`Set<String>`), selection bar, updated content with `isSelected`/`onSelectionToggle` |
| **Favorites/FavoriteCardView** | ✅ Complete | Added `isSelected`, `onSelectionToggle` params, replaced removeButton with Toggle checkbox |
| **DownloadQueueView** | ✅ Complete | Added SelectionManager, `selection` computed property (`Set<String>`), updated `selectedItems` filter, `toggleSelection`, `removeSelected`, `clearAction`, `onExitCommand` - **FIXED**: DownloadSelectionBar now uses `clearAction` parameter instead of direct `selectionManager` access (line 1119) |

---

## 🔧 TECHNICAL FIXES APPLIED

| Issue | Fix |
|-------|-----|
| "cannot find 'EmptyStateView' in scope" | Added PBXFileReference + PBXBuildFile to project.pbxproj with UUIDs |
| "cannot infer contextual base in reference to member 'infinity'" | Changed `.infinity` → `CGFloat.infinity` in 7 files |
| "cannot find 'searchText' in scope" (Watchlist) | Changed to `query` (actual @State var name) |
| "cannot find type 'DownloadStatusFilter'/'HistoryStreamFilter'" | Made enums `public` in DownloadQueueView.swift:1281, HistoryView.swift:636 |
| ToastQueue not found in scope | Added ToastQueue.swift to pbxproj with correct file paths |
| SelectionManager not found in scope | Added missing PBXBuildFile entry (A10152) in pbxproj Sources section |
| Type mismatch: UUID vs String IDs | Refactored SelectionManager to use **String universally** |
| SelectionManager used UUID but views use String/UUID | Changed all views to `Set<String>`, convert UUIDs via `.uuidString` |
| DownloadQueueView: "instance method 'contains' requires UUID conform to Collection" | Changed `selection.contains(item.id)` → `selection.contains(item.id.uuidString)` |
| DownloadQueueView: "missing argument label 'id:' in call" | Fixed `handleClick` call with named parameter: `handleClick(id: item.id.uuidString, in: ..., context: ..., modifierFlags: ...)` |
| DownloadQueueView: "cannot use mutating member on immutable value" | Replaced `selection.removeAll()` → `selectionManager.deselectAll(in: .downloads)` |
| **DownloadQueueView: "cannot find 'selectionManager' in scope" (line 1119)** | **FIXED**: DownloadSelectionBar private struct now uses `clearAction` parameter passed from parent view |

---

## ✅ COMPLETED: Tooltips on All Icon Buttons
**Files Modified:**
- `PMVDL/PMVDL/LibraryView.swift` - Added tooltip to filter chip lock icon ("Requires LustreStudio Pro")
- `PMVDL/PMVDL/DownloadQueueView.swift` - Verified: action menu ("Queue actions"), collapse/expand chevrons ("Expand completed"/"Collapse completed"), status icons ("Queue position X of Y")
- `PMVDL/PMVDL/Feed/FeedView.swift` - Verified: selection bar buttons ("Clear selection", "Extract Selected")
- `PMVDL/PMVDL/Feed/PornHubBrowserView.swift` - Verified: iconButton helper applies `.help()` to all navigation buttons
- `PMVDL/PMVDL/History/HistoryView.swift` - Verified: HistoryIconButton component includes `.help()` for all icon buttons
- `PMVDL/PMVDL/Favorites/FavoriteCardView.swift` - Verified: remove button has `.help("Remove from Favorites")`
- `PMVDL/PMVDL/GlassComponents.swift` - Verified: AppModalCloseButton has `.help("Close")`, CategoryIconButton has labels

**Pattern:** All icon-only buttons now have descriptive `.help()` tooltips. Row action buttons use `Label` (text + icon) for accessibility. Component-level tooltips added where reusable.

### 5. Drag-Drop Reorder in Library/Watchlist ✅ COMPLETE
- **Models**: Added `sortOrder: Int = Int.max` field to both `LibraryItem` and `WatchlistItem` structs
- **VideoLibrary**: Updated `restorePersistedLibrary()`, `add()`, `mergedLibraryItems()` to sort by `sortOrder` asc then date desc; added `resetSortOrder()` and sequential sortOrder assignment
- **WatchlistStore**: Updated `load()`, `add()` with sortOrder logic; added `moveItems()`, `resetSortOrder()`, `reorderItems()` for drag-drop
- **LibraryTimeline**: Updated `entries()` to sort video items by `sortOrder` then timestamp
- **LibraryView**: 
  - List view: `.onMove(perform: moveLibraryItems)` on video entries ForEach
  - Grid view: Custom `GridDropDelegate` with `onDrag`/`onDrop` for card reordering
  - Added "Reset Order" button in toolbar
- **WatchlistView**: 
  - `visibleItems` sorted by `sortOrder` asc then date/title
  - `.onMove(perform: moveWatchlistItems)` on grouped ForEach
  - Added "Reset Order" button in controls
- **Persistence**: Custom sort order persisted to UserDefaults (Library) and JSON file (Watchlist)
- **Backward compatibility**: `Int.max` default means legacy items sort by date; migration on load

### 6. Settings Search + Pro Upgrade Links
- Add search field to SettingsView for filtering sections
- Add "Upgrade to Pro" links in relevant settings sections
- Deep link to purchase/restore flow

---

## 🏗️ BUILD & DEPLOYMENT NOTES

- **Architecture:** x86_64 (Intel) via external Xcode at `/Volumes/WD/Applications/Xcode.app`
- **Build Command (CORRECT):** `DEVELOPER_DIR=/Volumes/WD/Applications/Xcode.app/Contents/Developer xcodebuild -project /Volumes/WD/Projects/pmvhavendownloader/PMVDL/PMVDL.xcodeproj -scheme PMVDL -configuration Release -destination 'platform=macOS' build CONFIGURATION_BUILD_DIR=/Volumes/WD/Projects/pmvhavendownloader/PMVDL/build/Release` — NOTE: the .xcodeproj is at `PMVDL/PMVDL.xcodeproj` (NOT repo root); a prior command without `-project` fails with "does not contain an Xcode project". Xcode is on external volume; `sudo xcode-select -s` fails (no TTY).
- **DMG Creation:** `create-dmg` is NOT installed; use `hdiutil create -volname PMVDL -srcfolder <stage> -ov -format UDZO <out.dmg>`. Stage `LustreStudio.app` + symlink `Applications -> /Applications`. Product name is `LustreStudio`, so the built bundle is `LustreStudio.app`. Output: `/Volumes/WD/Projects/pmvhavendownloader/PMVDL/build/Release/PMVDL-1.0.dmg`.
- **Key Files for DMG:** `PMVDL.xcodeproj`, `PMVDL/PMVDL/Info.plist`, built `.app` bundle

---

## 🎯 NEXT SESSION RECOMMENDATIONS

1. **Settings Search + Pro Upgrade Links** - Next audit item: Add search field to SettingsView for filtering sections, add "Upgrade to Pro" links in relevant settings sections, deep link to purchase/restore flow
2. **Consider:** Keyboard shortcuts (was skipped), bulk operations UX improvements

---

## 💾 MEMORY SERVER ENTITIES CREATED

- `PMVDL - UI/State Clarity Improvements` (project)
- `SelectionManager Integration Complete` (task)  
- `Next Audit Items Remaining` (task)

Use `mcp__memory__search_nodes` to recall in future sessions.

---

## ✅ COMPLETED: PornHub Watchlist Duration-Title Bug (2026-08-28)

**Symptom:** PornHub watchlist cards displayed bare video durations (e.g. `21:22`) as titles instead of real titles.

**Root cause:** `WatchlistStore.synchronizeWithAgent()` merged the local `items` with the cloud LustreStudio agent snapshot. The compiled agent (an unsigned binary, `LustreStudio-2.2.7-build19-unsigned.app` — NOT editable source) echoes bare duration strings as `title` for PornHub `view_video.php` entries. All local Swift paths (`PornHubFeedScraper`, `PornHubBrowserFeedMapper`, `NativeVideoPageExtractor`) carry correct titles — corruption was introduced by the cloud sync.

**Fixes (in `PMVDL/PMVDL/Watchlist.swift` + `PMVDL/PMVDL/Feed/PornHubFeedScraper.swift`):**
1. `mergeCloud(_:)` — preserves locally-correct titles; won't let an empty/bare-duration cloud title clobber a real local one.
2. `repairDurationTitles()` — self-heals already-corrupted entries by re-fetching the real page title via a new `PornHubFeedScraper.fetchVideoPageTitle(viewkey:)` helper (hits `view_video.php` with feed headers/cookies, parses via `NativeVideoPageExtractor.extractTitle`, strips ` - Pornhub.com`/` | Pornhub.com`).
3. **The actual blocker:** `repairDurationTitles()` originally ran ONLY inside `synchronizeWithAgent()`, whose first line `guard let client = try? LustreAgentClient() else { return }` bails when the agent/Keychain is unavailable (unsigned dev build can't read the attestation token). So corrupted entries never healed. **Decoupled** the repair to run directly from `init()`/`load()` (`Task { await repairDurationTitles() }`), independent of the cloud, and made it always `save()` the correction.
- Gotcha: the `viewkey` helper is `DownloadedFeedIndex.pornHubViewkey(url)`, NOT `FeedView.pornHubViewkey` (that caused a compile error).

**Status:** ✅ FIXED & VERIFIED. Fresh Release build + DMG created; user confirmed cards now show real titles.

**Build/DMG deliverable:** `/Volumes/WD/Projects/pmvhavendownloader/PMVDL/build/Release/PMVDL-1.0.dmg` (contains `LustreStudio.app`).