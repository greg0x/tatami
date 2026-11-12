//! Deterministic simulation: a model of macOS as a window manager sees it, driven by one
//! seeded PRNG. The same Engine that runs under the real shell runs here against apps that
//! hang, windows that refuse sizes, animate, fight back, change titles late, form tab
//! groups, and monitors that come and go.
//!
//! After every step the engine's invariants are verified. Whenever the workload pauses the
//! system must go quiet in bounded work (no endless flashing) and must then agree with the
//! simulated OS about frames and focus.
const std = @import("std");
const assert = std.debug.assert;
const stdx = @import("stdx.zig");
const geometry = @import("geometry.zig");
const tree = @import("tree.zig");
const command = @import("command.zig");
const config_module = @import("config.zig");
const engine_module = @import("engine.zig");

const Rect = geometry.Rect;
const Engine = engine_module.Engine;
const WindowId = engine_module.WindowId;
const MonitorInfo = engine_module.MonitorInfo;

pub const windows_max: u32 = 40;
pub const apps_max: u32 = 10;
pub const queue_max: u32 = 8192;
/// Upper bound on events needed to go quiet. Exceeding it means something loops.
pub const settle_events_max: u32 = 50_000;

/// Upper bound on the frames one window is sent while the system goes quiet: a few times
/// what a window that fights the layout costs before it is floated.
pub const settle_frames_max: u32 =
    4 * (@as(u32, engine_module.drift_max) + 1) * (@as(u32, engine_module.attempts_max) + 1);

/// Set by the runner: print every event and effect.
pub var trace: bool = false;
/// The seed in flight, for whoever inspects a crash.
pub var seed_running: u64 = 0;

pub const Options = struct {
    seed: u64,
    /// Hung apps, stubborn windows, animations, minimum sizes, spurious notifications.
    faults: bool = true,
};

const SimWindow = struct {
    id: WindowId = 0,
    pid: i32 = 0,
    frame: Rect = Rect.zero,
    min_w: i32 = 1,
    min_h: i32 = 1,
    kind: engine_module.WindowKind = .standard,
    resizable: bool = true,
    minimized: bool = false,
    /// Native fullscreen: the window fills its display and takes no frame it is sent.
    fullscreen: bool = false,
    /// The frame it had before it went fullscreen, and returns to.
    restore: Rect = Rect.zero,
    /// On its way into or out of fullscreen: macOS animates the frame, and whatever
    /// frame the window is sent meanwhile is lost.
    in_transition: bool = false,
    /// Moves itself back to home whenever it is moved.
    stubborn: bool = false,
    home: Rect = Rect.zero,
    /// Takes a while to reach a new frame and reports frames on the way.
    animates: bool = false,
    animation: u32 = 0,
    /// Windows with the same non-zero group are native tabs of each other.
    tab_group: u32 = 0,
    title: []const u8 = "",
    adopted: bool = false,
    /// The workspace a window manager that ran before is said to have left it on.
    left_on: ?u8 = null,
    /// macOS never lets this much of the top of the window sink below the screen.
    title_bar: i32 = 0,
};

const SimApp = struct {
    pid: i32 = 0,
    name: []const u8 = "",
    bundle: []const u8 = "",
    unresponsive_until_ms: u64 = 0,
    /// Hidden with cmd-h. The shell reports every window of it as minimized meanwhile.
    hidden: bool = false,
};

const QueuedKind = enum {
    appeared,
    destroyed,
    frame_applied,
    frame_changed,
    title_changed,
    minimized,
    fullscreen,
    tab_changed,
    focused,
    focus_report,
    app_launched,
    app_terminated,
    app_unresponsive,
    // Things the simulated OS does to itself later.
    self_move,
    animation_end,
    fullscreen_end,
    late_title,
};

const Queued = struct {
    at_ms: u64,
    seq: u64,
    kind: QueuedKind,
    id: WindowId = 0,
    pid: i32 = 0,
    frame: Rect = Rect.zero,
    flag: bool = false,
    token: u32 = 0,
};

const AppTemplate = struct { name: []const u8, bundle: []const u8 };

const app_templates = [_]AppTemplate{
    .{ .name = "Ghostty", .bundle = "com.mitchellh.ghostty" },
    .{ .name = "Brave Browser", .bundle = "com.brave.Browser" },
    .{ .name = "Google Chrome", .bundle = "com.google.Chrome" },
    .{ .name = "Slack", .bundle = "com.tinyspeck.slackmacgap" },
    .{ .name = "Granola", .bundle = "com.granola.app" },
    .{ .name = "Finder", .bundle = "com.apple.finder" },
    .{ .name = "Zed", .bundle = "dev.zed.Zed" },
    .{ .name = "Simulator", .bundle = "com.apple.iphonesimulator" },
};

const titles = [_][]const u8{ "Untitled", "main.zig", "Inbox", "Tempo Wallet", "Huddle", "~" };

/// What real applications were seen to insist on: nothing, 32 pixels, 40 pixels.
const title_bars = [_]i32{ 0, 28, 32, 40 };

const monitor_presets = [_][]const MonitorInfo{
    &.{monitor(1, 0, 0, 1728, 1117, true)},
    &.{ monitor(1, 0, 0, 1728, 1117, true), monitor(2, 1728, 0, 2560, 1440, false) },
    &.{ monitor(2, 0, 0, 2560, 1440, false), monitor(1, 2560, 323, 1728, 1117, true) },
    &.{
        monitor(3, 0, 0, 1920, 1080, false),
        monitor(1, 1920, 0, 1728, 1117, true),
        monitor(2, 3648, 0, 2560, 1440, false),
    },
    &.{ monitor(2, 0, 0, 2560, 1440, false), monitor(1, 416, 1440, 1728, 1117, true) },
};

fn monitor(display: u32, x: i32, y: i32, w: i32, h: i32, main: bool) MonitorInfo {
    const frame: Rect = .{ .x = x, .y = y, .w = w, .h = h };
    return .{ .display = display, .frame = frame, .visible = visible_area(frame, 0), .main = main };
}

const menu_bar: i32 = 38;
const dock: i32 = 70;

/// The display without its menu bar and without the Dock, which is hidden (0), at the
/// bottom (1), on the left (2) or on the right (3).
fn visible_area(frame: Rect, dock_side: u32) Rect {
    var visible: Rect =
        .{ .x = frame.x, .y = frame.y + menu_bar, .w = frame.w, .h = frame.h - menu_bar };
    switch (dock_side) {
        0 => {},
        1 => visible.h -= dock,
        2 => {
            visible.x += dock;
            visible.w -= dock;
        },
        3 => visible.w -= dock,
        else => unreachable,
    }
    return visible;
}

/// The resolutions a display may switch to.
const display_sizes = [_][2]i32{
    .{ 1728, 1117 }, .{ 1512, 982 },  .{ 2560, 1440 },
    .{ 1920, 1080 }, .{ 3008, 1692 }, .{ 1280, 720 },
};

/// A display that reconnects may come back under any of this many ids.
const display_ids: u32 = 6;

const commands = [_][]const u8{
    "focus west",                       "focus south",                "focus north",
    "focus east",                       "swap west",                  "swap south",
    "swap north",                       "swap east",                  "warp west",
    "warp south",                       "warp north",                 "warp east",
    "insert west",                      "insert south",               "resize left -20",
    "resize right 20",                  "resize top 20",              "resize bottom -20",
    "resize width 50",                  "resize height -50",          "balance",
    "retile",                           "rotate 90",                  "rotate 270",
    "mirror x-axis",                    "mirror y-axis",              "toggle split",
    "toggle float",                     "toggle zoom-parent",         "toggle zoom-fullscreen",
    "toggle sticky",                    "toggle gaps",                "workspace 1",
    "workspace 2",                      "workspace 3",                "workspace 4",
    "workspace next",                   "workspace prev",             "workspace recent",
    "workspace new",                    "send 1",                     "send 2",
    "send 3 --follow",                  "send next --follow",         "send recent",
    "focus-monitor next",               "focus-monitor prev",         "focus-monitor recent",
    "focus-monitor 1",                  "send-monitor next --follow", "send-monitor 2",
    "grid 1:2:0:0:1:1",                 "grid 4:4:1:1:2:2",           "move-floating 20 0",
    "layout bsp",                       "layout float",               "close",
    "close-others",                     "query windows",              "query workspaces",
    "query monitors",                   "query stats",                "query focus",
    "workspace 2",
    // Commands that name their windows. The simulator numbers windows from 100.
                         "focus next",                 "focus prev --wrap",
    "focus west --wrap",                "focus south --wrap",         "focus 101",
    "focus 104",                        "focus logs",                 "swap 100 102",
    "swap 103 logs",                    "move 101 below 100",         "move right 102 --ratio 30",
    "move logs left build",             "move 105 above 103",         "zoom",
    "zoom 102 --on",                    "zoom --off",                 "tile",
    "tile 104",                         "float 103",                  "close 106",
    "label logs",                       "label 101 build",            "label 102 logs",
    "label --clear",                    "label-workspace web",        "workspace web",
    "send web",                         "insert east --ratio 30",     "resize ratio 70",
    "query tree",                       "query tree --json",          "query windows --json",
    "query window",                     "query window 101 --json",    "query bindings --json",
    "query workspaces --json",          "query monitors --json",      "query focus --json",
    "query stats --json",               "query commands",             "query modes --json",
    "float --bounds 0.25,0.25,0.5,0.5", "toggle accordion",
};

