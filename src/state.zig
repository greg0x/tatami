//! The state file: what a tatami that quits, or dies, leaves for the one that starts next,
//! so that a restart changes nothing. It holds what the engine says there is to remember:
//! for every workspace its display, whether it was showing and in use, its gaps, whether
//! its tiles were stacked as an accordion, and its label; for every window its workspace,
//! its mode, its place in the layout and the rest of engine.WindowMemory.
//!
//! The file is text, one record per line: a word and then every field of the record in
//! the order the engine declares them, flags as 0 or 1, a rect as four numbers, a label
//! as its word or a dash. Anything may be in it when it is read: it may be from before a
//! reboot, cut short, or written by someone else. Lines that make no sense are skipped
//! here, and the engine checks what is left against the displays and windows that are
//! really there.
const std = @import("std");
const assert = std.debug.assert;
const stdx = @import("stdx.zig");
const geometry = @import("geometry.zig");
const command = @import("command.zig");
const engine_module = @import("engine.zig");

const Engine = engine_module.Engine;
const WorkspaceMemory = engine_module.WorkspaceMemory;
const Rect = geometry.Rect;
const Label = command.Label;

/// Room for the longest file there can be: every window with every number at its widest.
pub const bytes_max: usize = 64 * 1024;
const header = "tatami-state 3";

/// What is kept of a window. Window ids outlive the manager but not the login session,
/// so the process is kept too: an id that now belongs to another process is someone else.
pub const WindowMemory = engine_module.WindowMemory;

pub const State = struct {
    workspaces: [engine_module.workspaces_max]WorkspaceMemory = undefined,
    workspaces_count: u32 = 0,
    windows: [engine_module.windows_max]WindowMemory = undefined,
    windows_count: u32 = 0,

    pub fn workspaces_slice(state: *const State) []const WorkspaceMemory {
        return state.workspaces[0..state.workspaces_count];
    }

    pub fn windows_slice(state: *const State) []const WindowMemory {
        return state.windows[0..state.windows_count];
    }

    /// The workspace on which this window of this process was left, if it is known.
    pub fn window_find(state: *const State, id: u32, pid: i32) ?u8 {
        for (state.windows_slice()) |window| {
            if (window.id == id and window.pid == pid) return window.workspace;
        }
        return null;
    }
};

/// Writes what the engine knows. Nothing is written while every display is asleep: no
/// workspace is showing then, and what was written before still holds.
pub fn print(text: *stdx.Text, engine: *const Engine) void {
    if (engine.monitors_count == 0) return;
    text.append(header ++ "\n");
    var workspaces: [engine_module.workspaces_max]WorkspaceMemory = undefined;
    const workspaces_count = engine.workspaces_remember(&workspaces);
    for (workspaces[0..workspaces_count]) |workspace| record_print(text, "workspace", workspace);
    var windows: [engine_module.windows_max]WindowMemory = undefined;
    const windows_count = engine.windows_remember(&windows);
    for (windows[0..windows_count]) |window| window_print(text, window);
}

pub fn window_print(text: *stdx.Text, window: WindowMemory) void {
    record_print(text, "window", window);
}

fn record_print(text: *stdx.Text, comptime word: []const u8, record: anytype) void {
    text.append(word);
    inline for (@typeInfo(@TypeOf(record)).@"struct".field_names) |name| {
        const field = @field(record, name);
        switch (@TypeOf(field)) {
            bool => text.print(" {d}", .{@intFromBool(field)}),
            Rect => text.print(" {d} {d} {d} {d}", .{ field.x, field.y, field.w, field.h }),
            Label => text.print(" {s}", .{if (field.len > 0) field.slice() else "-"}),
            else => text.print(" {d}", .{field}),
        }
    }
    text.append("\n");
}

pub fn parse(bytes: []const u8, state: *State) void {
    state.workspaces_count = 0;
    state.windows_count = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const first = lines.next() orelse return;
    if (!std.mem.eql(u8, first, header)) return;
    while (lines.next()) |line| {
        // What follows the last line break is nothing, or a line that was cut short.
        if (lines.peek() == null) break;
        line_parse(line, state);
    }
}

fn line_parse(line: []const u8, state: *State) void {
    var fields = std.mem.splitScalar(u8, line, ' ');
    const word = fields.next() orelse return;
    if (std.mem.eql(u8, word, "workspace")) {
        const workspace = record_parse(WorkspaceMemory, &fields) orelse return;
        if (workspace.workspace >= engine_module.workspaces_max) return;
        if (state.workspaces_count == state.workspaces.len) return;
        state.workspaces[state.workspaces_count] = workspace;
        state.workspaces_count += 1;
    } else if (std.mem.eql(u8, word, "window")) {
        const window = record_parse(WindowMemory, &fields) orelse return;
        if (window.id == 0 or window.pid <= 0) return;
        if (window.workspace >= engine_module.workspaces_max) return;
        if (state.windows_count == state.windows.len) return;
        state.windows[state.windows_count] = window;
        state.windows_count += 1;
    }
}

