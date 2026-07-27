# Dual Screenshots

A menu bar utility that replaces macOS's single-display post-screenshot thumbnail with
an equivalent thumbnail shown simultaneously in the bottom-right corner of **every**
connected display.

macOS draws the native thumbnail via `screencaptureui`, a SIP-protected system process
with no plugin or IPC surface — it can't be moved or duplicated. So this app disables it
and reimplements it: it watches your screenshot folder, and when a new screenshot lands
it shows its own thumbnail on all screens at once.

It runs as a background agent (no Dock icon, no window) and requires **no** permissions —
no Screen Recording, Accessibility, or Full Disk Access.

## Prerequisite — turn off the native thumbnail

Otherwise you'll get a double thumbnail on one display. Run:

```bash
defaults write com.apple.screencapture show-thumbnail -bool false
killall SystemUIServer
```

The app also detects this for you: if the native thumbnail is still on, the menu bar item
shows a **"Native thumbnail is on — click to disable"** row that runs the equivalent write
for you. The app never touches `com.apple.screencapture` unless you click that row.

## Build

Requires Xcode 15+ / Swift 5.9+ and macOS 14+.

```bash
./build.sh
```

This compiles with SwiftPM and assembles an ad-hoc–signed `build/Dual Screenshots.app`.
Then:

```bash
open "build/Dual Screenshots.app"
```

To iterate from source without bundling: `swift build && swift run`.

## Use

- Take a region screenshot the usual way (⇧⌘4). A thumbnail appears bottom-right on every
  display.
- **Click** it to open the file. **Drag** it into Slack / Mail / Finder / Figma to attach
  the file. **Swipe right** or wait 5 seconds to dismiss. **Right-click** for Open, Reveal
  in Finder, Copy, Delete, Dismiss.
- Dismissing any thumbnail dismisses the whole set.

The menu bar item lets you change the auto-dismiss time (3 / 5 / 10 s / Never) and toggle
launch at login.

### Launch at login

Menu bar item → **Launch at Login**. Backed by `SMAppService`; toggling it off unregisters
the login item.

## Revert to native behavior

Quit the app (menu bar → Quit), then re-enable the system thumbnail:

```bash
defaults write com.apple.screencapture show-thumbnail -bool true
killall SystemUIServer
```

## Notes & limitations (v1)

- Reacts to screenshot **files** only; it does not capture. Clipboard-only captures
  (⇧⌃⌘4) write no file and are not shown.
- Watches the folder from `com.apple.screencapture location` (falling back to `~/Desktop`),
  and picks up changes to that setting without a restart.
- Screen recordings (`.mov`) are not shown in v1, but the matcher and image loader are
  structured so enabling them is a one-line change (see `videoExtensions` in
  `ScreencaptureDefaults.swift`).
- Local build only — no notarization, no App Store, no auto-update.
