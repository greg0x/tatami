//! Scenario tests: one for each AeroSpace failure this window manager exists to not have.
//! They run the real engine against the simulated OS with random faults switched off, so
//! every expectation is exact.
const std = @import("std");
const testing = std.testing;
const geometry = @import("geometry.zig");
const stdx = @import("stdx.zig");
const config_module = @import("config.zig");
const engine_module = @import("engine.zig");
const sim = @import("sim.zig");

const Rect = geometry.Rect;
const Engine = engine_module.Engine;

var engine: Engine = undefined;
var simulator: sim.Simulator = undefined;

// The simulated laptop screen: 1728x1117 with a 38 pixel menu bar.
const screen = Rect.init(0, 38, 1728, 1079);
const left_half = Rect.init(0, 38, 864, 1079);
const right_half = Rect.init(864, 38, 864, 1079);

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

/// Opens a window and lets the OS report it, so that windows appear in the order written.
fn open(os: *sim.Simulator, app: i32, options: sim.Simulator.WindowOptions) engine_module.WindowId {
    const id = os.window_open(app, options);
    os.advance(1);
    return id;
}

fn frame_of(id: engine_module.WindowId) Rect {
    return simulator.window_find(id).?.frame;
}

fn expect_frame(expected: Rect, id: engine_module.WindowId) !void {
    const actual = frame_of(id);
    if (!actual.eql(expected)) {
        std.debug.print("window {d}: expected {any}, found {any}\n", .{ id, expected, actual });
        return error.TestUnexpectedResult;
    }
}

fn parked(id: engine_module.WindowId) bool {
    const frame = frame_of(id);
    return frame.overlap(Rect.init(0, 0, 1728, 1117), .x) <= 1;
}

test "new windows tile like yabai bsp and focus moves with cmd-hjkl" {
    const os = boot("");
    const app = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const a = open(os, app, .{});
    os.settle();
    try expect_frame(screen, a);
    const b = open(os, app, .{});
    os.settle();
    const c = open(os, app, .{});
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(Rect.init(864, 38, 864, 540), b);
    try expect_frame(Rect.init(864, 578, 864, 539), c);
    try testing.expectEqual(c, engine.focused_window);
    os.command_run("focus north");
    try testing.expectEqual(b, engine.focused_window);
    os.command_run("focus west");
    try testing.expectEqual(a, engine.focused_window);
    // Focus is optimistic: two presses in a row do not wait for the OS in between.
    os.command_run("focus east");
    os.command_run("focus south");
    try testing.expectEqual(c, engine.focused_window);
    os.settle();
    try testing.expectEqual(c, os.focused);
}

test "a window that fights the layout is floated after a bounded number of tries" {
    // AeroSpace: 'my granola is flashing all the time'.
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const calm = open(os, app, .{});
    const home = Rect.init(300, 200, 500, 400);
    const stubborn = open(os, app, .{ .stubborn = true, .frame = home });
    os.settle(); // Would never return if the fight went on forever.
    const known = engine.window_find(stubborn).?;
    try testing.expect(known.auto_floated);
    try testing.expectEqual(engine_module.Mode.floating, known.mode);
    try testing.expect(known.sets_total <= engine_module.drift_max + 1);
    try expect_frame(home, stubborn);
    try expect_frame(screen, calm);
    try testing.expectEqual(@as(u64, 1), engine.stats.windows_auto_floated);
}

test "a window with a minimum size is asked a bounded number of times" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const wide = open(os, app, .{ .min_w = 1200 });
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(Rect.init(864, 38, 1200, 1079), wide);
    const known = engine.window_find(wide).?;
    try testing.expect(known.sets_total <= 1 + engine_module.attempts_max);
}

test "a title that arrives late still matches its rule, a later title change does not" {
    // AeroSpace needed a polling shell script to float the Tempo Wallet popup in Brave.
    const os = boot("");
    const brave = os.app_launch("Brave Browser", "com.brave.Browser");
    const browser = open(os, brave, .{ .title = "Inbox" });
    const wallet = open(os, brave, .{ .title = "Untitled", .late_title = true });
    os.advance(100);
    try testing.expectEqual(engine_module.Mode.tiled, engine.window_find(wallet).?.mode);
    os.advance(1000);
    try testing.expectEqual(engine_module.Mode.floating, engine.window_find(wallet).?.mode);
    os.settle();
    try expect_frame(screen, browser);
    // Navigating a tiled browser window to the wallet later must not float the browser.
    os.advance(10_000);
    os.window_title(browser, "Tempo Wallet");
    os.settle();
    try testing.expectEqual(engine_module.Mode.tiled, engine.window_find(browser).?.mode);
}

