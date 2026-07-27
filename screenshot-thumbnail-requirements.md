# Multi-Display Screenshot Thumbnail — Requirements

## Goal

macOS shows the post-screenshot floating thumbnail on exactly one display. Build a
menu bar utility that replaces it with an equivalent thumbnail shown simultaneously in
the bottom-right corner of **every** connected display.

The native thumbnail is drawn by `screencaptureui`, a SIP-protected system process with
no plugin or IPC surface. It cannot be duplicated, moved, or queried. The only viable
approach is to disable it and reimplement it.

## Non-goals (v1)

- No screenshot capture. The system keeps handling capture; this app only reacts to the
  resulting file.
- No Markup/annotation UI. Click-through to Preview is sufficient.
- No custom hotkey registration.
- No clipboard-only capture support (⇧⌃⌘4). Out of scope — the target workflow is ⇧⌘4,
  which always writes a file.
- No screen recording support required for v1, but see "Video" below — do not architect
  it out.
- No App Store distribution, no notarization, no auto-update. Local build only.

## Platform & stack

- Swift 5.9+, AppKit. SwiftUI is acceptable for the thumbnail view's internals; the
  windows themselves must be `NSWindow`/`NSPanel`.
- Minimum target: macOS 14. Use current APIs; do not add back-deployment shims.
- `LSUIElement = true` in Info.plist. No Dock icon, no main window.
- No entitlements required. No Screen Recording permission, no Accessibility permission,
  no Full Disk Access. If the implementation ever appears to need one of these, stop and
  flag it — it means the approach drifted.

## Prerequisite (document in README, do not perform silently)

The native thumbnail must be off, or the user gets a double thumbnail on one display:

```
defaults write com.apple.screencapture show-thumbnail -bool false
killall SystemUIServer
```

The app should **detect** this state on launch by reading the same key and show a menu
bar warning item if it's still enabled, with a menu action to turn it off. Do not write
the key without an explicit user action.

## Architecture

Four components:

1. **ScreenshotWatcher** — detects new screenshot files.
2. **ThumbnailPresenter** — owns the set of overlay windows, one per screen.
3. **ThumbnailWindow** — a single borderless overlay window and its content view.
4. **MenuBarController** — status item, settings, quit.

## 1. ScreenshotWatcher

### Watch location

Resolve the screenshot directory at launch and on every change:

- Read `com.apple.screencapture` `location`. Expand `~` and any tilde-relative path.
- If unset or the path doesn't exist, fall back to `~/Desktop`.
- Re-resolve when the app is woken from sleep and on a 60s timer, or observe the prefs
  file directly. The user can change this at any time; do not resolve once and cache
  forever.

### Detection mechanism

Use `FSEventStreamCreate` on the resolved directory with
`kFSEventStreamCreateFlagFileEvents`. `DispatchSource.makeFileSystemObjectSource` is an
acceptable alternative but FSEvents handles directory replacement more gracefully.

### Matching rules

**Do not match on filename.** The default prefix (`Screenshot`) is localized and
user-configurable via `defaults write com.apple.screencapture name`. Apple has changed
the timestamp format across releases. Match on:

- Extension is `png`, `jpg`, `heic`, `pdf`, or `tiff` (the set `screencapture` can emit;
  the format is user-configurable via the `type` key).
- File is a direct child of the watch directory, not a subdirectory.
- `contentModificationDate` is within the last 3 seconds.
- File is not currently being written. Debounce 150ms after the last event for a given
  path, then confirm the file size is stable across two reads 50ms apart before acting.
  A screenshot of a 6K display is not small; a naive read will get a truncated PNG.

### Deduplication

FSEvents will fire multiple times for a single file creation. Key on resolved path and
suppress repeats within a 2-second window.

### Video

`screencapture` also produces `.mov` for screen recordings. v1 does not need to present
these, but the matcher should be structured so adding `mov` is a one-line change, and the
thumbnail view should take an `NSImage` produced by a source-agnostic loader (for video,
`AVAssetImageGenerator` first frame).

## 2. ThumbnailPresenter

### Window set

On each detected screenshot, create one `ThumbnailWindow` per entry in
`NSScreen.screens`. All windows show the same image and share a single dismissal
lifecycle.

If a screenshot arrives while a previous set is still on screen, dismiss the old set
immediately without animation and present the new one. Do not stack or queue.

### Screen configuration changes

Observe `NSApplication.didChangeScreenParametersNotification`. On fire:

- Tear down any window whose screen is no longer in `NSScreen.screens`.
- Create windows for newly-attached screens if a thumbnail set is currently visible.
- Reposition all surviving windows against their screen's current `visibleFrame`.

This is the primary source of bugs. A window whose `NSScreen` has been disconnected will
otherwise linger as an orphan or crash on `visibleFrame` access. Test by docking and
undocking while a thumbnail is visible.

### Dismissal

The set dismisses when any of the following happen, and dismissal always applies to
**all** windows in the set:

