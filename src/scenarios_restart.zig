//! Restart tests: a window manager that quits and one that starts in its place, against
//! the same simulated OS. The one that starts reads the state file that the other one
//! wrote, and must end up where that one left off: the same windows on the same
//! workspaces, the same layout, the same focus, and no window moved that was in view.
//! The file may also be old, cut short or made up, and then the one that starts must
//! still end up with a layout that holds.
const std = @import("std");
const testing = std.testing;
const geometry = @import("geometry.zig");
const stdx = @import("stdx.zig");
const tree = @import("tree.zig");
const command = @import("command.zig");
const config_module = @import("config.zig");
const engine_module = @import("engine.zig");
const state_module = @import("state.zig");
const sim = @import("sim.zig");

const Rect = geometry.Rect;
const Engine = engine_module.Engine;
const Mode = engine_module.Mode;
const Window = engine_module.Window;
const WindowId = engine_module.WindowId;
const WindowMemory = engine_module.WindowMemory;
const State = state_module.State;
const MonitorInfo = engine_module.MonitorInfo;
const node_none = tree.node_none;
const workspaces_max = engine_module.workspaces_max;
const windows_max = engine_module.windows_max;

/// How many seeds each test over random workloads runs. They are quick at this number;
/// a longer search only needs a larger one.
const seeds: u64 = 16;

/// Two window managers that take turns: one quits, the other starts.
var first: Engine = undefined;
var second: Engine = undefined;
var simulator: sim.Simulator = undefined;
var config: config_module.Config = undefined;

/// The state file, as the shell last wrote it.
var file: [state_module.bytes_max]u8 = undefined;
var file_len: usize = 0;
/// What the window manager that runs now read from the file when it started.
var left: State = .{};
/// Where every window of the simulated OS was when the state was written down.
var frames_before: [sim.windows_max]Rect = undefined;
/// The window that is in native fullscreen, which the simulator has no notion of.
var fullscreen: WindowId = 0;

// The simulated laptop screen: 1728x1117 with a 38 pixel menu bar.
const screen = Rect.init(0, 38, 1728, 1079);
const left_half = Rect.init(0, 38, 864, 1079);
const right_half = Rect.init(864, 38, 864, 1079);
const right_top = Rect.init(864, 38, 864, 540);
const right_bottom = Rect.init(864, 578, 864, 539);

/// A window manager under the random workload of the simulator.
fn boot(seed: u64, faults: bool) *sim.Simulator {
    config.load_default();
    fullscreen = 0;
    file_len = 0;
    left = .{};
    first.init(&config);
    simulator.init(&first, .{ .seed = seed, .faults = faults });
    return &simulator;
}

/// A window manager for a scenario: no faults, and the default configuration with
/// more lines added to it.
fn desk(extra_config: []const u8) *sim.Simulator {
    var source: [16 * 1024]u8 = undefined;
    const default = config_module.default_source;
    @memcpy(source[0..default.len], default);
    source[default.len] = '\n';
    @memcpy(source[default.len + 1 ..][0..extra_config.len], extra_config);
    var buffer: [512]u8 = undefined;
    var diagnostics = stdx.Text.init(&buffer);
    const ok = config.load(source[0 .. default.len + 1 + extra_config.len], &diagnostics);
    std.debug.assert(ok);
    fullscreen = 0;
    file_len = 0;
    left = .{};
    first.init(&config);
    simulator.init(&first, .{ .seed = 1, .faults = false });
    return &simulator;
}

/// Opens a window and lets the OS report it, so that windows appear in the order written.
fn open(os: *sim.Simulator, app: i32, options: sim.Simulator.WindowOptions) WindowId {
    const id = os.window_open(app, options);
    os.advance(1);
    return id;
}

fn frame_of(id: WindowId) Rect {
    return simulator.window_find(id).?.frame;
}

fn expect_frame(expected: Rect, id: WindowId) !void {
    const actual = frame_of(id);
    if (!actual.eql(expected)) {
        std.debug.print("window {d}: expected {any}, found {any}\n", .{ id, expected, actual });
        return error.TestUnexpectedResult;
    }
}

/// The window as the window manager that runs now knows it.
fn known(id: WindowId) *Window {
    return simulator.engine.window_find(id).?;
}

/// Runs a command built from a format string.
fn run(os: *sim.Simulator, comptime format: []const u8, args: anytype) void {
    var buffer: [128]u8 = undefined;
    os.command_run(std.fmt.bufPrint(&buffer, format, args) catch unreachable);
}

/// More than the one pixel of a parked window shows on some display.
fn in_view(os: *const sim.Simulator, frame: Rect) bool {
    for (os.monitors) |*monitor| {
        if (frame.overlap(monitor.frame, .x) > 1 and frame.overlap(monitor.frame, .y) > 1) {
            return true;
        }
    }
    return false;
}

// The part of the shell: what it writes at a quit and what it reports at a start.

fn app_runs(os: *sim.Simulator, pid: i32) bool {
    for (&os.apps) |*app| {
        if (app.pid == pid) return true;
    }
    return false;
}

/// Writes the state file, as the shell does when something changed and before the
/// window manager goes.
fn write_down(os: *sim.Simulator) void {
    tabs_compare(os, os.engine);
    for (&os.windows, &frames_before) |*window, *frame| frame.* = window.frame;
    var bytes: [state_module.bytes_max]u8 = undefined;
    var text = stdx.Text.init(&bytes);
    state_module.print(&text, os.engine);
    // Windows of the last run that were not reported yet keep their line for as long
    // as their application runs.
    for (left.windows_slice()) |window| {
        if (os.engine.window_find(window.id) != null or !app_runs(os, window.pid)) continue;
        state_module.window_print(&text, window);
    }
    // Nothing is written while every display is asleep: the file stays as it was.
    const content = text.slice();
    if (content.len == 0 or text.truncated) return;
    @memcpy(file[0..content.len], content);
    file_len = content.len;
}

fn quit(os: *sim.Simulator) void {
    write_down(os);
    os.command_run("quit");
}

/// The window manager that is not running now.
fn other(os: *const sim.Simulator) *Engine {
    return if (os.engine == &first) &second else &first;
}

/// Another window of the same tab group, as the shell finds it.
fn tab_peer(os: *sim.Simulator, id: WindowId, group: u32) WindowId {
    if (group == 0) return 0;
    for (&os.windows) |*peer| {
        if (peer.id != 0 and peer.id != id and peer.tab_group == group) return peer.id;
    }
    return 0;
}