test "a native tab shares the tile of its window" {
    // AeroSpace: 'a second ghostty tab will be treated as a new window'.
    const os = boot("");
    const ghostty = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const terminal = open(os, ghostty, .{});
    const editor = open(os, zed, .{});
    os.settle();
    try expect_frame(left_half, terminal);
    try expect_frame(right_half, editor);
    os.window_click(terminal);
    os.settle();
    const tab = open(os, ghostty, .{ .tab_of = terminal });
    os.settle();
    try expect_frame(left_half, tab);
    try expect_frame(right_half, editor);
    try testing.expectEqual(tab, engine.focused_window);
    try testing.expectEqual(tab, engine.window_find(terminal).?.tab_of);
    os.window_close(tab);
    os.settle();
    try expect_frame(left_half, terminal);
    try expect_frame(right_half, editor);
    try testing.expectEqual(terminal, engine.focused_window);
}

test "popups and helper windows are never tiled" {
    // AeroSpace: 'a chrome window that is fucking up my tiling'.
    const os = boot("");
    const chrome = os.app_launch("Google Chrome", "com.google.Chrome");
    const browser = open(os, chrome, .{});
    const popup = open(os, chrome, .{ .kind = .popup, .frame = Rect.init(50, 50, 300, 20) });
    const dialog = open(os, chrome, .{ .kind = .dialog, .frame = Rect.init(500, 300, 400, 300) });
    os.settle();
    try expect_frame(screen, browser);
    try expect_frame(Rect.init(50, 50, 300, 20), popup);
    try expect_frame(Rect.init(500, 300, 400, 300), dialog);
    try testing.expect(engine.window_find(popup) == null);
    try testing.expectEqual(engine_module.Mode.floating, engine.window_find(dialog).?.mode);
}

test "a zoomed window stays zoomed when another window takes focus" {
    // Asked for: 'my window stayed in full screen and the window I alt tabbed towards just
    // came as a temporary overlay'.
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    os.window_click(a);
    os.settle();
    os.command_run("toggle zoom-fullscreen");
    os.settle();
    try expect_frame(screen, a);
    os.window_click(b);
    os.settle();
    try expect_frame(screen, a);
    try expect_frame(right_half, b);
    try testing.expectEqual(b, engine.focused_window);
    os.command_run("toggle zoom-fullscreen");
    os.command_run("focus west");
    os.command_run("toggle zoom-fullscreen");
    os.settle();
    try expect_frame(left_half, a);
}

test "an accordion stacks the tiles and focus steps through them in layout order" {
    // Asked for: 'many overlapping windows and I can scroll through them with a key
    // combination', as with AeroSpace's accordion layout.
    const os = boot("");
    const app = os.app_launch("Slack", "com.tinyspeck.slackmacgap");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    const c = open(os, app, .{});
    // Wider than a third of the screen: as a tile it would lie over its neighbour.
    const wide = open(os, app, .{ .min_w = 800 });
    os.settle();
    os.command_run("toggle accordion");
    os.settle();
    for ([_]engine_module.WindowId{ a, b, c, wide }) |id| try expect_frame(screen, id);
    try testing.expectEqual(wide, engine.focused_window);
    // South and east go on through the stack, north and west go back.
    os.command_run("focus north");
    try testing.expectEqual(c, engine.focused_window);
    os.command_run("focus west");
    os.command_run("focus west");
    try testing.expectEqual(a, engine.focused_window);
    os.command_run("focus north");
    try testing.expectEqual(a, engine.focused_window);
    os.command_run("focus north --wrap");
    try testing.expectEqual(wide, engine.focused_window);
    os.command_run("focus south --wrap");
    try testing.expectEqual(a, engine.focused_window);
    os.command_run("focus east");
    try testing.expectEqual(b, engine.focused_window);
    // Swap moves the window one place along the stack.
    os.command_run("swap south");
    os.command_run("focus north");
    try testing.expectEqual(c, engine.focused_window);
    os.settle();
    try testing.expectEqual(c, os.focused);
    // The tree was kept underneath: the tiles come back where they were, b and c traded.
    os.command_run("toggle accordion");
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(Rect.init(864, 38, 864, 540), c);
    try testing.expect(!frame_of(b).eql(screen));
}

