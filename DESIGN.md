# VidDL UI/UX Redesign Brief for Google Stitch

## Product Context

VidDL is a macOS video downloader for streaming sites. Users paste URLs, extract downloadable video sources, download locally, send files to cloud/remote storage, browse supported feeds, and manage a library of downloaded or saved items.

The current app is a native SwiftUI macOS app with a dark glass visual language, compact floating bottom navigation, and four primary destinations:

- Home: URL entry, extraction results, active/completed download queue, dependency setup.
- Feed: controlled in-app feed/browser viewer with VidDL overlay actions such as Extract, Favorite, and site switching.
- Library: downloaded items, saved links, uploads, favorites, timeline/detail browsing.
- Settings: dependency setup, download location, notifications, playback/download preferences, Pro license, app info.

## Stitch Prompt

Use the attached screenshots as the current state of a native macOS app called VidDL. Redesign the UI/UX layout, hierarchy, and visual feel while preserving the existing product behavior. Do not produce a marketing landing page. Produce a polished app interface that feels like a professional macOS utility for power users.

Design direction:

- Take inspiration from established, proven desktop apps:
  - Raycast and Linear for dense but calm command surfaces, crisp typography, and strong hierarchy.
  - Arc/Safari compact browser chrome for the Feed browser overlay.
  - Downie, Folx, and Free Download Manager for download queue clarity.
  - Transmit and ForkLift for transfer/storage setup and file destination workflows.
  - Plex, Infuse, and Apple TV for media library browsing, thumbnails, metadata, and detail panels.
  - CleanShot X and Screen Studio for premium macOS utility polish.
- Keep the app dark, cinematic, and focused, but reduce visual clutter and excessive glow.
- Move toward a refined "download command center" feel: compact, confident, fast to scan, and useful during repeated daily use.
- Prefer clear information hierarchy over decorative cards. Use cards only where they frame actual tools, repeated items, modals, or media rows.
- Use native-feeling macOS controls, crisp icon buttons, tooltips, segmented controls, menus, toggles, and compact inputs.

Hard product constraints:

- Preserve the current information architecture: Home, Feed, Library, Settings.
- Preserve the floating bottom navigation concept, but improve its fit, spacing, active state, and relationship to page content.
- Home must support three clear states: idle URL entry, active downloads, and completed downloads.
- During active downloads, the queue should be the primary surface. When downloads are complete, the URL input should become primary again and completed downloads should become a compact success summary.
- Feed must feel like a controlled feed viewer, not a general web browser. Do not add a general editable address bar.
- Feed browser chrome should stay minimal: back, forward, reload/stop, home, site picker, extract current page, favorite, and compact title/status.
- Library should make media items easy to scan, filter, preview, and act on. It should not feel like a generic settings table.
- Settings should stay compact and utilitarian. Avoid oversized hero sections.
- Keep user-facing language generic: describe sources as video sites, streaming sites, feeds, providers, hosted videos, and downloads. Do not make adult-site branding the visual identity of the app.
- Do not remove existing core actions: paste, extract, download, pause/resume, retry, remove, favorite, open library, show in Finder, copy link/path, configure dependencies, activate Pro.

Screens to redesign:

1. Home idle state
   - Make paste/extract the primary action.
   - Keep setup/dependency status visible but secondary.
   - Supported sources should be compact and not compete with the input.

2. Home active downloads state
   - Make the queue the main command center.
   - Show aggregate progress, active/remaining counts, clear stages, destinations, thumbnails, and row actions.
   - Keep URL entry visible as an "add more URLs" affordance, but visually secondary.

3. Home completed downloads state
   - Show a compact success panel with count, Open Library, Show Details, and Clear All.
   - Keep completed details available but collapsed by default.
   - Return focus to adding another URL.

4. Feed browser state
   - Redesign the floating browser overlay so it feels integrated and does not cover common site controls.
   - Make VidDL actions obvious without making the embedded page feel trapped in heavy chrome.
   - Account for selection/batch extraction, right-click actions, and current-page extraction.

5. Library state
   - Improve scanability of saved/downloaded media.
   - Clarify timeline/list versus detail panel.
   - Improve filtering, empty states, thumbnail treatment, destination badges, and action density.

6. Settings state
   - Keep it small, quiet, and easy to configure.
   - Group setup, preferences, Pro, and info clearly.
   - Make dependency status and remote setup feel guided without becoming a wizard unless needed.

Deliverables:

- A redesigned visual direction for each screen using the screenshots as input.
- A compact design system: colors, typography scale, spacing, corner radii, elevation/material usage, icon style, and component states.
- Component guidance for: URL input card, queue summary, queue row, completed summary, browser overlay, library item row/card, detail panel, settings card, buttons, chips, badges, bottom nav, empty/loading/error states.
- Desktop layout rules for common macOS window sizes, including narrow widths.
- Accessibility notes for contrast, focus states, hit targets, reduced motion, and keyboard-first use.
- Explain why the new design improves hierarchy and day-to-day usability.

Avoid:

- A generic SaaS dashboard look.
- A landing-page hero.
- Large decorative gradients, orbs, or purely atmospheric visuals.
- Repeating the same hue everywhere.
- Text-heavy explanations inside the app UI.
- Removing functionality or changing the app into a general web browser.

## Implementation Notes for VidDL

- Prefer incremental SwiftUI changes screen by screen.
- Keep existing app behavior and stores intact unless a later implementation plan explicitly changes them.
- Treat screenshots and Stitch output as design guidance, not as a source of truth for business logic.
- Validate redesigned states manually in Xcode for idle, active, completed, error, empty, and narrow-window layouts.

## Implementation Lesson: Stitch Home Correction

- The Stitch-style Home command panel must apply to every no-active-download state, not only a completely empty idle state.
- Completed-only Home is still a "ready for the next URL" state: keep paste/extract primary and show completed downloads as a compact embedded success strip with Open Library, Show Details, and Clear All.
- Active downloads remain queue-first; no-active Home should not show the older separate hero/status card plus separate paste card stack.
- The target Home structure is one centered glass command panel containing: VidDL title/subtitle, dependency pills, large URL editor, Paste/Clear/Extract actions, optional completed/results strips, and the four supported platform cards.

## Implementation Lesson: Extraction Modal

- Extraction results should be modal-first: use a focused glass command panel instead of a generic sheet header plus card list.
- The extraction modal keeps Add URL at the top, extracted media rows in the middle, and status/batch/close controls in a compact footer.
- Result rows should preserve existing extraction and download behavior while improving scanability with thumbnail, title, status badge, progress line, quality picker, destination picker, download action, and copy action.
- Loading, success, failed, retrying, and batch-download states should all live inside the same modal shell so the workflow feels continuous.