/// Reports an application that is running, as the shell does at a start, and every
/// window of it that is open if the application answers.
fn report_app(os: *sim.Simulator, pid: i32, answers: bool) void {
    var hidden = false;
    for (&os.apps) |*app| {
        if (app.pid != pid) continue;
        hidden = app.hidden;
        const launched: engine_module.AppInfo =
            .{ .pid = app.pid, .name = app.name, .bundle = app.bundle };
        os.inject(.{ .app_launched = launched });
    }
    if (!answers) return;
    for (&os.windows) |*window| {
        if (window.id == 0 or window.pid != pid) continue;
        os.inject(.{ .window_appeared = .{
            .id = window.id,
            .pid = window.pid,
            .title = window.title,
            .frame = window.frame,
            .kind = window.kind,
            .resizable = window.resizable,
            .minimized = window.minimized or hidden,
            .fullscreen = window.fullscreen or window.id == fullscreen,
            .tab_of = tab_peer(os, window.id, window.tab_group),
            .adopted = true,
        } });
    }
}

const Start = struct {
    /// The state file is read. When it is not, a test has put what it likes in its place.
    read: bool = true,
    /// An application that does not answer in time: its windows are reported late.
    slow: i32 = 0,
    /// Every display is asleep.
    asleep: bool = false,
};

/// The first half of a start: the displays and what was written down.
fn start_begin(os: *sim.Simulator, engine: *Engine, options: Start) void {
    engine.init(&config);
    os.handover(engine);
    const displays: []const MonitorInfo = if (options.asleep) &.{} else os.monitors;
    os.inject(.{ .monitors_changed = displays });
    // The displays make the engine ask where the keyboard is. The shell cannot say
    // before it knows any application, and the question goes unanswered.
    os.handover(engine);
    if (options.read) state_module.parse(file[0..file_len], &left);
    os.inject(.{ .windows_remembered = left.windows_slice() });
    if (left.workspaces_count > 0) {
        os.inject(.{ .workspaces_remembered = left.workspaces_slice() });
    }
    os.inject(.{ .adoption = .begin });
}

/// The second half: the adoption ends, and the shell says where the keyboard is.
fn start_end(os: *sim.Simulator) void {
    os.inject(.{ .adoption = .end });
    os.focus_repeat();
}

/// What the shell does when a window manager starts.
fn start(os: *sim.Simulator, engine: *Engine, options: Start) void {
    start_begin(os, engine, options);
    for (&os.apps) |*app| {
        if (app.pid != 0) report_app(os, app.pid, app.pid != options.slow);
    }
    start_end(os);
}

/// Any workload, ending with the displays awake: what a restart does while they sleep
/// has tests of its own.
fn workload(os: *sim.Simulator, steps: u32) void {
    os.run_open(steps);
    if (!os.asleep) return;
    os.displays_set(os.monitors);
    os.settle();
}

/// The window manager quits and another one starts in its place.
fn restart(os: *sim.Simulator) void {
    quit(os);
    start(os, other(os), .{});
    os.settle();
}

// Telling whether the window manager that started is where the other one left off.

fn differ(comptime format: []const u8, args: anytype) error{TestUnexpectedResult} {
    std.debug.print("restart: " ++ format ++ "\n", args);
    return error.TestUnexpectedResult;
}

/// How many windows had the focus before this one last had it.
fn focus_rank(engine: *const Engine, window: *const Window) u32 {
    var rank: u32 = 0;
    for (&engine.windows) |*earlier| {
        if (earlier.id != 0 and earlier.focus_seq < window.focus_seq) rank += 1;
    }
    return rank;
}

/// The same splits with the same ratios, and the same window in every tile.
fn layout_same(a: *const Engine, b: *const Engine, workspace: u8) bool {
    const root_a = a.workspaces[workspace].root;
    const root_b = b.workspaces[workspace].root;
    var x = root_a;
    var y = root_b;
    while (x != node_none and y != node_none) {
        const leaf = a.forest.is_leaf(x);
        if (leaf != b.forest.is_leaf(y)) return false;
        const one = &a.forest.nodes[x];
        const two = &b.forest.nodes[y];
        if (leaf and one.window != two.window) return false;
        if (!leaf and (one.split != two.split or one.ratio != two.ratio)) return false;
        x = a.forest.next(root_a, x);
        y = b.forest.next(root_b, y);
    }
    return x == y;
}

/// The workspaces on which the window manager that quit had the native tabs wrong. The
/// simulated OS can take the window that shows out of a group of three or more, and the
/// engine then goes on taking the others for its tabs. A restart sees the groups as they
/// are, so on those workspaces it does change something.
var tabs_mistaken: [workspaces_max]bool = @splat(false);
/// The same about the window that the keyboard is on: the window manager that starts
/// may then find the focus, and with it the workspace in use, somewhere else.
var focus_mistaken: bool = false;

fn tab_leader(engine: *Engine, id: WindowId) WindowId {
    const window = engine.window_find(id) orelse return id;
    return if (window.tab_of != 0) window.tab_of else id;
}

fn tabs_compare(os: *sim.Simulator, engine: *Engine) void {
    tabs_mistaken = @splat(false);
    focus_mistaken = false;
    const focused_group = if (os.window_find(os.focused)) |window| window.tab_group else 0;
    for (&os.windows) |*window| {
        if (window.id == 0 or window.kind == .popup) continue;
        const mine = engine.window_find(window.id) orelse continue;
        const leader = tab_leader(engine, window.id);
        var agrees = true;
        for (&os.windows) |*peer| {
            if (peer.id == 0 or peer.kind == .popup or peer.id == window.id) continue;
            const grouped = window.tab_group != 0 and peer.tab_group == window.tab_group;
            if (grouped != (tab_leader(engine, peer.id) == leader)) agrees = false;
        }
        if (agrees) continue;
        tabs_mistaken[mine.workspace] = true;
        const with_focus = focused_group != 0 and window.tab_group == focused_group;
        if (window.id == os.focused or with_focus) focus_mistaken = true;
    }
}

/// A floating window whose place is on no display.
fn out_of_reach(engine: *const Engine, window: *const Window) bool {
    if (window.mode != .floating) return false;
    for (engine.monitors[0..engine.monitors_count]) |*monitor| {
        if (window.float_rect.intersects(monitor.frame)) return false;
    }
    return engine.monitors_count > 0;
}

