//! Scenario tests for the places where two behaviours of the engine meet, for the states
//! the operating system can report in any order, and for commands against the states they
//! are rarely tried in. They run the real engine against the simulated OS with random
//! faults switched off, so every expectation is exact. What the simulator cannot do
//! (displays that sleep, native fullscreen, notifications in an order no application was
//! seen to use) goes to the engine directly.
const std = @import("std");
const testing = std.testing;
const geometry = @import("geometry.zig");
const stdx = @import("stdx.zig");
const command = @import("command.zig");
const config_module = @import("config.zig");
const engine_module = @import("engine.zig");
const sim = @import("sim.zig");

const Rect = geometry.Rect;
const Engine = engine_module.Engine;
const WindowId = engine_module.WindowId;
const MonitorInfo = engine_module.MonitorInfo;

var engine: Engine = undefined;
var simulator: sim.Simulator = undefined;

// The simulated laptop screen: 1728x1117 with a 38 pixel menu bar.
const screen = Rect.init(0, 38, 1728, 1079);
const left_half = Rect.init(0, 38, 864, 1079);
const right_half = Rect.init(864, 38, 864, 1079);
// The external display of monitor preset 1, to the right of the laptop.
const external = Rect.init(1728, 38, 2560, 1402);

const laptop = [_]MonitorInfo{.{
    .display = 1,
    .frame = Rect.init(0, 0, 1728, 1117),
    .visible = screen,
    .main = true,
}};

fn boot(extra_config: []const u8) *sim.Simulator {
    var source: [16 * 1024]u8 = undefined;
    const default = config_module.default_source;
    @memcpy(source[0..default.len], default);
    source[default.len] = '\n';
    @memcpy(source[default.len + 1 ..][0..extra_config.len], extra_config);
    var config: config_module.Config = undefined;
    var buffer: [512]u8 = undefined;
    var diagnostics = stdx.Text.init(&buffer);
    const ok = config.load(source[0 .. default.len + 1 + extra_config.len], &diagnostics);
    std.debug.assert(ok);
    engine.init(&config);
    simulator.init(&engine, .{ .seed = 1, .faults = false });
    return &simulator;
}