pub const Coverage = struct {
    fullscreen: u32 = 0,
    hidden: u32 = 0,
    asleep: u32 = 0,
    renumbered: u32 = 0,
    resized: u32 = 0,
    main_moved: u32 = 0,
    disorder: u32 = 0,
    stale: u32 = 0,
    stacked: u32 = 0,
};

pub const Simulator = struct {
    options: Options,
    prng: stdx.Prng,
    engine: *Engine,
    now_ms: u64,
    windows: [windows_max]SimWindow,
    apps: [apps_max]SimApp,
    monitors: []const MonitorInfo,
    /// Holds a display list that is not one of the presets.
    monitors_buffer: [engine_module.monitors_max]MonitorInfo,
    /// Every display is asleep. The list is kept: windows stay where they are meanwhile.
    asleep: bool,
    /// Set once a window went fullscreen here. Tests also hand fullscreen events to the
    /// engine themselves, and those the simulator cannot vouch for.
    fullscreen_modelled: bool,
    /// A window that closed earlier, for notifications that still arrive about it.
    gone: WindowId,
    /// How often the workload did what is rare, to tell that it does it at all.
    coverage: Coverage,
    focused: WindowId,
    queue: [queue_max]Queued,
    queue_count: u32,
    seq: u64,
    window_id_next: WindowId,
    pid_next: i32,
    tab_group_next: u32,
    delivered: u64,
    frames_set: u64,
    settles: u64,

    pub fn init(simulator: *Simulator, engine: *Engine, options: Options) void {
        simulator.options = options;
        simulator.prng = stdx.Prng.init(options.seed);
        simulator.engine = engine;
        simulator.now_ms = 1000;
        for (&simulator.windows) |*window| window.* = .{};
        for (&simulator.apps) |*app| app.* = .{};
        simulator.monitors = monitor_presets[0];
        simulator.asleep = false;
        simulator.fullscreen_modelled = false;
        simulator.gone = 0;
        simulator.coverage = .{};
        simulator.focused = 0;
        simulator.queue_count = 0;
        simulator.seq = 0;
        simulator.window_id_next = 100;
        simulator.pid_next = 500;
        simulator.tab_group_next = 1;
        simulator.delivered = 0;
        simulator.frames_set = 0;
        simulator.settles = 0;
        simulator.step(.{ .monitors_changed = simulator.monitors });
    }

    // Queue.

    fn push(simulator: *Simulator, delay_ms: u64, entry: Queued) void {
        assert(simulator.queue_count < queue_max);
        var queued = entry;
        queued.at_ms = simulator.now_ms + delay_ms;
        queued.seq = simulator.seq;
        simulator.seq += 1;
        simulator.queue[simulator.queue_count] = queued;
        simulator.queue_count += 1;
    }

    fn jitter(simulator: *Simulator, max_ms: u32) u64 {
        if (!simulator.options.faults) return 0;
        return simulator.prng.below(max_ms + 1);
    }

    fn queue_next_at(simulator: *const Simulator) ?u64 {
        var earliest: ?u64 = null;
        for (simulator.queue[0..simulator.queue_count]) |*entry| {
            if (earliest == null or entry.at_ms < earliest.?) earliest = entry.at_ms;
        }
        return earliest;
    }

    fn pop_due(simulator: *Simulator) ?Queued {
        var best: ?u32 = null;
        for (simulator.queue[0..simulator.queue_count], 0..) |*entry, index| {
            if (entry.at_ms > simulator.now_ms) continue;
            if (best) |current| {
                const other = &simulator.queue[current];
                const earlier = entry.at_ms < other.at_ms or
                    (entry.at_ms == other.at_ms and entry.seq < other.seq);
                if (!earlier) continue;
            }
            best = @intCast(index);
        }
        const index = best orelse return null;
        const entry = simulator.queue[index];
        simulator.queue_count -= 1;
        simulator.queue[index] = simulator.queue[simulator.queue_count];
        return entry;
    }

    // Lookups.

    pub fn window_find(simulator: *Simulator, id: WindowId) ?*SimWindow {
        if (id == 0) return null;
        for (&simulator.windows) |*window| {
            if (window.id == id) return window;
        }
        return null;
    }

    fn app_find(simulator: *Simulator, pid: i32) ?*SimApp {
        for (&simulator.apps) |*app| {
            if (app.pid == pid and pid != 0) return app;
        }
        return null;
    }

    fn app_responsive(simulator: *Simulator, pid: i32) bool {
        const app = simulator.app_find(pid) orelse return false;
        return simulator.now_ms >= app.unresponsive_until_ms;
    }

    /// What the shell reports as minimized: a window in the Dock, and every window of an
    /// application that is hidden.
    fn window_away(simulator: *Simulator, window: *const SimWindow) bool {
        if (window.minimized) return true;
        const app = simulator.app_find(window.pid) orelse return false;
        return app.hidden;
    }

    /// True for a window that nobody can move: it is off the screen, or in native
    /// fullscreen, or on its way there or back.
    fn window_fixed(simulator: *Simulator, window: *const SimWindow) bool {
        return window.fullscreen or window.in_transition or simulator.window_away(window);
    }

    fn window_random(simulator: *Simulator) ?*SimWindow {
        var count: u32 = 0;
        for (&simulator.windows) |*window| count += @intFromBool(window.id != 0);
        if (count == 0) return null;
        var pick = simulator.prng.below(count);
        for (&simulator.windows) |*window| {
            if (window.id == 0) continue;
            if (pick == 0) return window;
            pick -= 1;
        }
        unreachable;
    }

    /// Another window of the same tab group, preferably the one the engine shows.
    fn tab_peer(simulator: *Simulator, window: *const SimWindow) WindowId {
        if (window.tab_group == 0) return 0;
        for (&simulator.windows) |*other| {
            if (other.id != 0 and other.id != window.id and other.tab_group == window.tab_group) {
                return other.id;
            }
        }
        return 0;
    }

    // The engine side: deliver an event, perform its effects, check invariants.

    fn step(simulator: *Simulator, event: engine_module.Event) void {
        var known_before: u32 = 0;
        for (&simulator.engine.windows) |*known| known_before += @intFromBool(known.id != 0);
        const effects = simulator.engine.step(event, simulator.now_ms);
        if (trace) trace_step(simulator, event, effects);
        var sets_per_window: [windows_max]u8 = @splat(0);
        var sets: u32 = 0;
        for (effects) |effect| {
            switch (effect) {
                .set_frame => |set| {
                    // One event never costs more than two frames for each window there is.
                    sets += 1;
                    assert(sets <= 2 * (known_before + 1));
                    // No window is ever sent more than two frames for one event.
                    for (&simulator.windows, 0..) |*window, index| {
                        if (window.id != set.id) continue;
                        sets_per_window[index] += 1;
                        assert(sets_per_window[index] <= 2);
                    }
                    simulator.perform_set_frame(set.id, set.frame);
                },
                .focus_window => |focus| simulator.perform_focus(focus.id),
                .close_window => |close| simulator.window_close(close.id),
                .query_focus => simulator.push(0, .{ .at_ms = 0, .seq = 0, .kind = .focus_report }),
                .warp_mouse, .exec, .reload, .quit => {},
            }
        }
        simulator.delivered += 1;
        simulator.engine.verify();
    }

    fn perform_set_frame(simulator: *Simulator, id: WindowId, frame: Rect) void {
        simulator.frames_set += 1;
        const window = simulator.window_find(id) orelse return; // Already gone.
        if (!simulator.app_responsive(window.pid)) {
            simulator.push(
                0,
                .{ .at_ms = 0, .seq = 0, .kind = .app_unresponsive, .pid = window.pid },
            );
            return;
        }
        if (window.fullscreen or window.in_transition) {
            // Native fullscreen: the frame stays, and that is what the shell reads back.
            simulator.push(
                0,
                .{ .at_ms = 0, .seq = 0, .kind = .frame_applied, .id = id, .frame = window.frame },
            );
            return;
        }
        var target: Rect = .{
            .x = frame.x,
            .y = frame.y,
            .w = @max(frame.w, window.min_w),
            .h = @max(frame.h, window.min_h),
        };
        target.y = simulator.title_bar_keep(window, target);
        // The shell reads the frame back right after setting it, before any notification
        // about the change can arrive; an animating window is only part of the way there.
        var result = target;
        if (window.animates and !target.eql(window.frame)) {
            window.animation += 1;
            const from = window.frame;
            result = .{
                .x = @divTrunc(from.x + target.x, 2),
                .y = @divTrunc(from.y + target.y, 2),
                .w = @divTrunc(from.w + target.w, 2),
                .h = @divTrunc(from.h + target.h, 2),
            };
            simulator.push(20 + simulator.jitter(80), .{
                .at_ms = 0,
                .seq = 0,
                .kind = .animation_end,
                .id = id,
                .frame = target,
                .token = window.animation,
            });
        }
        simulator.push(
            0,
            .{ .at_ms = 0, .seq = 0, .kind = .frame_applied, .id = id, .frame = result },
        );
        simulator.frame_assign(window, result);
        if (window.stubborn) {
            simulator.push(
                10 + simulator.jitter(70),
                .{ .at_ms = 0, .seq = 0, .kind = .self_move, .id = id },
            );
        }
    }

    /// A window that would hang off the bottom of the screen is lifted until its title bar
    /// is back on it, as macOS does.
    fn title_bar_keep(simulator: *Simulator, window: *const SimWindow, target: Rect) i32 {
        if (window.title_bar == 0) return target.y;
        var bottom: ?i32 = null;
        for (simulator.monitors) |*info| {
            if (target.overlap(info.frame, .x) <= 0) continue;
            bottom = @max(bottom orelse info.frame.bottom(), info.frame.bottom());
        }
        const floor = (bottom orelse return target.y) - window.title_bar;
        if (target.bottom() <= floor + window.title_bar) return target.y;
        return @min(target.y, floor);
    }

    /// Sets the frame of a window and of its tab group, and queues the notifications.
    fn frame_assign(simulator: *Simulator, window: *SimWindow, frame: Rect) void {
        assert(frame.w > 0 and frame.h > 0);
        for (&simulator.windows) |*other| {
            const grouped = window.tab_group != 0 and other.tab_group == window.tab_group;
            if (other.id == 0 or (other != window and !grouped)) continue;
            if (other.frame.eql(frame)) continue;
            other.frame = frame;
            simulator.push(
                simulator.jitter(40),
                .{ .at_ms = 0, .seq = 0, .kind = .frame_changed, .id = other.id },
            );
        }
    }

    fn perform_focus(simulator: *Simulator, id: WindowId) void {
        const window = simulator.window_find(id) orelse return;
        if (window.minimized or !simulator.app_responsive(window.pid)) return;
        // Focus makes the application frontmost, and that shows a hidden one.
        if (simulator.window_away(window)) simulator.app_show(window.pid);
        simulator.focus_set(id);
    }

    fn focus_set(simulator: *Simulator, id: WindowId) void {
        if (simulator.focused == id) return;
        simulator.focused = id;
        simulator.push(simulator.jitter(30), .{ .at_ms = 0, .seq = 0, .kind = .focused });
    }

    fn window_info(simulator: *Simulator, window: *const SimWindow) engine_module.WindowInfo {
        return .{
            .id = window.id,
            .pid = window.pid,
            .title = window.title,
            .frame = window.frame,
            .kind = window.kind,
            .resizable = window.resizable,
            .minimized = simulator.window_away(window),
            .fullscreen = window.fullscreen,
            .tab_of = simulator.tab_peer(window),
            .adopted = window.adopted,
            .workspace = window.left_on,
        };
    }

    /// Tells the engine where focus is: as a notification, or as the answer to its question.
    fn deliver_focus(simulator: *Simulator, notice: bool) void {
        const id = simulator.focused;
        simulator.flush_appeared(id);
        simulator.step(if (notice) .{ .window_focused = id } else .{ .focus_reported = id });
    }

    fn deliver(simulator: *Simulator, entry: Queued) void {
        switch (entry.kind) {
            .appeared => {
                const window = simulator.window_find(entry.id) orelse return;
                simulator.step(.{ .window_appeared = simulator.window_info(window) });
            },
            .destroyed => simulator.step(.{ .window_destroyed = entry.id }),
            .frame_applied => simulator.step(.{
                .window_frame_applied = .{ .id = entry.id, .frame = entry.frame },
            }),
            .frame_changed => {
                // Like the real shell, report the frame as it is now, not as it was.
                const window = simulator.window_find(entry.id) orelse return;
                simulator.step(.{ .window_frame_changed = .{
                    .id = entry.id,
                    .frame = window.frame,
                    .by_user = entry.flag,
                } });
            },
            .title_changed => {
                const window = simulator.window_find(entry.id) orelse return;
                simulator.step(
                    .{ .window_title_changed = .{ .id = entry.id, .title = window.title } },
                );
            },
            .minimized => {
                const window = simulator.window_find(entry.id) orelse return;
                const away = simulator.window_away(window);
                simulator.step(.{ .window_minimized = .{ .id = entry.id, .minimized = away } });
            },
            .fullscreen => {
                const window = simulator.window_find(entry.id) orelse return;
                const on = window.fullscreen;
                simulator.step(.{ .window_fullscreen = .{ .id = entry.id, .fullscreen = on } });
            },
            .tab_changed => {
                const window = simulator.window_find(entry.id) orelse return;
                simulator.step(.{ .window_tab_changed = .{
                    .id = entry.id,
                    .tab_of = simulator.tab_peer(window),
                } });
            },
            .focused, .focus_report => simulator.deliver_focus(entry.kind == .focused),
            .app_launched => {
                const app = simulator.app_find(entry.pid) orelse return;
                simulator.step(.{
                    .app_launched = .{ .pid = app.pid, .name = app.name, .bundle = app.bundle },
                });
            },
            .app_terminated => simulator.step(.{ .app_terminated = entry.pid }),
            .app_unresponsive => simulator.step(.{ .app_unresponsive = entry.pid }),
            .self_move, .animation_end, .fullscreen_end, .late_title => simulator.happen(entry),
        }
    }

    /// What the simulated OS does to itself when its time has come.
    fn happen(simulator: *Simulator, entry: Queued) void {
        const window = simulator.window_find(entry.id) orelse return;
        switch (entry.kind) {
            .self_move => {
                if (!window.stubborn or simulator.window_fixed(window)) return;
                simulator.frame_assign(window, window.home);
            },
            .animation_end => {
                if (window.animation == entry.token) simulator.frame_assign(window, entry.frame);
            },
            .fullscreen_end => {
                assert(window.in_transition);
                window.in_transition = false;
                const display = simulator.display_of(window.frame).frame;
                simulator.frame_assign(window, if (window.fullscreen) display else window.restore);
            },
            .late_title => {
                window.title = "Tempo Wallet";
                const kind: QueuedKind = .title_changed;
                simulator.push(0, .{ .at_ms = 0, .seq = 0, .kind = kind, .id = entry.id });
            },
            else => unreachable,
        }
    }

    /// Delivers everything that is due, including engine ticks.
    fn drain(simulator: *Simulator) u32 {
        var events: u32 = 0;
        while (true) : (events += 1) {
            assert(events < settle_events_max);
            if (simulator.pop_due()) |entry| {
                simulator.deliver(entry);
                continue;
            }
            const deadline = simulator.engine.next_deadline_ms() orelse break;
            if (deadline > simulator.now_ms) break;
            simulator.step(.tick);
            // A tick must make progress, or the real timer would spin.
            const after = simulator.engine.next_deadline_ms();
            assert(after == null or after.? > simulator.now_ms);
        }
        return events;
    }

    /// The shell reports a window before it reports focus on it; so does the simulator.
    fn flush_appeared(simulator: *Simulator, id: WindowId) void {
        for (simulator.queue[0..simulator.queue_count], 0..) |entry, index| {
            if (entry.kind != .appeared or entry.id != id) continue;
            simulator.queue_count -= 1;
            simulator.queue[index] = simulator.queue[simulator.queue_count];
            simulator.deliver(entry);
            return;
        }
    }

    // The world side: what users and applications do.

    pub const WindowOptions = struct {
        title: []const u8 = "Untitled",
        frame: ?Rect = null,
        kind: engine_module.WindowKind = .standard,
        resizable: bool = true,
        min_w: i32 = 1,
        min_h: i32 = 1,
        stubborn: bool = false,
        animates: bool = false,
        tab_of: WindowId = 0,
        late_title: bool = false,
        focus: bool = true,
        /// Reported as a window that was open before the window manager started.
        adopted: bool = false,
        left_on: ?u8 = null,
        title_bar: i32 = 0,
    };

    pub fn app_launch(simulator: *Simulator, name: []const u8, bundle: []const u8) i32 {
        for (&simulator.apps) |*app| {
            if (app.pid != 0) continue;
            app.* = .{ .pid = simulator.pid_next, .name = name, .bundle = bundle };
            simulator.pid_next += 1;
            simulator.push(0, .{ .at_ms = 0, .seq = 0, .kind = .app_launched, .pid = app.pid });
            return app.pid;
        }
        return 0;
    }

    pub fn window_open(simulator: *Simulator, pid: i32, options: WindowOptions) WindowId {
        assert(simulator.app_find(pid) != null);
        // An application that opens a window comes to the front, hidden or not.
        simulator.app_show(pid);
        var slot: ?*SimWindow = null;
        for (&simulator.windows) |*window| {
            if (window.id == 0 and slot == null) slot = window;
        }
        const window = slot orelse return 0;
        var frame = options.frame orelse simulator.frame_random(options.min_w, options.min_h);
        var group: u32 = 0;
        var min_w = options.min_w;
        var min_h = options.min_h;
        var animates = options.animates;
        var title_bar = options.title_bar;
        if (simulator.window_find(options.tab_of)) |peer| {
            assert(peer.pid == pid);
            assert(!peer.fullscreen);
            if (peer.tab_group == 0) {
                peer.tab_group = simulator.tab_group_next;
                simulator.tab_group_next += 1;
            }
            // Tabs are one native window frame: they share its geometry and its limits.
            group = peer.tab_group;
            frame = peer.frame;
            min_w = peer.min_w;
            min_h = peer.min_h;
            animates = peer.animates;
            title_bar = peer.title_bar;
            peer.stubborn = false;
        }
        window.* = .{
            .id = simulator.window_id_next,
            .pid = pid,
            .frame = frame,
            .home = frame,
            .min_w = min_w,
            .min_h = min_h,
            .kind = options.kind,
            .resizable = options.resizable,
            .stubborn = options.stubborn and group == 0,
            .animates = animates,
            .tab_group = group,
            .title = options.title,
            .adopted = options.adopted,
            .left_on = options.left_on,
            .title_bar = title_bar,
        };
        simulator.window_id_next += 1;
        simulator.push(
            simulator.jitter(20),
            .{ .at_ms = 0, .seq = 0, .kind = .appeared, .id = window.id },
        );
        if (options.late_title) {
            simulator.push(900, .{ .at_ms = 0, .seq = 0, .kind = .late_title, .id = window.id });
        }
        if (options.focus) simulator.focus_set(window.id);
        return window.id;
    }

    fn frame_random(simulator: *Simulator, min_w: i32, min_h: i32) Rect {
        const prng = &simulator.prng;
        return .{
            .x = prng.range(0, 1200),
            .y = prng.range(40, 600),
            .w = @max(min_w, prng.range(200, 1400)),
            .h = @max(min_h, prng.range(150, 900)),
        };
    }

    /// After the focused window went away macOS focuses a tab peer, then a window of the
    /// same application, then anything.
    fn focus_fallback(simulator: *Simulator, pid: i32, group: u32) void {
        var next: WindowId = 0;
        var rank_best: u32 = 0;
        for (&simulator.windows) |*window| {
            if (window.id == 0 or simulator.window_away(window)) continue;
            const rank: u32 = if (group != 0 and window.tab_group == group)
                3
            else if (window.pid == pid)
                2
            else
                1;
            if (rank > rank_best) {
                rank_best = rank;
                next = window.id;
            }
        }
        simulator.focused = 0;
        if (next != 0) {
            simulator.focus_set(next);
        } else {
            simulator.push(0, .{ .at_ms = 0, .seq = 0, .kind = .focused });
        }
    }

    pub fn window_close(simulator: *Simulator, id: WindowId) void {
        simulator.window_close_late(id, 0);
    }

    /// Closes a window whose destroyed notification takes its time: focus moves on, and
    /// frames and commands still name the window, before the engine hears that it is gone.
    pub fn window_close_late(simulator: *Simulator, id: WindowId, late_ms: u64) void {
        const window = simulator.window_find(id) orelse return;
        const pid = window.pid;
        const group = window.tab_group;
        if (window.kind != .popup) simulator.gone = id;
        window.* = .{};
        simulator.tab_group_shrink(group);
        simulator.push(
            late_ms + simulator.jitter(20),
            .{ .at_ms = 0, .seq = 0, .kind = .destroyed, .id = id },
        );
        if (simulator.focused == id) simulator.focus_fallback(pid, group);
    }

    /// A tab group with a single window left is just a window.
    fn tab_group_shrink(simulator: *Simulator, group: u32) void {
        if (group == 0) return;
        var count: u32 = 0;
        var last: ?*SimWindow = null;
        for (&simulator.windows) |*window| {
            if (window.id != 0 and window.tab_group == group) {
                count += 1;
                last = window;
            }
        }
        if (count != 1) return;
        last.?.tab_group = 0;
        simulator.push(
            simulator.jitter(20),
            .{ .at_ms = 0, .seq = 0, .kind = .tab_changed, .id = last.?.id },
        );
    }

    pub fn app_quit(simulator: *Simulator, pid: i32) void {
        simulator.app_quit_late(pid, 0);
    }

    /// Quits an application whose windows are reported destroyed this long after the
    /// application itself is reported gone.
    pub fn app_quit_late(simulator: *Simulator, pid: i32, late_ms: u64) void {
        const app = simulator.app_find(pid) orelse return;
        var focus_lost = false;
        for (&simulator.windows) |*window| {
            if (window.id == 0 or window.pid != pid) continue;
            if (simulator.focused == window.id) focus_lost = true;
            // The destroyed notification of a dying application may or may not arrive.
            if (late_ms > 0 or simulator.prng.chance(1, 2)) {
                simulator.push(
                    late_ms + simulator.jitter(20),
                    .{ .at_ms = 0, .seq = 0, .kind = .destroyed, .id = window.id },
                );
            }
            if (window.kind != .popup) simulator.gone = window.id;
            window.* = .{};
        }
        app.* = .{};
        simulator.push(
            simulator.jitter(30),
            .{ .at_ms = 0, .seq = 0, .kind = .app_terminated, .pid = pid },
        );
        if (focus_lost) simulator.focus_fallback(0, 0);
    }

    /// The application stops answering Accessibility calls for a while.
    pub fn app_hang(simulator: *Simulator, pid: i32, ms: u64) void {
        simulator.app_find(pid).?.unresponsive_until_ms = simulator.now_ms + ms;
    }

    /// The focused application announces its focus again, as browsers do.
    pub fn focus_repeat(simulator: *Simulator) void {
        simulator.push(0, .{ .at_ms = 0, .seq = 0, .kind = .focused });
    }

    pub fn window_click(simulator: *Simulator, id: WindowId) void {
        const window = simulator.window_find(id) orelse return;
        if (!simulator.window_away(window)) simulator.focus_set(id);
    }

    /// The user drags or resizes a window with the mouse.
    pub fn window_drag(simulator: *Simulator, id: WindowId, frame: Rect) void {
        const window = simulator.window_find(id) orelse return;
        if (simulator.window_fixed(window)) return;
        simulator.frame_assign_by(window, frame, true);
    }

    fn frame_assign_by(simulator: *Simulator, window: *SimWindow, frame: Rect, by_user: bool) void {
        const before = simulator.queue_count;
        simulator.frame_assign(window, frame);
        for (simulator.queue[before..simulator.queue_count]) |*entry| entry.flag = by_user;
    }

    pub fn window_minimize(simulator: *Simulator, id: WindowId, minimized: bool) void {
        const window = simulator.window_find(id) orelse return;
        // A fullscreen window has no button to minimize it with.
        if (window.minimized == minimized or window.fullscreen or window.in_transition) return;
        const hidden = simulator.app_find(window.pid).?.hidden;
        // Nor can the windows of a hidden application be reached.
        if (hidden and minimized) return;
        window.minimized = minimized;
        simulator.push(
            simulator.jitter(20),
            .{ .at_ms = 0, .seq = 0, .kind = .minimized, .id = id },
        );
        if (!minimized) {
            // Taking a window out of the Dock shows its application.
            simulator.app_show(window.pid);
            simulator.focus_set(id);
        } else if (simulator.focused == id) {
            simulator.focus_fallback(window.pid, window.tab_group);
        }
    }

    /// Native fullscreen, entered and left with the green button. The window fills the
    /// display it is on, and afterwards returns to the frame it had. The frame changes
    /// when the animation ends, and the notification comes when it comes: the engine
    /// hears of the two in either order.
    pub fn window_fullscreen(
        simulator: *Simulator,
        id: WindowId,
        fullscreen: bool,
        timing: struct { frame_ms: u64 = 0, notice_ms: u64 = 0 },
    ) void {
        const window = simulator.window_find(id) orelse return;
        if (window.fullscreen == fullscreen or simulator.window_away(window)) return;
        // The button does nothing while the window is still on its way.
        if (window.in_transition) return;
        // Dialogs and fixed windows have no such button. Tab groups are not modelled.
        if (window.kind != .standard or !window.resizable or window.tab_group != 0) return;
        simulator.fullscreen_modelled = true;
        if (fullscreen) window.restore = window.frame;
        window.fullscreen = fullscreen;
        window.in_transition = true;
        simulator.coverage.fullscreen += 1;
        // An animation of its own that was on its way ends here.
        window.animation += 1;
        simulator.push(
            timing.frame_ms,
            .{ .at_ms = 0, .seq = 0, .kind = .fullscreen_end, .id = id },
        );
        simulator.push(
            timing.notice_ms + simulator.jitter(20),
            .{ .at_ms = 0, .seq = 0, .kind = .fullscreen, .id = id },
        );
        if (fullscreen) simulator.focus_set(id);
    }

    /// The display a frame is on: the one under its centre, else the first.
    fn display_of(simulator: *const Simulator, frame: Rect) *const MonitorInfo {
        assert(simulator.monitors.len > 0);
        for (simulator.monitors) |*info| {
            if (info.frame.contains_point(frame.center_x(), frame.center_y())) return info;
        }
        return &simulator.monitors[0];
    }

    /// cmd-h: every window of the application leaves the screen. The shell reports each
    /// one as minimized.
    pub fn app_hide(simulator: *Simulator, pid: i32) void {
        const app = simulator.app_find(pid) orelse return;
        if (app.hidden) return;
        app.hidden = true;
        simulator.coverage.hidden += 1;
        var focus_lost = false;
        for (&simulator.windows) |*window| {
            if (window.id == 0 or window.pid != pid or window.kind == .popup) continue;
            if (simulator.focused == window.id) focus_lost = true;
            simulator.push(
                simulator.jitter(20),
                .{ .at_ms = 0, .seq = 0, .kind = .minimized, .id = window.id },
            );
        }
        if (focus_lost) simulator.focus_fallback(0, 0);
    }

    /// The application comes back, with focus on one of its windows. A window that was
    /// minimized by itself stays in the Dock.
    pub fn app_show(simulator: *Simulator, pid: i32) void {
        const app = simulator.app_find(pid) orelse return;
        if (!app.hidden) return;
        app.hidden = false;
        var front: WindowId = 0;
        for (&simulator.windows) |*window| {
            if (window.id == 0 or window.pid != pid or window.kind == .popup) continue;
            if (window.minimized) continue;
            if (front == 0) front = window.id;
            simulator.push(
                simulator.jitter(20),
                .{ .at_ms = 0, .seq = 0, .kind = .minimized, .id = window.id },
            );
        }
        if (front != 0) simulator.focus_set(front);
    }

    pub fn window_title(simulator: *Simulator, id: WindowId, title: []const u8) void {
        const window = simulator.window_find(id) orelse return;
        window.title = title;
        simulator.push(
            simulator.jitter(20),
            .{ .at_ms = 0, .seq = 0, .kind = .title_changed, .id = id },
        );
    }

    /// Drags a tab out of its group. Of a group of three or more, the shell would not
    /// report the window that shows as dragged out, but the tab that shows in its place;
    /// here it is the window itself, which the engine takes no notice of. The tabs that
    /// stay are then tabs of a window that left, in the engine's eyes, until focus moves
    /// between them. Nothing checks tab groups against the engine for that reason.
    pub fn tab_detach(simulator: *Simulator, id: WindowId) void {
        const window = simulator.window_find(id) orelse return;
        if (window.tab_group == 0) return;
        const group = window.tab_group;
        window.tab_group = 0;
        simulator.push(
            simulator.jitter(20),
            .{ .at_ms = 0, .seq = 0, .kind = .tab_changed, .id = id },
        );
        simulator.tab_group_shrink(group);
        simulator.frame_assign(window, simulator.frame_random(window.min_w, window.min_h));
    }

    pub fn monitors_set(simulator: *Simulator, preset: u32) void {
        simulator.displays_set(monitor_presets[preset]);
    }

    /// The displays change to this list, or wake up as it.
    pub fn displays_set(simulator: *Simulator, list: []const MonitorInfo) void {
        simulator.displays_change(list, 0, 0);
    }

    /// The displays change to this list, in which the display that had one id may have
    /// come back under another.
    fn displays_change(simulator: *Simulator, list: []const MonitorInfo, from: u32, to: u32) void {
        assert(list.len > 0);
        simulator.monitors = list;
        simulator.asleep = false;
        // A fullscreen window fills whatever display it is on now.
        for (&simulator.windows) |*window| {
            if (window.id == 0 or !window.fullscreen or window.in_transition) continue;
            simulator.frame_assign(window, simulator.display_of(window.frame).frame);
        }
        var shown: [engine_module.monitors_max]Shown = undefined;
        const count = simulator.shown_snapshot(&shown, from, to);
        simulator.step(.{ .monitors_changed = list });
        simulator.shown_check(shown[0..count]);
    }

    const Shown = struct { display: u32, workspace: u8 };

    /// Which workspace of its own every display shows, before the displays change. A
    /// workspace that waits on the main display while its own is gone does not count.
    fn shown_snapshot(
        simulator: *Simulator,
        shown: *[engine_module.monitors_max]Shown,
        from: u32,
        to: u32,
    ) u32 {
        const engine = simulator.engine;
        var count: u32 = 0;
        // Asleep, the engine keeps the displays that went to sleep.
        for (engine.monitors[0..@max(engine.monitors_count, engine.monitors_asleep)]) |*known| {
            if (engine.workspaces[known.workspace].display != known.display) continue;
            const display = if (known.display == from) to else known.display;
            shown[count] = .{ .display = display, .workspace = known.workspace };
            count += 1;
        }
        return count;
    }

    /// A display that is still there shows what it showed, whatever happened to the other
    /// displays, to its id or to its resolution. Only the window in use comes first: its
    /// workspace shows on its display.
    fn shown_check(simulator: *Simulator, before: []const Shown) void {
        const engine = simulator.engine;
        var in_use: ?u8 = null;
        if (engine.window_find(engine.focused_window)) |window| {
            in_use = engine.workspace_monitor(window.workspace);
        }
        for (before) |entry| {
            for (engine.monitors[0..engine.monitors_count], 0..) |*known, index| {
                if (known.display != entry.display) continue;
                if (in_use != null and in_use.? == index) continue;
                assert(known.workspace == entry.workspace);
            }
        }
    }

    /// Every display goes to sleep: the shell reports that there are none.
    pub fn displays_sleep(simulator: *Simulator) void {
        simulator.asleep = true;
        simulator.coverage.asleep += 1;
        simulator.step(.{ .monitors_changed = &.{} });
    }

    /// Copies the displays there are, for a change to one of them.
    fn displays_copy(simulator: *Simulator, list: *[engine_module.monitors_max]MonitorInfo) u32 {
        const count: u32 = @intCast(simulator.monitors.len);
        @memcpy(list[0..count], simulator.monitors);
        return count;
    }

    fn displays_apply(simulator: *Simulator, list: []const MonitorInfo) void {
        @memcpy(simulator.monitors_buffer[0..list.len], list);
        simulator.displays_set(simulator.monitors_buffer[0..list.len]);
    }

    /// A display reconnects and macOS gives it another id.
    pub fn display_renumber(simulator: *Simulator, index: u32, display: u32) void {
        var list: [engine_module.monitors_max]MonitorInfo = undefined;
        const count = simulator.displays_copy(&list);
        assert(index < count);
        for (list[0..count]) |*info| {
            if (info.display == display) return;
        }
        const before = list[index].display;
        list[index].display = display;
        simulator.coverage.renumbered += 1;
        @memcpy(simulator.monitors_buffer[0..count], list[0..count]);
        simulator.displays_change(simulator.monitors_buffer[0..count], before, display);
    }

    /// A display changes its resolution, and where its Dock is, in place. The displays
    /// to the right of it and below it move along. Nothing changes when they would end
    /// up on top of each other.
    pub fn display_resize(simulator: *Simulator, index: u32, w: i32, h: i32, dock_side: u32) void {
        var list: [engine_module.monitors_max]MonitorInfo = undefined;
        const count = simulator.displays_copy(&list);
        assert(index < count);
        const old = list[index].frame;
        for (list[0..count], 0..) |*info, other| {
            if (other == index) continue;
            const dx = if (info.frame.x >= old.right()) w - old.w else 0;
            const dy = if (info.frame.y >= old.bottom()) h - old.h else 0;
            info.frame.x += dx;
            info.frame.y += dy;
            info.visible.x += dx;
            info.visible.y += dy;
        }
        list[index].frame.w = w;
        list[index].frame.h = h;
        list[index].visible = visible_area(list[index].frame, dock_side);
        for (list[0..count], 0..) |*info, at| {
            for (list[0..at]) |*before| {
                if (info.frame.intersects(before.frame)) return;
            }
        }
        simulator.coverage.resized += 1;
        simulator.displays_apply(list[0..count]);
    }

    /// Another display becomes the main one, as when the menu bar is dragged over.
    pub fn display_main(simulator: *Simulator, index: u32) void {
        var list: [engine_module.monitors_max]MonitorInfo = undefined;
        const count = simulator.displays_copy(&list);
        assert(index < count);
        simulator.coverage.main_moved += @intFromBool(!list[index].main);
        for (list[0..count], 0..) |*info, at| info.main = at == index;
        simulator.displays_apply(list[0..count]);
    }

    pub fn adoption(simulator: *Simulator, phase: engine_module.Adoption) void {
        simulator.step(.{ .adoption = phase });
    }

    /// What a window manager that ran before left behind, as read at startup.
    pub fn remember(simulator: *Simulator, list: []const engine_module.WorkspaceMemory) void {
        simulator.step(.{ .workspaces_remembered = list });
    }

    pub fn command_run(simulator: *Simulator, text: []const u8) void {
        var pool: command.StringPool = .{};
        const parsed = command.parse(text, &pool) catch unreachable;
        simulator.step(.{ .command = parsed });
    }

    pub fn advance(simulator: *Simulator, ms: u64) void {
        simulator.now_ms += ms;
        _ = simulator.drain();
    }

    // The random workload.

    fn action(simulator: *Simulator) void {
        const prng = &simulator.prng;
        const faults = simulator.options.faults;
        const roll = prng.below(100);
        const window = simulator.window_random();
        const id: WindowId = if (window) |w| w.id else 0;
        // Displays that sleep wake up after a while, whatever else went on meanwhile.
        if (simulator.asleep and prng.chance(1, 12)) return simulator.action_wake();
        switch (roll) {
            0...37 => simulator.command_run(commands[prng.below(commands.len)]),
            38...49 => simulator.action_open_some(),
            50...55 => simulator.window_close(id),
            56...58 => {
                const template = app_templates[prng.below(app_templates.len)];
                _ = simulator.app_launch(template.name, template.bundle);
            },
            59 => if (window) |w| simulator.app_quit(w.pid),
            60...66 => simulator.window_click(id),
            67...71 => if (window) |w| simulator.action_drag(w),
            72...73 => if (window) |w| {
                if (!simulator.window_fixed(w)) {
                    simulator.frame_assign(w, simulator.frame_random(w.min_w, w.min_h));
                }
            },
            74...76 => if (window) |w| simulator.window_minimize(id, !w.minimized),
            77...78 => simulator.window_title(id, titles[prng.below(titles.len)]),
            79...80 => simulator.tab_detach(id),
            81...82 => if (window) |w| {
                if (faults) {
                    const app = simulator.app_find(w.pid).?;
                    app.unresponsive_until_ms = simulator.now_ms + 100 + prng.below(3000);
                }
            },
            83...85 => simulator.action_displays(),
            86...88 => if (faults) simulator.action_spurious(id),
            89 => simulator.action_remember(),
            90...92 => simulator.action_fullscreen(id),
            93...94 => if (window) |w| simulator.action_hide(w.pid),
            95...96 => if (faults) simulator.action_disorder(window),
            else => simulator.now_ms += 200,
        }
    }

    fn action_open_some(simulator: *Simulator) void {
        // Now and then several windows are reported in one go, as at startup.
        const batch = simulator.prng.chance(1, 8);
        if (batch) simulator.step(.{ .adoption = .begin });
        simulator.action_open();
        if (batch) {
            simulator.action_open();
            simulator.advance(2);
            simulator.step(.{ .adoption = .end });
        }
    }

    fn action_drag(simulator: *Simulator, window: *SimWindow) void {
        var frame = simulator.frame_random(window.min_w, window.min_h);
        if (simulator.prng.chance(1, 2)) {
            frame.w = window.frame.w;
            frame.h = window.frame.h;
        }
        simulator.window_drag(window.id, frame);
    }

    /// Windows leave fullscreen more readily than they enter it, so that few are in it
    /// at any one time.
    fn action_fullscreen(simulator: *Simulator, id: WindowId) void {
        var target = id;
        if (simulator.prng.chance(2, 3)) {
            for (&simulator.windows) |*window| {
                if (window.id != 0 and window.fullscreen) target = window.id;
            }
        }
        const window = simulator.window_find(target) orelse return;
        // The animation takes longer than any notification about it is late.
        simulator.window_fullscreen(target, !window.fullscreen, .{
            .frame_ms = 60 + simulator.jitter(340),
            .notice_ms = simulator.jitter(400),
        });
    }

    /// Hides the application, or more readily shows one that is hidden.
    fn action_hide(simulator: *Simulator, pid: i32) void {
        if (simulator.prng.chance(1, 4)) return simulator.action_hide_and_show(pid);
        if (simulator.prng.chance(2, 3)) {
            for (&simulator.apps) |*app| {
                if (app.pid != 0 and app.hidden) return simulator.app_show(app.pid);
            }
        }
        simulator.app_hide(pid);
    }

    /// cmd-h and back with nothing in between: every tile returns to the place it left.
    fn action_hide_and_show(simulator: *Simulator, pid: i32) void {
        const app = simulator.app_find(pid).?;
        if (app.hidden) return;
        // Focus that returns to a tab of a group changes which of them shows: left out.
        for (&simulator.windows) |*window| {
            if (window.id == 0 or window.pid != pid) continue;
            if (window.tab_group != 0) return;
            // So is a window that the engine still takes for a tab (see tab_detach).
            const known = simulator.engine.window_find(window.id) orelse continue;
            if (known.tab_of != 0) return;
        }
        simulator.settle();
        const floated = simulator.engine.stats.windows_auto_floated;
        const before = simulator.layout_hash();
        simulator.app_hide(pid);
        simulator.settle();
        simulator.app_show(pid);
        simulator.settle();
        const after = simulator.layout_hash();
        // A window that fights the layout may have been floated on the way. And focus
        // that falls on a tab whose group was minimized brings the group back as a tile.
        if (simulator.engine.stats.windows_auto_floated != floated) return;
        if (after.tiles > before.tiles) return;
        assert(after.tiles == before.tiles and after.hash == before.hash);
    }

    const Layout = struct { hash: u64, tiles: u32 };

    /// A hash of every workspace's tree: its splits, their ratios and the windows in
    /// them. The tabs of a group count as one window, whichever of them shows.
    fn layout_hash(simulator: *Simulator) Layout {
        const engine = simulator.engine;
        const forest = &engine.forest;
        var layout: Layout = .{ .hash = 0xcbf29ce484222325, .tiles = 0 };
        for (&engine.workspaces) |*workspace| {
            var index = workspace.root;
            while (index != tree.node_none) : (index = forest.next(workspace.root, index)) {
                const node = &forest.nodes[index];
                var words = [2]u32{ @backingInt(node.split), node.ratio };
                if (forest.is_leaf(index)) {
                    // A tab group is known by the lowest id in it.
                    words = .{ node.window, 0 };
                    for (&engine.windows) |*known| {
                        if (known.tab_of == node.window) words[0] = @min(words[0], known.id);
                    }
                    layout.tiles += 1;
                }
                for (words) |word| layout.hash = (layout.hash ^ word) *% 0x100000001b3;
            }
            layout.hash = (layout.hash ^ 0xffff_ffff) *% 0x100000001b3;
        }
        return layout;
    }

    fn action_wake(simulator: *Simulator) void {
        // Mostly the displays that went to sleep wake up, sometimes others.
        if (simulator.prng.chance(1, 4)) {
            return simulator.monitors_set(simulator.prng.below(monitor_presets.len));
        }
        simulator.displays_set(simulator.monitors);
    }

    /// Displays are plugged, unplugged and rearranged, go to sleep, come back under
    /// another id, change their resolution in place, and trade the menu bar.
    fn action_displays(simulator: *Simulator) void {
        const prng = &simulator.prng;
        const index = prng.below(@intCast(simulator.monitors.len));
        switch (prng.below(10)) {
            0...3 => simulator.monitors_set(prng.below(monitor_presets.len)),
            4...5 => simulator.displays_sleep(),
            6 => simulator.display_renumber(index, 1 + prng.below(display_ids)),
            7...8 => {
                const size = display_sizes[prng.below(display_sizes.len)];
                simulator.display_resize(index, size[0], size[1], prng.below(4));
            },
            else => simulator.display_main(index),
        }
    }

    /// What macOS reports in another order than one would expect, or twice.
    fn action_disorder(simulator: *Simulator, window: ?*SimWindow) void {
        const prng = &simulator.prng;
        const id: WindowId = if (window) |w| w.id else 0;
        simulator.coverage.disorder += @intFromBool(window != null);
        switch (prng.below(6)) {
            // Focus moves on long before the window is reported destroyed.
            0 => simulator.window_close_late(id, 40 + prng.below(600)),
            1 => {
                // The window is reported destroyed twice.
                simulator.window_close(id);
                simulator.push(
                    simulator.jitter(40),
                    .{ .at_ms = 0, .seq = 0, .kind = .destroyed, .id = id },
                );
            },
            // The application is reported gone before its windows are.
            2 => if (window) |w| simulator.app_quit_late(w.pid, 40 + prng.below(300)),
            3 => if (window) |w| {
                // A window that is known already is reported again.
                if (w.kind == .popup) return;
                simulator.step(.{ .window_appeared = simulator.window_info(w) });
            },
            else => simulator.action_stale(),
        }
    }

    /// Notifications about a window that is gone, or that the engine never heard of.
    fn action_stale(simulator: *Simulator) void {
        const prng = &simulator.prng;
        var popup: WindowId = 0;
        for (&simulator.windows) |*window| {
            if (window.id != 0 and window.kind == .popup) popup = window.id;
        }
        const ids = [3]WindowId{ simulator.gone, 999_999, popup };
        const id = ids[prng.below(ids.len)];
        if (id == 0) return;
        simulator.coverage.stale += 1;
        const frame = simulator.frame_random(1, 1);
        const flag = prng.chance(1, 2);
        simulator.step(switch (prng.below(6)) {
            0 => .{ .window_frame_applied = .{ .id = id, .frame = frame } },
            1 => .{ .window_frame_changed = .{ .id = id, .frame = frame, .by_user = flag } },
            2 => .{ .window_title_changed = .{ .id = id, .title = "Inbox" } },
            3 => .{ .window_minimized = .{ .id = id, .minimized = flag } },
            4 => .{ .window_fullscreen = .{ .id = id, .fullscreen = flag } },
            else => .{ .window_destroyed = id },
        });
    }

    /// What a state file left by another window manager may say: anything at all. The
    /// engine takes it only while it has no windows, as at the start of a run.
    fn action_remember(simulator: *Simulator) void {
        const prng = &simulator.prng;
        var list: [6]engine_module.WorkspaceMemory = undefined;
        const count = prng.below(list.len + 1);
        for (list[0..count]) |*memory| {
            memory.* = .{
                .workspace = @intCast(prng.below(20)),
                .display = @intCast(prng.below(5)),
                .shown = prng.chance(1, 2),
            };
        }
        simulator.remember(list[0..count]);
    }

    fn action_open(simulator: *Simulator) void {
        const prng = &simulator.prng;
        const faults = simulator.options.faults;
        var apps_count: u32 = 0;
        for (&simulator.apps) |*app| apps_count += @intFromBool(app.pid != 0);
        if (apps_count == 0) {
            _ = simulator.app_launch(app_templates[0].name, app_templates[0].bundle);
            return;
        }
        var pick = prng.below(apps_count);
        var pid: i32 = 0;
        for (&simulator.apps) |*app| {
            if (app.pid == 0) continue;
            if (pick == 0) pid = app.pid;
            pick -%= 1;
        }
        assert(pid != 0);
        var peer: WindowId = 0;
        for (&simulator.windows) |*window| {
            if (window.id == 0 or window.pid != pid or window.kind != .standard) continue;
            // A fullscreen window takes no tabs here: tab groups in fullscreen are not modelled.
            if (!window.fullscreen) peer = window.id;
        }
        const kind_roll = prng.below(100);
        const constrained = faults and prng.chance(1, 4);
        _ = simulator.window_open(pid, .{
            .title = titles[prng.below(titles.len)],
            .kind = if (kind_roll < 85) .standard else if (kind_roll < 95) .dialog else .popup,
            .resizable = prng.chance(92, 100),
            .min_w = if (constrained) prng.range(300, 900) else 1,
            .min_h = if (constrained) prng.range(300, 700) else 1,
            .stubborn = faults and prng.chance(6, 100),
            .animates = faults and prng.chance(12, 100),
            .tab_of = if (kind_roll < 85 and prng.chance(15, 100)) peer else 0,
            .late_title = prng.chance(1, 5),
            .focus = prng.chance(9, 10),
            .adopted = prng.chance(1, 10),
            // Any number at all: what a file says is not to be trusted.
            .left_on = if (prng.chance(1, 3)) @intCast(prng.below(40)) else null,
            .title_bar = if (faults) title_bars[prng.below(title_bars.len)] else 0,
        });
    }

    /// Notifications that are late, duplicated or about things that no longer exist.
    fn action_spurious(simulator: *Simulator, id: WindowId) void {
        switch (simulator.prng.below(6)) {
            0 => simulator.push(
                simulator.jitter(50),
                .{ .at_ms = 0, .seq = 0, .kind = .frame_changed, .id = id },
            ),
            1 => simulator.push(simulator.jitter(50), .{ .at_ms = 0, .seq = 0, .kind = .focused }),
            2 => simulator.step(.{ .window_destroyed = 999_999 }),
            3 => simulator.step(.{
                .window_frame_applied = .{ .id = 999_999, .frame = Rect.zero },
            }),
            4 => simulator.step(.{ .app_unresponsive = 77 }),
            else => simulator.step(.tick),
        }
    }

    pub fn run(simulator: *Simulator, steps: u32) void {
        var index: u32 = 0;
        while (index < steps) : (index += 1) {
            simulator.now_ms += simulator.prng.below(60);
            _ = simulator.drain();
            simulator.action();
            if (index % 97 == 96) simulator.settle();
        }
        simulator.settle();
        simulator.teardown();
    }

    /// Lets every pending event and timer play out, then checks that the engine and the
    /// simulated OS agree. Asserts that this takes a bounded number of events.
    pub fn settle(simulator: *Simulator) void {
        for (&simulator.apps) |*app| app.unresponsive_until_ms = 0;
        var sets: [engine_module.windows_max]u32 = undefined;
        for (&simulator.engine.windows, &sets) |*known, *count| count.* = known.sets_total;
        var events: u32 = 0;
        while (true) {
            events += simulator.drain();
            assert(events < settle_events_max);
            const queue_at = simulator.queue_next_at();
            const deadline = simulator.engine.next_deadline_ms();
            if (queue_at == null and deadline == null) break;
            const next =
                @min(queue_at orelse std.math.maxInt(u64), deadline orelse std.math.maxInt(u64));
            assert(next > simulator.now_ms);
            simulator.now_ms = next;
        }
        // Going quiet costs a window a bounded number of frames, however it behaves.
        for (&simulator.engine.windows, &sets) |*known, count| {
            assert(known.sets_total -| count <= settle_frames_max);
        }
        simulator.settles += 1;
        simulator.check_agreement();
    }

    fn check_agreement(simulator: *Simulator) void {
        const engine = simulator.engine;
        var tracked: u32 = 0;
        for (&simulator.windows) |*window| {
            if (window.id == 0) continue;
            if (window.kind == .popup) {
                assert(engine.window_find(window.id) == null);
                continue;
            }
            const known = engine.window_find(window.id).?;
            tracked += 1;
            // The engine's picture of the world is the world.
            assert(known.actual.eql(window.frame));
            assert(known.minimized == simulator.window_away(window));
            if (simulator.fullscreen_modelled) assert(known.fullscreen == window.fullscreen);
            // A sticky window is on whichever workspace its display shows.
            if (known.sticky and engine.monitors_count > 0) {
                assert(engine.workspace_visible(known.workspace));
            }
            if (!known.managed() or engine.monitors_count == 0) continue;
            assert(known.desired_valid);
            assert(!known.set_pending);
            if (known.frozen or window.stubborn) continue;
            // Every window is where it should be, as far as its minimum size and the
            // title bar rule of macOS allow.
            const expected: Rect = .{
                .x = known.desired.x,
                .y = known.desired.y,
                .w = @max(known.desired.w, window.min_w),
                .h = @max(known.desired.h, window.min_h),
            };
            // A window too tall for its tile hangs off the screen, and macOS lifts it.
            var lifted = expected;
            lifted.y = simulator.title_bar_keep(window, expected);
            const agrees = window.frame.eql(expected) or window.frame.eql(lifted);
            if (!agrees) simulator.report(window, known, expected);
            assert(agrees);
            if (!engine.workspace_visible(known.workspace)) simulator.check_parked(window, known);
        }
        var engine_windows: u32 = 0;
        for (&engine.windows) |*known| engine_windows += @intFromBool(known.id != 0);
        assert(engine_windows == tracked);
        simulator.check_leaves();
        simulator.check_tiles();
        simulator.check_focus();
    }

    /// A hidden window shows a sliver one pixel wide on its own display. Of the other
    /// displays it covers no more than it would from the best of the four places where
    /// a window can wait: nothing at all, wherever a corner is free.
    fn check_parked(
        simulator: *Simulator,
        window: *const SimWindow,
        known: *const engine_module.Window,
    ) void {
        const engine = simulator.engine;
        const index = engine.workspace_monitor(known.workspace);
        const own = engine.monitors[index].frame;
        const frame = window.frame;
        assert(frame.overlap(own, .x) <= 1 or frame.overlap(own, .y) <= 1);
        // A window that macOS lifted further than the engine allows for is where it is.
        if (!frame.eql(known.desired)) return;
        const y = own.bottom() - 1 - known.park_lift;
        const top = engine.monitors[index].visible.y;
        const spots = [4]Rect{
            .{ .x = own.right() - 1, .y = y, .w = frame.w, .h = frame.h },
            .{ .x = own.x - frame.w + 1, .y = y, .w = frame.w, .h = frame.h },
            .{ .x = own.right() - 1, .y = top, .w = frame.w, .h = frame.h },
            .{ .x = own.x - frame.w + 1, .y = top, .w = frame.w, .h = frame.h },
        };
        var least: i64 = std.math.maxInt(i64);
        for (spots) |spot| least = @min(least, simulator.shown_elsewhere(spot, index));
        const shown = simulator.shown_elsewhere(frame, index);
        if (shown > least) {
            std.debug.print("seed {d}: hidden window {d} shows {d} pixels, {d} at best\n", .{
                simulator.options.seed, window.id, shown, least,
            });
        }
        assert(shown <= least);
    }

    /// How many pixels of the rect lie on displays other than the given one.
    fn shown_elsewhere(simulator: *Simulator, rect: Rect, except: u8) i64 {
        const engine = simulator.engine;
        var total: i64 = 0;
        for (engine.monitors[0..engine.monitors_count], 0..) |*other, index| {
            if (index == except) continue;
            const w = rect.overlap(other.frame, .x);
            const h = rect.overlap(other.frame, .y);
            if (w > 0 and h > 0) total += @as(i64, w) * h;
        }
        return total;
    }

    /// Every window that tiles has exactly one leaf, in the tree of the workspace it
    /// belongs to. A window that floats, is minimized, hidden with its application, in
    /// native fullscreen or a background tab has none.
    fn check_leaves(simulator: *Simulator) void {
        const engine = simulator.engine;
        const forest = &engine.forest;
        var leaves: [windows_max]u8 = @splat(0);
        for (&engine.workspaces, 0..) |*workspace, workspace_index| {
            var leaf = forest.leaf_first(workspace.root);
            while (leaf != tree.node_none) : (leaf = forest.leaf_next(workspace.root, leaf)) {
                const id = forest.nodes[leaf].window;
                const window = simulator.window_find(id).?;
                assert(engine.window_find(id).?.workspace == workspace_index);
                leaves[window - &simulator.windows[0]] += 1;
            }
        }
        for (&simulator.windows, 0..) |*window, index| {
            if (window.id == 0 or window.kind == .popup) {
                assert(leaves[index] == 0);
                continue;
            }
            const known = engine.window_find(window.id).?;
            assert(known.workspace < engine_module.workspaces_max);
            const fullscreen =
                if (simulator.fullscreen_modelled) window.fullscreen else known.fullscreen;
            const tiles = known.mode == .tiled and !known.ignored and known.tab_of == 0 and
                !fullscreen and !simulator.window_away(window);
            assert(leaves[index] == @intFromBool(tiles));
        }
    }

    /// True for a tile that is where the layout puts it: on a workspace that shows, not
    /// zoomed over the others, and not a window that keeps a size or a place of its own.
    fn tile_placed(
        simulator: *Simulator,
        window: *const SimWindow,
        known: *const engine_module.Window,
    ) bool {
        if (!known.in_layout() or known.zoom != .none) return false;
        if (!simulator.engine.workspace_visible(known.workspace)) return false;
        if (known.frozen or window.stubborn) return false;
        // A tile that the gaps squeeze to nothing is still sent a frame one pixel wide,
        // and that pixel lies on its neighbour.
        const forest = &simulator.engine.forest;
        const rect = forest.nodes[forest.leaf_find(known.id)].rect;
        if (rect.w == 0 or rect.h == 0) return false;
        return window.frame.eql(known.desired);
    }

    /// The tiles of a workspace that shows lie inside the visible area of its display
    /// and do not overlap each other.
    fn check_tiles(simulator: *Simulator) void {
        const engine = simulator.engine;
        if (engine.monitors_count == 0) return;
        for (&simulator.windows, 0..) |*window, index| {
            const known = engine.window_find(window.id) orelse continue;
            if (!simulator.tile_placed(window, known)) continue;
            const area = engine.monitors[engine.workspace_monitor(known.workspace)].visible;
            const frame = window.frame;
            assert(frame.x >= area.x and frame.right() <= area.right());
            assert(frame.y >= area.y and frame.bottom() <= area.bottom());
            // The tiles of an accordion are stacked: each one fills the workspace.
            if (engine.workspaces[known.workspace].accordion) {
                const shown_on = engine.workspace_monitor(known.workspace);
                assert(frame.eql(engine.workspace_rect(shown_on)));
                simulator.coverage.stacked += 1;
                continue;
            }
            for (simulator.windows[0..index]) |*other| {
                const beside = engine.window_find(other.id) orelse continue;
                if (beside.workspace != known.workspace) continue;
                if (!simulator.tile_placed(other, beside)) continue;
                if (frame.intersects(other.frame)) {
                    std.debug.print("seed {d}: tiles {d} and {d} overlap\n", .{
                        simulator.options.seed, window.id, other.id,
                    });
                }
                assert(!frame.intersects(other.frame));
            }
        }
    }

    fn report(
        simulator: *Simulator,
        window: *const SimWindow,
        known: *const engine_module.Window,
        expected: Rect,
    ) void {
        std.debug.print(
            "seed {d}: window {d} is at {d},{d} {d}x{d}, expected {d},{d} {d}x{d}\n" ++
                "  workspace={d} visible={} mode={s} zoom={s} attempts={d} min={d}x{d} " ++
                "animates={} group={d}\n",
            .{
                simulator.options.seed, window.id,
                window.frame.x,         window.frame.y,
                window.frame.w,         window.frame.h,
                expected.x,             expected.y,
                expected.w,             expected.h,
                known.workspace + 1,    simulator.engine.workspace_visible(known.workspace),
                @tagName(known.mode),   @tagName(known.zoom),
                known.attempts,         window.min_w,
                window.min_h,           window.animates,
                window.tab_group,
            },
        );
    }

    fn check_focus(simulator: *Simulator) void {
        const engine = simulator.engine;
        if (engine.focused_window != 0) {
            // The window the engine has focus on is one that can be seen and typed into.
            const holder = engine.window_find(engine.focused_window).?;
            const window = simulator.window_find(holder.id).?;
            assert(!simulator.window_away(window));
            assert(!holder.ignored and holder.tab_of == 0);
            assert(engine.monitors_count == 0 or engine.workspace_visible(holder.workspace));
        }
        const known = engine.window_find(simulator.focused) orelse return;
        if (!known.focusable()) return;
        if (engine.focused_window == known.id) return;
        // The only excuses for disagreeing with the OS: the engine deliberately holds no
        // focus, because the OS-focused window is on a hidden workspace or because the
        // user moved to a monitor that has no windows.
        assert(engine.focused_window == 0);
        if (engine.monitors_count == 0) return;
        const hidden = !engine.workspace_visible(known.workspace);
        const elsewhere = engine.workspace_monitor(known.workspace) != engine.focused_monitor;
        if (!hidden and !elsewhere) {
            std.debug.print("seed {d}: focus lost: os={d} workspace={d} monitor={d} stale={}\n", .{
                simulator.options.seed, known.id,           known.workspace + 1,
                engine.focused_monitor, engine.focus_stale,
            });
        }
        assert(hidden or elsewhere);
    }

    /// Closes everything and checks that nothing leaked.
    fn teardown(simulator: *Simulator) void {
        for (&simulator.windows) |*window| {
            if (window.id != 0) simulator.window_close(window.id);
        }
        simulator.settle();
        for (&simulator.engine.windows) |*known| assert(known.id == 0);
        assert(simulator.engine.forest.free_count == tree.nodes_max);
        assert(simulator.engine.focused_window == 0);
    }

    // A window manager that restarts. The tests of it drive these.

    /// The random workload without its end: the windows stay open.
    pub fn run_open(simulator: *Simulator, steps: u32) void {
        var index: u32 = 0;
        while (index < steps) : (index += 1) {
            simulator.now_ms += simulator.prng.below(60);
            _ = simulator.drain();
            simulator.action();
            if (index % 97 == 96) simulator.settle();
        }
        simulator.settle();
    }

    /// Hands the engine an event that the simulator has no call for, and performs what
    /// it answers.
    pub fn inject(simulator: *Simulator, event: engine_module.Event) void {
        simulator.step(event);
    }

    /// Another window manager takes over. What the OS still had to tell the old one is
    /// lost with it; what the windows were doing by themselves they finish.
    pub fn handover(simulator: *Simulator, engine: *Engine) void {
        var events: u32 = 0;
        while (simulator.queue_next_at()) |at| {
            simulator.now_ms = @max(simulator.now_ms, at);
            while (simulator.pop_due()) |entry| : (events += 1) {
                assert(events < settle_events_max);
                switch (entry.kind) {
                    .self_move, .animation_end, .late_title => simulator.deliver(entry),
                    else => {},
                }
            }
        }
        simulator.engine = engine;
    }
};