/// Every field of the record, each from the next word of the line, or nothing when a
/// word is missing, is no such number, or is one too many.
fn record_parse(comptime Record: type, fields: anytype) ?Record {
    var record: Record = undefined;
    inline for (@typeInfo(Record).@"struct".field_names) |name| {
        const Field = @FieldType(Record, name);
        @field(record, name) = switch (Field) {
            bool => (number_parse(u1, fields) orelse return null) == 1,
            Rect => .{
                .x = number_parse(i32, fields) orelse return null,
                .y = number_parse(i32, fields) orelse return null,
                .w = number_parse(i32, fields) orelse return null,
                .h = number_parse(i32, fields) orelse return null,
            },
            Label => label_parse(fields) orelse return null,
            else => number_parse(Field, fields) orelse return null,
        };
    }
    if (fields.next() != null) return null;
    return record;
}

fn number_parse(comptime Number: type, fields: anytype) ?Number {
    const field = fields.next() orelse return null;
    return std.fmt.parseInt(Number, field, 10) catch null;
}

/// A dash is no label; anything else must be a word that the label command would take.
fn label_parse(fields: anytype) ?Label {
    const field = fields.next() orelse return null;
    if (std.mem.eql(u8, field, "-")) return .{};
    return Label.parse(field);
}

const testing = std.testing;

const two_windows =
    "window 186 501 4 1 1 0 0 0 0 1 2 7 -40 60 800 600 0 0 0 3 32768 0 logs\n" ++
    "window 187 502 0 0 0 0 0 0 0 0 0 0 0 0 0 0 2 186 190 1 19660 0 -\n";

test "the state file is read back as it was written" {
    var state: State = .{};
    const source = "tatami-state 3\n" ++
        "workspace 0 77 1 1 0 0 0 -\n" ++
        "workspace 4 78 0 0 1 1 1 mail\n" ++
        "workspace 5 0 0 0 0 0 0 -\n" ++
        two_windows;
    parse(source, &state);
    try testing.expectEqual(@as(u32, 3), state.workspaces_count);
    try testing.expectEqual(@as(u32, 78), state.workspaces[1].display);
    try testing.expect(state.workspaces[0].shown and !state.workspaces[1].shown);
    try testing.expect(state.workspaces[0].focused and state.workspaces[1].recent);
    try testing.expect(state.workspaces[1].gaps and state.workspaces[1].accordion);
    try testing.expect(!state.workspaces[0].accordion);
    try testing.expectEqualStrings("mail", state.workspaces[1].label.slice());
    try testing.expectEqual(@as(?u8, 4), state.window_find(186, 501));
    try testing.expectEqual(@as(?u8, 0), state.window_find(187, 502));
    // The same id in another process is another window.
    try testing.expectEqual(@as(?u8, null), state.window_find(186, 999));
    const first = state.windows[0];
    try testing.expect(first.floating and first.by_user and first.focused and !first.sticky);
    try testing.expectEqual(@as(u8, 2), first.zoom);
    try testing.expect(first.float_rect.eql(.{ .x = -40, .y = 60, .w = 800, .h = 600 }));
    try testing.expectEqualStrings("logs", first.label.slice());
    const second = state.windows[1];
    try testing.expectEqual(@as(u16, 2), second.order);
    try testing.expectEqual(@as(u32, 190), second.beside_last);
    try testing.expectEqual(@as(u32, 19660), second.ratio);
    var buffer: [512]u8 = undefined;
    var text = stdx.Text.init(&buffer);
    for (state.windows_slice()) |window| window_print(&text, window);
    try testing.expectEqualStrings(two_windows, text.slice());
}