fn expect_same_focus(a: *Engine, b: *Engine) !void {
    if (a.monitors_count != b.monitors_count) return differ("the displays differ", .{});
    for (a.monitors[0..a.monitors_count], b.monitors[0..b.monitors_count]) |*one, *two| {
        if (one.display != two.display) return differ("the displays differ", .{});
        if (one.workspace == two.workspace) continue;
        return differ("display {d} showed workspace {d} and now shows {d}", .{
            one.display, one.workspace + 1, two.workspace + 1,
        });
    }
    if (a.focused_monitor != b.focused_monitor) {
        return differ("monitor {d} was in use, now {d}", .{
            a.focused_monitor + 1, b.focused_monitor + 1,
        });
    }
    if (a.recent_workspace != b.recent_workspace) {
        return differ("the workspace used before was {d}, now {d}", .{
            a.recent_workspace + 1, b.recent_workspace + 1,
        });
    }
    if (a.focused_window != b.focused_window) {
        return differ("window {d} had focus, now {d}", .{ a.focused_window, b.focused_window });
    }
}

fn expect_same_desk(a: *Engine, b: *Engine) !void {
    if (!focus_mistaken) try expect_same_focus(a, b);
    for (&a.workspaces, &b.workspaces, 0..) |*one, *two, index| {
        const number = index + 1;
        if (one.display != two.display) {
            return differ("workspace {d} was on display {d}, now on {d}", .{
                number, one.display, two.display,
            });
        }
        if (one.gaps_toggled != two.gaps_toggled) return differ("gaps of {d}", .{number});
        if (one.accordion != two.accordion) return differ("accordion of {d}", .{number});
        if (!std.mem.eql(u8, one.label.slice(), two.label.slice())) {
            return differ("workspace {d} was labelled '{s}', now '{s}'", .{
                number, one.label.slice(), two.label.slice(),
            });
        }
        if (!tabs_mistaken[index] and !layout_same(a, b, @intCast(index))) {
            return differ("the layout of workspace {d} changed", .{number});
        }
    }
}

fn expect_same_mode(one: *const Window, two: *const Window) !void {
    const id = one.id;
    if (one.mode != two.mode) {
        return differ("window {d} was {s}, now {s}", .{
            id, @tagName(one.mode), @tagName(two.mode),
        });
    }
    if (one.mode_by_user != two.mode_by_user) return differ("window {d}: by hand", .{id});
    if (one.auto_floated != two.auto_floated) return differ("window {d}: auto-floated", .{id});
    if (one.sticky != two.sticky) return differ("window {d}: sticky", .{id});
    if (one.zoom != two.zoom) {
        return differ("window {d} was zoomed {s}, now {s}", .{
            id, @tagName(one.zoom), @tagName(two.zoom),
        });
    }
    if (!std.mem.eql(u8, one.label.slice(), two.label.slice())) {
        return differ("window {d} was labelled '{s}', now '{s}'", .{
            id, one.label.slice(), two.label.slice(),
        });
    }
}

fn expect_same_window(a: *Engine, b: *Engine, one: *const Window, two: *const Window) !void {
    const id = one.id;
    if (one.workspace != two.workspace) {
        return differ("window {d} was on workspace {d}, now on {d}", .{
            id, one.workspace + 1, two.workspace + 1,
        });
    }
    if (one.tab_of != two.tab_of) {
        return differ("window {d} was a tab of {d}, now of {d}", .{ id, one.tab_of, two.tab_of });
    }
    if (one.minimized != two.minimized) return differ("window {d}: minimized", .{id});
    if (one.ignored != two.ignored) return differ("window {d}: ignored", .{id});
    if (!focus_mistaken and focus_rank(a, one) != focus_rank(b, two)) {
        return differ("window {d} was number {d} in the order of focus, now {d}", .{
            id, focus_rank(a, one), focus_rank(b, two),
        });
    }
    if (one.tab_of != 0) return;
    try expect_same_mode(one, two);
    if (out_of_reach(a, one)) {
        // The one thing a restart is meant to change: a floating window that an
        // application put where no display reaches comes back into view.
        if (out_of_reach(b, two)) return differ("window {d} is still out of reach", .{id});
    } else if (one.mode == .floating and !one.float_rect.eql(two.float_rect)) {
        return differ("window {d} floated at {any}, now at {any}", .{
            id, one.float_rect, two.float_rect,
        });
    }
    if (!one.managed() and one.slot_beside != 0) {
        const same = one.slot_beside == two.slot_beside and
            one.slot_beside_last == two.slot_beside_last and
            one.slot_side == two.slot_side and one.slot_ratio == two.slot_ratio;
        if (!same) return differ("window {d} returns to another place", .{id});
    }
}

/// The window manager that started sees what the one that quit saw, and no window that
/// was in view has moved.
fn expect_same(os: *sim.Simulator, a: *Engine, b: *Engine) !void {
    try expect_same_desk(a, b);
    for (&os.windows, &frames_before) |*window, frame| {
        if (window.id == 0 or window.kind == .popup) continue;
        const one = a.window_find(window.id).?;
        const two = b.window_find(window.id).?;
        if (tabs_mistaken[one.workspace]) continue;
        try expect_same_window(a, b, one, two);
        if (!one.managed() or a.monitors_count == 0) continue;
        if (!a.workspace_visible(one.workspace) or out_of_reach(a, one)) continue;
        if (!one.desired.eql(two.desired)) {
            return differ("window {d} belonged at {any}, now at {any}", .{
                window.id, one.desired, two.desired,
            });
        }
        // A window that moves itself back is wherever it likes, before and after.
        if (window.stubborn or window.frame.eql(frame)) continue;
        return differ("window {d} was at {any}, now at {any}", .{ window.id, frame, window.frame });
    }
}

/// No window that was in view has moved, and none that was out of view shows.
fn expect_unmoved(os: *sim.Simulator) !void {
    for (&os.windows, &frames_before) |*window, frame| {
        if (window.id == 0) continue;
        const shows = in_view(os, window.frame);
        if (in_view(os, frame) == shows and (!shows or window.frame.eql(frame))) continue;
        return differ("window {d} was at {any}, now at {any}", .{ window.id, frame, window.frame });
    }
}

// Any workload, then a restart.

fn restart_after(seed: u64, steps: u32, faults: bool) !void {
    const os = boot(seed, faults);
    workload(os, steps);
    quit(os);
    start(os, &second, .{});
    os.settle();
    expect_same(os, &first, &second) catch |err| {
        std.debug.print("restart: seed {d}, {d} steps, faults={}\n", .{ seed, steps, faults });
        return err;
    };
    // The one that started is as good as any: it takes the same workload from here.
    os.run(200);
}