test "focus --wrap goes around an accordion even with a monitor that way" {
    // Seen live: with a display below the main one, hyper-j (focus south --wrap) stopped at the
    // last chat window and then went to the browser on the other display.
    const os = boot("");
    os.monitors_set(4); // The external display above, the laptop below it.
    const laptop = engine.focused_monitor;
    try testing.expect(engine.monitors[laptop].main);
    const app = os.app_launch("Slack", "com.tinyspeck.slackmacgap");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    const c = open(os, app, .{});
    os.settle();
    os.command_run("toggle accordion");
    os.settle();
    try testing.expectEqual(c, engine.focused_window);
    os.command_run("focus south --wrap");
    try testing.expectEqual(a, engine.focused_window);
    os.command_run("focus north --wrap");
    try testing.expectEqual(c, engine.focused_window);
    os.command_run("focus north");
    os.command_run("focus north");
    try testing.expectEqual(a, engine.focused_window);
    os.command_run("focus north --wrap");
    try testing.expectEqual(c, engine.focused_window);
    try testing.expectEqual(laptop, engine.focused_monitor);
    // Without --wrap the end of the stack is an edge like any other, and the display
    // above is that way.
    os.command_run("focus north");
    os.command_run("focus north");
    os.command_run("focus north");
    try testing.expect(engine.focused_monitor != laptop);
    _ = b;
}

test "a hung application delays only its own windows" {
    // AeroSpace: 'restart aerospace it is very slow', and a CLI that hangs with it.
    const os = boot("");
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const slack = os.app_launch("Slack", "com.tinyspeck.slackmacgap");
    const a = open(os, zed, .{});
    const b = open(os, slack, .{});
    os.settle();
    try expect_frame(left_half, a);
    try expect_frame(right_half, b);
    os.app_hang(slack, 2000);
    os.command_run("focus west");
    os.command_run("swap east");
    os.advance(1);
    try expect_frame(right_half, a); // Moved at once.
    try expect_frame(right_half, b); // Still where it was; nobody waited for it.
    try testing.expect(engine.stats.apps_suspended >= 1);
    os.advance(3000);
    try expect_frame(left_half, b); // Caught up once it answered again.
}

test "workspaces switch with one frame per window and come back exactly" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    const c = open(os, app, .{});
    os.settle();
    const frames = [3]Rect{ frame_of(a), frame_of(b), frame_of(c) };
    var sets = os.frames_set;
    os.command_run("workspace 2");
    os.settle();
    try testing.expectEqual(@as(u64, 3), os.frames_set - sets);
    try testing.expect(parked(a) and parked(b) and parked(c));
    try testing.expectEqual(@as(engine_module.WindowId, 0), engine.focused_window);
    const d = open(os, app, .{});
    os.settle();
    try expect_frame(screen, d);
    sets = os.frames_set;
    os.command_run("workspace 1");
    os.settle();
    try testing.expectEqual(@as(u64, 4), os.frames_set - sets);
    try expect_frame(frames[0], a);
    try expect_frame(frames[1], b);
    try expect_frame(frames[2], c);
    try testing.expect(parked(d));
    try testing.expectEqual(c, engine.focused_window);
    try testing.expectEqual(c, os.focused);
    // Send the focused window away and follow it.
    os.command_run("send 2 --follow");
    os.settle();
    try testing.expectEqual(c, engine.focused_window);
    try testing.expect(parked(a) and parked(b));
    try testing.expect(!parked(c) and !parked(d));
}

test "warp with nobody on that side puts the window there" {
    // Asked for: cmd-shift-j and cmd-shift-k 'so i can put a window down / below another'.
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    try testing.expectEqual(b, engine.focused_window);
    try testing.expect(frame_of(a).x < frame_of(b).x and frame_of(a).y == frame_of(b).y);
    // Side by side, the focused window goes below the other one.
    os.command_run("warp south");
    os.settle();
    try testing.expect(frame_of(a).y < frame_of(b).y and frame_of(a).x == frame_of(b).x);
    try testing.expectEqual(screen.w, frame_of(a).w);
    try testing.expectEqual(screen.w, frame_of(b).w);
    try testing.expectEqual(screen.h, frame_of(a).h + frame_of(b).h);
    try testing.expectEqual(b, engine.focused_window);
    // With a neighbour on that side it trades places with it, as before.
    os.command_run("warp north");
    os.settle();
    try testing.expect(frame_of(b).y < frame_of(a).y);
    // And back to side by side, on the side that was asked for.
    os.command_run("warp west");
    os.settle();
    try testing.expect(frame_of(b).x < frame_of(a).x and frame_of(a).y == frame_of(b).y);
    try testing.expectEqual(screen.h, frame_of(a).h);
    // A third window that is at the bottom of its column moves under everything.
    const c = open(os, app, .{});
    os.settle();
    os.command_run("warp south");
    os.settle();
    const below = frame_of(c);
    try testing.expectEqual(screen.w, below.w);
    try testing.expect(below.y > frame_of(a).y and below.y > frame_of(b).y);
    try testing.expectEqual(c, engine.focused_window);
}