test "a state file that is cut short, stale or nonsense loses only the lines that are" {
    var state: State = .{};
    // The last line has no line break: it may be half a number.
    parse("tatami-state 3\n" ++ two_windows[0 .. two_windows.len - 1], &state);
    try testing.expectEqual(@as(u32, 1), state.windows_count);
    const source = "tatami-state 3\n" ++
        "workspace 16 77 1 0 0 0 0 -\n" ++
        "workspace 3 77\n" ++
        "workspace 3 77 1 0 0 0 0 - 9\n" ++
        "workspace -1 77 1 0 0 0 0 -\n" ++
        "workspace 3 77 2 0 0 0 0 -\n" ++
        "workspace 3 77 1 0 0 0 0 next\n" ++
        "workspace 3 77 1 0 0 0 0 a-label-that-is-far-too-long-to-be-one\n" ++
        "window 0 501 4 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 3 32768 0 -\n" ++
        "window 186 0 4 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 3 32768 0 -\n" ++
        "window 186 -5 4 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 3 32768 0 -\n" ++
        "window 186 4294967295 4 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 3 32768 0 -\n" ++
        "window 186 501 16 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 3 32768 0 -\n" ++
        "window 99999999999 501 4 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 3 32768 0 -\n" ++
        "window 0x10 501 4 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 3 32768 0 -\n" ++
        "window  186 501 4 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 3 32768 0 -\n" ++
        "window 186 501 4 0 0 0 0 0 0 0 0 0 0 0 0 0 70000 0 0 3 32768 0 -\n" ++
        "window 186 501 4\n" ++
        "bogus 1 2 3\n" ++
        "\n" ++
        "window 9 9 9 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 3 32768 0 -\n";
    parse(source, &state);
    try testing.expectEqual(@as(u32, 0), state.workspaces_count);
    try testing.expectEqual(@as(u32, 1), state.windows_count);
    try testing.expectEqual(@as(?u8, 9), state.window_find(9, 9));
    // Another version of the file, or no file at all, is nothing.
    parse("tatami-state 1\nwindow 9 9 9\n", &state);
    try testing.expectEqual(@as(u32, 0), state.windows_count);
    parse("tatami-state 2\nworkspace 4 78 0 0 1 1 mail\n", &state);
    try testing.expectEqual(@as(u32, 0), state.workspaces_count);
    parse("", &state);
    try testing.expectEqual(@as(u32, 0), state.windows_count);
}

test "the longest state there can be fits in the file" {
    var buffer: [bytes_max]u8 = undefined;
    var text = stdx.Text.init(&buffer);
    text.append(header ++ "\n");
    const longest: [command.label_max]u8 = @splat('a');
    const label = Label.parse(&longest).?;
    const far = std.math.minInt(i32);
    var index: u32 = 0;
    while (index < engine_module.workspaces_max) : (index += 1) {
        record_print(&text, "workspace", WorkspaceMemory{
            .workspace = @intCast(index),
            .display = std.math.maxInt(u32),
            .shown = true,
            .label = label,
        });
    }
    index = 0;
    while (index < engine_module.windows_max) : (index += 1) {
        window_print(&text, .{
            .id = std.math.maxInt(u32) - index,
            .pid = std.math.maxInt(i32),
            .workspace = 15,
            .zoom = 255,
            .focus_order = std.math.maxInt(u32),
            .float_rect = .{ .x = far, .y = far, .w = far, .h = far },
            .order = std.math.maxInt(u16),
            .beside = std.math.maxInt(u32),
            .beside_last = std.math.maxInt(u32),
            .side = 255,
            .ratio = std.math.maxInt(u32),
            .label = label,
        });
    }
    try testing.expect(!text.truncated);
    var state: State = .{};
    parse(text.slice(), &state);
    try testing.expectEqual(engine_module.windows_max, state.windows_count);
    try testing.expectEqual(engine_module.workspaces_max, state.workspaces_count);
}

test "more lines than there can be windows, and random bytes, are read without harm" {
    var state: State = .{};
    var buffer: [bytes_max]u8 = undefined;
    var text = stdx.Text.init(&buffer);
    text.append(header ++ "\n");
    var id: u32 = 1;
    while (id <= engine_module.windows_max + 50) : (id += 1) {
        window_print(&text, .{ .id = id, .pid = 7, .workspace = @intCast(id % 16) });
        const workspace: WorkspaceMemory =
            .{ .workspace = @intCast(id % 16), .display = id, .shown = true };
        record_print(&text, "workspace", workspace);
    }
    assert(!text.truncated);
    parse(text.slice(), &state);
    try testing.expectEqual(engine_module.windows_max, state.windows_count);
    try testing.expectEqual(engine_module.workspaces_max, state.workspaces_count);
    var prng = stdx.Prng.init(42);
    var round: u32 = 0;
    while (round < 2000) : (round += 1) {
        const len = prng.below(400);
        @memcpy(buffer[0..header.len], header);
        buffer[header.len] = '\n';
        const alphabet = "window workspace 0123456789 0 1 0 1 \n\n-x\x00\xff";
        for (buffer[header.len + 1 ..][0..len]) |*byte| {
            byte.* = alphabet[prng.below(alphabet.len)];
        }
        parse(buffer[0 .. header.len + 1 + len], &state);
        for (state.windows_slice()) |window| {
            try testing.expect(window.id != 0 and window.workspace < engine_module.workspaces_max);
        }
        for (state.workspaces_slice()) |workspace| {
            try testing.expect(workspace.workspace < engine_module.workspaces_max);
        }
    }
}