/// Starts an application and lets the OS report it, so that rules that go by its name
/// apply to its first window.
fn launch(os: *sim.Simulator, name: []const u8, bundle: []const u8) i32 {
    const pid = os.app_launch(name, bundle);
    os.advance(1);
    return pid;
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

/// Runs a command built from a format string and returns what the engine answered.
fn run(os: *sim.Simulator, comptime format: []const u8, args: anytype) []const u8 {
    var buffer: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch unreachable;
    os.command_run(text);
    return engine.reply();
}

/// The reply starts with the words given; an empty expectation means no reply at all.
fn expect_reply(expected: []const u8, reply: []const u8) !void {
    const matches = if (expected.len == 0)
        reply.len == 0
    else
        std.mem.startsWith(u8, reply, expected);
    if (!matches) {
        std.debug.print("expected a reply starting '{s}', found '{s}'\n", .{ expected, reply });
        return error.TestUnexpectedResult;
    }
}

fn known(id: WindowId) *engine_module.Window {
    return engine.window_find(id).?;
}

/// True when the window shows at most a one pixel sliver on every display.
fn sliver_only(id: WindowId) bool {
    const frame = frame_of(id);
    for (engine.monitors[0..engine.monitors_count]) |*monitor| {
        const w = frame.overlap(monitor.frame, .x);
        const h = frame.overlap(monitor.frame, .y);
        if (w > 1 and h > 1) return false;
    }
    return true;
}

/// Sends one event straight to the engine. The effects are not performed, only counted;
/// the invariants are checked as the simulator checks them after every step.
fn step(os: *sim.Simulator, event: engine_module.Event) usize {
    const count = engine.step(event, os.now_ms).len;
    engine.verify();
    return count;
}

/// Every display goes to sleep. The engine must answer with no effects at all.
fn displays_sleep(os: *sim.Simulator) !void {
    const none: []const MonitorInfo = &.{};
    try testing.expectEqual(@as(usize, 0), step(os, .{ .monitors_changed = none }));
}

fn info_of(id: WindowId, pid: i32, frame: Rect) engine_module.WindowInfo {
    return .{
        .id = id,
        .pid = pid,
        .title = "Untitled",
        .frame = frame,
        .kind = .standard,
        .resizable = true,
    };
}

// Rules.

test "a tab that a sticky rule matches rides along with the window that shows" {
    // A rule that goes by the application matches every tab of a sticky window.
    const os = boot("rule app=\"Finder\" : sticky\n");
    const finder = launch(os, "Finder", "com.apple.finder");
    const home = Rect.init(200, 200, 600, 400);
    const a = open(os, finder, .{ .frame = home });
    os.settle();
    const b = open(os, finder, .{ .tab_of = a, .focus = false });
    os.settle();
    try testing.expect(known(a).sticky);
    try testing.expect(!known(b).sticky);
    os.command_run("workspace 2");
    os.settle();
    try testing.expectEqual(@as(u8, 1), known(a).workspace);
    try testing.expectEqual(@as(u8, 1), known(b).workspace);
    try expect_frame(home, a);
    // The tab shows: it takes the place of the window, sticky and all.
    os.window_click(b);
    os.settle();
    try testing.expect(known(b).sticky);
    try testing.expect(!known(a).sticky);
    os.command_run("workspace 1");
    os.settle();
    try testing.expectEqual(@as(u8, 0), known(b).workspace);
    try testing.expectEqual(b, engine.focused_window);
    // A change of displays moves sticky windows too, and the tab with them.
    os.monitors_set(1);
    os.settle();
    try testing.expectEqual(known(b).workspace, known(a).workspace);
    try expect_frame(home, b);
}

test "a sticky rule keeps its window in view when another rule names a hidden workspace" {
    const orders = [2][]const u8{
        "rule app=\"Simulator\" : workspace 3\nrule app=\"Simulator\" : sticky\n",
        "rule app=\"Simulator\" : sticky\nrule app=\"Simulator\" : workspace 3\n",
    };
    for (orders) |rules| {
        const os = boot(rules);
        const ios = launch(os, "Simulator", "com.apple.iphonesimulator");
        const home = Rect.init(100, 100, 400, 400);
        const phone = open(os, ios, .{ .frame = home });
        os.settle();
        try testing.expect(known(phone).sticky);
        try testing.expectEqual(@as(u8, 0), known(phone).workspace);
        try expect_frame(home, phone);
        // In view, it takes the keyboard like any window that opens.
        try testing.expectEqual(phone, engine.focused_window);
        os.command_run("workspace 2");
        os.settle();
        try expect_frame(home, phone);
    }
}

test "a window whose rule names the workspace in use takes the keyboard like any other" {
    const os = boot("rule app=\"Slack\" : workspace 1\n");
    const zed = launch(os, "Zed", "dev.zed.Zed");
    const editor = open(os, zed, .{});
    os.settle();
    const slack = launch(os, "Slack", "com.tinyspeck.slackmacgap");
    const chat = open(os, slack, .{});
    os.settle();
    try expect_frame(left_half, editor);
    try expect_frame(right_half, chat);
    try testing.expectEqual(chat, engine.focused_window);
    try testing.expectEqual(chat, os.focused);
    // From another workspace the rule still sends the window away without the keyboard.
    os.command_run("workspace 2");
    os.settle();
    const more = open(os, slack, .{});
    os.settle();
    try testing.expectEqual(@as(u8, 0), known(more).workspace);
    try testing.expectEqual(@as(u8, 1), engine.workspace_current());
    try testing.expectEqual(@as(WindowId, 0), engine.focused_window);
}

test "a floating window whose rule names the workspace in use comes to its monitor" {
    const os = boot("rule app=\"Simulator\" : float\nrule app=\"Simulator\" : workspace 1\n");
    os.monitors_set(1); // Laptop on the left, external display on the right.
    const ios = launch(os, "Simulator", "com.apple.iphonesimulator");
    // The application draws it on the external display; the rule says workspace 1,
    // which the laptop shows.
    const phone = open(os, ios, .{ .frame = Rect.init(2000, 100, 400, 400) });
    os.settle();
    try testing.expectEqual(@as(u8, 0), known(phone).workspace);
    try expect_frame(Rect.init(664, 377, 400, 400), phone);
    try testing.expectEqual(phone, engine.focused_window);
    // Without such a rule a floating window belongs to the monitor it is drawn on.
    const zed = launch(os, "Zed", "dev.zed.Zed");
    const drawn = Rect.init(2000, 100, 400, 400);
    const dialog = open(os, zed, .{ .kind = .dialog, .frame = drawn });
    os.settle();
    try testing.expectEqual(@as(u8, 1), known(dialog).workspace);
    try expect_frame(drawn, dialog);
}

test "a late title that sends the window in use away leaves the keyboard where the user is" {
    const os = boot("rule title=\"Debug\" : workspace 3\n");
    const zed = launch(os, "Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    os.settle();
    try testing.expectEqual(b, engine.focused_window);
    os.window_title(b, "Debug console");
    os.settle();
    try testing.expectEqual(@as(u8, 2), known(b).workspace);
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
    try testing.expectEqual(a, engine.focused_window);
    try testing.expectEqual(a, os.focused);
    try expect_frame(screen, a);
    try testing.expect(sliver_only(b));
}

test "a late title that makes the window in use ignored leaves the keyboard alone" {
    const os = boot("rule title=\"Notification\" : ignore\n");
    const zed = launch(os, "Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const home = Rect.init(1300, 60, 400, 120);
    const toast = open(os, zed, .{ .frame = home });
    os.settle();
    try testing.expectEqual(toast, engine.focused_window);
    os.window_drag(toast, home);
    os.window_title(toast, "Notification");
    os.settle();
    // The window used before is the one commands act on; the keyboard was not taken
    // from the notification, as it is not when a window is ignored from the start.
    try testing.expectEqual(a, engine.focused_window);
    try testing.expectEqual(toast, os.focused);
    try expect_frame(screen, a);
    try expect_reply("", run(os, "toggle float", .{}));
    try testing.expectEqual(engine_module.Mode.floating, known(a).mode);
}

// Displays that sleep, and displays that are not there yet.

test "windows reported before any display is known are in view when a display arrives" {
    const os = boot("");
    // Started with the lid closed: no display, then the windows, then no focus to go by.
    engine.init(&engine.config);
    const none: []const MonitorInfo = &.{};
    _ = step(os, .{ .monitors_changed = none });
    _ = step(os, .{ .adoption = .begin });
    var info = info_of(7, 42, Rect.init(10, 50, 400, 400));
    info.adopted = true;
    _ = step(os, .{ .window_appeared = info });
    _ = step(os, .{ .adoption = .end });
    _ = step(os, .{ .monitors_changed = &laptop });
    try testing.expectEqual(@as(u8, 0), known(7).workspace);
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
    try testing.expect(engine.workspace_visible(0));
    try testing.expect(known(7).desired.eql(screen));
}

test "frames held back at startup do not keep the timer firing while the displays sleep" {
    const os = boot("");
    const zed = launch(os, "Zed", "dev.zed.Zed");
    os.adoption(.begin);
    const a = open(os, zed, .{ .adopted = true, .frame = Rect.init(100, 100, 500, 500) });
    try testing.expect(known(a).set_pending);
    // The displays go to sleep before the last window is reported.
    try displays_sleep(os);
    _ = step(os, .{ .adoption = .end });
    os.now_ms += 10;
    _ = step(os, .tick);
    // Nothing is left that a tick could do: a deadline in the past would have the shell
    // tick again at once, for as long as the displays sleep.
    if (engine.next_deadline_ms()) |deadline| try testing.expect(deadline > os.now_ms);
    os.monitors_set(0);
    os.settle();
    try expect_frame(screen, a);
}

test "a window that is minimized while the displays sleep is not sent a frame" {
    const os = boot("");
    const zed = launch(os, "Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    os.settle();
    try displays_sleep(os);
    // The application minimizes the window and reports frames on the way to the Dock.
    _ = step(os, .{ .window_minimized = .{ .id = a, .minimized = true } });
    const shrunk = Rect.init(5, 5, 50, 50);
    const moved: engine_module.Event =
        .{ .window_frame_changed = .{ .id = a, .frame = shrunk, .by_user = false } };
    try testing.expectEqual(@as(usize, 0), step(os, moved));
    os.now_ms += 2 * engine_module.settle_ms;
    try testing.expectEqual(@as(usize, 0), step(os, .tick));
    // A late answer to a frame that was set before the displays slept changes nothing.
    const answer: engine_module.Event = .{ .window_frame_applied = .{ .id = a, .frame = shrunk } };
    try testing.expectEqual(@as(usize, 0), step(os, answer));
    _ = step(os, .{ .window_minimized = .{ .id = a, .minimized = false } });
    os.window_drag(a, shrunk);
    os.monitors_set(0);
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
}

test "displays that sleep as two and wake as one keep the window in use in view" {
    const os = boot("");
    os.monitors_set(1);
    const zed = launch(os, "Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    os.settle();
    os.command_run("focus-monitor 2");
    const b = open(os, zed, .{});
    os.settle();
    try expect_frame(external, b);
    try displays_sleep(os);
    // The external display was unplugged while everything slept.
    os.monitors_set(0);
    os.settle();
    try testing.expectEqual(b, engine.focused_window);
    try expect_frame(screen, b);
    try testing.expect(sliver_only(a));
    // It comes back: both displays show what they showed.
    os.monitors_set(1);
    os.settle();
    try expect_frame(screen, a);
    try expect_frame(external, b);
    try testing.expectEqual(b, engine.focused_window);
}

test "the window in use closing while the displays sleep leaves focus to be found on waking" {
    const os = boot("");
    const zed = launch(os, "Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    os.settle();
    try testing.expectEqual(b, engine.focused_window);
    try displays_sleep(os);
    os.window_close(b);
    os.advance(1000);
    try testing.expectEqual(@as(u32, 0), engine.effects_count);
    os.monitors_set(0);
    os.settle();
    try testing.expectEqual(a, engine.focused_window);
    try expect_frame(screen, a);
}

// Windows that float.

test "a zoomed window that starts to float does so on the monitor of its workspace" {
    const os = boot("");
    os.monitors_set(1); // Laptop on the left, external display on the right.
    const zed = launch(os, "Zed", "dev.zed.Zed");
    // The application draws the window on the external display; it joins the workspace
    // in use, on the laptop, and is tiled there.
    const a = open(os, zed, .{ .frame = Rect.init(2000, 100, 400, 400) });
    os.settle();
    try expect_frame(screen, a);
    os.command_run("zoom --on");
    os.command_run("toggle float");
    os.command_run("zoom --off");
    os.settle();
    try testing.expectEqual(@as(u8, 0), known(a).workspace);
    try expect_frame(Rect.init(664, 377, 400, 400), a);
    // The same for a window that is floated while its workspace is hidden.
    const b = open(os, zed, .{ .frame = Rect.init(2100, 200, 500, 300) });
    os.settle();
    os.command_run("workspace 3");
    os.settle();
    try testing.expect(sliver_only(b));
    try expect_reply("", run(os, "float {d}", .{b}));
    os.command_run("workspace 1");
    os.settle();
    try expect_frame(Rect.init(614, 427, 500, 300), b);
}

test "moving a floating window further than the numbers reach brings it back into view" {
    const os = boot("");
    const zed = launch(os, "Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    os.settle();
    os.command_run("float --bounds 0.25,0.25,0.5,0.5");
    os.settle();
    try expect_frame(Rect.init(432, 307, 864, 539), a);
    const middle = Rect.init(432, 308, 864, 539);
    const far = [_][]const u8{
        "move-floating 2147483647 0",  "move-floating 0 -2147483647",
        "move-floating -2147483647 0", "move-floating 2147483647 2147483647",
    };
    for (far) |text| {
        os.command_run(text);
        os.settle();
        // Off every display, it comes back to the middle of its own.
        try expect_frame(middle, a);
    }
}

// Labels and the commands that name their windows.

test "a tab keeps its own label when the window that showed closes" {
    const os = boot("");
    const zed = launch(os, "Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    os.settle();
    const b = open(os, zed, .{ .tab_of = a, .focus = false });
    const c = open(os, zed, .{});
    os.settle();
    const d = open(os, zed, .{ .tab_of = c, .focus = false });
    os.settle();
    try expect_reply("", run(os, "label {d} logs", .{b}));
    try expect_reply("", run(os, "label {d} editor", .{c}));
    // The close is reported before anything else about the tabs.
    _ = step(os, .{ .window_destroyed = a });
    _ = step(os, .{ .window_destroyed = c });
    try expect_reply("id=", run(os, "query window logs", .{}));
    try testing.expectEqual(@as(WindowId, 0), known(b).tab_of);
    // A tab without a name goes on under the name of the window it replaces.
    try testing.expectEqualStrings("editor", known(d).label.slice());
    try expect_reply("", run(os, "swap logs editor", .{}));
}

test "commands that name a background tab say why they cannot act on it" {
    const os = boot("");
    const zed = launch(os, "Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const other = open(os, zed, .{});
    os.settle();
    const tab = open(os, zed, .{ .tab_of = a, .focus = false });
    os.settle();
    try testing.expectEqual(a, known(tab).tab_of);
    try expect_reply("error: conflict", run(os, "focus {d}", .{tab}));
    try expect_reply("error: conflict", run(os, "zoom {d} --on", .{tab}));
    try expect_reply("error: conflict", run(os, "float {d}", .{tab}));
    try expect_reply("error: conflict", run(os, "tile {d}", .{tab}));
    try expect_reply("error: conflict", run(os, "swap {d} {d}", .{ tab, other }));
    try expect_reply("error: conflict", run(os, "move {d} left {d}", .{ tab, other }));
    try expect_reply("error: conflict", run(os, "move {d} left {d}", .{ other, tab }));
    try expect_reply("id=", run(os, "query window {d}", .{tab}));
    try expect_reply("", run(os, "label {d} spare", .{tab}));
    os.settle();
    // Nothing moved, and focus stayed where it was.
    try expect_frame(left_half, a);
    try expect_frame(right_half, other);
    try testing.expectEqual(other, engine.focused_window);
    // Closing it closes the tab, not the window that shows.
    try expect_reply("", run(os, "close spare", .{}));
    os.settle();
    try testing.expect(engine.window_find(tab) == null);
    try expect_frame(left_half, a);
    try expect_reply("error: not-found", run(os, "focus spare", .{}));
}

test "commands that name a minimized window leave it minimized and say so" {
    const os = boot("");
    const zed = launch(os, "Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    os.settle();
    os.window_minimize(a, true);
    os.settle();
    try expect_frame(screen, b);
    try expect_reply("error: conflict", run(os, "focus {d}", .{a}));
    try expect_reply("error: conflict", run(os, "zoom {d}", .{a}));
    try expect_reply("error: conflict", run(os, "float {d}", .{a}));
    try expect_reply("error: conflict", run(os, "tile {d}", .{a}));
    try expect_reply("error: conflict", run(os, "swap {d} {d}", .{ a, b }));
    try expect_reply("error: conflict", run(os, "move {d} left {d}", .{ a, b }));
    try expect_reply("error: conflict", run(os, "move {d} left {d}", .{ b, a }));
    os.settle();
    try testing.expect(known(a).minimized);
    try expect_frame(screen, b);
    try testing.expectEqual(b, engine.focused_window);
}

test "a monitor that does not exist is an error, not a silent nothing" {
    const os = boot("");
    const zed = launch(os, "Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    os.settle();
    try expect_reply("error: not-found", run(os, "focus-monitor 2", .{}));
    try expect_reply("error: not-found", run(os, "send-monitor 5 --follow", .{}));
    // The ones that are relative have nowhere to go with one display, and say nothing.
    try expect_reply("", run(os, "focus-monitor next", .{}));
    try expect_reply("", run(os, "send-monitor prev", .{}));
    os.settle();
    try expect_frame(screen, a);
    try testing.expectEqual(a, engine.focused_window);
    os.monitors_set(1);
    try expect_reply("", run(os, "send-monitor 2 --follow", .{}));
    os.settle();
    try expect_frame(external, a);
}

test "every command is harmless when there is no window at all" {
    const os = boot("");
    const texts = [_][]const u8{
        "focus west",         "focus next --wrap",   "focus south --wrap", "swap east",
        "warp north",         "insert east",         "resize left -20",    "resize ratio 70",
        "balance",            "retile",              "rotate 90",          "mirror x-axis",
        "toggle split",       "toggle float",        "toggle zoom-parent", "toggle sticky",
        "toggle gaps",        "send 2",              "send new --follow",  "send-monitor next",
        "grid 1:2:0:0:1:1",   "move-floating 20 0",  "layout bsp",         "layout float",
        "close",              "close-others",        "workspace next",     "workspace recent",
        "focus-monitor next", "label-workspace web",
    };
    for (texts) |text| {
        os.command_run(text);
        try testing.expectEqual(@as(u32, 0), engine.effects_count);
    }
    try expect_reply("error: not-found", run(os, "zoom", .{}));
    try expect_reply("error: not-found", run(os, "float", .{}));
    try expect_reply("error: not-found", run(os, "tile", .{}));
    try expect_reply("error: not-found", run(os, "label logs", .{}));
    try expect_reply("error: not-found", run(os, "move left 7", .{}));
    try expect_reply("error: not-found", run(os, "swap 7 8", .{}));
    try expect_reply("error: not-found", run(os, "close 7", .{}));
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
    try expect_reply("", run(os, "workspace web", .{}));
}

test "a window id that is used again starts with nothing of the window before it" {
    const os = boot("");
    const zed = launch(os, "Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    os.settle();
    _ = run(os, "label {d} logs", .{b});
    os.command_run("toggle sticky");
    os.command_run("zoom --on");
    os.command_run("workspace 2");
    os.settle();
    // The window goes and another one of another application takes its number.
    const pid = simulator.window_find(b).?.pid;
    _ = step(os, .{ .window_destroyed = b });
    try expect_reply("error: not-found", run(os, "focus logs", .{}));
    _ = step(os, .{ .window_appeared = info_of(b, pid, Rect.init(50, 80, 300, 300)) });
    const again = known(b);
    try testing.expectEqual(@as(u8, 1), again.workspace);
    try testing.expectEqual(engine_module.Mode.tiled, again.mode);
    try testing.expectEqual(engine_module.Zoom.none, again.zoom);
    try testing.expect(!again.sticky);
    try testing.expectEqual(@as(usize, 0), again.label.slice().len);
    try testing.expect(again.desired.eql(screen));
    try testing.expectEqual(@as(u8, 0), known(a).workspace);
}

// The place a minimized window returns to.

test "a minimized window returns beside its neighbour wherever that one has gone since" {
    const os = boot("");
    const zed = launch(os, "Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    const c = open(os, zed, .{});
    os.settle();
    const top = Rect.init(864, 38, 864, 540);
    const bottom = Rect.init(864, 578, 864, 539);
    try expect_frame(top, b);
    try expect_frame(bottom, c);
    // c sat below b. While it is away b trades places with a.
    os.window_minimize(c, true);
    os.settle();
    try expect_reply("", run(os, "swap {d} {d}", .{ a, b }));
    os.settle();
    try expect_frame(left_half, b);
    os.window_minimize(c, false);
    os.settle();
    try expect_frame(Rect.init(0, 38, 864, 540), b);
    try expect_frame(Rect.init(0, 578, 864, 539), c);
    try expect_frame(right_half, a);
    // With its neighbour on another workspace it joins the layout like a new window.
    os.window_minimize(c, true);
    os.settle();
    os.window_click(b);
    os.command_run("send 2");
    os.settle();
    os.window_minimize(c, false);
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(right_half, c);
}

test "a minimized window whose neighbour closed joins like a new one, and its place beats insert" {
    const os = boot("");
    const zed = launch(os, "Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    const c = open(os, zed, .{});
    os.settle();
    os.window_minimize(c, true);
    os.settle();
    os.window_close(b);
    os.settle();
    try expect_frame(screen, a);
    os.window_minimize(c, false);
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(right_half, c);
    os.window_minimize(c, true);
    os.settle();
    os.command_run("insert west");
    os.window_minimize(c, false);
    os.settle();
    // The place it left wins over the side that insert chose, which is kept for the next
    // new window.
    try expect_frame(left_half, a);
    try expect_frame(right_half, c);
    const d = open(os, zed, .{});
    os.settle();
    try expect_frame(Rect.init(864, 38, 432, 1079), d);
    try expect_frame(Rect.init(1296, 38, 432, 1079), c);
}

test "a minimized window returns to its place when the split beside it lost or gained a window" {
    const os = boot("");
    const zed = launch(os, "Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    const c = open(os, zed, .{});
    const d = open(os, zed, .{});
    os.settle();
    // a fills the left half; on the right b sits above c and d, which are side by side.
    const top = Rect.init(864, 38, 864, 540);
    try expect_frame(top, b);
    try expect_frame(Rect.init(864, 578, 432, 539), c);
    try expect_frame(Rect.init(1296, 578, 432, 539), d);
    os.window_minimize(b, true);
    os.settle();
    os.window_close(d);
    os.settle();
    os.window_minimize(b, false);
    os.settle();
    // Above c as before, and not across the top of a as well.
    try expect_frame(left_half, a);
    try expect_frame(top, b);
    try expect_frame(Rect.init(864, 578, 864, 539), c);
    // The split under it grows by a window while it is away: it returns above all of it.
    os.window_click(c);
    os.settle();
    const e = open(os, zed, .{});
    os.settle();
    os.window_minimize(b, true);
    os.window_click(c);
    os.settle();
    const f = open(os, zed, .{});
    os.settle();
    os.window_minimize(b, false);
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(top, b);
    try expect_frame(Rect.init(864, 578, 432, 270), c);
    try expect_frame(Rect.init(864, 848, 432, 269), f);
    try expect_frame(Rect.init(1296, 578, 432, 539), e);
}

// Tiles dropped on another monitor.

test "a tile dropped on a monitor that shows a zoomed window joins the layout under it" {
    const os = boot("");
    os.monitors_set(1); // Laptop on the left, external display on the right.
    const zed = launch(os, "Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    os.settle();
    os.command_run("focus-monitor 2");
    const c = open(os, zed, .{});
    const d = open(os, zed, .{});
    os.settle();
    os.command_run("zoom --on");
    os.settle();
    try expect_frame(external, d);
    os.window_click(a);
    os.settle();
    // Dropped where c's cell is, under the zoomed window.
    var drop = frame_of(a);
    drop.x = 2000;
    drop.y = 300;
    os.window_drag(a, drop);
    os.settle();
    try testing.expectEqual(@as(u8, 1), known(a).workspace);
    try testing.expectEqual(a, engine.focused_window);
    try testing.expectEqual(@as(u8, 1), engine.focused_monitor);
    // The window it left fills the laptop; the zoom is as it was, and the layout under
    // it has the new window beside the one it was dropped on.
    try expect_frame(screen, b);
    try expect_frame(external, d);
    try testing.expectEqual(engine_module.Zoom.fullscreen, known(d).zoom);
    try expect_frame(Rect.init(1728, 38, 1280, 701), c);
    try expect_frame(Rect.init(1728, 739, 1280, 701), a);
}

test "in an accordion the mouse, warp and resize leave the hidden layout as it was" {
    const os = boot("");
    const zed = launch(os, "Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    const c = open(os, zed, .{});
    os.settle();
    os.command_run("toggle accordion");
    os.settle();
    try expect_frame(screen, c);
    // Dropped where a's hidden cell is: nothing trades places, and c snaps back.
    var drop = frame_of(c);
    drop.x = -600;
    drop.y = 100;
    os.window_drag(c, drop);
    os.settle();
    try expect_frame(screen, c);
    // An edge dragged, and resized by command: a stacked window has no size of its own.
    os.window_drag(c, Rect.init(300, 38, 1428, 1079));
    os.settle();
    try expect_frame(screen, c);
    os.command_run("resize left -100");
    os.command_run("resize ratio 30");
    // warp has no side to go to in a stack: it trades places along it, as swap does.
    os.command_run("warp north");
    os.settle();
    try expect_frame(screen, c);
    os.command_run("toggle accordion");
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(Rect.init(864, 38, 864, 540), c);
    try expect_frame(Rect.init(864, 578, 864, 539), b);
}

test "from a floating window an accordion is one place, and focus goes to the tile on top" {
    const os = boot("");
    const zed = launch(os, "Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    const b = open(os, zed, .{});
    const c = open(os, zed, .{});
    os.settle();
    os.command_run("toggle accordion");
    _ = run(os, "focus {d}", .{a});
    _ = run(os, "float {d} --bounds 0.75,0.25,0.25,0.5", .{c});
    os.settle();
    _ = run(os, "focus {d}", .{c});
    // b's hidden cell is nearer, but every tile is where the stack is, and a is on top.
    os.command_run("focus west");
    try testing.expectEqual(a, engine.focused_window);
    // From a tile the stack goes on to its other tiles; the floating window comes in the
    // layout order of focus next.
    os.command_run("focus east --wrap");
    try testing.expectEqual(b, engine.focused_window);
    os.command_run("focus next");
    try testing.expectEqual(c, engine.focused_window);
}

test "a tile with tabs dropped on an empty monitor takes its tabs along" {
    const os = boot("");
    os.monitors_set(1);
    const zed = launch(os, "Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    os.settle();
    const tab = open(os, zed, .{ .tab_of = a, .focus = false });
    const b = open(os, zed, .{});
    os.settle();
    os.window_click(a);
    os.settle();
    var drop = frame_of(a);
    drop.x = 2400;
    os.window_drag(a, drop);
    os.settle();
    try expect_frame(external, a);
    try expect_frame(screen, b);
    try testing.expectEqual(@as(u8, 1), known(a).workspace);
    try testing.expectEqual(@as(u8, 1), known(tab).workspace);
    try testing.expectEqual(a, engine.focused_window);
}

// Parking with three displays.

test "hidden windows that refuse to be small show only a sliver on three displays" {
    const os = boot("");
    os.monitors_set(3); // Three displays in a row; the middle one is the main one.
    const zed = launch(os, "Zed", "dev.zed.Zed");
    var ids: [6]WindowId = undefined;
    const monitors = [3][]const u8{ "focus-monitor 1", "focus-monitor 2", "focus-monitor 3" };
    for (&ids, 0..) |*id, index| {
        os.command_run(monitors[index % 3]);
        id.* = open(os, zed, .{ .min_w = 2000, .min_h = 1300 });
        os.settle();
    }
    for (monitors) |text| {
        os.command_run(text);
        os.command_run("workspace new");
        os.settle();
    }
    for (ids) |id| {
        try testing.expect(!engine.workspace_visible(known(id).workspace));
        try testing.expect(sliver_only(id));
        try testing.expect(frame_of(id).w >= 2000 and frame_of(id).h >= 1300);
    }
}

// Limits.

test "more windows and applications than fit are counted, and no step overflows its effects" {
    const os = boot("");
    engine.init(&engine.config);
    _ = step(os, .{ .monitors_changed = &laptop });
    var id: WindowId = 1;
    while (id <= engine_module.windows_max + 40) : (id += 1) {
        // More applications than fit, too: the windows of the ones left out are dropped.
        const pid: i32 = @intCast(1 + id % (engine_module.apps_max + 12));
        _ = step(os, .{ .window_appeared = info_of(id, pid, Rect.init(10, 50, 300, 300)) });
        _ = step(os, .{ .window_focused = id });
    }
    var tracked: u32 = 0;
    for (&engine.windows) |*window| tracked += @intFromBool(window.id != 0);
    try testing.expect(tracked <= engine_module.windows_max);
    try testing.expectEqual(engine_module.windows_max + 40 - tracked, engine.stats.windows_dropped);
    const texts = [_][]const u8{
        "balance",         "retile",       "rotate 90",       "layout float",
        "layout bsp",      "close-others", "send 2 --follow", "workspace 1",
        "query tree",      "toggle gaps",  "focus next",      "warp west",
        "send 1 --follow", "focus 3",      "close-others",    "toggle zoom-fullscreen",
    };
    for (texts) |text| {
        var pool: command.StringPool = .{};
        const parsed = command.parse(text, &pool) catch unreachable;
        os.now_ms += 200;
        try testing.expect(step(os, .{ .command = parsed }) <= engine_module.windows_max + 2);
        try testing.expect(step(os, .tick) <= 2 * engine_module.windows_max);
    }
    // An application with many windows quits: more happened than the notes can hold.
    try testing.expect(step(os, .{ .app_terminated = 1 }) <= engine_module.windows_max + 2);
    try testing.expect(step(os, .{ .app_terminated = 2 }) <= engine_module.windows_max + 2);
    try testing.expect(step(os, .{ .monitors_changed = &laptop }) <= engine_module.windows_max + 2);
}

test "an application that quits with many windows ends its notes with overflow" {
    const os = boot("");
    const zed = launch(os, "Zed", "dev.zed.Zed");
    const ghostty = launch(os, "Ghostty", "com.mitchellh.ghostty");
    const keeper = open(os, ghostty, .{});
    var count: u32 = 0;
    while (count < engine_module.notes_max + 4) : (count += 1) _ = open(os, zed, .{});
    os.settle();
    _ = step(os, .{ .app_terminated = zed });
    const notes = engine.notes_slice();
    try testing.expectEqual(@as(usize, engine_module.notes_max), notes.len);
    try testing.expect(notes[notes.len - 1] == .overflow);
    // The frames of that step were dropped; reporting the displays again sends them.
    os.app_quit(zed);
    os.monitors_set(0);
    os.settle();
    try testing.expectEqual(keeper, engine.focused_window);
    try expect_frame(screen, keeper);
}

// Anything the operating system can report, in any order.

const Storm = struct {
    prng: stdx.Prng,
    now_ms: u64 = 1000,
    next_id: WindowId = 1,
    live: [48]WindowId = @splat(0),

    const titles = [_][]const u8{ "x", "aa", "bb", "cc", "dd", "ee", "ff", "y" };
    const rules =
        "rule title=\"aa\" : sticky\nrule title=\"bb\" : workspace 3\n" ++
        "rule title=\"cc\" : ignore\nrule title=\"dd\" : float\n" ++
        "rule title=\"ee\" : workspace 1\nrule title=\"ff\" : tile\n";
    const commands = [_][]const u8{
        "focus west",              "focus east",                 "swap north",
        "warp south",              "warp east",                  "balance",
        "retile",                  "rotate 90",                  "toggle float",
        "toggle zoom-parent",      "toggle zoom-fullscreen",     "send 2",
        "send 3 --follow",         "workspace 1",                "workspace 2",
        "workspace 3",             "workspace next",             "workspace recent",
        "workspace new",           "send new",                   "layout float",
        "layout bsp",              "focus next",                 "toggle sticky",
        "focus-monitor next",      "focus-monitor 2",            "send-monitor next --follow",
        "send-monitor 1",          "move-floating 900 0",        "move-floating -900 300",
        "grid 4:4:1:1:2:2",        "focus 3",                    "focus 7",
        "move 2 left 5",           "move 9 below 4",             "swap 1 6",
        "zoom 8 --on",             "float 5",                    "tile 5",
        "label 4 a",               "focus a",                    "float 3 --bounds 0.5,0,0.5,1",
        "close",                   "close 3",                    "label b",
        "label 6 b",               "swap a b",                   "move a right b --ratio 20",
        "zoom b",                  "tile b",                     "focus prev --wrap",
        "focus south --wrap",      "insert east --ratio 30",     "resize ratio 70",
        "resize left -9999",       "mirror y-axis",              "toggle split",
        "toggle gaps",             "query tree --json",          "query windows",
        "label-workspace web",     "workspace web",              "send web",
        "workspace prev",          "focus-monitor recent",       "send recent",
        "send-monitor 3 --follow", "move-floating 2147483647 0", "move-floating 0 -2147483647",
    };

    fn any(storm: *Storm) WindowId {
        return storm.live[storm.prng.below(storm.live.len)];
    }

    fn frame(storm: *Storm) Rect {
        const prng = &storm.prng;
        return Rect.init(@intCast(prng.below(5000)), @intCast(prng.below(1500)), 400, 300);
    }

    fn send(storm: *Storm, event: engine_module.Event) void {
        _ = engine.step(event, storm.now_ms);
    }

    /// Between none and four displays, anywhere, of any size, with or without a main one.
    fn displays(storm: *Storm) void {
        const prng = &storm.prng;
        var list: [4]MonitorInfo = undefined;
        const count = prng.below(list.len + 1);
        var main_set = false;
        for (list[0..count], 0..) |*info, index| {
            const main = !main_set and prng.chance(1, 2);
            main_set = main_set or main;
            const x: i32 = @intCast(prng.below(4) * 1500);
            const y: i32 = @intCast(prng.below(3) * 700);
            const w: i32 = @intCast(800 + prng.below(1500));
            const h: i32 = @intCast(600 + prng.below(900));
            info.* = .{
                // Never the same display twice in one list.
                .display = @intCast(1 + index + 4 * prng.below(2)),
                .frame = Rect.init(x, y, w, h),
                .visible = Rect.init(x, y + 30, w, h - 30),
                .main = main,
            };
        }
        storm.send(.{ .monitors_changed = list[0..count] });
    }

    fn window_toggle(storm: *Storm) void {
        const prng = &storm.prng;
        const slot = &storm.live[prng.below(storm.live.len)];
        if (slot.* != 0) {
            storm.send(.{ .window_destroyed = slot.* });
            slot.* = 0;
            return;
        }
        slot.* = storm.next_id;
        storm.next_id += 1;
        var info = info_of(slot.*, @intCast(1 + prng.below(5)), storm.frame());
        info.title = titles[prng.below(titles.len)];
        info.resizable = prng.chance(9, 10);
        info.adopted = prng.chance(1, 5);
        info.minimized = prng.chance(1, 20);
        info.fullscreen = prng.chance(1, 20);
        if (prng.chance(1, 10)) info.kind = .dialog;
        if (prng.chance(1, 4)) info.workspace = @intCast(prng.below(20));
        if (prng.chance(1, 6)) info.tab_of = storm.any();
        storm.send(.{ .window_appeared = info });
    }

    fn application(storm: *Storm) void {
        const pid: i32 = @intCast(1 + storm.prng.below(5));
        if (storm.prng.chance(2, 3)) return storm.send(.{ .app_unresponsive = pid });
        storm.send(.{ .app_terminated = pid });
        for (&storm.live) |*id| {
            if (engine.window_find(id.*) == null) id.* = 0;
        }
    }

    fn remember(storm: *Storm) void {
        const prng = &storm.prng;
        var memory: [4]engine_module.WorkspaceMemory = undefined;
        for (&memory) |*entry| {
            entry.* = .{
                .workspace = @intCast(prng.below(20)),
                .display = prng.below(8),
                .shown = prng.chance(1, 2),
            };
        }
        storm.send(.{ .workspaces_remembered = &memory });
    }

    /// The answer to a frame that may never have been set.
    fn answer(storm: *Storm) void {
        const id = storm.any();
        storm.send(.{ .window_frame_applied = .{ .id = id, .frame = storm.frame() } });
    }

    fn tick(storm: *Storm) !void {
        storm.send(.tick);
        // A deadline that a tick leaves in the past would have the shell tick for ever.
        if (engine.next_deadline_ms()) |deadline| try testing.expect(deadline > storm.now_ms);
    }

    fn command_any(storm: *Storm) void {
        var pool: command.StringPool = .{};
        const text = commands[storm.prng.below(commands.len)];
        storm.send(.{ .command = command.parse(text, &pool) catch unreachable });
    }

    fn window_event(storm: *Storm, roll: u32) void {
        const prng = &storm.prng;
        const id = storm.any();
        const flag = prng.chance(1, 2);
        switch (roll % 7) {
            0 => storm.send(.{ .window_focused = id }),
            1 => storm.send(.{ .focus_reported = id }),
            2 => storm.send(.{ .window_minimized = .{ .id = id, .minimized = flag } }),
            3 => storm.send(.{ .window_fullscreen = .{ .id = id, .fullscreen = flag } }),
            4 => storm.send(.{ .window_tab_changed = .{
                .id = id,
                .tab_of = if (flag) storm.any() else 0,
            } }),
            5 => storm.send(.{ .window_frame_changed = .{
                .id = id,
                .frame = storm.frame(),
                .by_user = flag,
            } }),
            else => storm.send(.{ .window_title_changed = .{
                .id = id,
                .title = titles[prng.below(titles.len)],
            } }),
        }
    }

    fn round(storm: *Storm) !void {
        const prng = &storm.prng;
        storm.now_ms += prng.below(300);
        const roll = prng.below(100);
        switch (roll) {
            0...11 => storm.displays(),
            12...29 => storm.window_toggle(),
            30...64 => storm.window_event(roll),
            65...66 => storm.application(),
            67...69 => try storm.tick(),
            70 => storm.answer(),
            71 => storm.remember(),
            72...73 => storm.send(.{ .adoption = if (prng.chance(1, 2)) .begin else .end }),
            else => storm.command_any(),
        }
        engine.verify();
        for (&engine.windows) |*window| {
            if (window.id == 0 or !window.sticky or engine.monitors_count == 0) continue;
            // Sticky means in view.
            try testing.expect(engine.workspace_visible(window.workspace));
        }
    }
};

test "the engine keeps its invariants whatever is reported to it, in whatever order" {
    _ = boot(Storm.rules);
    var seed: u64 = 1;
    while (seed <= 200) : (seed += 1) {
        engine.init(&engine.config);
        var storm: Storm = .{ .prng = stdx.Prng.init(seed) };
        var rounds: u32 = 0;
        while (rounds < 400) : (rounds += 1) try storm.round();
    }
}