test "an empty workspace stays when a hidden application repeats its focus" {
    // Seen live: 800 ms after switching to an empty workspace, the browser announced the
    // focus it already had and the old workspace came straight back.
    const os = boot("");
    const app = os.app_launch("Brave Browser", "com.brave.Browser");
    const a = open(os, app, .{});
    const other = os.app_launch("Zed", "dev.zed.Zed");
    const b = open(os, other, .{ .focus = false });
    os.settle();
    os.window_click(a);
    os.settle();
    try testing.expectEqual(a, engine.focused_window);
    os.command_run("workspace 9");
    os.settle();
    try testing.expect(parked(a) and parked(b));
    for (0..5) |_| {
        os.advance(800);
        os.focus_repeat();
        os.settle();
        try testing.expect(parked(a) and parked(b));
    }
    // Really going to another window of a hidden workspace still brings it back.
    os.window_click(b);
    os.settle();
    try testing.expect(!parked(a) and !parked(b));
    try testing.expectEqual(b, engine.focused_window);
}

test "a parked window that macOS lifts is not asked twice" {
    // Seen live: parked at the very bottom, windows came back 32 or 40 pixels higher,
    // and every workspace switch retried every frame.
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{ .title_bar = 32 });
    const b = open(os, app, .{ .title_bar = 40 });
    os.settle();
    const frames = [2]Rect{ frame_of(a), frame_of(b) };
    for (0..3) |_| {
        var sets = os.frames_set;
        os.command_run("workspace 2");
        os.settle();
        try testing.expectEqual(@as(u64, 2), os.frames_set - sets);
        try testing.expect(parked(a) and parked(b));
        sets = os.frames_set;
        os.command_run("workspace 1");
        os.settle();
        try testing.expectEqual(@as(u64, 2), os.frames_set - sets);
        try expect_frame(frames[0], a);
        try expect_frame(frames[1], b);
    }
    try testing.expectEqual(@as(u64, 0), engine.stats.frames_retried);
}

test "a sticky window stays on screen across workspaces" {
    // AeroSpace has no sticky windows (its pull request 2083 was tried and reverted).
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const note = open(os, app, .{ .frame = Rect.init(1200, 100, 400, 300) });
    os.settle();
    os.command_run("toggle sticky");
    os.settle();
    try expect_frame(screen, a);
    const place = frame_of(note);
    os.command_run("workspace 3");
    os.settle();
    try testing.expect(parked(a));
    try expect_frame(place, note);
    os.command_run("workspace 1");
    os.settle();
    try expect_frame(screen, a);
    try expect_frame(place, note);
}

test "a window sent away by a rule does not pull focus or the workspace with it" {
    // Asked for: 'in all your tests the window kept popping up in front of my face'.
    const os = boot("rule app=\"Simulator\" : workspace 9\n");
    const ghostty = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const terminal = open(os, ghostty, .{});
    os.settle();
    const ios = os.app_launch("Simulator", "com.apple.iphonesimulator");
    const phone = open(os, ios, .{ .frame = Rect.init(400, 100, 400, 800) });
    os.settle();
    try testing.expect(parked(phone));
    try expect_frame(screen, terminal);
    try testing.expectEqual(terminal, engine.focused_window);
    try testing.expectEqual(terminal, os.focused);
    try testing.expectEqual(@as(u8, 8), engine.window_find(phone).?.workspace);
    // Going there on purpose still works.
    os.command_run("workspace 9");
    os.settle();
    try testing.expect(!parked(phone));
    try testing.expectEqual(phone, engine.focused_window);
}