fn trace_step(
    simulator: *Simulator,
    event: engine_module.Event,
    effects: []const engine_module.Effect,
) void {
    std.debug.print("{d:>8} ", .{simulator.now_ms});
    switch (event) {
        .window_appeared => |e| std.debug.print(
            "appeared {d} pid={d} tab_of={d} kind={s}",
            .{ e.id, e.pid, e.tab_of, @tagName(e.kind) },
        ),
        .window_destroyed => |id| std.debug.print("destroyed {d}", .{id}),
        .window_frame_applied => |e| std.debug.print(
            "applied {d} {d},{d} {d}x{d}",
            .{ e.id, e.frame.x, e.frame.y, e.frame.w, e.frame.h },
        ),
        .window_frame_changed => |e| std.debug.print(
            "changed {d} {d},{d} {d}x{d} user={}",
            .{ e.id, e.frame.x, e.frame.y, e.frame.w, e.frame.h, e.by_user },
        ),
        .window_focused => |id| std.debug.print("focused {d}", .{id}),
        .focus_reported => |id| std.debug.print("focus-report {d}", .{id}),
        .window_minimized => |e| std.debug.print("minimized {d} {}", .{ e.id, e.minimized }),
        .window_fullscreen => |e| std.debug.print("fullscreen {d} {}", .{ e.id, e.fullscreen }),
        .window_tab_changed => |e| std.debug.print("tab {d} of {d}", .{ e.id, e.tab_of }),
        .window_title_changed => |e| std.debug.print("title {d} {s}", .{ e.id, e.title }),
        .app_launched => |e| std.debug.print("launched {d} {s}", .{ e.pid, e.name }),
        .app_terminated => |pid| std.debug.print("terminated {d}", .{pid}),
        .app_unresponsive => |pid| std.debug.print("unresponsive {d}", .{pid}),
        .monitors_changed => |list| std.debug.print("monitors {d}", .{list.len}),
        .command => |cmd| std.debug.print("command {s}", .{@tagName(cmd)}),
        else => std.debug.print("{s}", .{@tagName(event)}),
    }
    const engine = simulator.engine;
    const shown: u32 = if (engine.monitors_count > 0) engine.workspace_current() + 1 else 0;
    std.debug.print("  [focus={d} os={d} monitor={d} workspace={d}]\n", .{
        engine.focused_window, simulator.focused, engine.focused_monitor, shown,
    });
    for (effects) |effect| {
        switch (effect) {
            .set_frame => |e| std.debug.print(
                "           -> set {d} {d},{d} {d}x{d}\n",
                .{ e.id, e.frame.x, e.frame.y, e.frame.w, e.frame.h },
            ),
            .focus_window => |e| std.debug.print("           -> focus {d}\n", .{e.id}),
            else => std.debug.print("           -> {s}\n", .{@tagName(effect)}),
        }
    }
}

