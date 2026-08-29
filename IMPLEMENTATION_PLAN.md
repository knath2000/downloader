# Implementation Plan: Quick Wins + Video Preview / Thumbnail Scrubbing

**Project:** PMVDL / LustreStudio  
**Date:** 2026-08-28  
**Branch:** main

---

## Phase 1: Quick Wins (Estimated: 1-2 days total)

### QW-1: "Clear Failed" Button in DownloadQueue Toolbar
**Effort:** 30 min | **Risk:** Low | **Files:** `DownloadQueueView.swift`

**Current State:** `DownloadQueueView.swift:619` has `clearFailed` passed to `DownloadsToolbar` but toolbar doesn't render it.

**Changes:**
1. Update `DownloadsToolbar` (in `DownloadQueueView.swift` or separate file) to add "Clear Failed" button
2. Wire to `queue.clearFailed()` method (add if missing)

```swift
// In DownloadQueue.swift - add if not exists
func clearFailed() {
    let failedIDs = queue.filter { $0.status.isTerminal && $0.status.isFailed }.map(\.id)
    failedIDs.forEach { lastProgressUpdateAt[$0] = nil }
    queue.removeAll { $0.status.isTerminal && $0.status.isFailed }
    save()
}
```

**Testing:** Add failed items → click button → verify removed from queue

---

### QW-2: "Copy Video URL" Context Menu
**Effort:** 45 min | **Risk:** Low | **Files:** `LibraryView.swift`, `WatchlistView.swift`, `FavoritesView.swift`

**Pattern:** Follow existing context menu pattern in `LibraryView.swift` (search for `.contextMenu`)

```swift
// Add to each view's row context menu
Button("Copy Video URL") {
    ClipboardManager.copy(item.url)
}
.keyboardShortcut("c", modifiers: [.command, .shift])
```

**Testing:** Right-click item → Copy URL → paste in browser → verify correct URL

---

### QW-3: Show File Size in Library Rows
**Effort:** 30 min | **Risk:** Low | **Files:** `LibraryView.swift`, `LibraryTimeline.swift`

**Data Source:** `LibraryItem` already has `fileSize: Int64?`

```swift
// In LibraryTimeline.swift or row view
if let size = item.fileSize {
    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

**Testing:** Verify size appears for downloaded items, hidden for non-downloaded

---

### QW-4: "Open in Browser" for Completed Downloads
**Effort:** 30 min | **Risk:** Low | **Files:** `DownloadQueueView.swift`, `DownloadQueueRow.swift`

**Data Source:** `DownloadQueueItem.finalPath` + `sourcePageURL`

```swift
// In DownloadQueueRow context menu
if item.status == .completed, let url = item.sourcePageURL {
    Button("Open in Browser") {
        NSWorkspace.shared.open(URL(string: url)!)
    }
}
```

**Testing:** Complete a download → right-click → Open in Browser → verify opens source page

---

### QW-5: Undo for Bulk Delete
**Effort:** 1 hour | **Risk:** Medium | **Files:** `SelectionManager.swift`, `LibraryView.swift`, `FavoritesView.swift`, `WatchlistView.swift`

**Approach:** Use existing `SelectionManager` + add transient "recently deleted" buffer

```swift
// In SelectionManager.swift - add
private var recentlyDeleted: [SelectionContext: [Any]] = [:]
var undoAction: (() -> Void)?

func deleteSelected(in context: SelectionContext) {
    let items = getSelectedItems(context)
    recentlyDeleted[context] = items
    // ... perform delete ...
    undoAction = { restoreItems(items, to: context) }
    // Show toast with "Undo" action
    ToastQueue.shared.info("Deleted \(items.count) items", action: .undo(undoAction!))
}
```

**Testing:** Select multiple → Delete → Toast appears → Click Undo → Items restored

---

### QW-6: Keyboard Shortcuts Customization in Settings
**Effort:** 2-3 hours | **Risk:** Medium | **Files:** `SettingsView.swift`, new `ShortcutManager.swift`, `ContentView.swift`

**New File:** `ShortcutManager.swift`
```swift
@MainActor
final class ShortcutManager: ObservableObject {
    static let shared = ShortcutManager()
    @Published var shortcuts: [Action: KeyboardShortcut] = [:]
    
    enum Action: String, CaseIterable {
        case newDownload, openQueue, openLibrary, openWatchlist, openFavorites
        case pauseAll, resumeAll, clearCompleted, toggleSelection
    }
    
    func registerDefaults() { /* ... */ }
    func binding(for action: Action) -> Binding<KeyboardShortcut> { /* ... */ }
}
```

**SettingsView Addition:**
```swift
SettingsCard(tint: Theme.skyBlue) {
    SettingsCardTitle(title: "Keyboard Shortcuts", ...)
    ForEach(ShortcutManager.Action.allCases) { action in
        ShortcutRecorderRow(action: action, binding: manager.binding(for: action))
    }
}
```

**Testing:** Change shortcut → restart app → verify new shortcut works

---

## Phase 2: Video Preview / Thumbnail Scrubbing (Estimated: 5-7 days)

### Overview
Generate a sprite sheet (grid of thumbnails) for each video using ffmpeg, cache it, and show scrub preview on hover over Library/Watchlist cards.

### Architecture

```
┌─────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│  Video File     │────▶│  VideoProcessor  │────▶│  ThumbnailCache  │
│  (local/remote) │     │  .generateSprite │     │  .storeSprite()  │
└─────────────────┘     └──────────────────┘     └──────────────────┘
                                                        │
                                                        ▼