test "windows that were already open stay on the monitor they are on" {
    const os = boot("");
    os.monitors_set(1); // Laptop on the left, external display on the right.
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const external = Rect.init(1728, 38, 2560, 1402);
    const there = open(os, app, .{ .frame = Rect.init(2000, 200, 900, 700), .adopted = true });
    os.settle();
    try expect_frame(external, there);
    // A window opened from now on joins the workspace in use, wherever the app drew it.
    os.command_run("focus-monitor 1");
    os.settle();
    const here = open(os, app, .{ .frame = Rect.init(2100, 300, 900, 700) });
    os.settle();
    try expect_frame(screen, here);
    try expect_frame(external, there);
}

test "workspaces return to a monitor that is unplugged and plugged back in" {
    const os = boot("");
    os.monitors_set(1); // Laptop on the left, external display on the right.
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    os.settle();
    os.command_run("focus-monitor 2");
    const b = open(os, app, .{});
    os.settle();
    const external = Rect.init(1728, 38, 2560, 1402);
    try expect_frame(screen, a);
    try expect_frame(external, b);
    os.monitors_set(0);
    os.settle();
    // The window in use stays in view on the remaining screen; the other waits.
    try expect_frame(screen, b);
    try testing.expect(parked(a));
    os.monitors_set(1);
    os.settle();
    try expect_frame(screen, a);
    try expect_frame(external, b);
}

test "the mouse can swap and resize tiles" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    // Drop the left window onto the right one.
    os.window_drag(a, Rect.init(900, 100, 864, 1079));
    os.settle();
    try expect_frame(right_half, a);
    try expect_frame(left_half, b);
    // Drag the shared edge 100 pixels to the right.
    os.window_drag(b, Rect.init(0, 38, 964, 1079));
    os.settle();
    try expect_frame(Rect.init(0, 38, 964, 1079), b);
    try expect_frame(Rect.init(964, 38, 764, 1079), a);
}

test "quitting brings every parked window back on screen" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    os.settle();
    os.command_run("workspace 2");
    os.settle();
    try testing.expect(parked(a));
    os.command_run("quit");
    os.advance(1000);
    try testing.expect(!parked(a));
    // A stopped engine does nothing more, whatever still arrives.
    os.command_run("workspace 1");
    try testing.expectEqual(@as(u32, 0), engine.effects_count);
}

// Commands that name their windows, after Rex's command line (docs/REX.md).

/// Runs a command built from a format string and returns what the engine answered.
fn run(os: *sim.Simulator, comptime format: []const u8, args: anytype) []const u8 {
    var buffer: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch unreachable;
    os.command_run(text);
    return engine.reply();
}

fn expect_reply(prefix: []const u8, reply: []const u8) !void {
    if (std.mem.startsWith(u8, reply, prefix)) return;
    std.debug.print("expected a reply starting with {s}, found {s}\n", .{ prefix, reply });
    return error.TestUnexpectedResult;
}

test "windows are addressed by id and by label" {
    const os = boot("");
    const app = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    const c = open(os, app, .{});
    os.settle();
    try testing.expectEqual(c, engine.focused_window);
    try expect_reply("", run(os, "label {d} editor", .{a}));
    _ = run(os, "focus editor", .{});
    try testing.expectEqual(a, engine.focused_window);
    _ = run(os, "focus {d}", .{c});
    try testing.expectEqual(c, engine.focused_window);
    // Only the two windows trade places.
    const a_before = frame_of(a);
    const c_before = frame_of(c);
    _ = run(os, "swap editor {d}", .{c});
    os.settle();
    try expect_frame(c_before, a);
    try expect_frame(a_before, c);
    try expect_frame(Rect.init(864, 38, 864, 540), b);
    // A name that fits nothing or several things changes nothing and says so.
    try expect_reply("error: not-found", run(os, "focus 9999", .{}));
    try expect_reply("error: not-found", run(os, "focus logs", .{}));
    _ = run(os, "label {d} Editor", .{b});
    try expect_reply("error: ambiguous", run(os, "focus editor", .{}));
    try testing.expectEqual(c, engine.focused_window);
    _ = run(os, "label {d} --clear", .{b});
    _ = run(os, "focus EDITOR", .{});
    try testing.expectEqual(a, engine.focused_window);
    try expect_reply("error: bad-request", run(os, "swap editor {d}", .{a}));
}

