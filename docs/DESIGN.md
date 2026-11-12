# Design

## Layers

```
macOS notifications ──► shell (src/macos) ──► event ──► engine.step ──► effects ──► shell ──► macOS
                                                           ▲
                                  simulator (src/sim.zig) ─┘  the same engine, a fake macOS
```

| Layer | Files | Rule |
|---|---|---|
| Engine | `engine.zig`, `tree.zig`, `command.zig`, `config.zig`, `geometry.zig` | Pure. No system calls, no clock, no allocation. Time arrives as an argument. |
| Shell | `macos/shell.zig`, `ax.zig`, `ipc.zig`, `c.zig` | Translates only. Holds no layout state and makes no decisions. |
| Simulator | `sim.zig`, `sim_main.zig`, `scenarios.zig` | Plays macOS, badly, from a seed. |

Everything is single-threaded. The shell runs one CFRunLoop; every callback turns into one
`engine.step` call, whose effects are performed before the next event is read.

## The engine

`step(event, now_ms) -> []Effect`.

Events: monitors changed, app launched / terminated / unresponsive, window appeared /
destroyed / frame applied / frame changed / title changed / minimized / fullscreen / tab
changed / focused, focus reported, command, tick.

Effects: set frame, focus window, close window, warp mouse, exec, query focus, reload, quit.

