//! The command language shared by key bindings and the command line client.
const std = @import("std");
const assert = std.debug.assert;
const stdx = @import("stdx.zig");
const geometry = @import("geometry.zig");
const Direction = geometry.Direction;

pub const Target = union(enum) {
    /// One-based index, as typed by the user.
    index: u8,
    next,
    prev,
    recent,
    /// The lowest numbered empty workspace. Only meaningful for workspaces.
    new,
    /// The workspace that carries this label. Only meaningful for workspaces.
    label: Label,
};

pub const label_max = 24;

/// A name the user gives a window or a workspace, to address it in later commands.
pub const Label = struct {
    bytes: [label_max]u8 = @splat(0),
    len: u8 = 0,

    pub fn slice(label: *const Label) []const u8 {
        return label.bytes[0..label.len];
    }

    /// Labels start with a letter, so they are never mistaken for a window id or a
    /// workspace number, and are none of the words that commands give a meaning to, in
    /// capitals or not: a label is matched without regard to case.
    pub fn parse(word: []const u8) ?Label {
        if (word.len == 0 or word.len > label_max) return null;
        if (!is_letter(word[0])) return null;
        for (word) |byte| {
            const digit = byte >= '0' and byte <= '9';
            if (!is_letter(byte) and !digit and byte != '-' and byte != '_' and byte != '.') {
                return null;
            }
        }
        var folded_bytes: [label_max]u8 = undefined;
        for (word, 0..) |byte, index| folded_bytes[index] = std.ascii.toLower(byte);
        const folded = folded_bytes[0..word.len];
        const reserved = [_][]const u8{ "focused", "next", "prev", "recent", "new", "on", "off" };
        for (reserved) |name| {
            if (std.mem.eql(u8, folded, name)) return null;
        }
        if (parse_direction(folded) != null) return null;
        var label: Label = .{};
        @memcpy(label.bytes[0..word.len], word);
        label.len = @intCast(word.len);
        return label;
    }
};

fn is_letter(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z');
}

/// The window a command acts on: the one with focus, or one named by id or label.
pub const WindowRef = union(enum) {
    focused,
    id: u32,
    label: Label,
};

pub const Switch = enum { toggle, on, off };

/// A rectangle as thousandths of the workspace's width and height.
pub const Bounds = struct { x: u16, y: u16, w: u16, h: u16 };

pub const MoveBeside = struct {
    window: WindowRef,
    side: Direction,
    anchor: WindowRef,
    /// The share of the new split that the moved window gets.
    percent: u8,
};

pub const QueryRequest = struct {
    what: Query,
    json: bool = false,
    /// Only for the window query.
    window: WindowRef = .focused,
};

pub const Toggle = enum { split, float, zoom_parent, zoom_fullscreen, sticky, gaps, accordion };
pub const MirrorAxis = enum { x_axis, y_axis };
pub const Dimension = enum { width, height };
pub const Layout = enum { bsp, float };
pub const Query = enum {
    windows,
    workspaces,
    monitors,
    focus,
    stats,
    window,
    tree,
    bindings,
    modes,
    commands,
};

pub const Grid = struct { rows: u8, cols: u8, x: u8, y: u8, w: u8, h: u8 };
pub const Move = struct { target: Target, follow: bool };

/// A span inside the string pool that the command was parsed into.
pub const Span = struct { offset: u16, len: u16 };

pub const Command = union(enum) {
    focus: Direction,
    /// As focus, but from the last window that way it continues at the other end.
    focus_wrap: Direction,
    /// The next or previous window in layout order.
    focus_cycle: struct { forward: bool, wrap: bool },
    focus_window: WindowRef,
    swap: Direction,
    swap_windows: struct { a: WindowRef, b: WindowRef },
    warp: Direction,
    move: MoveBeside,
    insert: Direction,
    insert_ratio: struct { direction: Direction, percent: u8 },
    resize_ratio: u8,
    zoom: struct { window: WindowRef, state: Switch },
    float: struct { window: WindowRef, bounds: ?Bounds },
    tile: WindowRef,
    close_window: WindowRef,
    label: struct { window: WindowRef, label: Label },
    label_workspace: Label,
    resize_edge: struct { edge: Direction, delta: i32 },
    resize_dimension: struct { dimension: Dimension, delta: i32 },
    balance,
    retile,
    rotate: u16,
    mirror: MirrorAxis,
    toggle: Toggle,
    workspace: Target,
    send: Move,
    focus_monitor: Target,
    send_monitor: Move,
    grid: Grid,
    move_floating: struct { dx: i32, dy: i32 },
    layout: Layout,
    close,
    close_others,
    exec: Span,
    query: QueryRequest,
    reload,
    /// Switch the active set of key bindings. The name is resolved by whoever runs it.
    mode: Span,
    quit,
};