test "move puts a window beside any other one, with its share of the split" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    try expect_frame(left_half, a);
    _ = run(os, "move {d} below {d} --ratio 30", .{ a, b });
    os.settle();
    try testing.expect(frame_of(b).y < frame_of(a).y);
    try testing.expectEqual(screen.w, frame_of(a).w);
    try testing.expectEqual(screen.w, frame_of(b).w);
    try testing.expectEqual(screen.h, frame_of(a).h + frame_of(b).h);
    try testing.expect(@abs(frame_of(a).h * 100 - screen.h * 30) < 200);
    // From another workspace, and focus goes along when the window had it.
    const c = open(os, app, .{});
    os.settle();
    _ = run(os, "send 2", .{});
    os.settle();
    try testing.expect(parked(c));
    try testing.expect(engine.focused_window != c);
    _ = run(os, "move {d} left {d}", .{ c, a });
    os.settle();
    try testing.expectEqual(@as(u8, 0), engine.window_find(c).?.workspace);
    try testing.expect(frame_of(c).x < frame_of(a).x and frame_of(c).y == frame_of(a).y);
    try testing.expect(engine.focused_window != c);
    // A floating window joins the layout.
    _ = run(os, "float {d}", .{b});
    _ = run(os, "move {d} right {d}", .{ b, c });
    os.settle();
    try testing.expectEqual(engine_module.Mode.tiled, engine.window_find(b).?.mode);
    try testing.expect(frame_of(b).x > frame_of(c).x and frame_of(b).y == frame_of(c).y);
    _ = run(os, "float {d}", .{c});
    try expect_reply("error: conflict", run(os, "move {d} left {d}", .{ a, c }));
}

test "focus next and prev follow the layout order, and wrap when asked" {
    const os = boot("");
    const app = os.app_launch("Ghostty", "com.mitchellh.ghostty");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    const c = open(os, app, .{});
    os.settle();
    os.command_run("focus next");
    try testing.expectEqual(c, engine.focused_window);
    os.command_run("focus next --wrap");
    try testing.expectEqual(a, engine.focused_window);
    os.command_run("focus next");
    try testing.expectEqual(b, engine.focused_window);
    os.command_run("focus prev");
    os.command_run("focus prev");
    try testing.expectEqual(a, engine.focused_window);
    os.command_run("focus prev --wrap");
    try testing.expectEqual(c, engine.focused_window);
    // By direction: from the left edge around to the window furthest right.
    os.command_run("focus west");
    os.command_run("focus west");
    try testing.expectEqual(a, engine.focused_window);
    os.command_run("focus west --wrap");
    try testing.expect(engine.focused_window == b or engine.focused_window == c);
    os.command_run("focus east --wrap");
    try testing.expectEqual(a, engine.focused_window);
    os.settle();
    try testing.expectEqual(a, os.focused);
}

test "zoom, float with bounds and tile take the window they name" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    const b = open(os, app, .{});
    os.settle();
    try testing.expectEqual(b, engine.focused_window);
    _ = run(os, "zoom {d} --on", .{a});
    os.settle();
    try expect_frame(screen, a);
    try testing.expectEqual(a, engine.focused_window);
    _ = run(os, "zoom --on", .{});
    os.settle();
    try expect_frame(screen, a);
    _ = run(os, "zoom --off", .{});
    os.settle();
    try expect_frame(left_half, a);
    _ = run(os, "float {d} --bounds 0.25,0.25,0.5,0.5", .{b});
    os.settle();
    try expect_frame(Rect.init(432, 307, 864, 539), b);
    try expect_frame(screen, a);
    _ = run(os, "tile {d}", .{b});
    os.settle();
    try testing.expect(frame_of(a).w + frame_of(b).w == screen.w);
}

test "insert takes a share for the next window, and resize ratio sets one" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    os.settle();
    os.command_run("insert west --ratio 25");
    const b = open(os, app, .{});
    os.settle();
    try expect_frame(Rect.init(0, 38, 432, 1079), b);
    try expect_frame(Rect.init(432, 38, 1296, 1079), a);
    os.command_run("resize ratio 50");
    os.settle();
    try expect_frame(left_half, b);
    // The share is spent: the next window splits evenly.
    const c = open(os, app, .{});
    os.settle();
    try testing.expectEqual(frame_of(b).h, frame_of(c).h + 1);
}