A step also leaves notes of what it changed (a window taken on or gone, focus, the
workspace in use, the layout's revision). The shell passes them on to whoever follows
`tatami events`. The revision comes from a hash of everything a query can show, taken after
each step, so no code path can change the layout without it counting.

Layout is a binary space partition per workspace, kept in one static pool of nodes
(`tree.zig`). Tree walks are iterative; nothing recurses. A workspace can show its tree as
an accordion: every tile at full size, the tree kept as it is underneath. A stacked tile
then has an order and no place or size of its own, so directions step along the stack and
the mouse and resize leave the tree alone.

The rules that make it behave:

| Rule | Value |
|---|---|
| A frame is sent only when the target changed | — |
| Retries when a frame did not take | 2, then the window's own size is accepted |
| Time an app may animate before a wrong frame is corrected | 150 ms |
| Corrections before a window that fights the layout is floated | more than 4 in 3 s |
| Backoff for an app whose Accessibility call timed out | 250 ms doubling to 8 s |
| Title rules keep applying after a window appears | 3 s |
| A window sent away by a rule may not pull focus back for | 1.5 s |
| An unconfirmed focus request expires and focus is asked for again after | 500 ms |
| A parked window that macOS lifts | the lift is remembered per window, never retried |
| A hidden application that repeats the focus it already had | ignored |

Focus is optimistic: a command updates the engine's idea of focus at once and the request to
the OS is queued as pending. An echo confirms it. If the echo never comes, or the window is
destroyed first, the engine asks the OS where focus really is instead of guessing.

## Limits

Static, checked by assertions, and reported in `tatami query stats` when hit.

| What | Limit |
|---|---|
| Windows | 256 |
| Applications | 128 |
| Workspaces | 16 |
| Monitors | 8 |
| Effects per step | 1024 |
| Bindings and rules | see `config.zig` |

## Protocols implemented

| Protocol | Use |
|---|---|
| Accessibility (AXUIElement, AXObserver) | Per app: window created, focused window changed, main window changed, application hidden and shown (cmd-h takes its windows out of the layout as minimizing does). Native fullscreen has no notification of its own: it is read when a window reports a frame it was not sent to. Per window: destroyed, moved, resized, title changed, miniaturized, deminiaturized. Frames are read and written through position and size; focus through main, raise and frontmost. A frame whose size is already right is only moved, which is all a workspace switch needs. |
| Accessibility messaging timeout | 250 ms for every call in the process. An app that hits it is suspended by the engine, so one hung app delays only its own windows. |
| Windows that are announced early | Electron, Java and others announce a window before it has the role of one. It is looked at again after 150, 500 and 1500 ms. An application that was not ready, or not an ordinary application, at launch is tried again when it comes to the front, and its window list is read again then. |
| `AXEnhancedUserInterface` | Turned off while frames are set, so apps driven by assistive software do not animate them: once per application for all the frames of a step, not around each one. |
| `_AXUIElementGetWindow` (private) | The window id. The only private call. |
| Carbon hot keys (`RegisterEventHotKey`) | Global bindings without an event tap or Input Monitoring permission. A registered key is consumed, so option-f cannot type "ƒ". Failures are printed, never silent. |
| Carbon application events | Launched, terminated, front switched. |
| Quartz display reconfiguration | Monitors added, removed, rearranged or asleep. Debounced. While it lasts macOS moves windows about by itself; those reports are dropped and every frame is read once at the end. A display is known by its UUID, not by the number macOS gives it for the session, so workspaces find it again on another port. Mirrors are left out. |
| Dock, menu bar and unlock notifications | `NSApplicationDidChangeScreenParametersNotification`, `com.apple.dock.prefchanged`, `AppleInterfaceMenuBarHidingChangedNotification` and `com.apple.screenIsUnlocked`: the usable area of each display is read again, and the engine is told only when it differs. |
| Mouse | The button state is polled every 30 ms only while a window is being dragged, to tell a drag in progress from a finished one. A button held while the pointer is somewhere else is not a drag of this window. |
| Secure Input (`IsSecureEventInputEnabled`) | Read at startup, at every application switch, at unlock and by `tatami check`, with the process that holds it. While it is held, option-only hot keys cannot fire; the log and `tatami events` say when it starts and ends. |
| Unix socket `/tmp/tatami-<uid>.sock` | One line in, one reply out. The client gives up after 2 s; the server reads with a 100 ms timeout. `exec` is refused over the socket. A manager that finds another one answering on the socket does not start: two would fight over every window. |
| State file `/tmp/tatami-<uid>.state` | Everything a user can see of the engine's state, one line per workspace and per window ([src/state.zig](../src/state.zig)): the display of each workspace, which ones show and which are accordions, and for each window its workspace, its place in the layout with the split and ratio, whether it floats and where, sticky, zoom, label, tab and focus order. Written two seconds after the layout changed and at quit, replaced in one step. The next start reads it before it looks at the windows, so a restart, an upgrade or a crash changes nothing: no window that was in view is sent a frame. A window is matched by id and process; lines that make no sense are skipped and the engine checks the rest, so a file from before a reboot, or from someone else, does no harm. |
| Signals | SIGINT and SIGTERM restore parked windows and quit. On a fatal signal the process replaces itself with `tatami rescue`. |

## The simulator

`tatami-sim <seed> <steps>` drives the real engine with a generated workload: apps and
windows opening and closing, native tabs, dialogs and popups, every command in the language,
monitors plugged and unplugged, minimize, user drags, native fullscreen, applications
hidden and shown, displays that go to sleep, come back under another id, change their
resolution in place or trade the menu bar.

Faults it injects:

- Apps that stop answering.
- Windows with a minimum size that never take the frame asked for.
- Windows that move themselves back.
- Windows that animate and report frames on the way.
- Titles that arrive late.
- Windows that macOS lifts by 28, 32 or 40 pixels when they are parked below the screen
  (seen live: the title bar must stay reachable).
- Notifications that are late, duplicated, or about windows that are gone: focus that
  moves on before a window is reported destroyed, a window reported destroyed or appeared
  twice, an application reported gone before its windows are.
- Windows on their way into or out of native fullscreen, which lose every frame they are
  sent, and whose notification and frame change arrive in either order.

After every quiet moment it asserts:

- The engine's picture of every window's frame and minimized state is the real one.
- Every managed window is exactly where the engine wants it, as far as its minimum size
  allows.
- Hidden windows show a sliver one pixel wide on their own display, and of the other
  displays no more than the best of the four parking spots would show: nothing, wherever
  a corner is free.
- The tiles of a workspace that shows lie inside the visible area of its display and do
  not overlap, or, in an accordion, each one fills the workspace.
- Every window that tiles has exactly one leaf, in the tree of its own workspace; a
  window that is minimized, hidden with its application, in native fullscreen, floating
  or a background tab has none.
- The window that has focus is on screen: not minimized, not hidden with its application,
  not on a hidden workspace. A sticky window is on a workspace that shows.
- A display that is still there after the displays change shows the workspace it showed,
  also under another id; only the workspace of the window in use comes first.
- Popups are never tracked, and nothing else is missed.
- No window is sent more than two frames for one event, and going quiet costs a window
  a bounded number of frames.
- Engine focus and OS focus agree, unless the OS-focused window is on a hidden workspace or
  another monitor.
- At the end, with every window closed, nothing is left: no windows, no tree nodes, no focus.

A failing seed replays exactly. `scripts/sim-find.sh first last steps` prints the first
failing seed and the tail of its trace.

## Style

TigerStyle: assertions on arguments and invariants, static allocation only, no recursion,
bounded loops, functions of 70 lines or fewer, lines of 100 columns or fewer, no
dependencies beyond the Zig toolchain.
