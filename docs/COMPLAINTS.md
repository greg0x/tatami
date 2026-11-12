# Complaints and the behaviour that answers them

Each row is something that went wrong with AeroSpace, and what tatami does instead. The
"Checked by" column names the scenario test in `src/scenarios.zig`; rows without one are
shell behaviour and have not been exercised against real windows yet.

| Complaint | Behaviour | Checked by |
|---|---|---|
| The manager hangs, and then its own CLI hangs with it | The engine never blocks. Every Accessibility call has a 250 ms timeout and an app that hits it is suspended with backoff. The CLI gives up after 2 s. | "a hung application delays only its own windows" |
| "it is very slow" | A command is a few microseconds of engine work and one frame per window that actually moves. | `tatami bench` |
| A window breaks the tiling and jumps around | A frame is sent only when its target changes, with at most 2 retries. A window that keeps fighting is floated after more than 4 corrections in 3 s. | "a window that fights the layout is floated…", "a window with a minimum size is asked a bounded number of times" |
| A window "flashing all the time" | Same bound: no retry loop exists. | same |
| A second terminal tab is treated as a new window | A native tab shares the tile of its window. | "a native tab shares the tile of its window" |
| Fullscreen should stay fullscreen when another window takes focus | A zoomed window stays zoomed; the other window shows on top until focus returns. | "a zoomed window stays zoomed when another window takes focus" |
| Sticky windows needed a fork | `toggle sticky` and `rule … : sticky` are built in. | "a sticky window stays on screen across workspaces" |
| A config error killed every binding | A config with an error is rejected as a whole and the previous one stays active. | `config.zig` tests |
| Live reload deadlocked | Reload is one event like any other. | — |
| Windows of background test runs pop up in front | A window sent to a workspace by a rule does not take focus or switch the workspace. The default config sends Chrome for Testing and Chromium to workspace 10. | "a window sent away by a rule does not pull focus…" |
| Option-f types "ƒ" | Hot keys are registered with the OS, which consumes them. A key that fails to register is printed at startup. The other cause, and the one found live, is Secure Input: while any process holds it, macOS delivers no character key bound with only option and shift, to any window manager. On macOS 26.3.1 loginwindow leaks it at every lock screen, and only logging out clears it. `tatami check` and startup name the holder and say what clears it; no window manager can work around it. | Seen live |
| A window whose title arrives late misses its floating rule | Title rules keep applying for 3 s after the window appears. | "a title that arrives late still matches its rule…" |
| Popups and helper windows get tiled | Only standard windows tile; popups are never tracked. | "popups and helper windows are never tiled" |
| Workspaces get lost when a monitor is unplugged | Workspaces remember their display and return to it. | "workspaces return to a monitor that is unplugged and plugged back in" |
| Switching to an empty workspace bounces back | A hidden application that announces again the focus it already had (browsers do, constantly) is ignored. Found in the live trial. | "an empty workspace stays when a hidden application repeats its focus" |
| "bring back up", "reset" | `tatami quit` and `tatami rescue` bring every parked window back on screen. A crash does the same. | "quitting brings every parked window back on screen" |
| AeroSpace's accordion layout had no replacement: chat windows that need a wide minimum size lie over each other as tiles | `toggle accordion` stacks every tile of the workspace at full size. Focus, swap and warp walk the stack in layout order (west and north go back, east and south go on), and `--wrap` goes around the stack, never to another display. The tree is kept underneath and the mouse and resize leave it alone, so toggling again brings the tiles back. | "an accordion stacks the tiles and focus steps through them in layout order", "focus --wrap goes around an accordion even with a monitor that way" |
| AeroSpace's service mode had no replacement | `bind mode:<name>` and `mode <name>`; the default carries the service mode. A mode with no way out is rejected at load. | `config.zig` tests |