test "workspaces can be labelled and named in commands" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    _ = open(os, app, .{});
    os.settle();
    os.command_run("label-workspace web");
    os.command_run("workspace 2");
    try testing.expectEqual(@as(u8, 1), engine.workspace_current());
    try expect_reply("", run(os, "workspace WEB", .{}));
    try testing.expectEqual(@as(u8, 0), engine.workspace_current());
    try expect_reply("error: not-found", run(os, "workspace mail", .{}));
    const b = open(os, app, .{});
    os.settle();
    os.command_run("workspace 3");
    os.command_run("label-workspace mail");
    os.command_run("workspace web");
    _ = run(os, "focus {d}", .{b});
    os.command_run("send mail --follow");
    os.settle();
    try testing.expectEqual(@as(u8, 2), engine.workspace_current());
    try testing.expectEqual(b, engine.focused_window);
    try testing.expect(std.mem.indexOf(u8, run(os, "query workspaces", .{}), "\tmail\n") != null);
}

test "queries answer as lines or as JSON, and the tree carries a revision" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{ .title = "say \"hi\"" });
    const b = open(os, app, .{});
    os.settle();
    var expected: [256]u8 = undefined;
    const layout = std.fmt.bufPrint(
        &expected,
        "\"layout\":{{\"split\":\"columns\",\"ratio\":0.500,\"first\":{{\"window\":{d}}}," ++
            "\"second\":{{\"window\":{d}}}}},\"floating\":[]",
        .{ a, b },
    ) catch unreachable;
    const tree_json = run(os, "query tree --json", .{});
    try testing.expect(std.mem.indexOf(u8, tree_json, layout) != null);
    try expect_reply("{\"revision\":", tree_json);
    const revision = engine.revision;
    try testing.expect(revision > 0);
    // Asking changes nothing; moving a window does.
    _ = run(os, "query tree", .{});
    try testing.expectEqual(revision, engine.revision);
    os.command_run("swap west");
    try testing.expectEqual(revision + 1, engine.revision);
    const notes = engine.notes_slice();
    try testing.expectEqual(@as(usize, 1), notes.len);
    try testing.expectEqual(engine_module.Note{ .view_changed = revision + 1 }, notes[0]);
    const windows = run(os, "query windows --json", .{});
    try expect_reply("{\"windows\":[{\"id\":", windows);
    try testing.expect(std.mem.indexOf(u8, windows, "\"title\":\"say \\\"hi\\\"\"") != null);
    try expect_reply("id=", run(os, "query window {d}", .{a}));
    try expect_reply("{\"id\":", run(os, "query window {d} --json", .{a}));
    try expect_reply("main\tcmd-h\tfocus west\n", run(os, "query bindings", .{}));
    const bindings = run(os, "query bindings --json", .{});
    try expect_reply("{\"bindings\":[{\"mode\":\"main\",\"keys\":\"cmd-h\"", bindings);
    try expect_reply(" main\n", run(os, "query modes", .{}));
    try expect_reply("focus <direction> [--wrap]\t", run(os, "query commands", .{}));
    try expect_reply("{\"events\":", run(os, "query stats --json", .{}));
    try expect_reply("{\"window\":", run(os, "query focus --json", .{}));
    try expect_reply("{\"monitors\":[{\"index\":1,", run(os, "query monitors --json", .{}));
    try expect_reply("{\"workspaces\":[{\"index\":1,", run(os, "query workspaces --json", .{}));
}

test "a step says what it changed" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, app, .{});
    os.settle();
    os.command_run("workspace 2");
    const notes = engine.notes_slice();
    try testing.expectEqual(@as(usize, 3), notes.len);
    try testing.expectEqual(engine_module.Note{ .workspace_changed = 2 }, notes[0]);
    try testing.expectEqual(engine_module.Note{ .focus_changed = 0 }, notes[1]);
    try testing.expect(notes[2] == .view_changed);
    os.command_run("workspace 1");
    try testing.expectEqual(engine_module.Note{ .focus_changed = a }, engine.notes_slice()[1]);
    os.command_run("query windows");
    try testing.expectEqual(@as(usize, 0), engine.notes_slice().len);
}

test "windows found at startup are laid out once, in the order they sit on screen" {
    const os = boot("");
    const app = os.app_launch("Zed", "dev.zed.Zed");
    os.adoption(.begin);
    const right = open(os, app, .{ .frame = Rect.init(1000, 100, 500, 500) });
    const left = open(os, app, .{ .frame = Rect.init(10, 100, 500, 500) });
    const middle = open(os, app, .{ .frame = Rect.init(500, 60, 400, 400) });
    try testing.expectEqual(@as(u64, 0), engine.stats.frames_set);
    os.adoption(.end);
    os.settle();
    try expect_frame(left_half, left);
    try expect_frame(Rect.init(864, 38, 864, 540), middle);
    try expect_frame(Rect.init(864, 578, 864, 539), right);
    // One frame per window, not one layout per window that was found.
    try testing.expectEqual(@as(u64, 3), engine.stats.frames_set);
}