test "a restart after any workload changes nothing" {
    var seed: u64 = 1;
    while (seed <= seeds) : (seed += 1) {
        const steps: u32 = @intCast(100 + (seed * 137) % 1500);
        try restart_after(seed, steps, false);
        try restart_after(seed, steps, true);
    }
}

test "a crash and a start from what was written down last change nothing" {
    var seed: u64 = 1;
    while (seed <= seeds / 2) : (seed += 1) {
        const os = boot(seed, seed % 2 == 0);
        workload(os, @intCast(150 + (seed * 91) % 1200));
        // No quit: the windows of hidden workspaces are still parked in their corners.
        write_down(os);
        start(os, &second, .{});
        os.settle();
        try expect_same(os, &first, &second);
        os.run(100);
    }
}

/// Every window is on the workspace it was left on, whatever became of the displays.
/// Sticky windows are on whichever workspace their display shows.
fn expect_same_workspaces(os: *sim.Simulator, a: *Engine, b: *Engine, seed: u64) !void {
    for (&os.windows) |*window| {
        if (window.id == 0 or window.kind == .popup) continue;
        const one = a.window_find(window.id).?;
        const two = b.window_find(window.id).?;
        // A tab is wherever its window is, and that one is looked at by itself.
        if (tabs_mistaken[one.workspace] or one.sticky or one.tab_of != 0) continue;
        // A floating window that moves itself belongs to the display it moves to.
        if (window.stubborn and one.mode == .floating) continue;
        if (one.workspace == two.workspace) continue;
        return differ("seed {d}: window {d} was on workspace {d}, now on {d}", .{
            seed, window.id, one.workspace + 1, two.workspace + 1,
        });
    }
}

test "a restart onto other displays keeps every window on its workspace" {
    var seed: u64 = 1;
    while (seed <= seeds / 2) : (seed += 1) {
        const os = boot(seed, true);
        workload(os, @intCast(150 + (seed * 67) % 1000));
        quit(os);
        // The displays change while no window manager runs.
        os.monitors_set(@intCast(seed % 5));
        start(os, &second, .{});
        os.settle();
        try expect_same_workspaces(os, &first, &second, seed);
        for (&os.windows) |*window| {
            if (window.id == 0 or window.kind == .popup) continue;
            const found = second.window_find(window.id).?;
            // Where a tab would float says nothing: it is wherever its window is.
            if (found.tab_of != 0 or !out_of_reach(&second, found)) continue;
            return differ("seed {d}: window {d} is out of reach", .{ seed, window.id });
        }
        os.run(100);
    }
}

test "a quit while the displays sleep and a start after they wake change nothing" {
    var seed: u64 = 1;
    while (seed <= seeds / 2) : (seed += 1) {
        const os = boot(seed, true);
        workload(os, @intCast(150 + (seed * 59) % 1000));
        write_down(os);
        os.inject(.{ .monitors_changed = &.{} });
        os.settle();
        quit(os);
        start(os, &second, .{ .asleep = seed % 2 == 0 });
        os.settle();
        if (seed % 2 == 0) os.inject(.{ .monitors_changed = os.monitors });
        os.settle();
        try expect_same_workspaces(os, &first, &second, seed);
        const asleep = first.monitors[0..first.monitors_asleep];
        for (asleep, second.monitors[0..second.monitors_count]) |*one, *two| {
            if (one.workspace == two.workspace or focus_mistaken) continue;
            return differ("seed {d}: display {d} showed workspace {d} and now shows {d}", .{
                seed, one.display, one.workspace + 1, two.workspace + 1,
            });
        }
        os.run(100);
    }
}

test "a restart after a restart changes nothing either" {
    var seed: u64 = 1;
    while (seed <= seeds / 2) : (seed += 1) {
        const os = boot(seed, true);
        workload(os, @intCast(200 + (seed * 53) % 900));
        restart(os);
        try expect_same(os, &first, &second);
        workload(os, 150);
        restart(os);
        try expect_same(os, &second, &first);
        os.run(100);
    }
}

// What a restart keeps, one thing at a time.

