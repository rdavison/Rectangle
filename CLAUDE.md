# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is Rectangle?

Rectangle is a macOS window management app (10.15+) based on Spectacle, written in Swift. It provides keyboard shortcuts and drag-to-snap functionality for resizing/positioning windows. Configuration is stored in NSUserDefaults (`com.knollsoft.Rectangle`).

## Build & Test Commands

```bash
# Build (archive)
xcodebuild -project Rectangle.xcodeproj -scheme Rectangle archive CODE_SIGN_IDENTITY="-" -archivePath build/Rectangle.xcarchive

# Run tests
xcodebuild -project Rectangle.xcodeproj -scheme Rectangle test

# Run a single test
xcodebuild -project Rectangle.xcodeproj -scheme Rectangle test -only-testing:RectangleTests/RectangleTests/testExample
```

Dependencies (Sparkle, MASShortcut) are managed via Swift Package Manager and resolve automatically.

**macOS < 26 build fix:** Delete "Asset Catalog Other Flags" in build settings (Liquid Glass icon causes failure on older macOS). Do not commit this change.

## Architecture

### Event Flow

```
Trigger (keyboard shortcut / URL scheme / drag-to-snap)
  → WindowAction enum (90+ actions defined in WindowAction.swift)
  → ExecutionParameters notification
  → WindowManager.execute()
  → WindowCalculationFactory → WindowCalculation subclass (computes target rect)
  → WindowMover chain: StandardWindowMover → BestEffortWindowMover
```

### Key Components

- **AppDelegate.swift** — Entry point. Initializes accessibility auth, ShortcutManager, WindowManager, SnappingManager, menu bar item.
- **WindowAction.swift** — Enum of all 90+ actions (halves, thirds, fourths, corners, sixths, eighths, ninths, move, display, maximize, tile, cascade, todo).
- **WindowManager.swift** — Core execution engine. Tracks window history (restore rects, last action). Handles multi-monitor. Chains window movers.
- **ShortcutManager.swift** — Binds actions to keyboard shortcuts via MASShortcut. Supports Spectacle defaults and Rectangle alternate defaults.
- **SnappingManager.swift** — Monitors mouse drag events, detects snap areas at screen edges, shows FootprintWindow preview, executes snap action on release.
- **ScreenDetection.swift** — Multi-monitor detection, adjacent screen tracking, screen ordering.
- **Defaults.swift** — 100+ user preferences backed by NSUserDefaults. JSON import/export support. Auto-loads `~/Library/Application Support/Rectangle/RectangleConfig.json` on launch.

### WindowCalculation/ (Strategy Pattern)

~80 calculation classes, one per action type. Base class `WindowCalculation` provides shared math. `WindowCalculationFactory` maps `WindowAction` → calculator. Key parameter struct: `WindowCalculationParameters` (window, usableScreens, action, lastAction, ignoreTodo).

### WindowMover/ (Chain of Responsibility)

- `StandardWindowMover` — Uses Accessibility API (AXUIElement)
- `BestEffortWindowMover` — Fallback for problematic apps
- `CenteringFixedSizedWindowMover` — Centers non-resizable windows

### Snapping/ (Drag-to-Snap)

- `SnapArea` / `CompoundSnapArea` — Define snap regions at screen edges
- `Directional` enum — Cardinal + compound directions
- `FootprintWindow` — Animated preview overlay

### Repeated Execution Behavior

`SubsequentExecutionMode` controls what happens on repeated keypresses: cycle across monitors, resize through fractions, or both. This is central to how thirds cycling works (first third → center third → last third).

### Coordinate System

All rects use macOS screen coordinates (Y-axis flipped from AppKit). `CGExtension.swift` provides conversion utilities. Visible frame accounts for dock, menu bar, Stage Manager, and todo sidebar.

## Key Patterns

- **Notification-driven**: WindowAction posts notifications; managers subscribe and respond.
- **Accessibility API**: Built on AXUIElement. `AccessibilityElement.swift` wraps AX calls. Private API `_AXUIElementGetWindow` used via bridging header.
- **Gap system**: Configurable screen edge gaps (per-side) affect all window calculations.
- **URL scheme**: `rectangle://execute-action?name=left-half` — see README for full action list.
- **Todo mode**: Sidebar mode that reserves screen space, affecting all other window calculations.

## Contributing Notes

- Rectangle is not accepting new feature requests (only bug fixes and contributor-implemented features with prior approval).
- Match existing coding style.
- RectangleLauncher is only used on macOS < 13 for launch-on-login.
- Debug logging: Hold Alt with Rectangle menu open → "View Logging..."