/// More than the one pixel of a parked window shows on the laptop or the display beside it.
fn in_view(id: engine_module.WindowId) bool {
    const frame = frame_of(id);
    const desk = Rect.init(0, 0, 1728 + 2560, 1440);
    return frame.overlap(desk, .x) > 1 and frame.overlap(desk, .y) > 1;
}

test "a restart finds every window on the workspace it was left on" {
    const os = boot("rule app=\"Slack\" : workspace 2\n");
    os.monitors_set(1); // Laptop on the left, external display on the right.
    // Workspace 5 was showing on the external display, 3 on the laptop; 7 was hidden.
    const memory = [_]engine_module.WorkspaceMemory{
        .{ .workspace = 2, .display = 1, .shown = true },
        .{ .workspace = 4, .display = 2, .shown = true },
        .{ .workspace = 6, .display = 2, .shown = false },
        .{ .workspace = 99, .display = 2, .shown = true },
        .{ .workspace = 8, .display = 77, .shown = true },
    };
    os.remember(&memory);
    try testing.expectEqual(@as(u8, 2), engine.monitors[0].workspace);
    try testing.expectEqual(@as(u8, 4), engine.monitors[1].workspace);
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const slack = os.app_launch("Slack", "com.tinyspeck.slackmacgap");
    os.adoption(.begin);
    // The manager that quit brought every window back into view, wherever that was.
    const a = open(os, zed, .{ .adopted = true, .left_on = 2 });
    const b = open(os, zed, .{ .adopted = true, .left_on = 4, .focus = false });
    const c = open(os, zed, .{ .adopted = true, .left_on = 6, .focus = false });
    // The rule sends new Slack windows to workspace 2; this one had been moved since.
    const d = open(os, slack, .{ .adopted = true, .left_on = 6, .focus = false });
    // Nothing is known about this one: it stays on the display where it is found.
    const e = open(os, zed, .{
        .adopted = true,
        .focus = false,
        .frame = Rect.init(2000, 200, 900, 700),
    });
    // A number that is no workspace is as good as nothing.
    const f = open(os, zed, .{
        .adopted = true,
        .left_on = 200,
        .focus = false,
        .frame = Rect.init(100, 100, 900, 700),
    });
    os.adoption(.end);
    os.settle();
    try testing.expectEqual(@as(u8, 2), engine.window_find(a).?.workspace);
    try testing.expectEqual(@as(u8, 4), engine.window_find(b).?.workspace);
    try testing.expectEqual(@as(u8, 6), engine.window_find(c).?.workspace);
    try testing.expectEqual(@as(u8, 6), engine.window_find(d).?.workspace);
    try testing.expectEqual(@as(u8, 4), engine.window_find(e).?.workspace);
    try testing.expectEqual(@as(u8, 2), engine.window_find(f).?.workspace);
    try testing.expect(!in_view(c) and !in_view(d));
    try testing.expect(in_view(a) and in_view(b) and in_view(e) and in_view(f));
    // Hidden workspaces still belong to the display they were on.
    os.command_run("workspace 7");
    os.settle();
    try testing.expectEqual(@as(u8, 6), engine.monitors[1].workspace);
    try testing.expect(in_view(c) and in_view(d) and !in_view(b) and !in_view(e));
}

test "what an earlier window manager remembered is ignored once there are windows" {
    const os = boot("");
    os.monitors_set(1);
    const zed = os.app_launch("Zed", "dev.zed.Zed");
    const a = open(os, zed, .{});
    os.settle();
    const before = engine.revision;
    const memory = [_]engine_module.WorkspaceMemory{
        .{ .workspace = 4, .display = 1, .shown = true },
    };
    os.remember(&memory);
    os.settle();
    try testing.expectEqual(before, engine.revision);
    try testing.expectEqual(@as(u8, 0), engine.window_find(a).?.workspace);
    // A window that is not adopted never takes a workspace from a file.
    const b = open(os, zed, .{ .left_on = 9 });
    os.settle();
    try testing.expectEqual(@as(u8, 0), engine.window_find(b).?.workspace);
}