pub const ParseError = error{
    Empty,
    UnknownCommand,
    MissingArgument,
    BadArgument,
    TooManyArguments,
    StringPoolFull,
};

pub const words_max = 6;

const Words = struct {
    items: [words_max][]const u8 = undefined,
    count: u32 = 0,
    /// Everything after the first word, trimmed. Used by exec.
    rest: []const u8 = "",
};

fn is_space(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

pub fn trim(text: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = text.len;
    while (start < end and is_space(text[start])) start += 1;
    while (end > start and is_space(text[end - 1])) end -= 1;
    return text[start..end];
}

fn split_words(text: []const u8) ParseError!Words {
    var words: Words = .{};
    var index: usize = 0;
    while (index < text.len) {
        while (index < text.len and is_space(text[index])) index += 1;
        if (index == text.len) break;
        const start = index;
        while (index < text.len and !is_space(text[index])) index += 1;
        if (words.count == words_max) {
            // What exec runs is the rest of the line as it is, however many words.
            if (std.mem.eql(u8, words.items[0], "exec")) break;
            return error.TooManyArguments;
        }
        words.items[words.count] = text[start..index];
        words.count += 1;
        if (words.count == 1) words.rest = trim(text[index..]);
    }
    assert(words.count <= words_max);
    return words;
}

fn parse_direction(word: []const u8) ?Direction {
    const names = [_]struct { []const u8, Direction }{
        .{ "west", .west },   .{ "left", .west },
        .{ "south", .south }, .{ "down", .south },
        .{ "north", .north }, .{ "up", .north },
        .{ "east", .east },   .{ "right", .east },
        .{ "above", .north }, .{ "below", .south },
    };
    for (names) |entry| {
        if (std.mem.eql(u8, word, entry[0])) return entry[1];
    }
    return null;
}

/// Workspaces can also be named by label and by 'new'; monitors cannot.
fn parse_target(word: []const u8, workspace: bool) ParseError!Target {
    if (std.mem.eql(u8, word, "next")) return .next;
    if (std.mem.eql(u8, word, "prev")) return .prev;
    if (std.mem.eql(u8, word, "recent")) return .recent;
    if (std.mem.eql(u8, word, "new")) return if (workspace) .new else error.BadArgument;
    if (stdx.parse_int(word)) |value| {
        if (value < 1 or value > 255) return error.BadArgument;
        return .{ .index = @intCast(value) };
    }
    if (!workspace) return error.BadArgument;
    return .{ .label = Label.parse(word) orelse return error.BadArgument };
}

fn parse_window(word: []const u8) ParseError!WindowRef {
    if (std.mem.eql(u8, word, "focused")) return .focused;
    if (stdx.parse_int(word)) |value| {
        if (value < 1) return error.BadArgument;
        return .{ .id = @intCast(value) };
    }
    return .{ .label = Label.parse(word) orelse return error.BadArgument };
}

fn parse_percent(word: []const u8) ParseError!u8 {
    const value = stdx.parse_int(word) orelse return error.BadArgument;
    if (value < 1 or value > 99) return error.BadArgument;
    return @intCast(value);
}

/// A fraction between 0 and 1, such as 0.25, in thousandths.
fn parse_fraction(word: []const u8) ParseError!u16 {
    if (word.len == 0 or word.len > 8) return error.BadArgument;
    var value: u32 = 0;
    var scale: u32 = 1000;
    var seen_point = false;
    var digits: u32 = 0;
    for (word) |byte| {
        if (byte == '.') {
            if (seen_point) return error.BadArgument;
            seen_point = true;
            continue;
        }
        if (byte < '0' or byte > '9') return error.BadArgument;
        digits += 1;
        const digit: u32 = byte - '0';
        if (!seen_point) {
            value = value * 10 + digit * 1000;
        } else {
            scale /= 10;
            value += digit * scale;
        }
        if (value > 1000) return error.BadArgument;
    }
    // A point on its own is not a number.
    if (digits == 0) return error.BadArgument;
    return @intCast(value);
}

fn parse_bounds(word: []const u8) ParseError!Bounds {
    var values: [4]u16 = undefined;
    var count: u32 = 0;
    var parts = std.mem.splitScalar(u8, word, ',');
    while (parts.next()) |part| {
        if (count == values.len) return error.BadArgument;
        values[count] = try parse_fraction(part);
        count += 1;
    }
    if (count != values.len) return error.BadArgument;
    const bounds: Bounds = .{ .x = values[0], .y = values[1], .w = values[2], .h = values[3] };
    if (bounds.w == 0 or bounds.h == 0) return error.BadArgument;
    if (bounds.x + bounds.w > 1000 or bounds.y + bounds.h > 1000) return error.BadArgument;
    return bounds;
}

fn words_remove(words: *Words, index: u32) void {
    assert(index >= 1 and index < words.count);
    var at = index;
    while (at + 1 < words.count) : (at += 1) words.items[at] = words.items[at + 1];
    words.count -= 1;
}

/// Takes a flag such as --wrap out of the words. True when it was there.
fn flag_take(words: *Words, flag: []const u8) bool {
    var index: u32 = 1;
    while (index < words.count) : (index += 1) {
        if (!std.mem.eql(u8, words.items[index], flag)) continue;
        words_remove(words, index);
        return true;
    }
    return false;
}

/// Takes an option and its value out of the words, written --ratio 30 or --ratio=30.
fn option_take(words: *Words, option: []const u8) ParseError!?[]const u8 {
    var index: u32 = 1;
    while (index < words.count) : (index += 1) {
        const word = words.items[index];
        if (!std.mem.startsWith(u8, word, option)) continue;
        if (word.len == option.len) {
            if (index + 1 == words.count) return error.MissingArgument;
            const value = words.items[index + 1];
            words_remove(words, index + 1);
            words_remove(words, index);
            return value;
        }
        if (word[option.len] != '=') continue;
        words_remove(words, index);
        return word[option.len + 1 ..];
    }
    return null;
}

fn parse_move(words: *const Words, allow_new: bool) ParseError!Move {
    if (words.count < 2) return error.MissingArgument;
    if (words.count > 3) return error.TooManyArguments;
    var move: Move = .{ .target = try parse_target(words.items[1], allow_new), .follow = false };
    if (words.count == 3) {
        if (!std.mem.eql(u8, words.items[2], "--follow")) return error.BadArgument;
        move.follow = true;
    }
    return move;
}

fn parse_grid(word: []const u8) ParseError!Grid {
    var values: [6]u8 = undefined;
    var count: u32 = 0;
    var parts = std.mem.splitScalar(u8, word, ':');
    while (parts.next()) |part| {
        if (count == values.len) return error.BadArgument;
        const value = stdx.parse_int(part) orelse return error.BadArgument;
        if (value < 0 or value > 64) return error.BadArgument;
        values[count] = @intCast(value);
        count += 1;
    }
    if (count != values.len) return error.BadArgument;
    const grid: Grid = .{
        .rows = values[0],
        .cols = values[1],
        .x = values[2],
        .y = values[3],
        .w = values[4],
        .h = values[5],
    };
    if (grid.rows == 0 or grid.cols == 0 or grid.w == 0 or grid.h == 0) return error.BadArgument;
    if (grid.x + grid.w > grid.cols or grid.y + grid.h > grid.rows) return error.BadArgument;
    return grid;
}

fn parse_enum(comptime E: type, word: []const u8) ParseError!E {
    var name: [32]u8 = undefined;
    if (word.len == 0 or word.len > name.len) return error.BadArgument;
    for (word, 0..) |byte, index| {
        name[index] = if (byte == '-') '_' else byte;
    }
    return std.meta.stringToEnum(E, name[0..word.len]) orelse error.BadArgument;
}

fn expect_count(words: *const Words, count: u32) ParseError!void {
    if (words.count < count) return error.MissingArgument;
    if (words.count > count) return error.TooManyArguments;
}

/// Appends text to the pool. The pool is append only; a reload starts a fresh one.
pub const StringPool = struct {
    bytes: [16384]u8 = undefined,
    len: u32 = 0,

    pub fn add(pool: *StringPool, text: []const u8) ParseError!Span {
        if (text.len > pool.bytes.len - pool.len) return error.StringPoolFull;
        const span: Span = .{ .offset = @intCast(pool.len), .len = @intCast(text.len) };
        @memcpy(pool.bytes[pool.len..][0..text.len], text);
        pool.len += @intCast(text.len);
        return span;
    }

    pub fn get(pool: *const StringPool, span: Span) []const u8 {
        assert(@as(u32, span.offset) + span.len <= pool.len);
        return pool.bytes[span.offset..][0..span.len];
    }
};

pub fn parse(text: []const u8, pool: *StringPool) ParseError!Command {
    var words = try split_words(text);
    if (words.count == 0) return error.Empty;
    const name = words.items[0];
    if (std.mem.eql(u8, name, "exec")) {
        if (words.rest.len == 0) return error.MissingArgument;
        return .{ .exec = try pool.add(words.rest) };
    }
    if (std.mem.eql(u8, name, "mode")) {
        try expect_count(&words, 2);
        return .{ .mode = try pool.add(words.items[1]) };
    }
    if (parse_targeted(name, &words)) |result| return try result;
    if (parse_simple(name, &words)) |result| return try result;
    return parse_compound(name, &words);
}

/// Commands that take a direction, a window to act on, or options.
fn parse_targeted(name: []const u8, words: *Words) ?ParseError!Command {
    const Kind = enum {
        focus,
        swap,
        warp,
        insert,
        move,
        zoom,
        float,
        tile,
        close,
        label,
        @"label-workspace",
        query,
    };
    const kind = std.meta.stringToEnum(Kind, name) orelse return null;
    return switch (kind) {
        .focus => parse_focus(words),
        .swap => parse_swap(words),
        .warp => parse_warp(words),
        .insert => parse_insert(words),
        .move => parse_move_beside(words),
        .zoom => parse_zoom(words),
        .float => parse_float(words),
        .tile => parse_tile(words),
        .close => parse_close(words),
        .label => parse_label(words),
        .@"label-workspace" => parse_label_workspace(words),
        .query => parse_query(words),
    };
}

fn parse_focus(words: *Words) ParseError!Command {
    const wrap = flag_take(words, "--wrap");
    try expect_count(words, 2);
    const word = words.items[1];
    if (parse_direction(word)) |direction| {
        return if (wrap) .{ .focus_wrap = direction } else .{ .focus = direction };
    }
    if (std.mem.eql(u8, word, "next")) {
        return .{ .focus_cycle = .{ .forward = true, .wrap = wrap } };
    }
    if (std.mem.eql(u8, word, "prev")) {
        return .{ .focus_cycle = .{ .forward = false, .wrap = wrap } };
    }
    if (wrap) return error.BadArgument;
    return .{ .focus_window = try parse_window(word) };
}

fn parse_swap(words: *Words) ParseError!Command {
    if (words.count < 2) return error.MissingArgument;
    if (words.count == 2) {
        return .{ .swap = parse_direction(words.items[1]) orelse return error.BadArgument };
    }
    try expect_count(words, 3);
    return .{ .swap_windows = .{
        .a = try parse_window(words.items[1]),
        .b = try parse_window(words.items[2]),
    } };
}

fn parse_warp(words: *Words) ParseError!Command {
    try expect_count(words, 2);
    return .{ .warp = parse_direction(words.items[1]) orelse return error.BadArgument };
}

fn parse_insert(words: *Words) ParseError!Command {
    const ratio = try option_take(words, "--ratio");
    try expect_count(words, 2);
    const direction = parse_direction(words.items[1]) orelse return error.BadArgument;
    const share = ratio orelse return .{ .insert = direction };
    return .{ .insert_ratio = .{ .direction = direction, .percent = try parse_percent(share) } };
}

/// move [<window>] <direction> <anchor> [--ratio <percent>]
fn parse_move_beside(words: *Words) ParseError!Command {
    const ratio = try option_take(words, "--ratio");
    if (words.count < 3) return error.MissingArgument;
    if (words.count > 4) return error.TooManyArguments;
    const explicit = words.count == 4;
    const at: u32 = if (explicit) 2 else 1;
    return .{ .move = .{
        .window = if (explicit) try parse_window(words.items[1]) else .focused,
        .side = parse_direction(words.items[at]) orelse return error.BadArgument,
        .anchor = try parse_window(words.items[at + 1]),
        .percent = if (ratio) |share| try parse_percent(share) else 50,
    } };
}

fn parse_zoom(words: *Words) ParseError!Command {
    const on = flag_take(words, "--on");
    const off = flag_take(words, "--off");
    if (on and off) return error.BadArgument;
    if (words.count > 2) return error.TooManyArguments;
    return .{ .zoom = .{
        .window = if (words.count == 2) try parse_window(words.items[1]) else .focused,
        .state = if (on) .on else if (off) .off else .toggle,
    } };
}

fn parse_float(words: *Words) ParseError!Command {
    const bounds = try option_take(words, "--bounds");
    if (words.count > 2) return error.TooManyArguments;
    return .{ .float = .{
        .window = if (words.count == 2) try parse_window(words.items[1]) else .focused,
        .bounds = if (bounds) |word| try parse_bounds(word) else null,
    } };
}

fn parse_tile(words: *Words) ParseError!Command {
    if (words.count > 2) return error.TooManyArguments;
    return .{ .tile = if (words.count == 2) try parse_window(words.items[1]) else .focused };
}

fn parse_close(words: *Words) ParseError!Command {
    if (words.count == 1) return .close;
    try expect_count(words, 2);
    return .{ .close_window = try parse_window(words.items[1]) };
}

/// label [<window>] <name>, or label [<window>] --clear
fn parse_label(words: *Words) ParseError!Command {
    const clear = flag_take(words, "--clear");
    const names: u32 = if (clear) 0 else 1;
    if (words.count < 1 + names) return error.MissingArgument;
    if (words.count > 2 + names) return error.TooManyArguments;
    const explicit = words.count == 2 + names;
    var label: Label = .{};
    if (!clear) label = Label.parse(words.items[words.count - 1]) orelse return error.BadArgument;
    return .{ .label = .{
        .window = if (explicit) try parse_window(words.items[1]) else .focused,
        .label = label,
    } };
}

fn parse_label_workspace(words: *Words) ParseError!Command {
    if (flag_take(words, "--clear")) {
        try expect_count(words, 1);
        return .{ .label_workspace = .{} };
    }
    try expect_count(words, 2);
    return .{ .label_workspace = Label.parse(words.items[1]) orelse return error.BadArgument };
}

/// query <what> [--json], or query window [<window>] [--json]
fn parse_query(words: *Words) ParseError!Command {
    const json = flag_take(words, "--json");
    if (words.count < 2) return error.MissingArgument;
    const what = try parse_enum(Query, words.items[1]);
    var window: WindowRef = .focused;
    if (what == .window and words.count == 3) {
        window = try parse_window(words.items[2]);
    } else {
        try expect_count(words, 2);
    }
    return .{ .query = .{ .what = what, .json = json, .window = window } };
}

fn parse_simple(name: []const u8, words: *const Words) ?ParseError!Command {
    const Kind = enum { balance, retile, @"close-others", reload, quit };
    const kind = std.meta.stringToEnum(Kind, name) orelse return null;
    if (words.count > 1) return error.TooManyArguments;
    return switch (kind) {
        .balance => .balance,
        .retile => .retile,
        .@"close-others" => .close_others,
        .reload => .reload,
        .quit => .quit,
    };
}

fn parse_compound(name: []const u8, words: *const Words) ParseError!Command {
    const Kind = enum {
        resize,
        rotate,
        mirror,
        toggle,
        workspace,
        send,
        @"focus-monitor",
        @"send-monitor",
        grid,
        @"move-floating",
        layout,
    };
    const kind = std.meta.stringToEnum(Kind, name) orelse return error.UnknownCommand;
    switch (kind) {
        .resize => return parse_resize(words),
        .rotate => {
            try expect_count(words, 2);
            const degrees = stdx.parse_int(words.items[1]) orelse return error.BadArgument;
            if (degrees != 90 and degrees != 180 and degrees != 270) return error.BadArgument;
            return .{ .rotate = @intCast(degrees) };
        },
        .mirror => {
            try expect_count(words, 2);
            return .{ .mirror = try parse_enum(MirrorAxis, words.items[1]) };
        },
        .toggle => {
            try expect_count(words, 2);
            return .{ .toggle = try parse_enum(Toggle, words.items[1]) };
        },
        .workspace => {
            try expect_count(words, 2);
            return .{ .workspace = try parse_target(words.items[1], true) };
        },
        .send => return .{ .send = try parse_move(words, true) },
        .@"focus-monitor" => {
            try expect_count(words, 2);
            return .{ .focus_monitor = try parse_target(words.items[1], false) };
        },
        .@"send-monitor" => return .{ .send_monitor = try parse_move(words, false) },
        .grid => {
            try expect_count(words, 2);
            return .{ .grid = try parse_grid(words.items[1]) };
        },
        .@"move-floating" => {
            try expect_count(words, 3);
            const dx = stdx.parse_int(words.items[1]) orelse return error.BadArgument;
            const dy = stdx.parse_int(words.items[2]) orelse return error.BadArgument;
            return .{ .move_floating = .{ .dx = dx, .dy = dy } };
        },
        .layout => {
            try expect_count(words, 2);
            return .{ .layout = try parse_enum(Layout, words.items[1]) };
        },
    }
}

fn parse_resize(words: *const Words) ParseError!Command {
    try expect_count(words, 3);
    if (std.mem.eql(u8, words.items[1], "ratio")) {
        return .{ .resize_ratio = try parse_percent(words.items[2]) };
    }
    const delta = stdx.parse_int(words.items[2]) orelse return error.BadArgument;
    if (delta < -10_000 or delta > 10_000) return error.BadArgument;
    const what = words.items[1];
    if (std.mem.eql(u8, what, "width")) {
        return .{ .resize_dimension = .{ .dimension = .width, .delta = delta } };
    }
    if (std.mem.eql(u8, what, "height")) {
        return .{ .resize_dimension = .{ .dimension = .height, .delta = delta } };
    }
    const edges = [_]struct { []const u8, Direction }{
        .{ "left", .west }, .{ "right", .east }, .{ "top", .north }, .{ "bottom", .south },
    };
    for (edges) |entry| {
        if (std.mem.eql(u8, what, entry[0])) {
            return .{ .resize_edge = .{ .edge = entry[1], .delta = delta } };
        }
    }
    return error.BadArgument;
}

pub const Entry = struct { syntax: []const u8, summary: []const u8 };

/// Every command, for 'tatami help' and 'tatami query commands'.
pub const reference = [_]Entry{
    .{ .syntax = "focus <direction> [--wrap]", .summary = "focus the nearest window that way" },
    .{ .syntax = "focus next|prev [--wrap]", .summary = "focus the next window in layout order" },
    .{ .syntax = "focus <window>", .summary = "focus a window, showing its workspace" },
    .{ .syntax = "swap <direction>", .summary = "trade places with the neighbour that way" },
    .{ .syntax = "swap <window> <window>", .summary = "two windows trade places" },
    .{ .syntax = "warp <direction>", .summary = "re-insert the window beside its neighbour" },
    .{
        .syntax = "move [<window>] <direction> <anchor> [--ratio <percent>]",
        .summary = "put a window in a new split beside another",
    },
    .{
        .syntax = "insert <direction> [--ratio <percent>]",
        .summary = "where the next window goes, and its share",
    },
    .{ .syntax = "resize left|right|top|bottom <pixels>", .summary = "move one edge" },
    .{ .syntax = "resize width|height <pixels>", .summary = "grow or shrink" },
    .{ .syntax = "resize ratio <percent>", .summary = "the window's share of its split" },
    .{ .syntax = "balance", .summary = "even out every split" },
    .{ .syntax = "retile", .summary = "rebuild the layout in window order" },
    .{ .syntax = "rotate 90|180|270", .summary = "rotate the layout" },
    .{ .syntax = "mirror x-axis|y-axis", .summary = "flip the layout" },
    .{
        .syntax = "toggle split|float|zoom-parent|zoom-fullscreen|sticky|gaps|accordion",
        .summary = "switch one of these; accordion stacks the workspace's tiles",
    },
    .{ .syntax = "zoom [<window>] [--on|--off]", .summary = "fill the workspace with a window" },
    .{
        .syntax = "float [<window>] [--bounds x,y,w,h]",
        .summary = "take a window out of the layout; bounds are fractions of the workspace",
    },
    .{ .syntax = "tile [<window>]", .summary = "put a window back in the layout" },
    .{ .syntax = "grid rows:cols:x:y:w:h", .summary = "place a floating window on a grid" },
    .{ .syntax = "move-floating <dx> <dy>", .summary = "nudge a floating window" },
    .{ .syntax = "layout bsp|float", .summary = "tile or float the whole workspace" },
    .{ .syntax = "close [<window>]", .summary = "close a window" },
    .{ .syntax = "close-others", .summary = "close every other window of the workspace" },
    .{ .syntax = "label [<window>] <name>|--clear", .summary = "name a window" },
    .{ .syntax = "label-workspace <name>|--clear", .summary = "name the workspace in use" },
    .{ .syntax = "workspace <workspace>", .summary = "show a workspace" },
    .{ .syntax = "send <workspace> [--follow]", .summary = "send the window to a workspace" },
    .{ .syntax = "focus-monitor <monitor>", .summary = "focus a monitor" },
    .{ .syntax = "send-monitor <monitor> [--follow]", .summary = "send the window to a monitor" },
    .{
        .syntax = "query windows|workspaces|monitors|focus|tree|bindings|modes|commands|stats" ++
            " [--json]",
        .summary = "what the manager knows",
    },
    .{ .syntax = "query window [<window>] [--json]", .summary = "everything about one window" },
    .{ .syntax = "events [--json]", .summary = "follow what changes, one line per event" },
    .{ .syntax = "wait <window> [--for <seconds>]", .summary = "return when a window closes" },
    .{ .syntax = "mode <name>", .summary = "switch the set of key bindings" },
    .{ .syntax = "exec <shell command>", .summary = "run a program; key bindings only" },
    .{ .syntax = "reload", .summary = "read the configuration again" },
    .{ .syntax = "quit", .summary = "bring every window back and stop" },
};

pub const reference_notes =
    \\<direction>  west|east|north|south, or left|right|up|down, or above|below
    \\<window>     a window id from 'query windows', a label, or 'focused'
    \\<workspace>  a number, a label, next, prev, recent or new
    \\<monitor>    a number, next, prev or recent
    \\
;

pub fn reference_print(text: *stdx.Text, json: bool) void {
    if (json) text.append("{\"commands\":[");
    for (reference, 0..) |entry, index| {
        if (json) {
            if (index > 0) text.append(",");
            text.append("{\"syntax\":");
            text.json_string(entry.syntax);
            text.append(",\"summary\":");
            text.json_string(entry.summary);
            text.append("}");
        } else {
            text.print("{s}\t{s}\n", .{ entry.syntax, entry.summary });
        }
    }
    if (json) text.append("]}\n");
}

const testing = std.testing;

test "parse commands" {
    var pool: StringPool = .{};
    try testing.expectEqual(Command{ .focus = .west }, try parse("focus west", &pool));
    try testing.expectEqual(Command{ .focus = .west }, try parse("  focus   left ", &pool));
    try testing.expectEqual(Command{ .warp = .north }, try parse("warp up", &pool));
    try testing.expectEqual(Command.balance, try parse("balance", &pool));
    try testing.expectEqual(Command{ .rotate = 90 }, try parse("rotate 90", &pool));
    try testing.expectEqual(Command{ .mirror = .y_axis }, try parse("mirror y-axis", &pool));
    try testing.expectEqual(
        Command{ .toggle = .zoom_fullscreen },
        try parse("toggle zoom-fullscreen", &pool),
    );
    try testing.expectEqual(Command{ .toggle = .accordion }, try parse("toggle accordion", &pool));
    try testing.expectEqual(
        Command{ .workspace = .{ .index = 10 } },
        try parse("workspace 10", &pool),
    );
    try testing.expectEqual(Command{ .workspace = .new }, try parse("workspace new", &pool));
    try testing.expectEqual(
        Command{ .send = .{ .target = .next, .follow = true } },
        try parse("send next --follow", &pool),
    );
    try testing.expectEqual(
        Command{ .resize_edge = .{ .edge = .west, .delta = -20 } },
        try parse("resize left -20", &pool),
    );
    try testing.expectEqual(
        Command{ .resize_dimension = .{ .dimension = .width, .delta = 50 } },
        try parse("resize width +50", &pool),
    );
    try testing.expectEqual(
        Command{ .grid = .{ .rows = 4, .cols = 4, .x = 1, .y = 1, .w = 2, .h = 2 } },
        try parse("grid 4:4:1:1:2:2", &pool),
    );
    const exec = try parse("exec open -a Ghostty", &pool);
    try testing.expectEqualStrings("open -a Ghostty", pool.get(exec.exec));
    const script = "osascript -e 'tell application \"Finder\" to make new Finder window'";
    const long = try parse("exec " ++ script, &pool);
    try testing.expectEqualStrings(script, pool.get(long.exec));
}

test "parse rejects malformed commands" {
    var pool: StringPool = .{};
    try testing.expectError(error.Empty, parse("   ", &pool));
    try testing.expectError(error.UnknownCommand, parse("fly away", &pool));
    const mode = try parse("mode service", &pool);
    try testing.expectEqualStrings("service", pool.get(mode.mode));
    try testing.expectError(error.MissingArgument, parse("mode", &pool));
    try testing.expectError(error.MissingArgument, parse("focus", &pool));
    try testing.expectError(error.BadArgument, parse("focus 1.5", &pool));
    try testing.expectError(error.BadArgument, parse("focus logs --wrap", &pool));
    try testing.expectError(error.BadArgument, parse("swap 1 0", &pool));
    try testing.expectError(error.MissingArgument, parse("move left", &pool));
    try testing.expectError(error.BadArgument, parse("move left 3 --ratio 100", &pool));
    try testing.expectError(error.BadArgument, parse("zoom --on --off", &pool));
    try testing.expectError(error.BadArgument, parse("float --bounds 0.5,0.5,0.6,0.5", &pool));
    try testing.expectError(error.BadArgument, parse("float --bounds 0.5,0.5,0,0.5", &pool));
    try testing.expectError(error.BadArgument, parse("float --bounds .,.,1,1", &pool));
    try testing.expectError(error.BadArgument, parse("label left", &pool));
    try testing.expectError(error.BadArgument, parse("label 7up", &pool));
    try testing.expectError(error.MissingArgument, parse("label", &pool));
    try testing.expectError(error.BadArgument, parse("focus-monitor side", &pool));
    try testing.expectError(error.TooManyArguments, parse("query windows 3", &pool));
    try testing.expectError(error.TooManyArguments, parse("balance now", &pool));
    try testing.expectError(error.BadArgument, parse("rotate 45", &pool));
    try testing.expectError(error.BadArgument, parse("workspace 0", &pool));
    try testing.expectError(error.BadArgument, parse("focus-monitor new", &pool));
    try testing.expectError(error.BadArgument, parse("grid 1:2:2:0:1:1", &pool));
    try testing.expectError(error.BadArgument, parse("send 3 --now", &pool));
    try testing.expectError(error.MissingArgument, parse("exec", &pool));
}

test "parse commands that name their windows" {
    var pool: StringPool = .{};
    const logs = Label.parse("logs").?;
    try testing.expectEqualStrings("logs", logs.slice());
    try testing.expectEqual(Command{ .focus_wrap = .west }, try parse("focus left --wrap", &pool));
    try testing.expectEqual(
        Command{ .focus_cycle = .{ .forward = true, .wrap = true } },
        try parse("focus next --wrap", &pool),
    );
    try testing.expectEqual(Command{ .focus_window = .{ .id = 42 } }, try parse("focus 42", &pool));
    try testing.expectEqual(
        Command{ .focus_window = .{ .label = logs } },
        try parse("focus logs", &pool),
    );
    try testing.expectEqual(
        Command{ .swap_windows = .{ .a = .{ .id = 3 }, .b = .{ .label = logs } } },
        try parse("swap 3 logs", &pool),
    );
    try testing.expectEqual(
        Command{ .move = .{
            .window = .focused,
            .side = .south,
            .anchor = .{ .id = 7 },
            .percent = 50,
        } },
        try parse("move below 7", &pool),
    );
    try testing.expectEqual(
        Command{ .move = .{
            .window = .{ .label = logs },
            .side = .east,
            .anchor = .{ .id = 7 },
            .percent = 30,
        } },
        try parse("move logs right 7 --ratio 30", &pool),
    );
    try testing.expectEqual(
        Command{ .insert_ratio = .{ .direction = .south, .percent = 25 } },
        try parse("insert south --ratio=25", &pool),
    );
    try testing.expectEqual(Command{ .resize_ratio = 70 }, try parse("resize ratio 70", &pool));
    try testing.expectEqual(
        Command{ .zoom = .{ .window = .{ .id = 9 }, .state = .on } },
        try parse("zoom 9 --on", &pool),
    );
    try testing.expectEqual(
        Command{ .zoom = .{ .window = .focused, .state = .toggle } },
        try parse("zoom", &pool),
    );
    try testing.expectEqual(
        Command{ .float = .{
            .window = .focused,
            .bounds = .{ .x = 250, .y = 0, .w = 500, .h = 1000 },
        } },
        try parse("float --bounds 0.25,0,.5,1", &pool),
    );
    try testing.expectEqual(Command{ .tile = .{ .id = 4 } }, try parse("tile 4", &pool));
    try testing.expectEqual(Command.close, try parse("close", &pool));
    try testing.expectEqual(Command{ .close_window = .{ .id = 4 } }, try parse("close 4", &pool));
    try testing.expectEqual(
        Command{ .label = .{ .window = .focused, .label = logs } },
        try parse("label logs", &pool),
    );
    try testing.expectEqual(
        Command{ .label = .{ .window = .{ .id = 4 }, .label = .{} } },
        try parse("label 4 --clear", &pool),
    );
    try testing.expectEqual(
        Command{ .label_workspace = logs },
        try parse("label-workspace logs", &pool),
    );
    try testing.expectEqual(
        Command{ .workspace = .{ .label = logs } },
        try parse("workspace logs", &pool),
    );
    try testing.expectEqual(
        Command{ .query = .{ .what = .tree, .json = true } },
        try parse("query tree --json", &pool),
    );
    try testing.expectEqual(
        Command{ .query = .{ .what = .window, .window = .{ .id = 12 } } },
        try parse("query window 12", &pool),
    );
}

test "a label is none of the words with a meaning, in capitals or not" {
    // Or 'focus West' would name a window and 'focus west' a direction.
    try testing.expect(Label.parse("West") == null);
    try testing.expect(Label.parse("FOCUSED") == null);
    try testing.expect(Label.parse("Next") == null);
    try testing.expect(Label.parse("oN") == null);
    try testing.expect(Label.parse("Western") != null);
    var pool: StringPool = .{};
    try testing.expectError(error.BadArgument, parse("label Below", &pool));
    try testing.expectError(error.BadArgument, parse("workspace Recent", &pool));
}