/// One full simulation run. Returns the number of events delivered.
pub fn run_seed(engine: *Engine, simulator: *Simulator, seed: u64, steps: u32, faults: bool) u64 {
    var config: config_module.Config = undefined;
    config.load_default();
    engine.init(&config);
    simulator.init(engine, .{ .seed = seed, .faults = faults });
    simulator.run(steps);
    return simulator.delivered;
}

var test_engine: Engine = undefined;
var test_simulator: Simulator = undefined;

test "simulation: a hundred seeds with faults" {
    var seed: u64 = 1;
    while (seed <= 100) : (seed += 1) {
        _ = run_seed(&test_engine, &test_simulator, seed, 600, true);
    }
}

test "simulation: the workload plays fullscreen, hidden applications and changing displays" {
    _ = run_seed(&test_engine, &test_simulator, 3, 5000, true);
    const coverage = test_simulator.coverage;
    inline for (@typeInfo(Coverage).@"struct".field_names) |name| {
        try std.testing.expect(@field(coverage, name) > 0);
    }
}

test "simulation: is deterministic" {
    const first = run_seed(&test_engine, &test_simulator, 7, 800, true);
    const first_sets = test_simulator.frames_set;
    const second = run_seed(&test_engine, &test_simulator, 7, 800, true);
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(first_sets, test_simulator.frames_set);
}