- 5.0 seconds elapse from presentation.
- The user swipes right on any thumbnail.
- The user clicks any thumbnail (after the click action runs).
- The user completes a drag out of any thumbnail.
- A new screenshot arrives.

Dismissal animation: 0.25s, fade opacity to 0 combined with a small rightward translation
(~40pt). Match the native feel.

## 3. ThumbnailWindow

### Window configuration

- `NSWindow` (or `NSPanel` with `.nonactivatingPanel`), `styleMask = [.borderless]`.
- `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false` (draw the shadow in
  the content view so it animates with the content).
- `level = .statusBar`. Must float above normal windows and above full-screen apps'
  content where possible.
- `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary,
  .ignoresCycle]`.
- `ignoresMouseEvents = false`.
- Must never take key or main status. Clicking it must not activate the app or deactivate
  whatever the user was working in.

### Geometry

- Thumbnail content size: 240 × 160 points, with the image aspect-fit inside it. Match
  the native proportions closely enough that it reads as the same affordance.
- Anchor: bottom-right of the target screen's `visibleFrame`, inset 20pt from the right
  edge and 20pt from the bottom.
- Use `visibleFrame`, not `frame`, so the window clears the Dock on whichever screen the
  Dock currently occupies.

### Appearance

- Rounded rect, 8pt corner radius.
- 1pt white border, plus a subtle outer shadow (roughly `black @ 30%`, radius 12, offset
  y = -4).
- The image must be composited with alpha preserved. `⇧⌘4` then Space captures a window
  with a transparent shadow margin; rendering it on an opaque white card looks wrong.
  Draw the card behind the image only where the image is opaque, or simply preserve
  transparency and let the card show through.
- Scale-in on present: 0.2s, from 0.9 scale and 0 opacity to 1.0 and full opacity, with a
  spring or ease-out curve.

### Interactions

**Click** — open the file with `NSWorkspace.shared.open(url)`. Then dismiss the set.

**Drag** — begin an `NSDraggingSession` carrying the file URL. Use
`NSFilePromiseProvider`, or an `NSPasteboardItem` with the `.fileURL` type at minimum.
Must work as a drop into Slack, Figma, Mail, and Finder. On successful drop, dismiss the
set. This is the single most important interaction to get right — it is the main thing
users lose when the native thumbnail is disabled.

**Swipe right** — track a horizontal drag or a two-finger scroll. Past 60pt of rightward
travel, dismiss the set. Below that, spring back.

**Right-click** — context menu with: Open, Reveal in Finder, Copy, Delete, Dismiss.

## 4. MenuBarController

`NSStatusItem` with a template symbol image. Menu contents:

- Warning row (only when the native thumbnail is still enabled): "Native thumbnail is
  on — click to disable".
- Current watch directory, disabled/informational.
- "Show for 5 seconds" submenu: 3 / 5 / 10 / Never auto-dismiss.
- "Launch at Login" toggle, backed by `SMAppService.mainApp`.
- Quit.

Persist settings in `UserDefaults` under the app's own suite. Do not write to
`com.apple.screencapture` except via the explicit warning-row action.

## Error handling

- If the watch directory becomes unreadable or is deleted, degrade quietly: stop the
  stream, retry resolution every 30s, surface the state in the menu bar item.
- If an image fails to load, log and present nothing. Never present an empty or broken
  card.
- No crash on missing screen, missing file, or a file deleted between detection and
  presentation.

## Build & run

- Xcode project or SwiftPM package that produces a `.app` bundle.
- Ad-hoc signing is fine. No notarization.
- `README.md` covering: the `defaults write` prerequisite, how to build, how to enable
  launch at login, and how to revert to the native behavior.

## Acceptance criteria

1. With two displays connected, taking a ⇧⌘4 region screenshot shows a thumbnail in the
   bottom-right of both displays within ~500ms of the mouse release.
2. Both thumbnails dismiss together, by every dismissal path.
3. Dragging either thumbnail into Slack attaches the screenshot file.
4. Clicking either thumbnail opens the screenshot in Preview and does not steal focus
   from the previously frontmost app before the click.
5. Disconnecting a display while a thumbnail is visible does not crash, orphan a window,
   or leave the remaining thumbnail mispositioned.
6. Reconnecting the display and taking a new screenshot shows thumbnails on both again
   with no restart.
7. Thumbnails appear correctly on a screen where the Dock is visible (cleared, not
   overlapping) and where it is hidden.
8. A window screenshot (⇧⌘4 then Space) renders with its transparent shadow margin
   intact.
9. Changing the screenshot save location in the Screenshot app is picked up without a
   restart.
10. The app uses no permission prompts of any kind on first run.

## Suggested build order

1. Menu bar shell + quit. Confirm `LSUIElement` behavior.
2. Watcher, logging detected files to console only. Validate the matching and debounce
   rules against real screenshots before drawing anything.
3. One window on the main screen, static, no interactions, no dismissal.
4. Fan out to all screens + shared dismissal + screen-change handling.
5. Appearance polish and animations.
6. Drag out. Then click, swipe, context menu.
7. Settings persistence and launch at login.
