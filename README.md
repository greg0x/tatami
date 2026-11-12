# tatami

A tiling window manager for macOS, written from scratch in Zig. No dependencies: the only
thing the build needs is the pinned Zig toolchain, and the binary links only system
frameworks.

It exists because AeroSpace kept hanging, looping and re-tiling windows it should have left
alone. See [docs/COMPLAINTS.md](docs/COMPLAINTS.md) for each complaint and the behaviour
that answers it.

## Status

| Part | State |
|---|---|
| Engine (layout, focus, workspaces, rules) | Verified by unit tests, scenario tests and a deterministic simulator |
| macOS shell (Accessibility, hot keys, displays, IPC) | Run live on one Mac (macOS 26.3, one display, 4 windows). See below. |

Checked live, each against an independent Accessibility read of every window:

- Discovery and tiling of the windows that were open, focus, swap, zoom-fullscreen.
- Workspace switch and back (frames return exactly), send to workspace, an empty workspace
  that stays empty.
- Resizing a tile with the mouse.
- Hot keys with cmd in them (focus, warp), pressed by hand.
- `tatami quit`.
- A restart, and a kill followed by a start: no window was sent a frame, and the layout,
  the split, the zoom and the focus were the same before and after.
- A second `tatami start` while one runs: refused.

Not checked live yet: hot keys that use only option or option-shift (Secure Input was on
during the trial, see [docs/INSTALL.md](docs/INSTALL.md)), `tatami rescue` with windows
actually parked, binding modes, more than one display, native tabs, sticky windows, rules,
applications that hang, and what the shell does about native fullscreen, cmd-h, windows
that are announced early, displays that are replugged and a Dock that moves.
[docs/EDGE-CASES.md](docs/EDGE-CASES.md) says for every case whether a test shows it or
only the code does.

Measured live, from the command line including process start: focus 15 to 55 ms, workspace
switch 45 to 100 ms. Almost all of it is the applications answering Accessibility calls;
the engine's share is microseconds (`tatami bench`).

## Design in one paragraph

The window manager is a pure state machine: `engine.step(event, now) -> effects`. It never
blocks, allocates or calls the operating system. A thin shell turns macOS notifications into
events and performs the effects. Because the engine is pure, the simulator can drive it
through millions of events with a hostile fake macOS (apps that hang, refuse frames, move
themselves, report late or twice) and check after every quiet moment that every window is
exactly where the engine says it should be. See [docs/DESIGN.md](docs/DESIGN.md).

## Build

```sh
./zig/download.sh                       # Zig 0.17.1, checksummed, into ./zig
./zig/zig build -Doptimize=ReleaseSafe  # zig-out/bin/tatami and zig-out/bin/tatami-sim
./zig/zig build test --summary all      # unit and scenario tests
./scripts/sim-find.sh 1 3000 5000       # seeds 1..3000, 5000 steps each
```

Apple Silicon macOS only.

## Install

```sh
./scripts/install.sh    # starts at login; see docs/INSTALL.md
```

## Use

```sh
tatami check            # permission, configuration, displays, Secure Input
tatami probe            # what Accessibility reports for every window, and how fast
tatami start --verbose  # run in the foreground
tatami focus west       # any command from the config also works from the CLI
tatami help             # every command
tatami query windows    # windows | workspaces | monitors | focus | tree | bindings | stats
tatami query tree --json  # every query also answers as JSON
tatami label editor     # name the focused window, then: focus editor, move below editor
tatami events           # follow what changes, one line per event
tatami wait 186         # return when window 186 closes
tatami reload           # re-read the config; a file with errors is rejected as a whole
tatami quit             # brings every parked window back, then exits
tatami start            # the next start finds every window in its tile, on its workspace
tatami rescue           # the same, without a running daemon
tatami bench            # engine latency per command
tatami default-config   # print the built-in configuration
```

The configuration is one file, `~/.config/tatami/tatami.conf`. Without it the built-in
[src/default.conf](src/default.conf) applies: the yabai/skhd bindings, with option-N to
switch workspace and option-shift-N to send a window there.

Keys are named as in skhd (`return`, `pageup`, `f13`, `kp5`, ...), and any key can be
given by its code: `bind alt-0x32 : ...`. A hot key that macOS refuses is named in the log.

Binding modes work as in AeroSpace: `bind mode:<name> <chord> : <command>` binds a key only
while that mode is active, and `mode <name>` switches (also `tatami mode main` from the
CLI). The default has AeroSpace's service mode on option-shift-; with esc, backspace
(close the other windows), f (float) and r (retile). A mode with no binding that leaves it
is rejected, so a key press can never strand you in one.

`toggle accordion` stacks every tile of the workspace at full size, as AeroSpace's
accordion layout does. Focus, swap and warp then step through the stack in layout order:
west and north go back, east and south go on, and `--wrap` goes around the stack, never to
another display. The mouse and resize leave the layout underneath alone, so toggled again
the tiles come back where they were, in their new order. `focus next` also reaches the
floating windows.

Commands can name the windows they act on, by the id that `query windows` prints or by
a label: `swap 186 logs`, `move logs right editor --ratio 30`, `zoom editor --on`,
`float 186 --bounds 0.25,0.25,0.5,0.5`. This part of the command line is modelled on
Rex's; [docs/REX.md](docs/REX.md) lists what was taken and what was not. Every command
ends with the same statuses: 0 done, 1 failed, 2 not a command, 3 no such window or
workspace, 4 the manager is not running.

Every failure that could be found in the issue trackers of AeroSpace, yabai, skhd, i3, sway,
Amethyst, Rectangle, Hammerspoon and komorebi has a row in
[docs/EDGE-CASES.md](docs/EDGE-CASES.md): what tatami does about it and the test that
shows it.

## What it does not do

- No window borders, opacity, topmost or picture-in-picture: those need SIP disabled.
- Workspaces are virtual: hidden windows are parked in a corner, as in AeroSpace. Native
  Spaces are left alone.

## Licence

MIT or Apache-2.0, at your option: [LICENSE-MIT](LICENSE-MIT),
[LICENSE-APACHE](LICENSE-APACHE).