test "a restart keeps every tile and every split, and sends no window anywhere" {
    const os = desk("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    _ = open(os, app, .{});
    const d = open(os, app, .{});
    os.settle();
    os.command_run("resize ratio 70");
    os.command_run("swap west");
    run(os, "focus {d}", .{b});
    os.command_run("resize ratio 30");
    run(os, "focus {d}", .{a});
    os.command_run("resize right 100");
    os.settle();
    restart(os);
    try expect_unmoved(os);
    try testing.expectEqual(@as(u64, 0), second.stats.frames_set);
    try testing.expect(layout_same(&first, &second, 0));
    try testing.expectEqual(a, second.focused_window);
    // The same tree, not only the same picture: a tile that goes leaves the same gap.
    const height = frame_of(b).h + frame_of(d).h;
    os.window_close(b);
    os.settle();
    try testing.expectEqual(height, frame_of(d).h);
}

test "a window tiled or floated by hand stays so, whatever the rules say" {
    const os = desk("rule app=\"Slack\" : float\n");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const slack = os.app_launch("Slack", "com.tinyspeck.slackmacgap");
    const a = open(os, zed, .{});
    const chat = open(os, slack, .{ .frame = Rect.init(300, 200, 600, 500) });
    const b = open(os, zed, .{});
    os.settle();
    try testing.expectEqual(Mode.floating, known(chat).mode);
    run(os, "tile {d}", .{chat});
    run(os, "float {d} --bounds 0.5,0.25,0.25,0.5", .{b});
    os.settle();
    restart(os);
    try expect_unmoved(os);
    try testing.expectEqual(Mode.tiled, known(chat).mode);
    try testing.expectEqual(Mode.floating, known(b).mode);
    try testing.expectEqual(Mode.tiled, known(a).mode);
    try testing.expect(known(chat).mode_by_user and known(b).mode_by_user);
    // A late title makes rules look again, and still the choice made by hand stands.
    os.window_title(chat, "Huddle");
    os.settle();
    try testing.expectEqual(Mode.tiled, known(chat).mode);
}

test "a window that fought the layout and was left floating is not fought again" {
    const os = desk("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const calm = open(os, app, .{});
    const home = Rect.init(300, 200, 500, 400);
    const stubborn = open(os, app, .{ .stubborn = true, .frame = home });
    os.settle();
    try testing.expect(known(stubborn).auto_floated);
    restart(os);
    try testing.expect(known(stubborn).auto_floated);
    try testing.expectEqual(Mode.floating, known(stubborn).mode);
    try testing.expectEqual(@as(u64, 0), second.stats.frames_set);
    try expect_frame(home, stubborn);
    try expect_frame(screen, calm);
}

test "sticky windows, zoom, labels and toggled gaps come back as they were" {
    const os = desk("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    const c = open(os, app, .{});
    os.settle();
    os.command_run("label logs");
    os.command_run("label-workspace code");
    os.command_run("toggle gaps");
    os.command_run("toggle sticky");
    run(os, "zoom {d} --on", .{a});
    os.settle();
    restart(os);
    try expect_unmoved(os);
    try testing.expectEqualStrings("logs", known(c).label.slice());
    try testing.expectEqualStrings("code", second.workspaces[0].label.slice());
    try testing.expect(second.workspaces[0].gaps_toggled);
    try testing.expect(known(c).sticky);
    try testing.expectEqual(engine_module.Zoom.fullscreen, known(a).zoom);
    try testing.expectEqual(engine_module.Zoom.none, known(b).zoom);
    // The label still names the window, and the sticky window still follows.
    os.command_run("workspace 2");
    os.settle();
    try testing.expectEqual(@as(u8, 1), known(c).workspace);
    try testing.expect(in_view(os, frame_of(c)) and !in_view(os, frame_of(a)));
    os.command_run("focus logs");
    try testing.expectEqual(c, second.focused_window);
    os.command_run("workspace code");
    os.settle();
    try testing.expectEqual(@as(u8, 0), second.workspace_current());
}

test "native tabs are one window again, with the tab that showed in the tile" {
    const os = desk("");
    const ghostty = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const terminal = open(os, ghostty, .{});
    const tab = open(os, ghostty, .{ .tab_of = terminal });
    const editor = open(os, zed, .{});
    os.settle();
    try testing.expectEqual(tab, known(terminal).tab_of);
    restart(os);
    try expect_unmoved(os);
    try testing.expectEqual(tab, known(terminal).tab_of);
    try testing.expectEqual(@as(WindowId, 0), known(tab).tab_of);
    try testing.expectEqual(editor, second.focused_window);
    try testing.expectEqual(@as(u64, 0), second.stats.frames_set);
    try testing.expect(layout_same(&first, &second, 0));
}

test "a window minimized before the restart returns to the tile it left" {
    const os = desk("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    const c = open(os, app, .{});
    const d = open(os, app, .{});
    os.settle();
    os.command_run("send 2");
    os.window_minimize(d, true);
    os.window_minimize(a, true);
    os.settle();
    try expect_frame(Rect.init(0, 38, 1728, 540), b);
    restart(os);
    try expect_unmoved(os);
    try testing.expect(known(a).minimized and known(d).minimized);
    try testing.expectEqual(@as(u8, 1), known(d).workspace);
    os.window_minimize(a, false);
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(right_top, b);
    try expect_frame(right_bottom, c);
    // The one on the hidden workspace comes back there, not here.
    os.window_minimize(d, false);
    os.settle();
    try testing.expectEqual(@as(u8, 1), second.workspace_current());
    try expect_frame(screen, d);
    try testing.expect(!in_view(os, frame_of(a)));
}

test "hidden workspaces stay hidden, and the one in use stays in use" {
    const os = desk("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    os.command_run("send 2");
    os.command_run("workspace 4");
    os.settle();
    // Nothing has focus on the empty workspace; the keyboard is still on a window of
    // a workspace that is hidden.
    try testing.expectEqual(@as(WindowId, 0), first.focused_window);
    try testing.expect(os.focused != 0);
    restart(os);
    try testing.expectEqual(@as(u8, 3), second.workspace_current());
    try testing.expectEqual(@as(WindowId, 0), second.focused_window);
    try testing.expectEqual(@as(u8, 0), known(a).workspace);
    try testing.expectEqual(@as(u8, 1), known(b).workspace);
    try testing.expect(!in_view(os, frame_of(a)) and !in_view(os, frame_of(b)));
    // The workspace used before is still the one to go back to.
    os.command_run("workspace recent");
    os.settle();
    try testing.expectEqual(@as(u8, 0), second.workspace_current());
    try expect_frame(screen, a);
}

test "the window that had focus last on a workspace gets it there again" {
    const os = desk("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    const c = open(os, app, .{});
    os.settle();
    run(os, "focus {d}", .{b});
    os.settle();
    os.command_run("workspace 2");
    const d = open(os, app, .{});
    os.settle();
    restart(os);
    try testing.expectEqual(d, second.focused_window);
    os.command_run("workspace 1");
    os.settle();
    try testing.expectEqual(b, second.focused_window);
    _ = a;
    _ = c;
}

// What happens between the quit and the start.

test "a window that closed while no window manager ran leaves the gap its closing would" {
    const os = desk("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    const c = open(os, app, .{});
    const d = open(os, app, .{});
    os.settle();
    run(os, "focus {d}", .{b});
    os.command_run("resize ratio 30");
    os.settle();
    const top = frame_of(b);
    quit(os);
    os.window_close(c);
    start(os, &second, .{});
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(top, b);
    try expect_frame(Rect.init(864, top.bottom(), 864, 1117 - top.bottom()), d);
    // What is remembered of it waits no longer than its application runs.
    try testing.expectEqual(@as(u32, 1), second.memories_count);
    os.app_quit(app);
    os.settle();
    try testing.expectEqual(@as(u32, 0), second.memories_count);
}

test "a window minimized while no window manager ran still has its tile to return to" {
    const os = desk("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    const c = open(os, app, .{});
    os.settle();
    quit(os);
    os.window_minimize(a, true);
    start(os, &second, .{});
    os.settle();
    try expect_frame(Rect.init(0, 38, 1728, 540), b);
    try expect_frame(Rect.init(0, 578, 1728, 539), c);
    os.window_minimize(a, false);
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(right_top, b);
    try expect_frame(right_bottom, c);
}

test "the keyboard is where the user left it, not where the file says it was" {
    const os = desk("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    try testing.expectEqual(b, first.focused_window);
    quit(os);
    os.window_click(a);
    start(os, &second, .{});
    os.settle();
    try testing.expectEqual(a, second.focused_window);
    try testing.expectEqual(a, os.focused);
    try expect_unmoved(os);
}

test "a window opened while no window manager ran joins the layout at its end" {
    const os = desk("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    const c = open(os, app, .{});
    os.settle();
    quit(os);
    const new = open(os, app, .{ .frame = Rect.init(10, 60, 500, 400) });
    start(os, &second, .{});
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(right_top, b);
    try expect_frame(Rect.init(864, 578, 432, 539), c);
    try expect_frame(Rect.init(1296, 578, 432, 539), new);
}

test "a window whose application reports it late still returns to its tile" {
    const os = desk("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const slack = os.app_launch("Slack", "com.tinyspeck.slackmacgap");
    const a = open(os, zed, .{});
    const chat = open(os, slack, .{});
    const c = open(os, zed, .{});
    os.settle();
    run(os, "focus {d}", .{chat});
    os.command_run("resize ratio 30");
    os.settle();
    quit(os);
    start(os, &second, .{ .slow = slack });
    os.advance(500);
    // Until it answers, the others are laid out as if its window had closed.
    try expect_frame(left_half, a);
    try expect_frame(right_half, c);
    try testing.expectEqual(@as(u32, 1), second.memories_count);
    report_app(os, slack, true);
    os.settle();
    try expect_unmoved(os);
    try testing.expect(layout_same(&first, &second, 0));
    try testing.expectEqual(@as(u32, 0), second.memories_count);
}

test "after a crash the parked windows are found on their workspaces and nothing moves" {
    const os = desk("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    const c = open(os, app, .{ .kind = .dialog, .frame = Rect.init(400, 300, 500, 400) });
    os.settle();
    os.command_run("send 2");
    run(os, "focus {d}", .{b});
    os.command_run("send 2");
    os.settle();
    try testing.expect(!in_view(os, frame_of(b)) and !in_view(os, frame_of(c)));
    // No quit: the state is what was written down last, and the windows are still parked.
    write_down(os);
    start(os, &second, .{});
    os.settle();
    try testing.expectEqual(@as(u64, 0), second.stats.frames_set);
    try expect_unmoved(os);
    try expect_same(os, &first, &second);
    os.command_run("workspace 2");
    os.settle();
    try expect_frame(screen, b);
    try expect_frame(Rect.init(400, 300, 500, 400), c);
    try testing.expect(!in_view(os, frame_of(a)));
}

// A file that cannot be trusted.

test "a file from another boot, whose window ids are other windows now, is not believed" {
    const os = desk("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    _ = open(os, zed, .{});
    const b = open(os, zed, .{});
    _ = open(os, zed, .{});
    os.settle();
    os.command_run("send 3");
    run(os, "float {d}", .{b});
    os.command_run("label-workspace old");
    os.settle();
    quit(os);
    // The machine restarts: every application is another process, and the ids that
    // windows are numbered with start over.
    os.app_quit(zed);
    os.window_id_next = 100;
    const slack = os.app_launch("Slack", "com.tinyspeck.slackmacgap");
    const x = open(os, slack, .{ .frame = Rect.init(900, 100, 500, 400) });
    const y = open(os, slack, .{ .frame = Rect.init(100, 100, 500, 400) });
    const z = open(os, slack, .{ .frame = Rect.init(100, 600, 500, 400), .kind = .dialog });
    try testing.expectEqual(b, y);
    start(os, &second, .{});
    os.settle();
    // They are new windows: on the display where they are, tiled as they sit.
    for ([_]WindowId{ x, y, z }) |id| {
        try testing.expectEqual(@as(u8, 0), known(id).workspace);
    }
    try testing.expectEqual(Mode.tiled, known(y).mode);
    try expect_frame(left_half, y);
    try expect_frame(right_half, x);
    try expect_frame(Rect.init(100, 600, 500, 400), z);
    try testing.expectEqual(@as(u32, 0), second.memories_count);
}

/// A number of any size, small ones as likely as huge ones.
fn any_number(prng: *stdx.Prng) u64 {
    const shift: u6 = @intCast(prng.below(64));
    return prng.next() >> shift;
}

fn garbage_label(prng: *stdx.Prng) command.Label {
    var label: command.Label = .{};
    for (&label.bytes) |*byte| byte.* = @intCast(prng.below(256));
    label.len = @intCast(prng.below(256));
    if (prng.chance(1, 3)) label = command.Label.parse("logs").?;
    return label;
}

fn garbage_rect(prng: *stdx.Prng) Rect {
    const extreme = [_]i32{ std.math.maxInt(i32), std.math.minInt(i32), 0, -1, 1 << 30 };
    var numbers: [4]i32 = undefined;
    for (&numbers) |*number| {
        number.* = if (prng.chance(1, 4))
            extreme[prng.below(extreme.len)]
        else
            prng.range(-3000, 6000);
    }
    return .{ .x = numbers[0], .y = numbers[1], .w = numbers[2], .h = numbers[3] };
}

/// Anything at all about a window, now and then about one that is really there.
fn garbage_window(prng: *stdx.Prng, os: *sim.Simulator) WindowMemory {
    var id: WindowId = prng.below(600);
    var pid: i32 = prng.range(-2, 700);
    const real = &os.windows[prng.below(sim.windows_max)];
    if (real.id != 0 and prng.chance(2, 3)) {
        id = real.id;
        if (prng.chance(3, 4)) pid = real.pid;
    }
    return .{
        .id = id,
        .pid = pid,
        .workspace = @intCast(prng.below(40)),
        .floating = prng.chance(1, 3),
        .by_user = prng.chance(1, 2),
        .auto_floated = prng.chance(1, 4),
        .sticky = prng.chance(1, 6),
        .ignored = prng.chance(1, 10),
        .tab = prng.chance(1, 6),
        .focused = prng.chance(1, 3),
        .zoom = @intCast(prng.below(6)),
        .focus_order = @truncate(any_number(prng)),
        .float_rect = garbage_rect(prng),
        .order = @truncate(any_number(prng)),
        .beside = if (prng.chance(1, 2)) real.id else prng.below(600),
        .beside_last = if (prng.chance(1, 2)) real.id else prng.below(600),
        .side = @truncate(any_number(prng)),
        .ratio = @truncate(any_number(prng)),
        .label = garbage_label(prng),
    };
}

fn garbage(prng: *stdx.Prng, os: *sim.Simulator, state: *State) void {
    state.workspaces_count = prng.below(workspaces_max + 1);
    for (state.workspaces[0..state.workspaces_count]) |*memory| {
        memory.* = .{
            .workspace = @intCast(prng.below(40)),
            .display = prng.below(6),
            .shown = prng.chance(1, 2),
            .focused = prng.chance(1, 3),
            .recent = prng.chance(1, 3),
            .gaps = prng.chance(1, 3),
            .label = garbage_label(prng),
        };
    }
    state.windows_count = if (prng.chance(1, 4)) windows_max else prng.below(80);
    for (state.windows[0..state.windows_count]) |*memory| memory.* = garbage_window(prng, os);
}

/// A true state with some of what it says replaced by anything at all.
fn spoil(prng: *stdx.Prng, os: *sim.Simulator, state: *State) void {
    for (state.windows[0..state.windows_count]) |*memory| {
        if (prng.chance(2, 3)) continue;
        const wrong = garbage_window(prng, os);
        inline for (@typeInfo(WindowMemory).@"struct".field_names) |name| {
            if (prng.chance(1, 4)) @field(memory, name) = @field(wrong, name);
        }
    }
    for (state.workspaces[0..state.workspaces_count]) |*memory| {
        if (prng.chance(1, 4)) memory.display = prng.below(6);
        if (prng.chance(1, 4)) memory.shown = !memory.shown;
        if (prng.chance(1, 4)) memory.focused = !memory.focused;
        if (prng.chance(1, 4)) memory.workspace = @intCast(prng.below(40));
    }
}

/// The file ends early, and some of the bytes that are left are not what was written.
fn damage_bytes(prng: *stdx.Prng) void {
    file_len = prng.below(@intCast(file_len + 1));
    const alphabet = "0123456789 \n-window";
    var count = prng.below(8);
    while (count > 0 and file_len > 0) : (count -= 1) {
        file[prng.below(@intCast(file_len))] = alphabet[prng.below(alphabet.len)];
    }
}

const Damage = enum { made_up, spoiled, bytes };

/// Whatever the file says, the window manager that starts has a layout that holds, and
/// it is as good as any from there on.
fn restart_with(seed: u64, steps: u32, damage: Damage) void {
    const os = boot(seed, true);
    var prng = stdx.Prng.init(seed ^ 0x5eed);
    workload(os, steps);
    quit(os);
    state_module.parse(file[0..file_len], &left);
    switch (damage) {
        .made_up => garbage(&prng, os, &left),
        .spoiled => spoil(&prng, os, &left),
        .bytes => damage_bytes(&prng),
    }
    start(os, &second, .{ .read = damage == .bytes });
    os.settle();
    os.run(150);
}

test "a file that says anything at all still leaves a layout that holds" {
    var seed: u64 = 1;
    while (seed <= seeds) : (seed += 1) {
        const steps: u32 = @intCast(50 + (seed * 71) % 700);
        restart_with(seed, steps, .made_up);
        restart_with(seed, steps, .spoiled);
        restart_with(seed, steps, .bytes);
    }
}

test "a file that is cut short is believed as far as it goes" {
    const os = desk("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    const c = open(os, app, .{});
    os.settle();
    os.command_run("send 2");
    run(os, "focus {d}", .{b});
    os.command_run("send 3");
    os.settle();
    quit(os);
    // The file ends after the line of the first window.
    const header = std.mem.indexOf(u8, file[0..file_len], "\nwindow ").? + 1;
    file_len = header + std.mem.indexOfScalar(u8, file[header..file_len], '\n').? + 1;
    // The workspaces come first in it; without them, the windows are still believed.
    const line = file[header..file_len];
    std.mem.copyForwards(u8, file["tatami-state 3\n".len..], line);
    file_len = "tatami-state 3\n".len + line.len;
    start(os, &second, .{});
    try testing.expectEqual(@as(u32, 1), left.windows_count);
    try testing.expectEqual(a, left.windows[0].id);
    try testing.expectEqual(@as(u32, 0), left.workspaces_count);
    os.settle();
    try testing.expectEqual(@as(u8, 0), known(a).workspace);
    // The others are where the quit left them: in view, so on the workspace in view.
    try testing.expectEqual(@as(u8, 0), known(b).workspace);
    try testing.expectEqual(@as(u8, 0), known(c).workspace);
    for ([_]WindowId{ a, b, c }) |id| try testing.expect(in_view(os, frame_of(id)));
}

test "more windows than fit are remembered as far as they fit" {
    const os = desk("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    os.settle();
    quit(os);
    for (&left.windows, 0..) |*memory, index| {
        memory.* = .{ .id = @intCast(1000 + index), .pid = app, .workspace = 4, .order = 1 };
    }
    left.windows[windows_max - 1].id = a;
    left.windows_count = windows_max;
    left.workspaces_count = 0;
    start(os, &second, .{ .read = false });
    os.settle();
    try testing.expectEqual(@as(u8, 4), known(a).workspace);
    try testing.expectEqual(@as(u32, windows_max - 1), second.memories_count);
    // They all keep their line in the file for as long as their application runs.
    write_down(os);
    state_module.parse(file[0..file_len], &left);
    try testing.expectEqual(@as(u32, windows_max), left.windows_count);
    os.app_quit(app);
    os.settle();
    try testing.expectEqual(@as(u32, 0), second.memories_count);
}

// Restarts at awkward moments.

fn asleep_desk(os: *sim.Simulator) [2]WindowId {
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    os.command_run("send 2");
    os.settle();
    std.debug.assert(!in_view(os, frame_of(b)));
    // The file is as it was written before the displays went to sleep.
    write_down(os);
    os.inject(.{ .monitors_changed = &.{} });
    os.settle();
    return .{ a, b };
}

test "a quit while the displays sleep still brings the hidden windows back into view" {
    const os = desk("");
    const a, const b = asleep_desk(os);
    quit(os);
    try testing.expect(in_view(os, frame_of(b)));
    // The displays wake and a window manager starts: everything is as it was left.
    start(os, &second, .{});
    os.settle();
    try testing.expectEqual(@as(u8, 1), known(b).workspace);
    try testing.expect(!in_view(os, frame_of(b)));
    try expect_frame(screen, a);
    try testing.expectEqual(a, second.focused_window);
    try testing.expectEqual(@as(u8, 0), second.workspace_current());
}

test "a start while the displays sleep finds every window again when they wake" {
    const os = desk("");
    const a, const b = asleep_desk(os);
    quit(os);
    start(os, &second, .{ .asleep = true });
    os.settle();
    try testing.expectEqual(@as(u8, 1), known(b).workspace);
    try testing.expectEqual(a, second.focused_window);
    os.inject(.{ .monitors_changed = os.monitors });
    os.settle();
    try testing.expectEqual(@as(u8, 0), second.workspace_current());
    try testing.expectEqual(@as(u8, 1), known(b).workspace);
    try testing.expect(!in_view(os, frame_of(b)));
    try expect_frame(screen, a);
    try testing.expectEqual(a, second.focused_window);
    os.command_run("workspace 2");
    os.settle();
    try expect_frame(screen, b);
}

test "a quit while an application hangs loses nothing of its windows" {
    const os = desk("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const slack = os.app_launch("Slack", "com.tinyspeck.slackmacgap");
    const place = Rect.init(400, 300, 500, 400);
    const a = open(os, zed, .{});
    const chat = open(os, slack, .{ .kind = .dialog, .frame = place });
    const thread = open(os, slack, .{});
    os.settle();
    run(os, "focus {d}", .{chat});
    os.command_run("send 2");
    os.settle();
    try testing.expect(!in_view(os, frame_of(chat)));
    os.app_hang(slack, 60_000);
    quit(os);
    // It could not be brought back into view, and it still hangs when the next one starts.
    try testing.expect(!in_view(os, frame_of(chat)));
    start(os, &second, .{ .slow = slack });
    os.advance(500);
    try expect_frame(screen, a);
    report_app(os, slack, true);
    os.settle();
    try expect_unmoved(os);
    try testing.expectEqual(@as(u8, 1), known(chat).workspace);
    try testing.expect(layout_same(&first, &second, 0));
    try expect_frame(right_half, thread);
    // Where it floats is remembered, not taken from the corner it is parked in.
    os.command_run("workspace 2");
    os.settle();
    try expect_frame(place, chat);
}

test "a window in native fullscreen at the restart returns to its tile when it leaves it" {
    const os = desk("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    const c = open(os, app, .{});
    os.settle();
    os.inject(.{ .window_fullscreen = .{ .id = b, .fullscreen = true } });
    os.settle();
    try expect_frame(right_half, c);
    fullscreen = b;
    restart(os);
    try expect_unmoved(os);
    try testing.expect(known(b).fullscreen);
    try testing.expectEqual(@as(u64, 0), second.stats.frames_set);
    fullscreen = 0;
    os.inject(.{ .window_fullscreen = .{ .id = b, .fullscreen = false } });
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(right_top, b);
    try expect_frame(right_bottom, c);
}

test "a quit in the middle of an adoption forgets nothing about windows not yet reported" {
    const os = desk("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const slack = os.app_launch("Slack", "com.tinyspeck.slackmacgap");
    const a = open(os, zed, .{});
    const chat = open(os, slack, .{});
    const c = open(os, zed, .{});
    os.settle();
    run(os, "focus {d}", .{chat});
    os.command_run("resize ratio 30");
    os.command_run("label talk");
    os.settle();
    const top = frame_of(chat);
    const bottom = frame_of(c);
    quit(os);
    // The one that starts is told to quit when it has heard of one application only.
    start_begin(os, &second, .{});
    report_app(os, zed, true);
    quit(os);
    // The next one starts from what that one wrote down.
    start(os, &first, .{});
    try testing.expectEqual(@as(u32, 3), left.windows_count);
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(top, chat);
    try expect_frame(bottom, c);
    try testing.expectEqualStrings("talk", known(chat).label.slice());
    try testing.expectEqual(chat, first.focused_window);
    try testing.expectEqual(@as(u64, 0), first.stats.frames_set);
}

test "a restart onto fewer displays keeps the workspaces, and the one in use in view" {
    const os = desk("");
    os.monitors_set(1); // Laptop on the left, external display on the right.
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    os.settle();
    os.command_run("focus-monitor 2");
    const b = open(os, app, .{});
    const c = open(os, app, .{});
    os.settle();
    const outside = known(c).workspace;
    try testing.expect(outside != known(a).workspace);
    try testing.expectEqual(outside, known(b).workspace);
    quit(os);
    // The external display is unplugged while no window manager runs.
    os.monitors_set(0);
    start(os, &second, .{});
    os.settle();
    try testing.expectEqual(outside, second.workspace_current());
    try testing.expectEqual(c, second.focused_window);
    try testing.expectEqual(@as(u8, 0), known(a).workspace);
    try testing.expectEqual(outside, known(b).workspace);
    try testing.expect(!in_view(os, frame_of(a)));
    try testing.expect(in_view(os, frame_of(b)) and in_view(os, frame_of(c)));
    try testing.expect(layout_same(&first, &second, outside));
    // The display comes back and takes its workspace with it: all is as it was left.
    os.monitors_set(1);
    os.settle();
    try expect_unmoved(os);
    try testing.expectEqual(c, second.focused_window);
    try testing.expectEqual(@as(u8, 0), second.monitors[0].workspace);
    try testing.expectEqual(outside, second.monitors[1].workspace);
}

test "a restart with one more display leaves every window where it was" {
    const os = desk("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    const c = open(os, app, .{});
    os.settle();
    os.command_run("send 2");
    os.settle();
    quit(os);
    os.monitors_set(1);
    start(os, &second, .{});
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
    try testing.expectEqual(@as(u8, 1), known(c).workspace);
    try testing.expect(!in_view(os, frame_of(c)));
    try testing.expectEqual(@as(u8, 0), second.monitors[0].workspace);
    // The new display shows a workspace of its own, with nothing on it.
    const beside = second.monitors[1].workspace;
    for ([_]WindowId{ a, b, c }) |id| try testing.expect(known(id).workspace != beside);
    try testing.expectEqual(b, second.focused_window);
}

// What the restarts above brought to light in the window manager that quits.

test "a window floated while its workspace is hidden floats in view when it is shown" {
    const os = desk("");
    os.monitors_set(1); // Laptop on the left, external display on the right.
    const app = os.app_launch("Zed", "dev.zed.Zed");
    // It opens over on the external display, and is tiled on the laptop.
    const a = open(os, app, .{ .frame = Rect.init(2400, 200, 900, 700) });
    os.settle();
    try expect_frame(screen, a);
    os.monitors_set(0);
    os.command_run("workspace 2");
    run(os, "float {d}", .{a});
    os.command_run("workspace 1");
    os.settle();
    try testing.expectEqual(Mode.floating, known(a).mode);
    try testing.expect(in_view(os, frame_of(a)));
}

test "a window that is tiled again is no longer said to be auto-floated" {
    const os = desk("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    _ = open(os, app, .{});
    const stubborn = open(os, app, .{ .stubborn = true, .frame = Rect.init(300, 200, 500, 400) });
    os.settle();
    try testing.expect(known(stubborn).auto_floated);
    os.command_run("layout bsp");
    try testing.expectEqual(Mode.tiled, known(stubborn).mode);
    try testing.expect(!known(stubborn).auto_floated);
    os.settle();
}
