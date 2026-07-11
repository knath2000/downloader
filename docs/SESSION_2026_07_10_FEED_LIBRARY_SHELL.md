# Session 2026-07-10: Feed, Library, Sleep Prevention, and VPN Cleanup

## UI and interaction changes

- Replaced native SwiftUI context menus with a shared dark, borderless AppKit panel presenter. Downloads, Home queue, Library, History, Favorites, and the Feed browser share the same styled menu surface, cursor anchoring, clamping, and dismissal behavior.
- Added a compact completed-download row used only by the Home completed modal. The default row shows thumbnail, title, completion state, and destination; hover exposes path and actions; right-click exposes source, copy, Library, Finder, and removal actions.
- The Feed browser keeps its controlled in-app navigation. The top Favorite Page control was removed while right-click item favorite behavior remains. Extract Current Page now scans the loaded document and submits all detected individual video page URLs, with current-page fallback when no individual links are found.
- Feed shell geometry was tuned so the browser reaches a thin bottom margin while the unchanged floating navigation pill overlays inside it. Top titlebar overlap was removed and explicit traffic-light padding is now 32 points so the site switcher remains below the macOS traffic lights.
- The main Library surface, not the thumbnail detail popup, owns the expanded shell geometry. The main Library panel uses side margins, no outer ContentView bottom reserve, and a thin bottom reserve so the unchanged navigation pill overlays inside it. The thumbnail detail popup remains the original narrow detail modal.

## Runtime and cleanup

- Keep-awake now starts immediately at app launch and uses ProcessInfo activity options for idle system sleep, idle display sleep, automatic termination, and sudden termination while active download work exists.
- VPN retry was removed completely from Settings, Home extraction retry logic, extraction result rows, persisted preference keys, tests, the Xcode project, and `ExtractionVPN.swift`.
- Home’s first render now uses live root window geometry through an environment value rather than the initial 900x650 state default, preventing the initial small-to-large layout blink.

## Packaging and validation

- Version bumped to `2.2.3`, build `5`.
- The established local path is `bash scripts/build-dmg.sh`, producing `VidDL-2.2.3-build5-unsigned.dmg`.
- Validation sequence: `git diff --check`, focused Swift parse, external-Xcode Debug build, and `hdiutil verify` on the generated DMG.