┌─────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│  Hover Preview  │◀────│  SpriteSheetView │◀────│  .spriteURL(for) │
│  (LibraryRow)   │     │  (scrub logic)   │     │                  │
└─────────────────┘     └──────────────────┘     └──────────────────┘
```

---

### Step 2.1: Extend VideoProcessor with Sprite Generation
**Effort:** 1.5 days | **Files:** `VideoProcessor.swift`

```swift
// Add to VideoProcessor.swift
extension VideoProcessor {
    struct SpriteSheet {
        let url: URL          // Path to generated sprite image
        let interval: Double  // Seconds between frames
        let columns: Int      // Grid columns
        let rows: Int         // Grid rows
        let frameWidth: Int
        let frameHeight: Int
        let duration: Double  // Video duration
    }
    
    /// Generate sprite sheet for video preview
    /// - Parameters:
    ///   - videoURL: Local video file URL
    ///   - interval: Seconds between frames (default: 5% of duration or 10s)
    ///   - maxFrames: Maximum frames (default: 100)
    ///   - tileSize: Individual thumbnail size (default: 160x90)
    static func generateSpriteSheet(
        for videoURL: URL,
        interval: Double? = nil,
        maxFrames: Int = 100,
        tileSize: CGSize = CGSize(width: 160, height: 90)
    ) async throws -> SpriteSheet
}
```

**FFmpeg Command Pattern:**
```bash
ffmpeg -i input.mp4 -vf "fps=1/10,scale=160:90,tile=10x10" -q:v 2 sprite.jpg
```

**Implementation Details:**
- Calculate optimal interval: `duration / maxFrames`
- Use `tile=` filter to create grid
- Output to `ThumbnailCache` directory with hash-based naming
- Return `SpriteSheet` metadata for rendering

---

### Step 2.2: Extend ThumbnailCache for Sprite Sheets
**Effort:** 1 day | **Files:** `ThumbnailCache.swift`

```swift
// Add to ThumbnailCache.swift
extension ThumbnailCache {
    private static let spriteSubdir = "sprites"
    
    func spriteURL(for videoURL: URL) -> URL? {
        let hash = videoURL.absoluteString.stableHash
        let url = cacheDir.appendingPathComponent(spriteSubdir).appendingPathComponent("\(hash).jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    
    func storeSprite(_ data: Data, for videoURL: URL) -> URL {
        let hash = videoURL.absoluteString.stableHash
        let dir = cacheDir.appendingPathComponent(spriteSubdir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(hash).jpg")
        try? data.write(to: url)
        return url
    }
    
    func removeSprite(for videoURL: URL) { /* ... */ }
}
```

**Cache Key:** Use stable hash of video file path + modification date + size for invalidation

---

### Step 2.3: SpriteSheetView Component
**Effort:** 1.5 days | **Files:** New `SpriteSheetView.swift`, `LibraryView.swift`, `WatchlistView.swift`

```swift
// New file: SpriteSheetView.swift
struct SpriteSheetView: View {
    let spriteURL: URL
    let metadata: VideoProcessor.SpriteSheet
    @Binding var hoverProgress: Double?  // 0.0 - 1.0
    
    var body: some View {
        GeometryReader { geo in
            let frameWidth = metadata.frameWidth
            let frameHeight = metadata.frameHeight
            let columns = metadata.columns
            
            Image(nsImage: NSImage(contentsOf: spriteURL)!)
                .resizable()
                .frame(width: frameWidth * columns, height: frameHeight * metadata.rows)
                .offset(x: -hoverOffset(geo.size.width), y: -hoverRowOffset(geo.size.height))
                .clipped()
        }
        .frame(width: metadata.frameWidth, height: metadata.frameHeight)
    }
    
    private func hoverOffset(_ containerWidth: CGFloat) -> CGFloat {
        guard let progress = hoverProgress else { return 0 }
        let frameIndex = Int(progress * Double(metadata.columns * metadata.rows))
        let col = frameIndex % metadata.columns
        return CGFloat(col) * metadata.frameWidth
    }
    
    private func hoverRowOffset(_ containerHeight: CGFloat) -> CGFloat {
        guard let progress = hoverProgress else { return 0 }
        let frameIndex = Int(progress * Double(metadata.columns * metadata.rows))
        let row = frameIndex / metadata.columns
        return CGFloat(row) * metadata.frameHeight
    }
}
```

---

### Step 2.4: Integrate into Library/Watchlist Cards
**Effort:** 1.5 days | **Files:** `LibraryView.swift`, `Watchlist.swift`, `FavoritesView.swift`

**Hover Detection Pattern:**
```swift
// In LibraryRow / WatchlistRow / FavoriteCardView
@State private var hoverProgress: Double? = nil
@State private var spriteSheet: VideoProcessor.SpriteSheet? = nil
@State private var spriteURL: URL? = nil

var body: some View {
    ZStack(alignment: .topLeading) {
        // Existing thumbnail
        AsyncImage(url: item.thumbnailURL) { ... }
        
        // Sprite preview overlay (only on hover)
        if let spriteURL, let spriteSheet, hoverProgress != nil {
            SpriteSheetView(
                spriteURL: spriteURL,
                metadata: spriteSheet,
                hoverProgress: $hoverProgress
            )
            .transition(.opacity)
            .zIndex(1)
        }
    }
    .onHover { hovering in
        if hovering {
            Task { await loadSpriteSheet() }
            withAnimation(.easeOut(duration: 0.15)) { hoverProgress = 0 }
        } else {
            withAnimation(.easeOut(duration: 0.15)) { hoverProgress = nil }
        }
    }
    .onContinuousHover { phase in
        case .active(let location):
            // Convert location to progress (0-1) based on card width
            hoverProgress = min(max(location.x / cardWidth, 0), 1)
        case .ended:
            hoverProgress = nil
        }
    }
}
```

**Lazy Loading:** Only generate sprite on first hover, cache indefinitely

---

### Step 2.5: Background Generation & Queue Integration
**Effort:** 1 day | **Files:** `DownloadQueue.swift`, `VideoLibrary.swift`

**Trigger Generation:**
- On download completion (`DownloadQueue.complete()`)
- On library item addition (`VideoLibrary.add()`)
- Background task, non-blocking

```swift
// In DownloadQueue.complete()
if let finalPath = finalPath {
    Task.detached(priority: .background) {
        try? await VideoProcessor.generateSpriteSheet(for: URL(fileURLWithPath: finalPath))
    }
}
```

---

### Step 2.6: Performance & Memory Optimization
**Effort:** 0.5 days

- **Downsampling:** Load sprite at display size, not full resolution
- **Memory:** Use `NSImage` with `cacheMode: .never` for large sprites
- **Cancellation:** Cancel sprite generation if video deleted
- **Progressive:** Show single thumbnail first, swap to sprite when ready

---

## Dependencies & Risks

| Dependency | Risk | Mitigation |
|------------|------|------------|
| ffmpeg installed | High | Already checked in `VideoProcessor.isAvailable` |
| Disk space for sprites | Medium | Limit to ~500KB per sprite, configurable max cache |
| Remote files (Mega) | High | Only generate for local files; show placeholder for remote |
| Large videos (>2hr) | Medium | Cap frames at 100, increase interval |

---

## Testing Checklist

### Quick Wins
- [ ] QW-1: Clear Failed removes only failed items
- [ ] QW-2: Copy URL works in all 3 views
- [ ] QW-3: File size shows correctly formatted
- [ ] QW-4: Open in Browser opens correct URL
- [ ] QW-5: Undo restores exact selection state
- [ ] QW-6: Custom shortcuts persist across launches

### Video Preview
- [ ] Sprite generates for local MP4/MKV/MOV
- [ ] Sprite generates for HLS-downloaded files
- [ ] Hover scrub shows correct frame progression
- [ ] No UI lag on hover (60fps)
- [ ] Memory stable with 50+ videos in view
- [ ] Cache invalidation on file change
- [ ] Graceful fallback when ffmpeg missing
- [ ] Remote (Mega) videos show static thumbnail only

---

## File Change Summary

| File | Phase | Changes |
|------|-------|---------|
| `DownloadQueue.swift` | QW-1 | Add `clearFailed()` |
| `DownloadQueueView.swift` | QW-1, QW-4 | Toolbar button, row context menu |
| `LibraryView.swift` | QW-2, QW-3, QW-5, 2.4 | Context menu, file size, undo, hover preview |
| `Watchlist.swift` / `WatchlistView.swift` | QW-2, QW-5, 2.4 | Context menu, undo, hover preview |
| `FavoritesView.swift` | QW-2, QW-5, 2.4 | Context menu, undo, hover preview |
| `SettingsView.swift` | QW-6 | Keyboard shortcuts section |
| `ShortcutManager.swift` | QW-6 | **NEW** |
| `VideoProcessor.swift` | 2.1 | `generateSpriteSheet()` |
| `ThumbnailCache.swift` | 2.2 | Sprite storage/retrieval |
| `SpriteSheetView.swift` | 2.3 | **NEW** |
| `LibraryTimeline.swift` | QW-3 | File size display |

---

## Effort Summary

| Phase | Items | Total Effort |
|-------|-------|--------------|
| Quick Wins | 6 | ~5-6 hours |
| Video Preview | 6 steps | ~5-7 days |
| **Total** | **12** | **~6-8 days** |

---

## Recommended Order

1. **Day 1:** QW-1, QW-2, QW-3, QW-4 (all independent, ~2 hours)
2. **Day 2:** QW-5, QW-6 (~3-4 hours)
3. **Days 3-4:** VideoProcessor sprite generation + ThumbnailCache
4. **Days 5-6:** SpriteSheetView + Library/Watchlist integration
5. **Day 7:** Background generation, optimization, testing