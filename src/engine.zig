//! The window manager as a pure state machine.
//!
//! step() takes one event and the current time and returns the effects to perform. It never
//! blocks, allocates, reads a clock or talks to the operating system, so the same code runs
//! under the macOS shell and under the deterministic simulator.
//!
//! Rules that keep it honest:
//!   - A frame is sent to a window only when its target changes, plus at most attempts_max
//!     retries. A window that keeps fighting is floated instead of being fought forever.
//!   - Focus is updated optimistically, so key repeats never wait for the OS to echo.
//!   - Slow applications are suspended with a backoff; nothing waits for them.
const std = @import("std");
const assert = std.debug.assert;
const stdx = @import("stdx.zig");
const geometry = @import("geometry.zig");
const tree = @import("tree.zig");
const command = @import("command.zig");
const config_module = @import("config.zig");

const Rect = geometry.Rect;
const Direction = geometry.Direction;
const Command = command.Command;
const WindowRef = command.WindowRef;
const Config = config_module.Config;
const NodeIndex = tree.NodeIndex;
const node_none = tree.node_none;

pub const WindowId = tree.WindowId;

pub const windows_max: u32 = 256;
pub const apps_max: u32 = 128;
pub const workspaces_max: u32 = 16;
pub const monitors_max: u32 = 8;
pub const effects_max: u32 = 1024;
pub const focus_pending_max: u32 = 8;
pub const title_max: u32 = 96;
pub const name_max: u32 = 64;
/// Holds the longest answer there is: every window as JSON, 700 bytes each when the
/// title and the names are nothing but quotes. The shell's own buffer must hold it too.
pub const reply_max: u32 = 256 * 1024;

/// Retries after a frame did not take. Applications with a minimum size never comply.
pub const attempts_max: u8 = 2;
/// How long an application may animate before a wrong frame is corrected.
pub const settle_ms: u64 = 150;
/// More than drift_max corrections within drift_window_ms floats the window.
pub const drift_max: u8 = 4;
pub const drift_window_ms: u64 = 3000;
/// Title rules keep applying this long after a window appears (late titles).
pub const rule_grace_ms: u64 = 3000;
/// A window sent away by a rule may not pull focus back for this long.
pub const quiet_ms: u64 = 1500;
/// After the focused window goes away, focus may not jump to a hidden workspace.
pub const guard_ms: u64 = 400;
pub const focus_pending_ms: u64 = 500;
/// How long a floating window that left native fullscreen is given to be back at the
/// frame it had before: the animation takes about a second.
pub const fullscreen_exit_ms: u64 = 1500;
/// The most a parked window may be lifted; beyond this something else is going on.
pub const park_lift_max: i32 = 256;
pub const backoff_min_ms: u32 = 250;
pub const backoff_max_ms: u32 = 8000;
/// The furthest one command moves a floating window: more than any desk of displays is
/// wide, and little enough that the sums stay far from the end of the numbers.
pub const nudge_max: i32 = 1 << 20;

const workspace_none: u8 = std.math.maxInt(u8);

comptime {
    assert(tree.nodes_max >= 2 * windows_max);
    assert(workspaces_max >= monitors_max);
    assert(effects_max >= 2 * windows_max + 16);
    assert(config_module.rules_max <= 64);
}

pub const WindowKind = enum { standard, dialog, popup };

pub const MonitorInfo = struct {
    display: u32,
    /// The whole display.
    frame: Rect,
    /// The display without the menu bar and the Dock.
    visible: Rect,
    main: bool,
};

pub const AppInfo = struct { pid: i32, name: []const u8, bundle: []const u8 };

pub const WindowInfo = struct {
    id: WindowId,
    pid: i32,
    title: []const u8,
    frame: Rect,
    kind: WindowKind,
    resizable: bool,
    minimized: bool = false,
    fullscreen: bool = false,
    /// Another window of the same application that this one is a native tab of.
    tab_of: WindowId = 0,
    /// The window was already open when the window manager started.
    adopted: bool = false,
    /// The workspace on which the window manager that ran before this one left the
    /// window, when that is known. Only looked at for adopted windows.
    workspace: ?u8 = null,
};

/// What the window manager that ran before this one knew about a workspace. None of it
/// is trusted: the file it comes from may be old, cut short or about other displays.
pub const WorkspaceMemory = struct {
    workspace: u8,
    /// The display it belonged to, there or not.
    display: u32,
    /// A display was showing it.
    shown: bool,
    /// It was the workspace in use.
    focused: bool = false,
    /// It was the workspace in use before that one.
    recent: bool = false,
    /// Its gaps were toggled.
    gaps: bool = false,
    /// Its tiles were stacked as an accordion.
    accordion: bool = false,
    label: command.Label = .{},
};

/// What the window manager that ran before this one knew about a window. Every field
/// but the label is a number or a flag, and none is trusted.
pub const WindowMemory = struct {
    id: WindowId,
    /// The process that owned the window. An id that now belongs to another process is
    /// another window, and nothing here is about it.
    pid: i32,
    workspace: u8,
    floating: bool = false,
    /// The user chose the mode by hand.
    by_user: bool = false,
    auto_floated: bool = false,
    sticky: bool = false,
    ignored: bool = false,
    /// It was a native tab of another window: only its workspace is taken.
    tab: bool = false,
    /// It had the focus.
    focused: bool = false,
    /// 0 none, 1 parent, 2 fullscreen.
    zoom: u8 = 0,
    /// Larger had the focus more recently; 0 never had it.
    focus_order: u32 = 0,
    /// Where the window lives while it floats. An empty rect is not known.
    float_rect: Rect = Rect.zero,
    /// Its place among the tiles of its workspace in layout order, counting from 1; 0 when
    /// it was not in the layout.
    order: u16 = 0,
    /// For a tile, how it joins the tiles before it: the first and the last window of
    /// the part of the layout that it splits, the new tile below (side 1) or to the
    /// right (side 3), at this ratio. For a window that left the layout for a while,
    /// the place it returns to, as the engine keeps it: the two ends of what it sat
    /// beside, on side 0 west, 1 south, 2 north or 3 east.
    beside: WindowId = 0,
    beside_last: WindowId = 0,
    side: u8 = 3,
    ratio: u32 = tree.ratio_half,
    /// For a window that left the layout for a while: larger left more recently. The
    /// ones that left after it come back first, to make the layout the one it left.
    left_order: u32 = 0,
    label: command.Label = .{},
};

pub const Event = union(enum) {
    monitors_changed: []const MonitorInfo,
    app_launched: AppInfo,
    app_terminated: i32,
    /// An Accessibility call to the application timed out.
    app_unresponsive: i32,
    window_appeared: WindowInfo,
    window_destroyed: WindowId,
    /// The frame read back right after a set_frame effect was performed.
    window_frame_applied: struct { id: WindowId, frame: Rect },
    /// The window moved or resized without us asking.
    window_frame_changed: struct { id: WindowId, frame: Rect, by_user: bool },
    window_title_changed: struct { id: WindowId, title: []const u8 },
    window_minimized: struct { id: WindowId, minimized: bool },
    window_fullscreen: struct { id: WindowId, fullscreen: bool },
    window_tab_changed: struct { id: WindowId, tab_of: WindowId },
    /// The OS notified us that keyboard focus moved to this window.
    window_focused: WindowId,
    /// The answer to a query_focus effect: where keyboard focus is right now.
    focus_reported: WindowId,
    command: Command,
    /// The shell reports every window that is already open, as at startup, between begin
    /// and end. Nothing is arranged in between: one layout at the end, not one per window.
    adoption: Adoption,
    /// What a window manager that just quit left behind, so that a restart changes
    /// nothing. Sent before the windows are reported; ignored once there are windows.
    workspaces_remembered: []const WorkspaceMemory,
    /// What it knew about its windows, sent just before workspaces_remembered. A window
    /// that is then reported as already open, with the same id and process, is as it
    /// was left.
    windows_remembered: []const WindowMemory,
    tick,
};

pub const Adoption = enum { begin, end };

pub const Effect = union(enum) {
    set_frame: struct { id: WindowId, pid: i32, frame: Rect },
    focus_window: struct { id: WindowId, pid: i32 },
    close_window: struct { id: WindowId, pid: i32 },
    /// Centre the pointer on this monitor unless it is already there.
    warp_mouse: Rect,
    exec: command.Span,
    /// Report the focused window again; the engine lost track of it.
    query_focus,
    reload,
    quit,
};

pub const Mode = enum { tiled, floating };
pub const Zoom = enum { none, parent, fullscreen };

/// What a step changed, for whoever follows 'tatami events'.
pub const Note = union(enum) {
    window_created: WindowId,
    window_closed: WindowId,
    /// The window that has focus now, or 0 when none has.
    focus_changed: WindowId,
    /// The workspace in use now, counting from one.
    workspace_changed: u8,
    /// Anything about the layout changed: the new revision.
    view_changed: u64,
    /// More happened in one step than fits: query again.
    overflow,
};

pub const notes_max: u32 = 16;

pub const Window = struct {
    id: WindowId = 0,
    pid: i32 = 0,
    app: u8 = 0,
    workspace: u8 = 0,
    mode: Mode = .tiled,
    zoom: Zoom = .none,
    kind: WindowKind = .standard,
    resizable: bool = true,
    minimized: bool = false,
    fullscreen: bool = false,
    sticky: bool = false,
    ignored: bool = false,
    mode_by_user: bool = false,
    auto_floated: bool = false,
    tab_of: WindowId = 0,
    title: [title_max]u8 = undefined,
    title_len: u8 = 0,
    /// What we believe the frame is, from the last report.
    actual: Rect = Rect.zero,
    /// What we last asked for. Meaningful only when desired_valid.
    desired: Rect = Rect.zero,
    desired_valid: bool = false,
    /// Where the window lives while floating on a visible workspace.
    float_rect: Rect = Rect.zero,
    /// Until when the window is left alone because it is on its way back from native
    /// fullscreen, 0 when it is not.
    float_return_until_ms: u64 = 0,
    attempts: u8 = 0,
    set_pending: bool = false,
    frozen: bool = false,
    recheck_at_ms: u64 = 0,
    drift_count: u8 = 0,
    drift_since_ms: u64 = 0,
    rules_applied: u64 = 0,
    appeared_ms: u64 = 0,
    quiet_until_ms: u64 = 0,
    /// A rule chose the workspace of the window.
    rule_placed: bool = false,
    focus_seq: u64 = 0,
    sets_total: u32 = 0,
    /// How far above the parking spot macOS insists on keeping this window (see lifted).
    park_lift: i32 = 0,
    /// A name given with the label command, to address the window in later commands.
    label: command.Label = .{},
    /// The place in the layout that a minimized or native fullscreen window left, so that
    /// it returns there: the first and the last window of the subtree it sat beside (0
    /// when none), the side it was on and the ratio.
    slot_beside: WindowId = 0,
    /// When the window left, among the windows that did: 0 when it remembers no place.
    slot_seq: u64 = 0,
    slot_beside_last: WindowId = 0,
    slot_side: Direction = .west,
    slot_ratio: u32 = tree.ratio_half,

    pub fn title_slice(window: *const Window) []const u8 {
        return window.title[0..window.title_len];
    }

    fn title_set(window: *Window, title: []const u8) void {
        window.title_len = text_keep(&window.title, title);
    }

    /// Windows in the layout are exactly the windows that own a leaf in their workspace tree.
    pub fn in_layout(window: *const Window) bool {
        assert(window.id != 0);
        return window.mode == .tiled and window.managed();
    }

    /// Windows whose frame we control.
    pub fn managed(window: *const Window) bool {
        return !window.ignored and !window.minimized and !window.fullscreen and window.tab_of == 0;
    }

    /// True for a tile of the workspace that is out of its layout for a while and
    /// remembers the place it left.
    fn slot_waits(window: *const Window, workspace: u8) bool {
        if (window.workspace != workspace or window.mode != .tiled) return false;
        if (window.ignored or window.tab_of != 0 or window.slot_seq == 0) return false;
        return window.minimized or window.fullscreen;
    }

    pub fn focusable(window: *const Window) bool {
        return !window.ignored and !window.minimized and window.tab_of == 0;
    }
};

/// Keeps as much of a title or a name as fits, with its control characters turned into
/// spaces: a line break in one would break the one line per window that queries answer
/// with. Returns the length kept.
fn text_keep(target: []u8, text: []const u8) u8 {
    const len = stdx.copy_truncate(target, text);
    for (target[0..len]) |*byte| {
        if (byte.* < 0x20 or byte.* == 0x7f) byte.* = ' ';
    }
    return @intCast(len);
}

pub const App = struct {
    pid: i32 = 0,
    name: [name_max]u8 = undefined,
    name_len: u8 = 0,
    bundle: [name_max]u8 = undefined,
    bundle_len: u8 = 0,
    suspended_until_ms: u64 = 0,
    backoff_ms: u32 = 0,

    pub fn name_slice(app: *const App) []const u8 {
        return app.name[0..app.name_len];
    }

    pub fn bundle_slice(app: *const App) []const u8 {
        return app.bundle[0..app.bundle_len];
    }
};

pub const Workspace = struct {
    root: NodeIndex = node_none,
    /// The display this workspace lives on. Kept when the display unplugs, so the workspace
    /// returns to it when it comes back.
    display: u32 = 0,
    last_focus: WindowId = 0,
    insert: ?Direction = null,
    /// The share of the split that the next window gets, with insert. 0 is an even split.
    insert_percent: u8 = 0,
    gaps_toggled: bool = false,
    /// Every tile fills the workspace, stacked; focus and swap walk the stack in layout
    /// order. The tree stays as it is underneath, so turning it off brings the tiles back.
    accordion: bool = false,
    label: command.Label = .{},
    /// The display change before which this workspace was last seen showing on a monitor,
    /// 0 for never. A display that comes back shows what it showed when it went away.
    shown_seq: u64 = 0,
};

pub const Monitor = struct {
    display: u32,
    frame: Rect,
    visible: Rect,
    main: bool,
    workspace: u8,
};

const FocusPending = struct { id: WindowId, deadline_ms: u64 };

const Slot = struct {
    beside: WindowId = 0,
    beside_last: WindowId = 0,
    side: Direction = .west,
    ratio: u32 = tree.ratio_half,
};

pub const Stats = struct {
    events: u64 = 0,
    effects: u64 = 0,
    frames_set: u64 = 0,
    frames_retried: u64 = 0,
    frames_lifted: u64 = 0,
    frames_corrected: u64 = 0,
    windows_auto_floated: u64 = 0,
    windows_dropped: u64 = 0,
    focus_rejected: u64 = 0,
    apps_suspended: u64 = 0,
};

pub const Engine = struct {
    config: Config,
    forest: tree.Forest,
    windows: [windows_max]Window,
    apps: [apps_max]App,
    workspaces: [workspaces_max]Workspace,
    monitors: [monitors_max]Monitor,
    monitors_count: u32,
    /// How many monitors there were when every display went to sleep, else 0. Their
    /// entries are kept to compare with the displays that wake up.
    monitors_asleep: u32,
    /// Counts the display changes, to tell which workspace a display showed last.
    shown_seq: u64,
    /// Counts the windows that leave the layout for a while, to tell in which order.
    slot_seq: u64,
    focused_window: WindowId,
    focused_monitor: u8,
    recent_monitor: u8,
    recent_workspace: u8,
    focus_seq: u64,
    focus_pending: [focus_pending_max]FocusPending,
    focus_pending_count: u32,
    /// The window the OS last said has keyboard focus, whatever we made of it.
    os_focus: WindowId,
    guard_until_ms: u64,
    /// Set when we can no longer be sure where OS focus is; answered by focus_reported.
    focus_stale: bool,
    /// Set by quit. A stopped engine ignores every event.
    stopped: bool,
    /// Between adoption begin and end. Frames are not sent meanwhile.
    adopting: bool,
    /// What the last window manager knew of windows that were not reported yet, or whose
    /// adoption is still going on. No id is in it twice.
    memories: [windows_max]WindowMemory,
    memories_count: u32,
    /// From the moment it is taken over until the adoption ends. Meanwhile a workspace
    /// that windows were left on is not empty, though none of them was reported yet.
    memories_fresh: bool,
    now_ms: u64,
    effects: [effects_max]Effect,
    effects_count: u32,
    reply_buffer: [reply_max]u8,
    reply_len: u32,
    /// Counts the changes to the layout, so that a snapshot can be told from a newer one.
    revision: u64,
    view_hash: u64,
    notes: [notes_max]Note,
    notes_count: u32,
    stats: Stats,

    pub fn init(engine: *Engine, config: *const Config) void {
        engine.config = config.*;
        engine.forest.init();
        for (&engine.windows) |*window| window.* = .{};
        for (&engine.apps) |*app| app.* = .{};
        for (&engine.workspaces) |*workspace| workspace.* = .{};
        engine.monitors_count = 0;
        engine.monitors_asleep = 0;
        engine.shown_seq = 0;
        engine.slot_seq = 0;
        engine.focused_window = 0;
        engine.focused_monitor = 0;
        engine.recent_monitor = 0;
        engine.recent_workspace = 0;
        engine.focus_seq = 0;
        engine.focus_pending_count = 0;
        engine.os_focus = 0;
        engine.guard_until_ms = 0;
        engine.focus_stale = false;
        engine.stopped = false;
        engine.adopting = false;
        engine.memories_count = 0;
        engine.memories_fresh = false;
        engine.now_ms = 0;
        engine.effects_count = 0;
        engine.reply_len = 0;
        engine.revision = 0;
        engine.view_hash = 0;
        engine.notes_count = 0;
        engine.stats = .{};
    }

    /// Swaps in a new configuration. Existing windows keep their mode; rules only apply to
    /// windows that appear from now on.
    pub fn config_replace(engine: *Engine, config: *const Config) void {
        engine.config = config.*;
        for (&engine.windows) |*window| {
            if (window.id != 0) window.rules_applied = std.math.maxInt(u64);
        }
    }

    pub fn reply(engine: *const Engine) []const u8 {
        return engine.reply_buffer[0..engine.reply_len];
    }

    /// Handles one event. The returned effects are valid until the next call.
    pub fn step(engine: *Engine, event: Event, now_ms: u64) []const Effect {
        assert(now_ms >= engine.now_ms);
        engine.now_ms = now_ms;
        engine.effects_count = 0;
        engine.reply_len = 0;
        engine.notes_count = 0;
        if (engine.stopped) return engine.effects[0..0];
        const focus_before = engine.focused_window;
        const workspace_before = engine.workspace_current();
        engine.stats.events += 1;
        switch (event) {
            .monitors_changed => |list| engine.on_monitors_changed(list),
            .app_launched => |info| engine.on_app_launched(info),
            .app_terminated => |pid| engine.on_app_terminated(pid),
            .app_unresponsive => |pid| engine.on_app_unresponsive(pid),
            .window_appeared => |info| engine.on_window_appeared(info),
            .window_destroyed => |id| engine.on_window_destroyed(id),
            .window_frame_applied => |e| engine.on_frame_applied(e.id, e.frame),
            .window_frame_changed => |e| engine.on_frame_changed(e.id, e.frame, e.by_user),
            .window_title_changed => |e| engine.on_title_changed(e.id, e.title),
            .window_minimized => |e| engine.on_minimized(e.id, e.minimized),
            .window_fullscreen => |e| engine.on_fullscreen(e.id, e.fullscreen),
            .window_tab_changed => |e| engine.on_tab_changed(e.id, e.tab_of),
            .window_focused => |id| engine.focus_observe(id, false),
            .focus_reported => |id| engine.focus_observe(id, true),
            .command => |cmd| engine.on_command(cmd),
            .workspaces_remembered => |list| engine.on_workspaces_remembered(list),
            .windows_remembered => |list| engine.on_windows_remembered(list),
            .adoption => |phase| engine.on_adoption(phase),
            .tick => engine.on_tick(),
        }
        engine.arrange();
        if (engine.focus_stale) {
            engine.focus_stale = false;
            engine.emit(.query_focus);
        }
        engine.notes_derive(focus_before, workspace_before);
        engine.stats.effects += engine.effects_count;
        return engine.effects[0..engine.effects_count];
    }

    /// What the last step changed. Valid until the next call to step.
    pub fn notes_slice(engine: *const Engine) []const Note {
        return engine.notes[0..engine.notes_count];
    }

    fn note(engine: *Engine, entry: Note) void {
        if (engine.notes_count == notes_max) return;
        // The last slot is kept to say that more happened than fits.
        const last = engine.notes_count == notes_max - 1;
        engine.notes[engine.notes_count] = if (last) .overflow else entry;
        engine.notes_count += 1;
    }

    fn notes_derive(engine: *Engine, focus_before: WindowId, workspace_before: u8) void {
        const workspace = engine.workspace_current();
        if (workspace != workspace_before) engine.note(.{ .workspace_changed = workspace + 1 });
        if (engine.focused_window != focus_before) {
            engine.note(.{ .focus_changed = engine.focused_window });
        }
        const hash = engine.view_hash_compute();
        if (hash == engine.view_hash) return;
        engine.view_hash = hash;
        engine.revision += 1;
        engine.note(.{ .view_changed = engine.revision });
    }

    fn hash_mix(hash: u64, word: u32) u64 {
        return (hash ^ word) *% 0x100000001b3;
    }

    /// A hash of everything a query can show about the layout: which windows there are,
    /// where they belong and where they are meant to be, the labels and the focus.
    fn view_hash_compute(engine: *const Engine) u64 {
        var hash: u64 = 0xcbf29ce484222325;
        for (&engine.windows) |*window| {
            if (window.id == 0) continue;
            const frame = if (window.desired_valid) window.desired else Rect.zero;
            const flags = @as(u32, @backingInt(window.mode)) |
                @as(u32, @backingInt(window.zoom)) << 1 |
                @as(u32, @intFromBool(window.sticky)) << 3 |
                @as(u32, @intFromBool(window.minimized)) << 4 |
                @as(u32, @intFromBool(window.fullscreen)) << 5 |
                @as(u32, @intFromBool(window.ignored)) << 6;
            const words = [_]u32{
                window.id,         window.workspace,  flags,             window.tab_of,
                @bitCast(frame.x), @bitCast(frame.y), @bitCast(frame.w), @bitCast(frame.h),
            };
            for (words) |word| hash = hash_mix(hash, word);
            for (window.label.slice()) |byte| hash = hash_mix(hash, byte);
        }
        for (engine.monitors[0..engine.monitors_count]) |*monitor| {
            hash = hash_mix(hash, monitor.workspace);
        }
        for (&engine.workspaces) |*workspace| {
            for (workspace.label.slice()) |byte| hash = hash_mix(hash, byte);
            hash = hash_mix(hash, 0xff);
            hash = hash_mix(hash, @intFromBool(workspace.accordion));
        }
        return hash_mix(hash, engine.focused_window);
    }

    /// The earliest time at which a tick has work to do, if any.
    pub fn next_deadline_ms(engine: *const Engine) ?u64 {
        var deadline: ?u64 = null;
        for (engine.focus_pending[0..engine.focus_pending_count]) |pending| {
            deadline = min_deadline(deadline, pending.deadline_ms);
        }
        for (&engine.windows) |*window| {
            if (window.id == 0) continue;
            if (window.recheck_at_ms != 0) deadline = min_deadline(deadline, window.recheck_at_ms);
            if (window.float_return_until_ms != 0) {
                deadline = min_deadline(deadline, window.float_return_until_ms);
            }
            // Frames held back during adoption wait for its end, not for a time.
            if (window.set_pending and !engine.adopting) {
                deadline = min_deadline(deadline, engine.apps[window.app].suspended_until_ms);
            }
        }
        return deadline;
    }

    fn min_deadline(current: ?u64, candidate: u64) ?u64 {
        if (current) |value| return @min(value, candidate);
        return candidate;
    }

    fn emit(engine: *Engine, effect: Effect) void {
        assert(engine.effects_count < effects_max);
        engine.effects[engine.effects_count] = effect;
        engine.effects_count += 1;
    }

    // Lookups.

    pub fn window_find(engine: *Engine, id: WindowId) ?*Window {
        if (id == 0) return null;
        for (&engine.windows) |*window| {
            if (window.id == id) return window;
        }
        return null;
    }

    fn app_find(engine: *Engine, pid: i32) ?u8 {
        assert(pid != 0);
        for (&engine.apps, 0..) |*app, index| {
            if (app.pid == pid) return @intCast(index);
        }
        return null;
    }

    fn main_monitor(engine: *const Engine) u8 {
        assert(engine.monitors_count > 0);
        for (engine.monitors[0..engine.monitors_count], 0..) |*monitor, index| {
            if (monitor.main) return @intCast(index);
        }
        return 0;
    }

    /// The monitor a workspace lives on: its display when connected, else the main one.
    pub fn workspace_monitor(engine: *const Engine, workspace: u8) u8 {
        assert(workspace < workspaces_max);
        assert(engine.monitors_count > 0);
        const display = engine.workspaces[workspace].display;
        for (engine.monitors[0..engine.monitors_count], 0..) |*monitor, index| {
            if (monitor.display == display) return @intCast(index);
        }
        return engine.main_monitor();
    }

    pub fn workspace_visible(engine: *const Engine, workspace: u8) bool {
        if (engine.monitors_count == 0) return false;
        return engine.monitors[engine.workspace_monitor(workspace)].workspace == workspace;
    }

    fn workspace_empty(engine: *const Engine, workspace: u8) bool {
        for (&engine.windows) |*window| {
            if (window.id != 0 and window.workspace == workspace and !window.sticky) return false;
        }
        if (!engine.memories_fresh) return true;
        for (engine.memories[0..engine.memories_count]) |*memory| {
            if (memory.workspace == workspace and !memory.sticky) return false;
        }
        return true;
    }

    fn gap_inner(engine: *const Engine, workspace: u8) i32 {
        const toggled = engine.workspaces[workspace].gaps_toggled;
        return if (toggled) engine.config.gap_toggle else engine.config.gap_inner;
    }

    /// The area of the monitor that its visible workspace tiles into.
    pub fn workspace_rect(engine: *const Engine, monitor: u8) Rect {
        assert(monitor < engine.monitors_count);
        const workspace = engine.monitors[monitor].workspace;
        const toggled = engine.workspaces[workspace].gaps_toggled;
        const gap = if (toggled) engine.config.gap_toggle else engine.config.gap_outer;
        return engine.monitors[monitor].visible.inset(gap);
    }

    /// The most recently focused window of the workspace that can take focus, or 0.
    fn workspace_focus_candidate(engine: *Engine, workspace: u8) WindowId {
        const last = engine.workspaces[workspace].last_focus;
        if (engine.window_find(last)) |window| {
            if (window.workspace == workspace and window.focusable()) return last;
        }
        var best: WindowId = 0;
        var best_seq: u64 = 0;
        for (&engine.windows) |*window| {
            if (window.id == 0 or window.workspace != workspace or !window.focusable()) continue;
            if (best == 0 or window.focus_seq > best_seq) {
                best = window.id;
                best_seq = window.focus_seq;
            }
        }
        return best;
    }

    // Monitors and workspaces.

    fn on_monitors_changed(engine: *Engine, reported: []const MonitorInfo) void {
        // More displays than are followed: the ones past the limit are left alone.
        const list = reported[0..@min(reported.len, monitors_max)];
        engine.shown_remember();
        if (list.len == 0) {
            // Every display is asleep. Keep all state; it comes back with the displays.
            if (engine.monitors_count > 0) engine.monitors_asleep = engine.monitors_count;
            engine.monitors_count = 0;
            return;
        }
        var old = engine.monitors;
        // Displays that wake up are compared with the ones that went to sleep.
        const awake = engine.monitors_count > 0;
        const old_count = if (awake) engine.monitors_count else engine.monitors_asleep;
        engine.monitors_asleep = 0;
        engine.monitors_count = 0;
        for (list) |info| engine.monitor_insert_sorted(info);
        assert(engine.monitors_count == list.len);
        engine.displays_renumber(old[0..old_count]);
        const focused_display = if (old_count > 0) old[engine.focused_monitor].display else 0;
        const recent_display = if (old_count > 0) old[engine.recent_monitor].display else 0;
        // Monitors keep the workspace they were showing when that is still theirs.
        for (engine.monitors[0..engine.monitors_count], 0..) |*monitor, index| {
            for (old[0..old_count]) |*previous| {
                if (previous.display != monitor.display) continue;
                if (engine.workspace_monitor(previous.workspace) == index) {
                    monitor.workspace = previous.workspace;
                }
            }
        }
        // The first displays there are show what a window manager before this one left
        // showing, if it left word while every display was asleep.
        if (old_count == 0) engine.shown_restore();
        const main = engine.main_monitor();
        const taken = engine.monitors[main].workspace != workspace_none or
            engine.workspace_shown_anywhere(0);
        if (old_count == 0 and !taken and !engine.workspace_empty(0)) {
            // Windows that were reported before any display was known wait on the first
            // workspace, the one in use until then. The main display shows it.
            engine.workspaces[0].display = engine.monitors[main].display;
            engine.monitors[main].workspace = 0;
        }
        for (engine.monitors[0..engine.monitors_count], 0..) |*monitor, index| {
            if (monitor.workspace == workspace_none) {
                monitor.workspace = engine.workspace_pick(@intCast(index));
            }
        }
        engine.focused_monitor = engine.monitor_by_display(focused_display);
        engine.recent_monitor = engine.monitor_by_display(recent_display);
        if (engine.window_find(engine.focused_window)) |window| {
            // Whatever happened to the displays, the window in use stays in view.
            if (!engine.workspace_visible(window.workspace)) {
                engine.workspace_show(window.workspace);
            }
            engine.focused_monitor = engine.workspace_monitor(window.workspace);
        }
        engine.sticky_follow();
        for (&engine.windows) |*window| {
            if (window.id == 0) continue;
            engine.float_rescue(window);
            // Where macOS lets a window be depends on the displays: a frame it refused
            // before may be allowed now, so every window that is off its target is sent
            // there again, even to the same target.
            window.desired_valid = false;
        }
        // Which monitor has focus may have changed under us; ask instead of guessing.
        engine.focus_stale = true;
    }

    /// A display that is gone, while one that was not there has its frame, is the same
    /// display under another id: macOS hands out a new one when a display reconnects.
    /// Its workspaces go with it, instead of falling to the main display as those of a
    /// display that was unplugged do. The old entries are renamed too, for what follows.
    fn displays_renumber(engine: *Engine, old: []Monitor) void {
        for (old, 0..) |*previous, index| {
            if (display_among(engine.monitors[0..engine.monitors_count], previous.display)) {
                continue;
            }
            for (engine.monitors[0..engine.monitors_count]) |*monitor| {
                if (!monitor.frame.eql(previous.frame)) continue;
                // A display that kept its id is not another one's successor.
                if (display_among(old, monitor.display)) continue;
                for (&engine.workspaces) |*workspace| {
                    if (workspace.display == previous.display) workspace.display = monitor.display;
                }
                old[index].display = monitor.display;
                break;
            }
        }
    }

    fn display_among(monitors: []const Monitor, display: u32) bool {
        for (monitors) |*monitor| {
            if (monitor.display == display) return true;
        }
        return false;
    }

    /// The workspace an adopted window was on when the last window manager quit.
    fn workspace_left_on(engine: *const Engine, info: WindowInfo) ?u8 {
        if (!info.adopted or engine.monitors_count == 0) return null;
        const workspace = info.workspace orelse return null;
        return if (workspace < workspaces_max) workspace else null;
    }

    /// Takes over what the last window manager knew about the workspaces: the display of
    /// each, the ones that were showing, the one in use. A display that is not there
    /// keeps its workspaces for when it comes back, as one that is unplugged does.
    fn on_workspaces_remembered(engine: *Engine, list: []const WorkspaceMemory) void {
        for (&engine.windows) |*window| {
            if (window.id != 0) return;
        }
        // Newer than anything a display change has noted so far.
        engine.shown_seq += 1;
        var current: u8 = workspace_none;
        for (list) |memory| {
            if (memory.workspace >= workspaces_max) continue;
            const workspace = &engine.workspaces[memory.workspace];
            workspace.display = memory.display;
            workspace.shown_seq = if (memory.shown) engine.shown_seq else 0;
            workspace.gaps_toggled = memory.gaps;
            workspace.accordion = memory.accordion;
            workspace.label = label_checked(memory.label);
            if (memory.focused) current = memory.workspace;
            if (memory.recent) engine.recent_workspace = memory.workspace;
        }
        // With every display asleep, the displays that wake up take it from here.
        if (engine.monitors_count == 0) return;
        for (engine.monitors[0..engine.monitors_count]) |*monitor| {
            monitor.workspace = workspace_none;
        }
        engine.shown_restore();
        for (engine.monitors[0..engine.monitors_count], 0..) |*monitor, index| {
            if (monitor.workspace == workspace_none) {
                monitor.workspace = engine.workspace_pick(@intCast(index));
            }
        }
        if (current != workspace_none and engine.workspace_visible(current)) {
            engine.focused_monitor = engine.workspace_monitor(current);
        }
    }

    /// Gives the displays that show nothing yet the workspaces that were remembered as
    /// showing: each on its own display, or on the main one when its own is not there,
    /// which is where it was showing if it was.
    fn shown_restore(engine: *Engine) void {
        if (engine.shown_seq == 0) return;
        for (&engine.workspaces, 0..) |*workspace, index| {
            if (workspace.shown_seq != engine.shown_seq) continue;
            const monitor = &engine.monitors[engine.workspace_monitor(@intCast(index))];
            if (monitor.workspace == workspace_none) monitor.workspace = @intCast(index);
        }
    }

    /// A label from outside is taken only if the label command would have taken it.
    fn label_checked(label: command.Label) command.Label {
        if (label.len > command.label_max) return .{};
        return command.Label.parse(label.slice()) orelse .{};
    }

    /// Takes over what the last window manager knew about its windows, for the windows
    /// that are reported next. A window that is already ours is not one of them.
    fn on_windows_remembered(engine: *Engine, list: []const WindowMemory) void {
        engine.memories_count = 0;
        engine.memories_fresh = true;
        for (list) |entry| {
            if (engine.memories_count == windows_max) break;
            const memory = memory_checked(entry) orelse continue;
            if (engine.window_find(memory.id) != null) continue;
            if (engine.memory_find(memory.id) != null) continue;
            engine.memories[engine.memories_count] = memory;
            engine.memories_count += 1;
        }
    }

    /// The entry with everything in range, or nothing when it names no window, process
    /// or workspace that can be.
    fn memory_checked(entry: WindowMemory) ?WindowMemory {
        if (entry.id == 0 or entry.pid == 0 or entry.workspace >= workspaces_max) return null;
        var memory = entry;
        memory.label = label_checked(entry.label);
        if (memory.zoom > 2) memory.zoom = 0;
        if (memory.side > 3) memory.side = 3;
        memory.ratio = std.math.clamp(memory.ratio, tree.ratio_min, tree.ratio_max);
        // A place that arithmetic could overflow on is no place.
        const rect = memory.float_rect;
        const far = 1 << 24;
        const sized = rect.w > 0 and rect.h > 0 and rect.w < far and rect.h < far;
        const near = rect.x > -far and rect.x < far and rect.y > -far and rect.y < far;
        if (!sized or !near) memory.float_rect = Rect.zero;
        if (memory.sticky) memory.floating = true;
        if (memory.floating or memory.tab) memory.order = 0;
        if (!memory.floating) memory.auto_floated = false;
        return memory;
    }

    fn memory_find(engine: *Engine, id: WindowId) ?*WindowMemory {
        for (engine.memories[0..engine.memories_count]) |*memory| {
            if (memory.id == id) return memory;
        }
        return null;
    }

    fn memory_drop(engine: *Engine, id: WindowId) void {
        const memory = engine.memory_find(id) orelse return;
        engine.memories_count -= 1;
        memory.* = engine.memories[engine.memories_count];
    }

    /// What is remembered of a window that is reported now. Only a window that was
    /// already open can be remembered, and only by the process that owned it then.
    fn memory_take(engine: *Engine, info: WindowInfo) ?WindowMemory {
        const memory = engine.memory_find(info.id) orelse return null;
        const found = memory.*;
        const ours = info.adopted and found.pid == info.pid;
        // Kept while the adoption goes on: the layout is rebuilt from it at the end.
        if (!ours or !engine.adopting) engine.memory_drop(info.id);
        return if (ours) found else null;
    }

    /// The displays there are, or the ones that went to sleep.
    fn monitors_known(engine: *const Engine) []const Monitor {
        const awake = engine.monitors_count > 0;
        return engine.monitors[0..if (awake) engine.monitors_count else engine.monitors_asleep];
    }

    /// What to write down about the workspaces for the window manager that runs next,
    /// which gets it back as workspaces_remembered. Returns how many entries there are.
    pub fn workspaces_remember(
        engine: *const Engine,
        out: *[workspaces_max]WorkspaceMemory,
    ) u32 {
        const known = engine.monitors_known();
        for (out, &engine.workspaces, 0..) |*memory, *workspace, index| {
            var shown = false;
            for (known) |*monitor| {
                if (monitor.workspace == index) shown = true;
            }
            memory.* = .{
                .workspace = @intCast(index),
                .display = workspace.display,
                .shown = shown,
                .focused = known.len > 0 and index == engine.workspace_current(),
                .recent = index == engine.recent_workspace,
                .gaps = workspace.gaps_toggled,
                .accordion = workspace.accordion,
                .label = workspace.label,
            };
        }
        return workspaces_max;
    }

    /// What to write down about the windows for the window manager that runs next, which
    /// gets it back as windows_remembered. Returns how many entries there are. Windows
    /// that were remembered and not reported yet are not among them: whoever read the
    /// file they were in still has their lines.
    pub fn windows_remember(engine: *const Engine, out: *[windows_max]WindowMemory) u32 {
        var count: u32 = 0;
        for (&engine.windows) |*window| {
            if (window.id == 0) continue;
            out[count] = engine.window_memory(window);
            count += 1;
            if (!engine.adopting) continue;
            // While the windows are still being reported the layout is not rebuilt yet,
            // and what was remembered of a window is still all there is to say.
            for (engine.memories[0..engine.memories_count]) |*memory| {
                if (memory.id == window.id) out[count - 1] = memory.*;
            }
        }
        return count;
    }

    fn window_memory(engine: *const Engine, window: *const Window) WindowMemory {
        var memory: WindowMemory = .{
            .id = window.id,
            .pid = window.pid,
            .workspace = window.workspace,
            .floating = window.mode == .floating,
            .by_user = window.mode_by_user,
            .auto_floated = window.auto_floated,
            .sticky = window.sticky,
            .ignored = window.ignored,
            .tab = window.tab_of != 0,
            .focused = window.id == engine.focused_window,
            .zoom = @backingInt(window.zoom),
            .focus_order = engine.focus_rank(window),
            .float_rect = window.float_rect,
            .label = window.label,
        };
        const leaf = engine.forest.leaf_find(window.id);
        if (leaf != node_none) {
            engine.tile_memory(leaf, &memory);
        } else if (window.slot_seq != 0) {
            memory.beside = window.slot_beside;
            memory.beside_last = window.slot_beside_last;
            memory.side = @backingInt(window.slot_side);
            memory.ratio = window.slot_ratio;
            memory.left_order = @intCast(@min(window.slot_seq, std.math.maxInt(u32)));
        }
        return memory;
    }

    /// How many windows had the focus before this one last had it, plus one; 0 for a
    /// window that never had it.
    fn focus_rank(engine: *const Engine, window: *const Window) u32 {
        if (window.focus_seq == 0) return 0;
        var rank: u32 = 1;
        for (&engine.windows) |*other| {
            if (other.id == 0 or other.focus_seq == 0) continue;
            if (other.focus_seq < window.focus_seq) rank += 1;
        }
        return rank;
    }

    /// Where a tile is in layout order and how it joins the tiles before it: the split
    /// whose second half it starts, and the two ends of the first half of that split.
    fn tile_memory(engine: *const Engine, leaf: NodeIndex, memory: *WindowMemory) void {
        const forest = &engine.forest;
        const root = forest.root_of(leaf);
        var order: u16 = 1;
        var at = forest.leaf_first(root);
        while (at != leaf) : (at = forest.leaf_next(root, at)) {
            assert(order < windows_max);
            order += 1;
        }
        memory.order = order;
        var child = leaf;
        var split = forest.nodes[leaf].parent;
        var steps: u32 = 0;
        while (split != node_none and forest.nodes[split].first == child) : (steps += 1) {
            assert(steps < tree.nodes_max);
            child = split;
            split = forest.nodes[split].parent;
        }
        if (split == node_none) return; // The first tile joins nothing.
        const before = forest.nodes[split].first;
        const below = forest.nodes[split].split == .rows;
        memory.beside = forest.nodes[forest.leaf_first(before)].window;
        memory.beside_last = forest.nodes[forest.leaf_last(before)].window;
        memory.side = @backingInt(if (below) Direction.south else Direction.east);
        memory.ratio = forest.nodes[split].ratio;
    }

    fn side_direction(side: u8) Direction {
        return switch (side) {
            0 => .west,
            1 => .south,
            2 => .north,
            else => .east,
        };
    }

    /// Notes which workspace every display shows, before the displays change.
    fn shown_remember(engine: *Engine) void {
        if (engine.monitors_count == 0) return;
        engine.shown_seq += 1;
        for (engine.monitors[0..engine.monitors_count]) |*monitor| {
            engine.workspaces[monitor.workspace].shown_seq = engine.shown_seq;
        }
    }

    /// The workspace of this display that was showing when the display was last there.
    fn workspace_remembered(engine: *const Engine, display: u32) ?u8 {
        var best: ?u8 = null;
        var best_seq: u64 = 0;
        for (&engine.workspaces, 0..) |*workspace, index| {
            if (workspace.display != display or workspace.shown_seq <= best_seq) continue;
            if (engine.workspace_shown_anywhere(@intCast(index))) continue;
            best = @intCast(index);
            best_seq = workspace.shown_seq;
        }
        return best;
    }

    fn monitor_insert_sorted(engine: *Engine, info: MonitorInfo) void {
        assert(engine.monitors_count < monitors_max);
        assert(info.display != 0);
        var index = engine.monitors_count;
        while (index > 0) : (index -= 1) {
            const before = engine.monitors[index - 1].frame;
            const ordered = before.x < info.frame.x or
                (before.x == info.frame.x and before.y <= info.frame.y);
            if (ordered) break;
            engine.monitors[index] = engine.monitors[index - 1];
        }
        engine.monitors[index] = .{
            .display = info.display,
            .frame = info.frame,
            .visible = info.visible,
            .main = info.main,
            .workspace = workspace_none,
        };
        engine.monitors_count += 1;
    }

    fn monitor_by_display(engine: *const Engine, display: u32) u8 {
        for (engine.monitors[0..engine.monitors_count], 0..) |*monitor, index| {
            if (monitor.display == display) return @intCast(index);
        }
        return engine.main_monitor();
    }

    fn workspace_shown_anywhere(engine: *const Engine, workspace: u8) bool {
        for (engine.monitors[0..engine.monitors_count]) |*monitor| {
            if (monitor.workspace == workspace) return true;
        }
        return false;
    }

    /// Chooses a workspace for a monitor that has none: the one its display showed last,
    /// then one of its own with windows, then an empty one, then any that already maps to
    /// it, then any hidden one.
    fn workspace_pick(engine: *Engine, monitor: u8) u8 {
        const display = engine.monitors[monitor].display;
        if (engine.workspace_remembered(display)) |workspace| {
            assert(engine.workspace_monitor(workspace) == monitor);
            return workspace;
        }
        var pass: u32 = 0;
        while (pass < 4) : (pass += 1) {
            var workspace: u8 = 0;
            while (workspace < workspaces_max) : (workspace += 1) {
                if (engine.workspace_shown_anywhere(workspace)) continue;
                const empty = engine.workspace_empty(workspace);
                const own = engine.workspaces[workspace].display == display;
                const fits = switch (pass) {
                    0 => own and !empty,
                    1 => empty,
                    2 => engine.workspace_monitor(workspace) == monitor,
                    else => true,
                };
                if (!fits) continue;
                if (pass == 1 or pass == 3) engine.workspaces[workspace].display = display;
                if (engine.workspace_monitor(workspace) != monitor) continue;
                return workspace;
            }
        }
        unreachable; // There are at least as many workspaces as monitors.
    }

    /// Sticky windows belong to whichever workspace their monitor shows.
    fn sticky_follow(engine: *Engine) void {
        for (&engine.windows) |*window| {
            if (window.id != 0 and window.sticky) engine.sticky_home(window);
        }
    }

    fn sticky_home(engine: *Engine, window: *Window) void {
        assert(window.sticky);
        assert(window.mode == .floating);
        if (engine.monitors_count == 0) return;
        const monitor = engine.workspace_monitor(window.workspace);
        const shown = engine.monitors[monitor].workspace;
        if (shown == window.workspace) return;
        const left = &engine.workspaces[window.workspace];
        if (left.last_focus == window.id) left.last_focus = 0;
        window.workspace = shown;
        engine.tabs_follow(window);
    }

    fn tabs_follow(engine: *Engine, leader: *const Window) void {
        assert(leader.tab_of == 0);
        for (&engine.windows) |*tab| {
            if (tab.id != 0 and tab.tab_of == leader.id) tab.workspace = leader.workspace;
        }
    }

    fn workspace_show(engine: *Engine, workspace: u8) void {
        assert(engine.monitors_count > 0);
        const monitor = engine.workspace_monitor(workspace);
        const previous = engine.monitors[monitor].workspace;
        if (previous == workspace) return;
        assert(!engine.workspace_shown_anywhere(workspace));
        for (&engine.windows) |*window| {
            if (window.id != 0 and window.sticky and window.workspace == previous) {
                window.workspace = workspace;
                engine.tabs_follow(window);
            }
        }
        engine.monitors[monitor].workspace = workspace;
        engine.recent_workspace = previous;
    }

    /// Makes the workspace visible and moves keyboard focus to it.
    fn workspace_focus(engine: *Engine, workspace: u8) void {
        if (engine.monitors_count == 0) return;
        if (!engine.workspace_visible(workspace)) {
            if (engine.workspace_empty(workspace)) {
                // Empty workspaces open on the monitor in use.
                const display = engine.monitors[engine.focused_monitor].display;
                engine.workspaces[workspace].display = display;
            }
            engine.workspace_show(workspace);
        }
        const monitor = engine.workspace_monitor(workspace);
        assert(engine.monitors[monitor].workspace == workspace);
        if (monitor != engine.focused_monitor) {
            engine.recent_monitor = engine.focused_monitor;
            engine.focused_monitor = monitor;
            engine.emit(.{ .warp_mouse = engine.monitors[monitor].frame });
        }
        const candidate = engine.workspace_focus_candidate(workspace);
        if (candidate != 0) {
            engine.focus_request(engine.window_find(candidate).?);
        } else {
            engine.focused_window = 0;
        }
    }

    // Focus.

    fn focus_state_set(engine: *Engine, window: *Window) void {
        assert(window.focusable());
        engine.focus_seq += 1;
        window.focus_seq = engine.focus_seq;
        engine.focused_window = window.id;
        engine.workspaces[window.workspace].last_focus = window.id;
        engine.focused_monitor_follow(window);
    }

    /// The focused monitor is always the one the focused window is on.
    fn focused_monitor_follow(engine: *Engine, window: *const Window) void {
        if (engine.monitors_count == 0) return;
        const monitor = engine.workspace_monitor(window.workspace);
        if (monitor == engine.focused_monitor) return;
        engine.recent_monitor = engine.focused_monitor;
        engine.focused_monitor = monitor;
    }

    fn focus_request(engine: *Engine, window: *Window) void {
        assert(window.focusable());
        // In agreement only when the OS said so last: the keyboard may have gone to a
        // window that we do not follow, and then the request has to be made again.
        const in_sync = engine.focused_window == window.id and
            engine.focus_pending_count == 0 and engine.os_focus == window.id;
        engine.focus_state_set(window);
        if (!in_sync) engine.focus_emit(window);
    }

    /// Asks the OS to focus the window and remembers the request until it is confirmed.
    fn focus_emit(engine: *Engine, window: *const Window) void {
        if (engine.focus_pending_count == focus_pending_max) engine.focus_pending_drop(1);
        engine.focus_pending[engine.focus_pending_count] = .{
            .id = window.id,
            .deadline_ms = engine.now_ms + focus_pending_ms,
        };
        engine.focus_pending_count += 1;
        engine.emit(.{ .focus_window = .{ .id = window.id, .pid = window.pid } });
    }

    fn focus_pending_drop(engine: *Engine, count: u32) void {
        assert(count <= engine.focus_pending_count);
        const remaining = engine.focus_pending_count - count;
        var index: u32 = 0;
        while (index < remaining) : (index += 1) {
            engine.focus_pending[index] = engine.focus_pending[index + count];
        }
        engine.focus_pending_count = remaining;
    }

    /// The OS tells us where focus is: as a notification that it moved (reported false),
    /// or as the answer to a query_focus of ours (reported true).
    fn focus_observe(engine: *Engine, id: WindowId, reported: bool) void {
        var repeated = id == engine.os_focus;
        engine.os_focus = id;
        // An echo of a request of ours confirms it and everything requested before it.
        for (engine.focus_pending[0..engine.focus_pending_count], 0..) |pending, index| {
            if (pending.id != id) continue;
            engine.focus_pending_drop(@intCast(index + 1));
            // Nothing more to do if we still believe what was confirmed, or if newer
            // requests are in flight. Otherwise our belief moved on without the OS (the
            // window was sent away, say, or its workspace left for an empty one). The OS
            // is where we sent it; like a repeated announcement, that is not the user
            // going there, and it must not bring a hidden workspace back.
            if (engine.focused_window == id or engine.focus_pending_count > 0) return;
            repeated = true;
            break;
        }
        // While a request of ours is in flight, an answer that predates it means nothing.
        if (reported and engine.focus_pending_count > 0) return;
        const window = engine.window_find(id) orelse return;
        if (window.ignored) return;
        if (window.minimized) {
            // A minimized window cannot have focus: the deminimize notice is just late.
            window.minimized = false;
            engine.membership_sync(window);
        }
        if (id == engine.focused_window) return;
        if (window.tab_of != 0) engine.tab_promote(window);
        const hidden = !engine.workspace_visible(window.workspace);
        // The engine holds no focus on purpose after the user moved to a monitor that has
        // no windows, while the OS still has it on a window of another monitor.
        const away = !hidden and engine.focused_window == 0 and
            engine.workspace_monitor(window.workspace) != engine.focused_monitor;
        // An application that announces again the focus it already had is not the user
        // going there. Browsers do this all the time; following it would undo every switch
        // to an empty workspace or to an empty monitor.
        if (!reported and repeated and (hidden or away)) return;
        if (reported) {
            // An answer is not a focus change: it never switches workspace or monitor.
            if (hidden) {
                engine.focused_window = 0;
                return;
            }
            const monitor = engine.workspace_monitor(window.workspace);
            if (engine.focused_window == 0 and monitor != engine.focused_monitor) return;
        }
        const guarded = engine.now_ms < engine.guard_until_ms and hidden;
        // A window that a rule sent away may not pull focus to where it went. One that
        // is in view on the monitor in use pulls nothing, and takes focus like any other.
        const in_view = !hidden and
            engine.workspace_monitor(window.workspace) == engine.focused_monitor;
        const quiet = engine.now_ms < window.quiet_until_ms and !in_view;
        if (!reported and (quiet or guarded)) {
            engine.stats.focus_rejected += 1;
            if (engine.window_find(engine.focused_window)) |current| engine.focus_emit(current);
            return;
        }
        engine.focus_pending_count = 0;
        if (engine.monitors_count > 0) {
            if (hidden) engine.workspace_show(window.workspace);
            const monitor = engine.workspace_monitor(window.workspace);
            if (monitor != engine.focused_monitor) {
                engine.recent_monitor = engine.focused_monitor;
                engine.focused_monitor = monitor;
            }
        }
        engine.focus_state_set(window);
    }

    /// Picks the next window after the focused one went away.
    fn focus_after_loss(engine: *Engine, workspace: u8, heir: WindowId) void {
        assert(engine.focused_window == 0);
        engine.guard_until_ms = engine.now_ms + guard_ms;
        if (!engine.workspace_visible(workspace)) return;
        const candidate = if (heir != 0) heir else engine.workspace_focus_candidate(workspace);
        if (engine.window_find(candidate)) |window| engine.focus_request(window);
    }

    // Applications.

    fn on_app_launched(engine: *Engine, info: AppInfo) void {
        assert(info.pid != 0);
        const index = engine.app_find(info.pid) orelse engine.app_add(info.pid) orelse return;
        const app = &engine.apps[index];
        app.name_len = text_keep(&app.name, info.name);
        app.bundle_len = text_keep(&app.bundle, info.bundle);
    }

    fn app_add(engine: *Engine, pid: i32) ?u8 {
        for (&engine.apps, 0..) |*app, index| {
            if (app.pid == 0) {
                app.* = .{ .pid = pid };
                return @intCast(index);
            }
        }
        return null;
    }

    fn on_app_terminated(engine: *Engine, pid: i32) void {
        assert(pid != 0);
        for (&engine.windows) |*window| {
            if (window.id != 0 and window.pid == pid) engine.window_remove(window);
        }
        if (engine.app_find(pid)) |index| engine.apps[index] = .{};
        // What was remembered of its windows is about windows that are gone.
        var kept: u32 = 0;
        for (engine.memories[0..engine.memories_count]) |memory| {
            if (memory.pid == pid) continue;
            engine.memories[kept] = memory;
            kept += 1;
        }
        engine.memories_count = kept;
    }

    fn on_app_unresponsive(engine: *Engine, pid: i32) void {
        const index = engine.app_find(pid) orelse return;
        const app = &engine.apps[index];
        app.backoff_ms = std.math.clamp(app.backoff_ms * 2, backoff_min_ms, backoff_max_ms);
        app.suspended_until_ms = engine.now_ms + app.backoff_ms;
        engine.stats.apps_suspended += 1;
        for (&engine.windows) |*window| {
            if (window.id == 0 or window.app != index or !window.desired_valid) continue;
            if (!window.actual.eql(window.desired) and !window.frozen) window.set_pending = true;
        }
    }

    // Windows.

    pub fn workspace_current(engine: *const Engine) u8 {
        // While every display is asleep, the workspace in use is the one that was.
        assert(engine.monitors_count == 0 or engine.monitors_asleep == 0);
        if (engine.monitors_count + engine.monitors_asleep == 0) return 0;
        return engine.monitors[engine.focused_monitor].workspace;
    }

    /// A new window joins the workspace in use, wherever the application drew it. A window
    /// that was already open at startup stays on the monitor where it was found.
    fn workspace_for(engine: *const Engine, info: WindowInfo) u8 {
        if (engine.workspace_left_on(info)) |workspace| return workspace;
        if (engine.monitors_count == 0 or !info.adopted) return engine.workspace_current();
        const monitor = engine.monitor_at(info.frame.center_x(), info.frame.center_y()) orelse
            engine.focused_monitor;
        return engine.monitors[monitor].workspace;
    }

    fn window_slot_free(engine: *Engine) ?*Window {
        for (&engine.windows) |*window| {
            if (window.id == 0) return window;
        }
        return null;
    }

    fn representative(engine: *Engine, window: *Window) *Window {
        if (window.tab_of == 0) return window;
        const leader = engine.window_find(window.tab_of).?;
        assert(leader.tab_of == 0);
        return leader;
    }

    fn on_window_appeared(engine: *Engine, info: WindowInfo) void {
        assert(info.id != 0);
        assert(info.pid != 0);
        // Popups, tooltips and other helper windows are never ours to manage.
        if (info.kind == .popup) return;
        if (engine.window_find(info.id) != null) return;
        const memory = engine.memory_take(info);
        const app = engine.app_find(info.pid) orelse engine.app_add(info.pid) orelse {
            engine.stats.windows_dropped += 1;
            return;
        };
        const window = engine.window_slot_free() orelse {
            engine.stats.windows_dropped += 1;
            return;
        };
        const tiles = info.kind == .standard and info.resizable;
        window.* = .{
            .id = info.id,
            .pid = info.pid,
            .app = app,
            .workspace = if (memory) |known| known.workspace else engine.workspace_for(info),
            .mode = if (tiles) .tiled else .floating,
            .kind = info.kind,
            .resizable = info.resizable,
            .minimized = info.minimized,
            .fullscreen = info.fullscreen,
            .actual = info.frame,
            .float_rect = info.frame,
            .appeared_ms = engine.now_ms,
        };
        window.title_set(info.title);
        if (engine.window_find(info.tab_of)) |other| {
            if (other.pid == info.pid and other != window) {
                const leader = engine.representative(other);
                window.tab_of = leader.id;
                window.workspace = leader.workspace;
            }
        }
        if (memory) |known| {
            engine.window_recall(window, known);
        } else {
            engine.window_place(window, info);
        }
        engine.membership_sync(window);
        // The OS already said that the keyboard is on this window, before we knew it.
        if (engine.os_focus == info.id) engine.focus_stale = true;
        engine.note(.{ .window_created = info.id });
    }

    /// A window that nothing is remembered of goes where the rules send it, and
    /// otherwise stays where it is found.
    fn window_place(engine: *Engine, window: *Window, info: WindowInfo) void {
        engine.rules_apply(window, true);
        if (engine.workspace_left_on(info)) |workspace| {
            // A restart changes nothing: not even a rule sends the window elsewhere.
            const movable = window.tab_of == 0 and !window.sticky;
            if (movable and workspace != window.workspace) engine.window_move(window, workspace);
            engine.float_rescue(window);
        } else {
            engine.float_home(window);
        }
    }

    /// A window that the last window manager knew is as it was left. No rule applies to
    /// it again: it has been arranged once, and a restart changes nothing.
    fn window_recall(engine: *Engine, window: *Window, memory: WindowMemory) void {
        window.rules_applied = std.math.maxInt(u64);
        window.focus_seq = memory.focus_order;
        engine.focus_seq = @max(engine.focus_seq, memory.focus_order);
        if (window.tab_of != 0) {
            // It joined a window that it is a tab of. Of the two, the one that held the
            // tile before holds it again.
            const leader = engine.memory_find(window.tab_of);
            if (memory.tab or leader == null or !leader.?.tab) return;
            engine.tab_promote(window);
        }
        if (memory.tab) {
            // A tab had nothing of its own. Alone now, it is a window like any other
            // on the workspace of the window it was a tab of.
            if (!engine.on_some_monitor(window.float_rect)) engine.float_rescue(window);
            return;
        }
        if (window.workspace != memory.workspace) engine.window_move(window, memory.workspace);
        window.ignored = memory.ignored;
        window.mode = if (memory.floating) .floating else .tiled;
        window.mode_by_user = memory.by_user;
        window.auto_floated = memory.auto_floated;
        window.sticky = memory.sticky;
        window.zoom = switch (memory.zoom) {
            1 => .parent,
            2 => .fullscreen,
            else => .none,
        };
        window.label = memory.label;
        if (memory.float_rect.w > 0) window.float_rect = memory.float_rect;
        if (memory.order == 0 and (memory.beside != 0 or memory.left_order != 0)) {
            window.slot_beside = memory.beside;
            window.slot_beside_last = memory.beside_last;
            window.slot_side = side_direction(memory.side);
            window.slot_ratio = memory.ratio;
            // A file that names a place and no order: it left last, for all we know.
            engine.slot_seq = @max(engine.slot_seq, memory.left_order);
            if (memory.left_order == 0) engine.slot_seq += 1;
            window.slot_seq = if (memory.left_order == 0) engine.slot_seq else memory.left_order;
        }
        // In or out of the layout as it is now, before anything else moves it.
        engine.membership_sync(window);
        // Where it floated is where it floats, unless no display reaches there any more.
        if (!engine.on_some_monitor(window.float_rect)) engine.float_rescue(window);
        if (window.sticky and engine.monitors_count > 0) engine.sticky_follow();
    }

    fn on_some_monitor(engine: *const Engine, rect: Rect) bool {
        for (engine.monitors[0..engine.monitors_count]) |*monitor| {
            if (rect.intersects(monitor.frame)) return true;
        }
        return false;
    }

    /// A new window that floats is never moved to a tile, so it stays where its
    /// application drew it. Like a floating window that is dragged, it then belongs to
    /// the monitor it is on, not to the one in use; and when it is on no monitor at all
    /// (a place remembered from a display that is gone) it is brought into view. When a
    /// rule chose its workspace the rule wins: the window comes to that workspace's
    /// monitor if it was drawn wholly off it.
    fn float_home(engine: *Engine, window: *Window) void {
        if (engine.monitors_count == 0 or window.mode != .floating) return;
        if (!window.managed()) return;
        if (window.rule_placed) return engine.float_rescue(window);
        const frame = window.float_rect;
        if (engine.monitor_at(frame.center_x(), frame.center_y())) |monitor| {
            if (monitor == engine.workspace_monitor(window.workspace)) return;
            window.workspace = engine.monitors[monitor].workspace;
        } else {
            engine.float_rescue(window);
        }
    }

    fn on_window_destroyed(engine: *Engine, id: WindowId) void {
        if (engine.window_find(id)) |window| engine.window_remove(window);
    }

    fn tab_heir(engine: *Engine, window: *const Window) ?*Window {
        var heir: ?*Window = null;
        for (&engine.windows) |*candidate| {
            if (candidate.id == 0 or candidate.tab_of != window.id) continue;
            if (heir == null or candidate.focus_seq > heir.?.focus_seq) heir = candidate;
        }
        return heir;
    }

    fn window_remove(engine: *Engine, window: *Window) void {
        assert(window.id != 0);
        const id = window.id;
        const workspace_index = window.workspace;
        const workspace = &engine.workspaces[workspace_index];
        const was_focused = engine.focused_window == id;
        const leaf = engine.forest.leaf_find(id);
        const heir = engine.tab_heir(window);
        if (heir) |next| {
            // A tab takes over the place of the window that was showing.
            next.tab_of = 0;
            next.workspace = window.workspace;
            next.mode = window.mode;
            next.auto_floated = window.auto_floated;
            next.zoom = window.zoom;
            next.sticky = window.sticky;
            next.float_rect = window.float_rect;
            // The name of the window that was showing goes on with what shows in its
            // place, unless the tab has a name of its own.
            if (next.label.len == 0) next.label = window.label;
            next.desired_valid = false;
            for (&engine.windows) |*other| {
                if (other.id != 0 and other.tab_of == id) other.tab_of = next.id;
            }
            if (leaf != node_none) engine.forest.nodes[leaf].window = next.id;
            engine.slots_rename(id, next.id);
        } else if (leaf != node_none) {
            engine.forest.remove(&workspace.root, id);
        }
        if (workspace.last_focus == id) workspace.last_focus = 0;
        if (engine.os_focus == id) engine.os_focus = 0;
        engine.focus_pending_remove(id);
        window.* = .{};
        engine.note(.{ .window_closed = id });
        if (heir) |next| engine.membership_sync(next);
        if (was_focused) {
            engine.focused_window = 0;
            const heir_id = if (heir != null and heir.?.focusable()) heir.?.id else 0;
            engine.focus_after_loss(workspace_index, heir_id);
        }
    }

    fn focus_pending_remove(engine: *Engine, id: WindowId) void {
        var kept: u32 = 0;
        for (engine.focus_pending[0..engine.focus_pending_count]) |pending| {
            if (pending.id == id) continue;
            engine.focus_pending[kept] = pending;
            kept += 1;
        }
        // A request that can no longer be confirmed leaves us unsure where focus is.
        if (kept != engine.focus_pending_count) engine.focus_stale = true;
        engine.focus_pending_count = kept;
    }

    /// Makes the tree agree with the window: a leaf exactly when the window is in the layout.
    fn membership_sync(engine: *Engine, window: *Window) void {
        const leaf = engine.forest.leaf_find(window.id);
        const workspace = &engine.workspaces[window.workspace];
        if (window.in_layout() and leaf == node_none) {
            engine.tree_insert(window);
        } else if (!window.in_layout() and leaf != node_none) {
            assert(engine.forest.root_of(leaf) == workspace.root);
            engine.forest.remove(&workspace.root, window.id);
        }
        if (!window.in_layout() and window.zoom == .parent) window.zoom = .none;
        // A remembered place is spent once the window is back, in the layout or not.
        if (window.managed()) {
            window.slot_beside = 0;
            window.slot_seq = 0;
        }
        assert(window.in_layout() == (engine.forest.leaf_find(window.id) != node_none));
    }

    /// Remembers where a window sits in the layout before it leaves it for a while.
    fn slot_remember(engine: *Engine, window: *Window) void {
        window.slot_beside = 0;
        window.slot_seq = 0;
        if (engine.forest.leaf_find(window.id) == node_none) return;
        engine.slot_keep(window, engine.slot_of(window.id));
    }

    /// Notes the place a window leaves, and that it is the last one to have left.
    fn slot_keep(engine: *Engine, window: *Window, slot: Slot) void {
        window.slot_beside = slot.beside;
        window.slot_beside_last = slot.beside_last;
        window.slot_side = slot.side;
        window.slot_ratio = slot.ratio;
        engine.slot_seq += 1;
        window.slot_seq = engine.slot_seq;
    }

    /// The place of a tile in its layout, as a window keeps it (see Window.slot_beside).
    fn slot_of(engine: *const Engine, id: WindowId) Slot {
        const forest = &engine.forest;
        const leaf = forest.leaf_find(id);
        // Not in the layout, or alone in it: it sits beside nobody.
        if (leaf == node_none or forest.nodes[leaf].parent == node_none) return .{};
        const split = &forest.nodes[forest.nodes[leaf].parent];
        const first = split.first == leaf;
        const beside = if (first) split.second else split.first;
        return .{
            .beside = forest.nodes[forest.leaf_first(beside)].window,
            .beside_last = forest.nodes[forest.leaf_last(beside)].window,
            .side = switch (split.split) {
                .columns => if (first) .west else .east,
                .rows => if (first) .north else .south,
            },
            .ratio = split.ratio,
        };
    }

    /// The smallest part of a layout that holds what is left in it of the two ends of
    /// a subtree, or node_none when neither is there.
    fn slot_target(engine: *const Engine, root: NodeIndex, ends: [2]WindowId) NodeIndex {
        const forest = &engine.forest;
        var target: NodeIndex = node_none;
        for (ends) |id| {
            if (id == 0) continue;
            const leaf = forest.leaf_find(id);
            if (leaf == node_none or forest.root_of(leaf) != root) continue;
            target = if (target == node_none) leaf else forest.ancestor_common(target, leaf);
        }
        return target;
    }

    /// Puts a window back in the place it left. Windows that left the layout after it
    /// left a layout that it was not part of: hiding an application takes all of its
    /// windows away one by one, and showing it brings them back in any order. So they
    /// come back first, the last to leave first, which makes the layout the one this
    /// window left. Afterwards they leave again and remember their places anew.
    fn slot_restore(engine: *Engine, window: *Window) bool {
        const seq = window.slot_seq;
        window.slot_seq = 0;
        if (seq == 0 or window.slot_beside == 0) return false;
        var later: [windows_max]WindowId = undefined;
        const count = engine.slots_unwind(window.workspace, seq, &later);
        const restored = engine.slot_place(window);
        window.slot_beside = 0;
        var index = count;
        while (index > 0) : (index -= 1) {
            const other = engine.window_find(later[index - 1]).?;
            engine.slot_remember(other);
            engine.forest.remove(&engine.workspaces[other.workspace].root, other.id);
        }
        return restored;
    }

    /// Puts the windows of the workspace that left its layout after the given moment, and
    /// are still away, back in their places, the last to leave first. Returns how many,
    /// and which, in that order.
    fn slots_unwind(
        engine: *Engine,
        workspace: u8,
        seq: u64,
        later: *[windows_max]WindowId,
    ) u32 {
        var count: u32 = 0;
        var bound: u64 = std.math.maxInt(u64);
        while (count < windows_max) {
            var last: ?*Window = null;
            for (&engine.windows) |*other| {
                if (other.id == 0 or other.slot_seq <= seq or other.slot_seq >= bound) continue;
                if (!other.slot_waits(workspace)) continue;
                if (last == null or other.slot_seq > last.?.slot_seq) last = other;
            }
            const other = last orelse break;
            bound = other.slot_seq;
            // A window whose place is gone stays away as it is.
            if (!engine.slot_place(other)) continue;
            later[count] = other.id;
            count += 1;
        }
        return count;
    }

    /// Another tab of its group shows in the tile now. The windows that remember to have
    /// sat beside that tile know it by the window that shows.
    fn slots_rename(engine: *Engine, from: WindowId, to: WindowId) void {
        for (&engine.windows) |*window| {
            if (window.id == 0) continue;
            if (window.slot_beside == from) window.slot_beside = to;
            if (window.slot_beside_last == from) window.slot_beside_last = to;
        }
    }

    /// Inserts the window where it remembers to have been: alone, or beside the smallest
    /// part of the layout that holds what is left, on its workspace, of the two ends of
    /// the subtree it sat beside. Exact when nothing else changed in between, and still
    /// beside the same windows when that subtree gained or lost some.
    fn slot_place(engine: *Engine, window: *const Window) bool {
        const forest = &engine.forest;
        const workspace = &engine.workspaces[window.workspace];
        const ends = [2]WindowId{ window.slot_beside, window.slot_beside_last };
        if (ends[0] == 0) {
            if (workspace.root != node_none) return false;
            forest.insert(&workspace.root, node_none, window.id, .auto);
            return true;
        }
        const target = engine.slot_target(workspace.root, ends);
        if (target == node_none) return false;
        forest.insert_beside(&workspace.root, target, window.id, window.slot_side);
        const split = forest.nodes[forest.leaf_find(window.id)].parent;
        forest.nodes[split].ratio = window.slot_ratio;
        return true;
    }

    fn tree_insert(engine: *Engine, window: *Window) void {
        if (engine.slot_restore(window)) return;
        const workspace = &engine.workspaces[window.workspace];
        const placement: tree.Placement = if (workspace.insert) |side| .{ .side = side } else .auto;
        const percent = workspace.insert_percent;
        workspace.insert = null;
        workspace.insert_percent = 0;
        if (workspace.root == node_none) {
            engine.forest.insert(&workspace.root, node_none, window.id, .auto);
            return;
        }
        const anchor = engine.insert_anchor(window.workspace);
        engine.forest.insert(&workspace.root, anchor, window.id, placement);
        if (percent != 0) engine.forest.share_set(engine.forest.leaf_find(window.id), percent);
    }

    /// New windows split the focused window, else the last focused one, else the tile that
    /// had focus most recently, else the last leaf.
    fn insert_anchor(engine: *Engine, workspace_index: u8) NodeIndex {
        const workspace = &engine.workspaces[workspace_index];
        assert(workspace.root != node_none);
        const candidates = [2]WindowId{ engine.focused_window, workspace.last_focus };
        for (candidates) |id| {
            if (id == 0) continue;
            const leaf = engine.forest.leaf_find(id);
            if (leaf != node_none and engine.forest.root_of(leaf) == workspace.root) return leaf;
        }
        // A floating window has the focus: the new one goes beside the tile used before it,
        // not to the far end of the layout.
        const forest = &engine.forest;
        var best = forest.leaf_last(workspace.root);
        var best_seq: u64 = 0;
        var count: u32 = 0;
        var leaf = forest.leaf_first(workspace.root);
        while (leaf != node_none) : (leaf = forest.leaf_next(workspace.root, leaf)) {
            assert(count < windows_max);
            count += 1;
            const seq = engine.window_find(forest.nodes[leaf].window).?.focus_seq;
            if (seq <= best_seq) continue;
            best = leaf;
            best_seq = seq;
        }
        return best;
    }

    fn mode_set(engine: *Engine, window: *Window, mode: Mode) void {
        if (window.mode == mode) return;
        if (mode == .tiled) {
            window.sticky = false;
            window.auto_floated = false;
        }
        const on_screen = window.desired_valid and engine.workspace_visible(window.workspace);
        if (mode == .floating and on_screen and window.zoom == .none) {
            // A frame that is still on its way is where the window will be. Where it was
            // last seen may be the corner it was parked in.
            const arrived = window.actual.x == window.desired.x and
                window.actual.y == window.desired.y;
            window.float_rect = if (arrived) window.actual else window.desired;
        }
        window.mode = mode;
        // Hidden or zoomed, the window floats where it floated last or was first drawn,
        // and that may be on another monitor than the one its workspace is on.
        if (window.desired_valid) engine.float_rescue(window);
        engine.membership_sync(window);
    }

    /// Moves a window to another workspace without touching focus.
    fn window_move(engine: *Engine, window: *Window, target: u8) void {
        assert(target < workspaces_max);
        assert(target != window.workspace);
        assert(window.tab_of == 0);
        const origin = window.workspace;
        if (engine.forest.leaf_find(window.id) != node_none) {
            engine.forest.remove(&engine.workspaces[origin].root, window.id);
        }
        if (engine.workspaces[origin].last_focus == window.id) {
            engine.workspaces[origin].last_focus = 0;
        }
        if (engine.monitors_count > 0) {
            // Floating windows keep their spot relative to the monitor. On a monitor of
            // another size that spot may hang off its edge, or be bigger than all of it.
            const from = engine.monitors[engine.workspace_monitor(origin)].visible;
            const to = engine.monitors[engine.workspace_monitor(target)].visible;
            window.float_rect.x += to.x - from.x;
            window.float_rect.y += to.y - from.y;
            if (!from.eql(to)) window.float_rect = rect_within(window.float_rect, to);
        }
        window.workspace = target;
        window.zoom = .none;
        if (engine.focused_window == 0) engine.focus_stale = true;
        engine.float_rescue(window);
        engine.tabs_follow(window);
        engine.membership_sync(window);
    }

    /// The rect moved, and shrunk if it must be, so that all of it is inside the area.
    fn rect_within(rect: Rect, area: Rect) Rect {
        const w = @min(rect.w, area.w);
        const h = @min(rect.h, area.h);
        return .{
            .x = std.math.clamp(rect.x, area.x, area.right() - w),
            .y = std.math.clamp(rect.y, area.y, area.bottom() - h),
            .w = w,
            .h = h,
        };
    }

    // Rules.

    fn rules_apply(engine: *Engine, window: *Window, initial: bool) void {
        const strings = &engine.config.strings;
        for (engine.config.rules[0..engine.config.rules_count], 0..) |rule, index| {
            const bit = @as(u64, 1) << @as(u6, @intCast(index));
            if (window.rules_applied & bit != 0) continue;
            // Only title rules can start matching after the window appeared.
            if (!initial and rule.title.len == 0) continue;
            const app = &engine.apps[window.app];
            const name = strings.get(rule.app);
            if (name.len > 0 and !stdx.contains_ignore_case(app.name_slice(), name)) continue;
            const bundle = strings.get(rule.bundle);
            if (bundle.len > 0 and !std.mem.eql(u8, app.bundle_slice(), bundle)) continue;
            const title = strings.get(rule.title);
            if (title.len > 0 and !stdx.contains_ignore_case(window.title_slice(), title)) continue;
            window.rules_applied |= bit;
            engine.rule_action(window, rule.action);
        }
    }

    fn rule_action(engine: *Engine, window: *Window, action: config_module.RuleAction) void {
        switch (action) {
            .float => if (!window.mode_by_user) engine.mode_set(window, .floating),
            .tile => if (!window.mode_by_user) engine.mode_set(window, .tiled),
            .sticky => {
                engine.mode_set(window, .floating);
                // A tab has no place of its own to keep in view: it rides along with the
                // window that shows, and takes over that window's place when it shows.
                window.sticky = window.tab_of == 0;
                if (!window.sticky) return;
                // Sticky is in view by definition, whatever workspace the window was on
                // or another rule sent it to, and a window in view may have the keyboard.
                engine.sticky_home(window);
                window.quiet_until_ms = 0;
            },
            .ignore => window.ignored = true,
            .workspace => |target| {
                // A tab stays with its window and a sticky window with its monitor.
                if (window.tab_of != 0 or window.sticky) return;
                window.rule_placed = true;
                if (target == window.workspace) return;
                engine.window_move(window, target);
                // Sent away: only then is there a workspace it must not pull back.
                window.quiet_until_ms = engine.now_ms + quiet_ms;
            },
        }
    }

    fn on_title_changed(engine: *Engine, id: WindowId, title: []const u8) void {
        const window = engine.window_find(id) orelse return;
        window.title_set(title);
        if (engine.now_ms - window.appeared_ms > rule_grace_ms) return;
        const origin = window.workspace;
        engine.rules_apply(window, false);
        engine.membership_sync(window);
        if (engine.focused_window != id) return;
        if (window.focusable() and window.workspace == origin) return;
        // The rule took the window in use away. Sent to another workspace, it gives the
        // keyboard to the next window where the user is.
        engine.focused_window = 0;
        if (window.focusable()) return engine.focus_after_loss(origin, 0);
        // Ignored now: as with a window that is ignored from the start, the keyboard is
        // left where it is and we go by the window that was used before.
        if (!engine.workspace_visible(origin)) return;
        const next = engine.window_find(engine.workspace_focus_candidate(origin)) orelse return;
        engine.focus_state_set(next);
    }

    fn on_minimized(engine: *Engine, id: WindowId, minimized: bool) void {
        const window = engine.window_find(id) orelse return;
        if (minimized and window.managed()) engine.slot_remember(window);
        window.minimized = minimized;
        engine.membership_sync(window);
        if (minimized and engine.focused_window == id) {
            engine.focused_window = 0;
            engine.focus_after_loss(window.workspace, 0);
        }
    }

    fn on_fullscreen(engine: *Engine, id: WindowId, fullscreen: bool) void {
        const window = engine.window_find(id) orelse return;
        if (fullscreen and window.managed()) engine.slot_remember(window);
        const left = window.fullscreen and !fullscreen;
        window.fullscreen = fullscreen;
        // A floating window that leaves fullscreen floats where macOS puts it back. The
        // place we had for it may be the display it filled: its frame can grow before we
        // are told why, and that looks like the window moving itself there. Nor is the
        // frame we know now the one it returns to, for sure: that one may still be on
        // its way, or be reported late. So the window is left alone for a while, and
        // then floats where it is (see float_return).
        if (left and window.mode == .floating and window.zoom == .none) {
            window.float_return_until_ms = engine.now_ms + fullscreen_exit_ms;
        }
        engine.membership_sync(window);
    }

    /// The time that a floating window had to come back from native fullscreen is up:
    /// it floats where it is now, and is ours to place again.
    fn float_return(window: *Window) void {
        assert(window.float_return_until_ms != 0);
        window.float_return_until_ms = 0;
        if (window.mode == .floating and window.zoom == .none and window.managed()) {
            window.float_rect = window.actual;
        }
    }

    // Native tabs: one window of a tab group is in the layout, the others ride along.

    fn tab_promote(engine: *Engine, window: *Window) void {
        assert(window.tab_of != 0);
        const leader = engine.window_find(window.tab_of).?;
        assert(leader.tab_of == 0);
        assert(leader != window);
        const leaf = engine.forest.leaf_find(leader.id);
        const workspace = &engine.workspaces[leader.workspace];
        window.tab_of = 0;
        window.workspace = leader.workspace;
        window.mode = leader.mode;
        window.auto_floated = leader.auto_floated;
        window.zoom = leader.zoom;
        window.sticky = leader.sticky;
        window.float_rect = leader.float_rect;
        window.desired_valid = false;
        for (&engine.windows) |*other| {
            if (other.id != 0 and other.tab_of == leader.id) other.tab_of = window.id;
        }
        leader.tab_of = window.id;
        leader.zoom = .none;
        leader.sticky = false;
        leader.desired_valid = false;
        if (leaf != node_none) engine.forest.nodes[leaf].window = window.id;
        engine.slots_rename(leader.id, window.id);
        if (workspace.last_focus == leader.id) workspace.last_focus = window.id;
        if (engine.focused_window == leader.id) engine.focused_window = window.id;
        engine.membership_sync(window);
        engine.membership_sync(leader);
    }

    fn on_tab_changed(engine: *Engine, id: WindowId, tab_of: WindowId) void {
        const window = engine.window_find(id) orelse return;
        var target: ?*Window = null;
        if (engine.window_find(tab_of)) |other| {
            if (other.pid == window.pid and other != window) target = engine.representative(other);
        }
        if (target == window) {
            // The other window is a tab of ours and is now the one showing.
            engine.tab_promote(engine.window_find(tab_of).?);
            return;
        }
        const target_id = if (target) |leader| leader.id else 0;
        if (window.tab_of == target_id) return;
        if (target == null) {
            // Dragged out of its tab group into a window of its own. It keeps the mode its
            // rules gave it, and a floating one stays where it was dropped.
            window.tab_of = 0;
            if (window.kind != .standard or !window.resizable) window.mode = .floating;
            // Out of view, where it is now is the corner its group was parked in.
            const shown = engine.monitors_count == 0 or engine.workspace_visible(window.workspace);
            if (window.mode == .floating and shown) window.float_rect = window.actual;
            engine.float_rescue(window);
            window.desired_valid = false;
            engine.membership_sync(window);
            return;
        }
        const leader = target.?;
        const was_focused = engine.focused_window == id;
        const origin_index = window.workspace;
        const origin = &engine.workspaces[window.workspace];
        if (origin.last_focus == id) origin.last_focus = 0;
        for (&engine.windows) |*other| {
            if (other.id != 0 and other.tab_of == id) {
                other.tab_of = leader.id;
                other.workspace = leader.workspace;
            }
        }
        if (engine.forest.leaf_find(id) != node_none) engine.forest.remove(&origin.root, id);
        window.tab_of = leader.id;
        window.workspace = leader.workspace;
        window.zoom = .none;
        window.sticky = false;
        engine.membership_sync(window);
        if (was_focused) {
            // The window in use is the tab that shows, and the group comes to it.
            engine.tab_promote(window);
            if (window.workspace != origin_index) engine.window_move(window, origin_index);
        }
    }

    // Frames.

    fn frame_send(engine: *Engine, window: *Window) void {
        assert(window.desired_valid);
        assert(window.managed());
        const app = &engine.apps[window.app];
        // Held back while the application is not answering, and while the windows that
        // were already open are still being reported (see on_adoption).
        if (engine.adopting or engine.now_ms < app.suspended_until_ms) {
            window.set_pending = true;
            return;
        }
        window.set_pending = false;
        window.sets_total += 1;
        engine.stats.frames_set += 1;
        engine.emit(
            .{ .set_frame = .{ .id = window.id, .pid = window.pid, .frame = window.desired } },
        );
    }

    fn on_frame_applied(engine: *Engine, id: WindowId, frame: Rect) void {
        const window = engine.window_find(id) orelse return;
        window.actual = frame;
        engine.apps[window.app].backoff_ms = 0;
        if (!window.desired_valid or frame.eql(window.desired)) return;
        if (engine.lifted(window, frame)) return;
        if (window.attempts >= attempts_max) return; // It has a mind of its own; accept it.
        window.attempts += 1;
        engine.stats.frames_retried += 1;
        engine.frame_send(window);
    }

    /// macOS keeps the title bar of every window reachable: a frame that would put it
    /// below the screen comes back higher, by an amount that depends on the application.
    /// That is the answer of the OS, not something to ask for twice. A parked window
    /// remembers the lift, so the next time it is parked it goes straight there.
    fn lifted(engine: *Engine, window: *Window, frame: Rect) bool {
        const desired = window.desired;
        if (frame.x != desired.x or frame.w != desired.w or frame.h != desired.h) return false;
        if (frame.y >= desired.y) return false;
        const lift = desired.y - frame.y;
        if (!engine.workspace_visible(window.workspace)) {
            if (window.park_lift + lift > park_lift_max) return false;
            window.park_lift += lift;
        } else if (window.mode == .floating and window.zoom == .none) {
            window.float_rect.y = frame.y;
        } else {
            return false;
        }
        window.desired.y = frame.y;
        engine.stats.frames_lifted += 1;
        return true;
    }

    fn on_frame_changed(engine: *Engine, id: WindowId, frame: Rect, by_user: bool) void {
        const window = engine.window_find(id) orelse return;
        if (frame.eql(window.actual)) return; // The echo of a frame we set.
        window.actual = frame;
        if (!window.desired_valid) {
            if (window.mode == .floating and window.managed()) window.float_rect = frame;
            return;
        }
        if (frame.eql(window.desired) or window.frozen) return;
        const visible = engine.workspace_visible(window.workspace);
        if (visible and window.zoom == .none and window.mode == .floating) {
            engine.float_adopt(window, frame);
            return;
        }
        if (visible and window.zoom == .none and by_user) {
            engine.user_adjust(window, frame);
            window.desired_valid = false;
            return;
        }
        // The application moved itself, possibly mid-animation. Look again once it has been
        // still for a while; every further move pushes the check back.
        window.recheck_at_ms = engine.now_ms + settle_ms;
    }

    /// Floating windows go where the user or the application puts them, including onto
    /// another monitor. We never answer such a move with a move of our own: that is how
    /// window managers end up in a tug of war with an application.
    fn float_adopt(engine: *Engine, window: *Window, frame: Rect) void {
        assert(window.mode == .floating);
        window.float_rect = frame;
        window.desired = frame;
        const monitor = engine.monitor_at(frame.center_x(), frame.center_y()) orelse return;
        if (monitor == engine.workspace_monitor(window.workspace)) return;
        engine.window_move(window, engine.monitors[monitor].workspace);
        window.float_rect = frame;
        if (engine.focused_window == window.id) engine.focused_monitor_follow(window);
    }

    fn monitor_at(engine: *const Engine, x: i32, y: i32) ?u8 {
        for (engine.monitors[0..engine.monitors_count], 0..) |*monitor, index| {
            if (monitor.frame.contains_point(x, y)) return @intCast(index);
        }
        return null;
    }

    /// Brings a floating window that is stranded off its monitor back to the middle of it.
    /// Only called when we changed something ourselves (monitors, workspace), never in
    /// response to the window moving.
    fn float_rescue(engine: *Engine, window: *Window) void {
        if (engine.monitors_count == 0 or window.mode != .floating) return;
        const visible = engine.monitors[engine.workspace_monitor(window.workspace)].visible;
        if (window.float_rect.intersects(visible)) return;
        const w = @min(window.float_rect.w, visible.w);
        const h = @min(window.float_rect.h, visible.h);
        window.float_rect = .{
            .x = visible.x + @divTrunc(visible.w - w, 2),
            .y = visible.y + @divTrunc(visible.h - h, 2),
            .w = w,
            .h = h,
        };
    }

    /// A floating window that a command of ours carried onto another monitor joins the
    /// workspace shown there, as one that the user dragged over does. Carried off every
    /// monitor, it comes back to the middle of its own instead of being lost.
    fn float_settle(engine: *Engine, window: *Window) void {
        assert(window.mode == .floating);
        const rect = window.float_rect;
        const monitor = engine.monitor_at(rect.center_x(), rect.center_y()) orelse {
            return engine.float_rescue(window);
        };
        if (monitor == engine.workspace_monitor(window.workspace)) return;
        engine.window_move(window, engine.monitors[monitor].workspace);
        window.float_rect = rect;
        if (engine.focused_window == window.id) engine.focused_monitor_follow(window);
    }

    /// The user dragged or resized a tiled window with the mouse.
    fn user_adjust(engine: *Engine, window: *Window, frame: Rect) void {
        assert(window.in_layout());
        const leaf = engine.forest.leaf_find(window.id);
        const old = window.desired;
        if (frame.same_size(old)) {
            // Dropped on another tiled window: trade places with it.
            const x = frame.center_x();
            const y = frame.center_y();
            const target = engine.window_at(x, y, window) orelse {
                return engine.tile_drop_elsewhere(window, x, y);
            };
            if (target.workspace == window.workspace) {
                engine.forest.swap_windows(leaf, engine.forest.leaf_find(target.id));
            } else {
                engine.workspaces[target.workspace].last_focus = target.id;
                engine.window_move(window, target.workspace);
                if (engine.focused_window == window.id) engine.focused_monitor_follow(window);
            }
            return;
        }
        const gap = engine.gap_inner(window.workspace);
        const forest = &engine.forest;
        if (frame.x != old.x) _ = forest.resize_edge(leaf, .west, frame.x - old.x, gap);
        if (frame.right() != old.right()) {
            _ = forest.resize_edge(leaf, .east, frame.right() - old.right(), gap);
        }
        if (frame.y != old.y) _ = forest.resize_edge(leaf, .north, frame.y - old.y, gap);
        if (frame.bottom() != old.bottom()) {
            _ = forest.resize_edge(leaf, .south, frame.bottom() - old.bottom(), gap);
        }
    }

    /// A tile dropped where no other tile is. On another monitor, whose workspace has no
    /// tile there, the window joins that workspace; on its own monitor it snaps back.
    fn tile_drop_elsewhere(engine: *Engine, window: *Window, x: i32, y: i32) void {
        assert(window.in_layout());
        const monitor = engine.monitor_at(x, y) orelse return;
        if (monitor == engine.workspace_monitor(window.workspace)) return;
        engine.window_move(window, engine.monitors[monitor].workspace);
        if (engine.focused_window == window.id) engine.focused_monitor_follow(window);
    }

    /// The tiled window on a visible workspace whose cell contains the point.
    fn window_at(engine: *Engine, x: i32, y: i32, except: *const Window) ?*Window {
        for (&engine.windows) |*window| {
            if (window.id == 0 or window == except or !window.in_layout()) continue;
            if (!engine.workspace_visible(window.workspace)) continue;
            const leaf = engine.forest.leaf_find(window.id);
            if (engine.forest.nodes[leaf].rect.contains_point(x, y)) return window;
        }
        return null;
    }

    fn on_tick(engine: *Engine) void {
        var expired: u32 = 0;
        while (expired < engine.focus_pending_count) : (expired += 1) {
            if (engine.focus_pending[expired].deadline_ms > engine.now_ms) break;
        }
        if (expired > 0) {
            // The OS never confirmed a focus request. Ask where focus really is.
            engine.focus_pending_drop(expired);
            engine.emit(.query_focus);
        }
        for (&engine.windows) |*window| {
            if (window.id == 0) continue;
            const until_ms = window.float_return_until_ms;
            if (until_ms != 0 and until_ms <= engine.now_ms) float_return(window);
            if (window.recheck_at_ms == 0) continue;
            if (window.recheck_at_ms <= engine.now_ms) engine.recheck(window);
        }
        for (&engine.apps, 0..) |*app, index| {
            if (app.pid == 0 or app.suspended_until_ms == 0) continue;
            if (app.suspended_until_ms > engine.now_ms) continue;
            app.suspended_until_ms = 0;
            for (&engine.windows) |*window| {
                if (window.id == 0 or window.app != index or !window.set_pending) continue;
                window.set_pending = false;
                if (window.desired_valid and window.managed()) engine.frame_send(window);
            }
        }
    }

    fn recheck(engine: *Engine, window: *Window) void {
        window.recheck_at_ms = 0;
        if (!window.desired_valid or window.frozen) return;
        if (window.actual.eql(window.desired)) return;
        if (engine.now_ms - window.drift_since_ms > drift_window_ms) {
            window.drift_since_ms = engine.now_ms;
            window.drift_count = 0;
        }
        window.drift_count += 1;
        if (window.drift_count > drift_max) {
            engine.give_up(window);
            return;
        }
        window.attempts = 0;
        engine.stats.frames_corrected += 1;
        engine.frame_send(window);
    }

    /// The window will not stay where we put it. Stop fighting: float it if it is a visible
    /// tile, otherwise leave it alone until its target changes.
    fn give_up(engine: *Engine, window: *Window) void {
        window.drift_count = 0;
        const visible = engine.workspace_visible(window.workspace);
        if (visible and window.in_layout() and window.zoom == .none) {
            window.auto_floated = true;
            engine.stats.windows_auto_floated += 1;
            engine.mode_set(window, .floating);
            // It floats where it insists on being, not where it was asked to go.
            window.float_rect = window.actual;
            return;
        }
        window.frozen = true;
    }

    /// Where a hidden window waits: past a bottom corner of its monitor, with one pixel
    /// left on screen because macOS refuses to move a window fully off screen. Of the two
    /// corners, the one that shows less of the window on the other monitors wins. When
    /// another monitor lies under both corners, the window waits beside its monitor at
    /// the top instead, if less of it shows from there.
    fn park_rect(engine: *const Engine, monitor_index: u8, window: *const Window) Rect {
        const frame = engine.monitors[monitor_index].frame;
        const y = frame.bottom() - 1 - window.park_lift;
        const top = engine.monitors[monitor_index].visible.y;
        // Keep the size it was parked with, so a parked window is never asked twice. A
        // tile can sit at the very height of a parking spot, so the side has to match as
        // well: taking the tile's size for the parked one would leave a window that
        // refuses to be that small in view.
        const desired = window.desired;
        const at_side = desired.x == frame.right() - 1 or desired.right() - 1 == frame.x;
        const parked = window.desired_valid and at_side and (desired.y == y or desired.y == top);
        const w = if (parked) desired.w else window.actual.w;
        const h = if (parked) desired.h else window.actual.h;
        const spots = [4]Rect{
            .{ .x = frame.right() - 1, .y = y, .w = w, .h = h },
            .{ .x = frame.x - w + 1, .y = y, .w = w, .h = h },
            .{ .x = frame.right() - 1, .y = top, .w = w, .h = h },
            .{ .x = frame.x - w + 1, .y = top, .w = w, .h = h },
        };
        // The first spot wins a tie, so nothing changes where a corner is free.
        var best = spots[0];
        var best_shown = engine.exposure(best, monitor_index);
        for (spots[1..]) |spot| {
            const shown = engine.exposure(spot, monitor_index);
            if (shown >= best_shown) continue;
            best = spot;
            best_shown = shown;
        }
        return best;
    }

    /// How much of the rect shows on monitors other than the given one, in pixels.
    fn exposure(engine: *const Engine, rect: Rect, except: u8) i64 {
        var total: i64 = 0;
        for (engine.monitors[0..engine.monitors_count], 0..) |*monitor, index| {
            if (index == except) continue;
            const w = rect.overlap(monitor.frame, .x);
            const h = rect.overlap(monitor.frame, .y);
            if (w > 0 and h > 0) total += @as(i64, w) * h;
        }
        return total;
    }

    /// Where a window is meant to be. No window is ever asked to have no size: on a
    /// display smaller than its gaps, or with more tiles than pixels, a tile is one pixel
    /// and lies over its neighbours.
    fn window_target(engine: *const Engine, window: *const Window) ?Rect {
        if (!window.managed() or window.float_return_until_ms != 0) return null;
        const monitor_index = engine.workspace_monitor(window.workspace);
        const monitor = &engine.monitors[monitor_index];
        if (monitor.workspace != window.workspace) {
            return rect_sized(engine.park_rect(monitor_index, window));
        }
        const area = engine.workspace_rect(monitor_index);
        if (window.zoom == .fullscreen) return tile_sized(area, area);
        if (window.mode == .floating) return rect_sized(window.float_rect);
        const leaf = engine.forest.leaf_find(window.id);
        assert(leaf != node_none);
        if (engine.workspaces[window.workspace].accordion) return tile_sized(area, area);
        const node = &engine.forest.nodes[leaf];
        if (window.zoom == .parent and node.parent != node_none) {
            return tile_sized(engine.forest.nodes[node.parent].rect, area);
        }
        return tile_sized(node.rect, area);
    }

    fn rect_sized(rect: Rect) Rect {
        return .{ .x = rect.x, .y = rect.y, .w = @max(1, rect.w), .h = @max(1, rect.h) };
    }

    /// A tile that is given its one pixel stays inside the area it is a part of. A tile
    /// that has a size is returned as it is.
    fn tile_sized(rect: Rect, area: Rect) Rect {
        const w = @max(1, rect.w);
        const h = @max(1, rect.h);
        return .{
            .x = @max(area.x, @min(rect.x, area.right() - w)),
            .y = @max(area.y, @min(rect.y, area.bottom() - h)),
            .w = w,
            .h = h,
        };
    }

    /// Recomputes every target frame and sends the ones that changed. Idempotent.
    fn arrange(engine: *Engine) void {
        if (engine.monitors_count == 0) return engine.arrange_asleep();
        for (engine.monitors[0..engine.monitors_count], 0..) |*monitor, index| {
            const root = engine.workspaces[monitor.workspace].root;
            const area = engine.workspace_rect(@intCast(index));
            engine.forest.layout(root, area, engine.gap_inner(monitor.workspace));
        }
        // Windows coming on screen go first; that is the latency the user sees.
        for ([2]bool{ true, false }) |visible_pass| {
            for (&engine.windows) |*window| {
                if (window.id == 0) continue;
                if (engine.workspace_visible(window.workspace) != visible_pass) continue;
                engine.arrange_window(window);
            }
        }
    }

    /// With every display asleep nothing is placed. A window that left our care in the
    /// meantime (minimized, native fullscreen, now a tab) is still not ours to move, and
    /// one whose place is no longer known has no frame to wait for: what such a window
    /// was owed is forgotten, as it is when the displays are awake.
    fn arrange_asleep(engine: *Engine) void {
        assert(engine.monitors_count == 0);
        for (&engine.windows) |*window| {
            if (window.id == 0) continue;
            if (!window.managed()) window.desired_valid = false;
            if (window.desired_valid) continue;
            window.set_pending = false;
            window.recheck_at_ms = 0;
        }
    }

    fn arrange_window(engine: *Engine, window: *Window) void {
        const target = engine.window_target(window) orelse {
            window.desired_valid = false;
            window.set_pending = false;
            window.recheck_at_ms = 0;
            return;
        };
        if (window.desired_valid and window.desired.eql(target)) return;
        window.desired = target;
        window.desired_valid = true;
        window.attempts = 0;
        window.recheck_at_ms = 0;
        window.frozen = false;
        window.set_pending = false;
        if (window.actual.eql(target)) return;
        engine.frame_send(window);
    }

    // Commands.

    fn focused(engine: *Engine) ?*Window {
        return engine.window_find(engine.focused_window);
    }

    fn on_command(engine: *Engine, cmd: Command) void {
        switch (cmd) {
            .query => |request| return engine.query(request),
            .exec => |span| return engine.emit(.{ .exec = span }),
            .reload => return engine.emit(.reload),
            .quit => return engine.command_quit(),
            // Binding modes live in the shell: they choose which hot keys are registered.
            .mode => return,
            else => {},
        }
        if (engine.monitors_count == 0) return;
        if (engine.command_targeted(cmd)) return;
        switch (cmd) {
            .focus => |direction| engine.command_focus(direction),
            .swap => |direction| engine.command_swap(direction),
            .warp => |direction| engine.command_warp(direction),
            .insert => |direction| engine.insert_set(direction, 0),
            .resize_edge => |resize| engine.command_resize(resize.edge, resize.delta),
            .resize_dimension => |resize| {
                const edge: Direction = if (resize.dimension == .width) .east else .south;
                engine.command_resize(edge, resize.delta);
            },
            .balance => engine.forest.balance(engine.workspaces[engine.workspace_current()].root),
            .retile => engine.command_retile(),
            .rotate => |degrees| {
                engine.forest.rotate(engine.workspaces[engine.workspace_current()].root, degrees);
            },
            .mirror => |axis| {
                // yabai names the axis the tree is flipped over, not the direction windows move.
                const across: geometry.Axis = if (axis == .y_axis) .x else .y;
                engine.forest.mirror(engine.workspaces[engine.workspace_current()].root, across);
            },
            .toggle => |what| engine.command_toggle(what),
            .workspace => |target| {
                if (engine.workspace_resolve(target)) |workspace| engine.workspace_focus(workspace);
            },
            .send => |move| {
                const window = engine.focused() orelse return;
                const workspace = engine.workspace_resolve(move.target) orelse return;
                engine.window_send(window, workspace, move.follow);
            },
            .focus_monitor => |target| {
                const monitor = engine.monitor_resolve(target) orelse return;
                engine.workspace_focus(engine.monitors[monitor].workspace);
            },
            .send_monitor => |move| {
                const window = engine.focused() orelse return;
                const monitor = engine.monitor_resolve(move.target) orelse return;
                engine.window_send(window, engine.monitors[monitor].workspace, move.follow);
            },
            .grid => |grid| engine.command_grid(grid),
            .move_floating => |delta| {
                const window = engine.focused() orelse return;
                if (window.mode != .floating or window.zoom != .none) return;
                window.float_rect.x += std.math.clamp(delta.dx, -nudge_max, nudge_max);
                window.float_rect.y += std.math.clamp(delta.dy, -nudge_max, nudge_max);
                engine.float_settle(window);
            },
            .layout => |layout| engine.command_layout(layout),
            .close => {
                const window = engine.focused() orelse return;
                engine.emit(.{ .close_window = .{ .id = window.id, .pid = window.pid } });
            },
            .close_others => engine.command_close_others(),
            else => unreachable,
        }
    }

    /// The commands that name the windows they act on, by id or by label, and the ones
    /// that take options. Most of them are modelled on Rex's (see docs/REX.md).
    fn command_targeted(engine: *Engine, cmd: Command) bool {
        switch (cmd) {
            .focus_wrap => |direction| engine.command_focus_wrap(direction),
            .focus_cycle => |cycle| engine.command_focus_cycle(cycle.forward, cycle.wrap),
            .focus_window => |ref| {
                if (engine.window_resolve(ref)) |window| engine.window_focus(window);
            },
            .swap_windows => |pair| engine.command_swap_windows(pair.a, pair.b),
            .move => |move| engine.command_move(move),
            .insert_ratio => |insert| engine.insert_set(insert.direction, insert.percent),
            .resize_ratio => |percent| {
                const window = engine.focused() orelse return true;
                if (!window.in_layout() or window.zoom != .none) return true;
                engine.forest.share_set(engine.forest.leaf_find(window.id), percent);
            },
            .zoom => |zoom| engine.command_zoom(zoom.window, zoom.state),
            .float => |float| engine.command_float(float.window, float.bounds),
            .tile => |ref| {
                const window = engine.window_resolve(ref) orelse return true;
                if (!window.managed()) {
                    engine.fail("conflict: window {d} cannot be tiled", .{window.id});
                    return true;
                }
                window.mode_by_user = true;
                window.auto_floated = false;
                engine.mode_set(window, .tiled);
            },
            .close_window => |ref| {
                const window = engine.window_resolve(ref) orelse return true;
                engine.emit(.{ .close_window = .{ .id = window.id, .pid = window.pid } });
            },
            .label => |named| {
                if (engine.window_resolve(named.window)) |window| window.label = named.label;
            },
            .label_workspace => |label| {
                engine.workspaces[engine.workspace_current()].label = label;
            },
            else => return false,
        }
        return true;
    }

    fn insert_set(engine: *Engine, direction: Direction, percent: u8) void {
        const workspace = &engine.workspaces[engine.workspace_current()];
        workspace.insert = direction;
        workspace.insert_percent = percent;
    }

    /// Answers a command that could not be done. The words before the first colon are
    /// what the command line turns into its exit status.
    fn fail(engine: *Engine, comptime format: []const u8, args: anytype) void {
        var text = stdx.Text.init(&engine.reply_buffer);
        text.print("error: " ++ format ++ "\n", args);
        engine.reply_len = text.len;
    }

    fn window_resolve(engine: *Engine, ref: command.WindowRef) ?*Window {
        switch (ref) {
            .focused => {
                if (engine.focused()) |window| return window;
                engine.fail("not-found: no window has focus", .{});
            },
            .id => |id| {
                if (engine.window_find(id)) |window| return window;
                engine.fail("not-found: no window {d}", .{id});
            },
            .label => |label| {
                var found: ?*Window = null;
                var count: u32 = 0;
                for (&engine.windows) |*window| {
                    if (window.id == 0 or window.label.len == 0) continue;
                    if (!stdx.eql_ignore_case(window.label.slice(), label.slice())) continue;
                    found = window;
                    count += 1;
                }
                if (count == 1) return found;
                if (count == 0) {
                    engine.fail("not-found: no window is labelled {s}", .{label.slice()});
                } else {
                    const name = label.slice();
                    engine.fail("ambiguous: {d} windows are labelled {s}", .{ count, name });
                }
            },
        }
        return null;
    }

    /// Focuses a window wherever it is, showing its workspace first if it is hidden.
    fn window_focus(engine: *Engine, window: *Window) void {
        if (!window.focusable()) {
            return engine.fail("conflict: window {d} cannot take focus", .{window.id});
        }
        if (engine.workspace_visible(window.workspace)) return engine.focus_request(window);
        engine.workspaces[window.workspace].last_focus = window.id;
        engine.workspace_focus(window.workspace);
    }

    /// With nothing that way, focus goes around to the far end of the other side. In an
    /// accordion it goes around the stack, also when a monitor lies that way: the stack is
    /// one place on the screen, and going through it is a cycle.
    fn command_focus_wrap(engine: *Engine, direction: Direction) void {
        const window = engine.focused() orelse return engine.command_focus(direction);
        const from = engine.workspace_monitor(window.workspace);
        const stacked = engine.workspaces[window.workspace].accordion and window.in_layout();
        const onward = engine.neighbor(window, direction, false) != null or
            (!stacked and engine.monitor_neighbor(from, direction) != null);
        if (onward) return engine.command_focus(direction);
        var target = window;
        var steps: u32 = 0;
        while (engine.neighbor(target, direction.opposite(), false)) |next| : (steps += 1) {
            if (steps == windows_max) break;
            target = next;
        }
        if (target != window) engine.focus_request(target);
    }

    /// The windows of a workspace that can take focus, in layout order: the tiles, each
    /// split's first half before its second, and then the floating windows.
    fn layout_order(engine: *Engine, workspace: u8, order: *[windows_max]WindowId) u32 {
        var count: u32 = 0;
        const root = engine.workspaces[workspace].root;
        var leaf = engine.forest.leaf_first(root);
        while (leaf != node_none) : (leaf = engine.forest.leaf_next(root, leaf)) {
            assert(count < windows_max);
            order[count] = engine.forest.nodes[leaf].window;
            count += 1;
        }
        for (&engine.windows) |*window| {
            if (window.id == 0 or window.workspace != workspace) continue;
            if (window.in_layout() or !window.focusable() or window.fullscreen) continue;
            assert(count < windows_max);
            order[count] = window.id;
            count += 1;
        }
        return count;
    }

    fn command_focus_cycle(engine: *Engine, forward: bool, wrap: bool) void {
        var order: [windows_max]WindowId = undefined;
        const count = engine.layout_order(engine.workspace_current(), &order);
        if (count == 0) return;
        var at: u32 = 0;
        while (at < count and order[at] != engine.focused_window) at += 1;
        var target: u32 = if (forward) 0 else count - 1;
        if (at < count) {
            const edge = if (forward) at + 1 == count else at == 0;
            if (edge and !wrap) return;
            if (!edge) target = if (forward) at + 1 else at - 1;
        }
        engine.focus_request(engine.window_find(order[target]).?);
    }

    /// Only the two windows trade places; every split and its size stays as it is.
    fn command_swap_windows(engine: *Engine, one: WindowRef, other: WindowRef) void {
        const a = engine.window_resolve(one) orelse return;
        const b = engine.window_resolve(other) orelse return;
        if (a == b) return engine.fail("bad-request: a window cannot swap with itself", .{});
        if (!a.in_layout() or !b.in_layout()) {
            return engine.fail("conflict: both windows must be tiled", .{});
        }
        if (a.workspace != b.workspace) {
            return engine.fail("conflict: the windows are on different workspaces", .{});
        }
        const forest = &engine.forest;
        forest.swap_windows(forest.leaf_find(a.id), forest.leaf_find(b.id));
    }

    /// Puts a window in a new split beside another one, on whichever workspace that is.
    /// Focus follows the window if it had it.
    fn command_move(engine: *Engine, move: command.MoveBeside) void {
        const window = engine.window_resolve(move.window) orelse return;
        const anchor = engine.window_resolve(move.anchor) orelse return;
        if (window == anchor) {
            return engine.fail("bad-request: a window cannot be put beside itself", .{});
        }
        if (!anchor.in_layout()) return engine.fail("conflict: the anchor must be tiled", .{});
        if (!window.managed()) {
            return engine.fail("conflict: window {d} cannot be tiled", .{window.id});
        }
        // The move says where the window goes. Joining the layout on the way must not
        // spend the place that insert keeps for the next new window.
        const kept = engine.workspaces[anchor.workspace];
        if (window.workspace != anchor.workspace) {
            engine.window_send(window, anchor.workspace, engine.focused_window == window.id);
        }
        if (window.mode != .tiled) {
            window.mode_by_user = true;
            window.auto_floated = false;
            engine.mode_set(window, .tiled);
        }
        assert(window.in_layout());
        assert(window.workspace == anchor.workspace);
        const forest = &engine.forest;
        const workspace = &engine.workspaces[window.workspace];
        workspace.insert = kept.insert;
        workspace.insert_percent = kept.insert_percent;
        forest.remove(&workspace.root, window.id);
        const beside = forest.leaf_find(anchor.id);
        forest.insert(&workspace.root, beside, window.id, .{ .side = move.side });
        forest.share_set(forest.leaf_find(window.id), move.percent);
        window.zoom = .none;
        anchor.zoom = .none;
    }

    /// Zoom fills the workspace with one window and leaves the layout as it is.
    fn command_zoom(engine: *Engine, ref: command.WindowRef, state: command.Switch) void {
        const window = engine.window_resolve(ref) orelse return;
        if (!window.managed()) {
            return engine.fail("conflict: window {d} cannot be zoomed", .{window.id});
        }
        if (window.id != engine.focused_window) engine.window_focus(window);
        const zoomed = switch (state) {
            .toggle => window.zoom != .fullscreen,
            .on => true,
            .off => false,
        };
        window.zoom = if (zoomed) .fullscreen else .none;
    }

    /// Takes a window out of the layout, to where it is or to the bounds given as
    /// thousandths of the workspace.
    fn command_float(engine: *Engine, ref: command.WindowRef, bounds: ?command.Bounds) void {
        const window = engine.window_resolve(ref) orelse return;
        if (!window.managed()) {
            return engine.fail("conflict: window {d} cannot be floated", .{window.id});
        }
        window.mode_by_user = true;
        window.auto_floated = false;
        engine.mode_set(window, .floating);
        const part = bounds orelse return;
        const area = engine.workspace_rect(engine.workspace_monitor(window.workspace));
        window.zoom = .none;
        window.float_rect = Rect.init(
            area.x + @divTrunc(area.w * part.x, 1000),
            area.y + @divTrunc(area.h * part.y, 1000),
            @max(1, @divTrunc(area.w * part.w, 1000)),
            @max(1, @divTrunc(area.h * part.h, 1000)),
        );
    }

    fn edge_distance(origin: Rect, rect: Rect, direction: Direction) i32 {
        return switch (direction) {
            .west => origin.x - rect.right(),
            .east => rect.x - origin.right(),
            .north => origin.y - rect.bottom(),
            .south => rect.y - origin.bottom(),
        };
    }

    fn center_distance(origin: Rect, rect: Rect, direction: Direction) i32 {
        return switch (direction) {
            .west => origin.center_x() - rect.center_x(),
            .east => rect.center_x() - origin.center_x(),
            .north => origin.center_y() - rect.center_y(),
            .south => rect.center_y() - origin.center_y(),
        };
    }

    fn nav_rect(engine: *const Engine, window: *const Window) Rect {
        if (!window.in_layout()) return window.float_rect;
        return engine.forest.nodes[engine.forest.leaf_find(window.id)].rect;
    }

    /// The closest window in a direction on the same workspace. Ties go to the window that
    /// had focus most recently.
    fn neighbor(engine: *Engine, window: *Window, direction: Direction, tiled_only: bool) ?*Window {
        if (engine.workspaces[window.workspace].accordion and window.in_layout()) {
            return engine.accordion_neighbor(window, direction);
        }
        const origin = engine.nav_rect(window);
        const across: geometry.Axis = if (direction.axis() == .x) .y else .x;
        var best: ?*Window = null;
        var best_distance: i32 = std.math.maxInt(i32);
        for (&engine.windows) |*candidate| {
            if (candidate.id == 0 or candidate == window) continue;
            if (candidate.workspace != window.workspace) continue;
            if (!candidate.focusable() or candidate.fullscreen) continue;
            if (tiled_only and !candidate.in_layout()) continue;
            const rect = engine.nav_rect(candidate);
            const tiles = candidate.in_layout() and window.in_layout();
            const distance = if (tiles)
                edge_distance(origin, rect, direction)
            else
                center_distance(origin, rect, direction) - 1;
            if (distance < 0) continue;
            if (tiles and origin.overlap(rect, across) <= 0) continue;
            const closer = distance < best_distance;
            const tie = distance == best_distance and candidate.focus_seq > best.?.focus_seq;
            if (best == null or closer or tie) {
                best = candidate;
                best_distance = distance;
            }
        }
        return best;
    }

    /// In an accordion every tile has the same place, so a direction is a step through the
    /// stack in layout order: west and north to the one before, east and south to the next.
    fn accordion_neighbor(engine: *Engine, window: *Window, direction: Direction) ?*Window {
        const forest = &engine.forest;
        const root = engine.workspaces[window.workspace].root;
        const leaf = forest.leaf_find(window.id);
        assert(leaf != node_none);
        var target = node_none;
        if (direction.is_leading()) {
            var before = forest.leaf_first(root);
            var steps: u32 = 0;
            while (before != leaf) : (steps += 1) {
                assert(steps < tree.nodes_max);
                target = before;
                before = forest.leaf_next(root, before);
            }
        } else {
            target = forest.leaf_next(root, leaf);
        }
        if (target == node_none) return null;
        return engine.window_find(forest.nodes[target].window).?;
    }

    fn monitor_neighbor(engine: *const Engine, from: u8, direction: Direction) ?u8 {
        const origin = engine.monitors[from].frame;
        const across: geometry.Axis = if (direction.axis() == .x) .y else .x;
        var best: ?u8 = null;
        var best_distance: i32 = std.math.maxInt(i32);
        for (engine.monitors[0..engine.monitors_count], 0..) |*monitor, index| {
            if (index == from) continue;
            const distance = edge_distance(origin, monitor.frame, direction);
            if (distance < 0 or origin.overlap(monitor.frame, across) <= 0) continue;
            if (distance < best_distance) {
                best = @intCast(index);
                best_distance = distance;
            }
        }
        return best;
    }

    fn command_focus(engine: *Engine, direction: Direction) void {
        const window = engine.focused() orelse {
            if (engine.monitor_neighbor(engine.focused_monitor, direction)) |monitor| {
                engine.workspace_focus(engine.monitors[monitor].workspace);
            } else {
                engine.workspace_focus(engine.workspace_current());
            }
            return;
        };
        if (engine.neighbor(window, direction, false)) |target| {
            engine.focus_request(target);
            return;
        }
        const from = engine.workspace_monitor(window.workspace);
        if (engine.monitor_neighbor(from, direction)) |monitor| {
            engine.workspace_focus(engine.monitors[monitor].workspace);
        }
    }

    /// Carries the window over to the monitor in that direction, and focus with it.
    fn window_cross_monitor(engine: *Engine, window: *Window, direction: Direction) void {
        const from = engine.workspace_monitor(window.workspace);
        const monitor = engine.monitor_neighbor(from, direction) orelse return;
        engine.window_send(window, engine.monitors[monitor].workspace, true);
    }

    fn command_swap(engine: *Engine, direction: Direction) void {
        const window = engine.focused() orelse return;
        if (!window.in_layout()) return;
        const target = engine.neighbor(window, direction, true) orelse {
            return engine.window_cross_monitor(window, direction);
        };
        const forest = &engine.forest;
        forest.swap_windows(forest.leaf_find(window.id), forest.leaf_find(target.id));
    }

    fn command_warp(engine: *Engine, direction: Direction) void {
        const window = engine.focused() orelse return;
        if (!window.in_layout()) return;
        const target = engine.neighbor(window, direction, true) orelse {
            const from = engine.workspace_monitor(window.workspace);
            if (engine.monitor_neighbor(from, direction) != null) {
                return engine.window_cross_monitor(window, direction);
            }
            return engine.window_restack(window, direction);
        };
        const forest = &engine.forest;
        const leaf = forest.leaf_find(window.id);
        const target_leaf = forest.leaf_find(target.id);
        if (forest.nodes[leaf].parent == forest.nodes[target_leaf].parent) {
            forest.swap_windows(leaf, target_leaf);
            return;
        }
        // Move into the neighbour's cell, on the side we came from.
        const workspace = &engine.workspaces[window.workspace];
        forest.remove(&workspace.root, window.id);
        const anchor = forest.leaf_find(target.id);
        forest.insert(&workspace.root, anchor, window.id, .{ .side = direction.opposite() });
    }

    /// With nobody on that side, the window goes there itself: it leaves the nearest split
    /// that runs the other way and becomes one half of a new split with what is left of
    /// it. Of two windows side by side, 'warp south' puts the focused one below the other.
    fn window_restack(engine: *Engine, window: *Window, direction: Direction) void {
        assert(window.in_layout());
        const forest = &engine.forest;
        const workspace = &engine.workspaces[window.workspace];
        const leaf = forest.leaf_find(window.id);
        const across: tree.Split = if (direction.axis() == .x) .rows else .columns;
        var child = leaf;
        var ancestor = forest.nodes[leaf].parent;
        var depth: u32 = 0;
        while (ancestor != node_none and forest.nodes[ancestor].split != across) {
            assert(depth < tree.nodes_max);
            depth += 1;
            child = ancestor;
            ancestor = forest.nodes[ancestor].parent;
        }
        if (ancestor == node_none) return; // Already as far that way as it can be.
        // What is left of the split once the window is gone: the split itself, or the
        // window's sibling when the window was one of its two halves.
        const node = forest.nodes[ancestor];
        const sibling = if (node.first == leaf) node.second else node.first;
        const remains = if (child == leaf) sibling else ancestor;
        forest.remove(&workspace.root, window.id);
        forest.insert_beside(&workspace.root, remains, window.id, direction);
    }

    fn command_resize(engine: *Engine, edge: Direction, delta: i32) void {
        const window = engine.focused() orelse return;
        if (!window.in_layout() or window.zoom != .none) return;
        const leaf = engine.forest.leaf_find(window.id);
        const gap = engine.gap_inner(window.workspace);
        if (engine.forest.resize_edge(leaf, edge, delta, gap)) return;
        // No neighbour on that side: change the size by the same amount on the other side.
        _ = engine.forest.resize_edge(leaf, edge.opposite(), -delta, gap);
    }

    /// The tiles of a workspace in tree order.
    fn tiles_collect(engine: *Engine, workspace_index: u8, order: *[windows_max]WindowId) u32 {
        const root = engine.workspaces[workspace_index].root;
        var count: u32 = 0;
        var leaf = engine.forest.leaf_first(root);
        while (leaf != node_none) : (leaf = engine.forest.leaf_next(root, leaf)) {
            assert(count < windows_max);
            order[count] = engine.forest.nodes[leaf].window;
            count += 1;
        }
        return count;
    }

    /// Builds the workspace tree from scratch with the tiles in the order given.
    fn workspace_rebuild(engine: *Engine, workspace_index: u8, order: []const WindowId) void {
        const workspace = &engine.workspaces[workspace_index];
        const area = engine.workspace_rect(engine.workspace_monitor(workspace_index));
        engine.forest.clear(&workspace.root);
        workspace.insert = null;
        workspace.insert_percent = 0;
        for (order) |id| {
            engine.window_find(id).?.zoom = .none;
            const anchor = engine.forest.leaf_last(workspace.root);
            engine.forest.insert(&workspace.root, anchor, id, .auto);
            engine.forest.layout(workspace.root, area, engine.gap_inner(workspace_index));
        }
    }

    /// Rebuilds the workspace tree from scratch, in the current window order.
    fn command_retile(engine: *Engine) void {
        const workspace_index = engine.workspace_current();
        var order: [windows_max]WindowId = undefined;
        const count = engine.tiles_collect(workspace_index, &order);
        engine.workspace_rebuild(workspace_index, order[0..count]);
    }

    fn on_adoption(engine: *Engine, phase: Adoption) void {
        engine.adopting = phase == .begin;
        if (engine.adopting) return;
        var workspace: u8 = 0;
        while (workspace < workspaces_max) : (workspace += 1) {
            if (engine.layout_recall(workspace)) continue;
            if (engine.monitors_count > 0) engine.layout_as_found(workspace);
        }
        engine.memories_spend();
        // One layout for all of them, so that each held frame is for where its window
        // ends up. With every display asleep there is nothing to place, and the frames
        // that were held back still go out: a frame that stays held with nothing to
        // wait for would have the timer fire for ever.
        if (engine.monitors_count > 0) engine.arrange();
        for (&engine.windows) |*window| {
            if (window.id == 0 or !window.set_pending) continue;
            window.set_pending = false;
            if (window.desired_valid and window.managed()) engine.frame_send(window);
        }
    }

    /// The windows were reported application by application. Tile them the way they sit
    /// on screen instead, so that a first start keeps the arrangement it finds.
    fn layout_as_found(engine: *Engine, workspace: u8) void {
        var order: [windows_max]WindowId = undefined;
        const count = engine.tiles_collect(workspace, &order);
        if (count < 2) return;
        engine.reading_sort(order[0..count]);
        engine.workspace_rebuild(workspace, order[0..count]);
    }

    fn reading_sort(engine: *Engine, order: []WindowId) void {
        var index: u32 = 1;
        while (index < order.len) : (index += 1) {
            const id = order[index];
            var at = index;
            while (at > 0 and engine.reads_before(id, order[at - 1])) : (at -= 1) {
                order[at] = order[at - 1];
            }
            order[at] = id;
        }
    }

    /// The tiles that the last window manager left on a workspace, in its layout order.
    /// A window that is ours counts only where it is; one that is not is still counted,
    /// as the layout is shaped by every tile that was in it.
    fn memories_of(engine: *Engine, workspace: u8, out: *[windows_max]WindowMemory) u32 {
        var count: u32 = 0;
        for (engine.memories[0..engine.memories_count]) |memory| {
            if (memory.workspace != workspace or memory.order == 0) continue;
            if (engine.window_find(memory.id)) |window| {
                if (window.workspace != workspace or window.mode != .tiled) continue;
                if (window.tab_of != 0 or window.ignored) continue;
            }
            var at = count;
            while (at > 0 and memory_before(memory, out[at - 1])) : (at -= 1) {
                out[at] = out[at - 1];
            }
            out[at] = memory;
            count += 1;
        }
        return count;
    }

    fn memory_before(a: WindowMemory, b: WindowMemory) bool {
        if (a.order != b.order) return a.order < b.order;
        return a.id < b.id;
    }

    /// Rebuilds the layout of a workspace as the last window manager left it, when it
    /// left word of it. Tiles that are missing (closed, minimized, or their application
    /// is slow to report them) are put in all the same and then taken out with their
    /// place noted, which leaves the others exactly where a window going away would.
    /// Windows that it did not know follow at the end.
    fn layout_recall(engine: *Engine, workspace_index: u8) bool {
        var known: [windows_max]WindowMemory = undefined;
        const known_count = engine.memories_of(workspace_index, &known);
        if (known_count == 0) return false;
        var rest: [windows_max]WindowId = undefined;
        const rest_count = engine.tiles_collect(workspace_index, &rest);
        const workspace = &engine.workspaces[workspace_index];
        const forest = &engine.forest;
        forest.clear(&workspace.root);
        // Every tile takes two nodes at most, and the ones that are ours must all fit.
        assert(forest.free_count / 2 >= rest_count);
        var spare = forest.free_count / 2 - rest_count;
        var last = node_none;
        for (known[0..known_count]) |memory| {
            const window = engine.window_find(memory.id);
            if (window == null or !window.?.in_layout()) {
                if (spare == 0) continue;
                spare -= 1;
            }
            if (last == node_none) {
                forest.insert(&workspace.root, node_none, memory.id, .auto);
            } else {
                // What it split is there by now in a file that is true to a layout.
                const ends = [2]WindowId{ memory.beside, memory.beside_last };
                var target = engine.slot_target(workspace.root, ends);
                if (target == node_none) target = last;
                const below = side_direction(memory.side).axis() == .y;
                const side: Direction = if (below) .south else .east;
                forest.insert_beside(&workspace.root, target, memory.id, side);
                forest.nodes[forest.nodes[target].parent].ratio = memory.ratio;
            }
            last = forest.leaf_find(memory.id);
        }
        engine.layout_append(workspace_index, rest[0..rest_count]);
        engine.layout_prune(workspace_index, known[0..known_count]);
        return true;
    }

    /// Adds the windows that are not in the layout of the workspace yet at its end, in
    /// the order they sit on screen.
    fn layout_append(engine: *Engine, workspace_index: u8, tiles: []WindowId) void {
        const workspace = &engine.workspaces[workspace_index];
        const forest = &engine.forest;
        engine.reading_sort(tiles);
        for (tiles) |id| {
            if (forest.leaf_find(id) != node_none) continue;
            if (engine.monitors_count > 0) {
                const area = engine.workspace_rect(engine.workspace_monitor(workspace_index));
                forest.layout(workspace.root, area, engine.gap_inner(workspace_index));
            }
            forest.insert(&workspace.root, forest.leaf_last(workspace.root), id, .auto);
        }
    }

    /// Takes the tiles that are not there out of a layout that was rebuilt with them.
    /// Each keeps the place it left, for when it turns up or is brought back.
    fn layout_prune(engine: *Engine, workspace_index: u8, known: []const WindowMemory) void {
        const workspace = &engine.workspaces[workspace_index];
        var index = known.len;
        while (index > 0) : (index -= 1) {
            const id = known[index - 1].id;
            if (engine.forest.leaf_find(id) == node_none) continue;
            const window = engine.window_find(id);
            if (window != null and window.?.in_layout()) continue;
            const slot = engine.slot_of(id);
            engine.forest.remove(&workspace.root, id);
            if (window) |gone| {
                engine.slot_keep(gone, slot);
            } else {
                const memory = engine.memory_find(id).?;
                memory.order = 0;
                memory.beside = slot.beside;
                memory.beside_last = slot.beside_last;
                memory.side = @backingInt(slot.side);
                memory.ratio = slot.ratio;
            }
        }
    }

    /// The adoption is over, and what was remembered of the windows that are here is
    /// spent. The rest waits for an application that is slow to report its windows, for
    /// as long as that application runs.
    fn memories_spend(engine: *Engine) void {
        engine.memories_fresh = false;
        if (engine.memories_count == 0) return;
        var focus: ?*Window = null;
        var kept: u32 = 0;
        for (engine.memories[0..engine.memories_count]) |memory| {
            if (engine.window_find(memory.id)) |window| {
                if (memory.focused and window.focusable()) focus = window;
                continue;
            }
            if (engine.app_find(memory.pid) == null) continue;
            engine.memories[kept] = memory;
            kept += 1;
        }
        engine.memories_count = kept;
        if (engine.focused_window == 0) {
            if (focus) |window| {
                // Whatever happened to the displays, the window in use stays in view.
                const shown = engine.monitors_count == 0 or
                    engine.workspace_visible(window.workspace);
                if (!shown) engine.workspace_show(window.workspace);
                engine.focus_state_set(window);
            }
        }
        // This is what we believe, not a request: the keyboard is where the OS has it,
        // and the answer to this question says where that is.
        engine.focus_stale = true;
    }

    /// Reading order of where two windows are: left to right, then top to bottom.
    fn reads_before(engine: *Engine, a: WindowId, b: WindowId) bool {
        const first = engine.window_find(a).?.actual;
        const second = engine.window_find(b).?.actual;
        if (first.x != second.x) return first.x < second.x;
        return first.y < second.y;
    }

    fn command_toggle(engine: *Engine, what: command.Toggle) void {
        const workspace = &engine.workspaces[engine.workspace_current()];
        if (what == .gaps) {
            workspace.gaps_toggled = !workspace.gaps_toggled;
            return;
        }
        if (what == .accordion) {
            workspace.accordion = !workspace.accordion;
            return;
        }
        const window = engine.focused() orelse return;
        if (!window.managed()) return;
        switch (what) {
            .gaps, .accordion => unreachable,
            .split => {
                if (window.in_layout()) {
                    _ = engine.forest.toggle_split(engine.forest.leaf_find(window.id));
                }
            },
            .float => {
                window.mode_by_user = true;
                window.auto_floated = false;
                engine.mode_set(window, if (window.mode == .floating) .tiled else .floating);
            },
            .zoom_parent => {
                if (window.in_layout()) window.zoom =
                    if (window.zoom == .parent) .none else .parent;
            },
            .zoom_fullscreen => {
                window.zoom = if (window.zoom == .fullscreen) .none else .fullscreen;
            },
            .sticky => {
                if (window.sticky) {
                    window.sticky = false;
                } else {
                    engine.mode_set(window, .floating);
                    window.sticky = true;
                }
            },
        }
    }

    fn command_grid(engine: *Engine, grid: command.Grid) void {
        const window = engine.focused() orelse return;
        if (window.mode != .floating or !window.managed()) return;
        const area = engine.workspace_rect(engine.workspace_monitor(window.workspace));
        window.zoom = .none;
        window.float_rect = area.grid(grid.rows, grid.cols, grid.x, grid.y, grid.w, grid.h);
    }

    fn command_layout(engine: *Engine, layout: command.Layout) void {
        const workspace = engine.workspace_current();
        for (&engine.windows) |*window| {
            if (window.id == 0 or window.workspace != workspace or !window.managed()) continue;
            switch (layout) {
                .float => engine.mode_set(window, .floating),
                .bsp => {
                    const tiles = window.kind == .standard and window.resizable and !window.sticky;
                    if (tiles) engine.mode_set(window, .tiled);
                },
            }
        }
    }

    fn command_close_others(engine: *Engine) void {
        const window = engine.focused() orelse return;
        for (&engine.windows) |*other| {
            if (other.id == 0 or other == window or other.workspace != window.workspace) continue;
            if (!other.focusable()) continue;
            engine.emit(.{ .close_window = .{ .id = other.id, .pid = other.pid } });
        }
    }

    /// Brings every parked window back on screen before the manager exits.
    fn command_quit(engine: *Engine) void {
        // Displays that are asleep are still where the windows are.
        const asleep = engine.monitors_count == 0;
        if (asleep) engine.monitors_count = engine.monitors_asleep;
        defer if (asleep) {
            engine.monitors_count = 0;
        };
        for (&engine.windows) |*window| {
            if (window.id == 0 or !window.managed() or engine.monitors_count == 0) continue;
            if (engine.workspace_visible(window.workspace)) continue;
            const monitor = engine.workspace_monitor(window.workspace);
            const area = engine.monitors[monitor].visible;
            var frame = area.grid(8, 8, 1, 1, 6, 6);
            if (window.mode == .floating and window.float_rect.intersects(area)) {
                frame = window.float_rect;
            }
            frame = rect_sized(frame);
            engine.emit(.{ .set_frame = .{ .id = window.id, .pid = window.pid, .frame = frame } });
        }
        engine.emit(.quit);
        engine.stopped = true;
    }

    fn window_send(engine: *Engine, window: *Window, target: u8, follow: bool) void {
        if (target == window.workspace or window.tab_of != 0) return;
        const origin = window.workspace;
        const was_focused = engine.focused_window == window.id;
        window.sticky = false;
        if (engine.workspace_empty(target) and !engine.workspace_visible(target)) {
            const display = engine.monitors[engine.workspace_monitor(origin)].display;
            engine.workspaces[target].display = display;
        }
        engine.window_move(window, target);
        if (follow) {
            engine.workspaces[target].last_focus = window.id;
            engine.workspace_focus(target);
        } else if (was_focused) {
            engine.focused_window = 0;
            engine.focus_after_loss(origin, 0);
        }
    }

    fn workspace_resolve(engine: *Engine, target: command.Target) ?u8 {
        const current = engine.workspace_current();
        switch (target) {
            .index => |number| {
                if (number <= workspaces_max) return number - 1;
                engine.fail("not-found: no workspace {d}", .{number});
                return null;
            },
            .label => |label| {
                for (&engine.workspaces, 0..) |*workspace, index| {
                    const same = stdx.eql_ignore_case(workspace.label.slice(), label.slice());
                    if (same) return @intCast(index);
                }
                engine.fail("not-found: no workspace is labelled {s}", .{label.slice()});
                return null;
            },
            .recent => {
                const recent = engine.recent_workspace;
                return if (recent != current) recent else null;
            },
            .new => {
                var workspace: u8 = 0;
                while (workspace < workspaces_max) : (workspace += 1) {
                    const hidden = !engine.workspace_visible(workspace);
                    if (hidden and engine.workspace_empty(workspace)) return workspace;
                }
                return null;
            },
            .next, .prev => {
                // Cycle through the workspaces that have windows, skipping other monitors'.
                var step_index: u32 = 1;
                while (step_index < workspaces_max) : (step_index += 1) {
                    const offset = if (target == .next) step_index else workspaces_max - step_index;
                    const workspace: u8 = @intCast((current + offset) % workspaces_max);
                    if (engine.workspace_visible(workspace)) continue;
                    // A hidden workspace of another monitor would show over there and take
                    // focus with it, and the way back would skip the one that was left.
                    if (engine.workspace_monitor(workspace) != engine.focused_monitor) continue;
                    if (!engine.workspace_empty(workspace)) return workspace;
                }
                return null;
            },
        }
    }

    fn monitor_resolve(engine: *Engine, target: command.Target) ?u8 {
        const count: u32 = engine.monitors_count;
        assert(count > 0);
        const current: u32 = engine.focused_monitor;
        switch (target) {
            .index => |number| {
                if (number <= count) return number - 1;
                engine.fail("not-found: no monitor {d}", .{number});
                return null;
            },
            .next => return if (count > 1) @intCast((current + 1) % count) else null,
            .prev => return if (count > 1) @intCast((current + count - 1) % count) else null,
            .recent => {
                const recent = engine.recent_monitor;
                return if (recent != current and recent < count) recent else null;
            },
            .new, .label => return null,
        }
    }

    // Queries.

    fn query(engine: *Engine, request: command.QueryRequest) void {
        var text = stdx.Text.init(&engine.reply_buffer);
        const json = request.json;
        switch (request.what) {
            .windows => engine.query_windows(&text, json),
            .workspaces => engine.query_workspaces(&text, json),
            .monitors => engine.query_monitors(&text, json),
            .focus => engine.query_focus(&text, json),
            .stats => engine.query_stats(&text, json),
            .window => {
                const window = engine.window_resolve(request.window) orelse return;
                if (json) {
                    engine.window_json(&text, window);
                    text.append("\n");
                } else {
                    engine.window_describe(&text, window);
                }
            },
            .tree => engine.query_tree(&text, json),
            .bindings => engine.config.bindings_print(&text, json),
            .modes => engine.config.modes_print(&text, json, null),
            .commands => command.reference_print(&text, json),
        }
        if (text.truncated) {
            return engine.fail("too-large: the answer does not fit in {d} bytes", .{reply_max});
        }
        engine.reply_len = text.len;
    }

    fn bool_name(value: bool) []const u8 {
        return if (value) "true" else "false";
    }

    fn window_mode_name(window: *const Window) []const u8 {
        if (window.tab_of != 0) return "tab";
        if (window.ignored) return "ignored";
        if (window.sticky) return "sticky";
        if (window.auto_floated) return "auto-floated";
        return @tagName(window.mode);
    }

    fn query_windows(engine: *Engine, text: *stdx.Text, json: bool) void {
        if (json) text.append("{\"windows\":[");
        var count: u32 = 0;
        for (&engine.windows) |*window| {
            if (window.id == 0) continue;
            if (json) {
                if (count > 0) text.append(",");
                engine.window_json(text, window);
            } else {
                engine.window_line(text, window);
            }
            count += 1;
        }
        if (json) text.append("]}\n");
    }

    /// Columns: id (starred when focused), workspace, mode, frame, label, application, title.
    fn window_line(engine: *Engine, text: *stdx.Text, window: *const Window) void {
        const mark: u8 = if (window.id == engine.focused_window) '*' else ' ';
        const frame = window.actual;
        const label = if (window.label.len > 0) window.label.slice() else "-";
        text.print("{c}{d}\tws={d}\t{s}\t{d},{d} {d}x{d}\t{s}\t{s}\t{s}\n", .{
            mark,                 window.id,
            window.workspace + 1, window_mode_name(window),
            frame.x,              frame.y,
            frame.w,              frame.h,
            label,                engine.apps[window.app].name_slice(),
            window.title_slice(),
        });
    }

    fn window_json(engine: *Engine, text: *stdx.Text, window: *const Window) void {
        const app = &engine.apps[window.app];
        const frame = window.actual;
        const is_focused = window.id == engine.focused_window;
        text.print("{{\"id\":{d},\"focused\":{s},\"workspace\":{d}", .{
            window.id, bool_name(is_focused), window.workspace + 1,
        });
        text.print(",\"mode\":\"{s}\",\"zoom\":\"{s}\"", .{
            window_mode_name(window), @tagName(window.zoom),
        });
        text.print(",\"frame\":{{\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d}}}", .{
            frame.x, frame.y, frame.w, frame.h,
        });
        text.print(",\"pid\":{d},\"tab_of\":{d},\"minimized\":{s},\"fullscreen\":{s}", .{
            window.pid, window.tab_of, bool_name(window.minimized), bool_name(window.fullscreen),
        });
        text.append(",\"label\":");
        text.json_string(window.label.slice());
        text.append(",\"app\":");
        text.json_string(app.name_slice());
        text.append(",\"bundle\":");
        text.json_string(app.bundle_slice());
        text.append(",\"title\":");
        text.json_string(window.title_slice());
        text.append("}");
    }

    /// Everything about one window, one field per line.
    fn window_describe(engine: *Engine, text: *stdx.Text, window: *const Window) void {
        const app = &engine.apps[window.app];
        const frame = window.actual;
        const is_focused = window.id == engine.focused_window;
        text.print("id={d}\nlabel={s}\nfocused={s}\n", .{
            window.id, window.label.slice(), bool_name(is_focused),
        });
        text.print("workspace={d}\nmode={s}\nzoom={s}\n", .{
            window.workspace + 1, window_mode_name(window), @tagName(window.zoom),
        });
        text.print("frame={d},{d} {d}x{d}\n", .{ frame.x, frame.y, frame.w, frame.h });
        text.print("minimized={s}\nfullscreen={s}\ntab_of={d}\npid={d}\n", .{
            bool_name(window.minimized), bool_name(window.fullscreen), window.tab_of, window.pid,
        });
        text.print("app={s}\nbundle={s}\ntitle={s}\n", .{
            app.name_slice(), app.bundle_slice(), window.title_slice(),
        });
    }

    fn workspace_windows(engine: *const Engine, workspace: u8) u32 {
        var count: u32 = 0;
        for (&engine.windows) |*window| {
            if (window.id != 0 and window.workspace == workspace) count += 1;
        }
        return count;
    }

    /// Workspaces that are shown, hold windows or carry a label.
    fn workspace_listed(engine: *const Engine, workspace: u8) bool {
        if (engine.workspace_visible(workspace)) return true;
        if (engine.workspaces[workspace].label.len > 0) return true;
        return engine.workspace_windows(workspace) > 0;
    }

    fn query_workspaces(engine: *Engine, text: *stdx.Text, json: bool) void {
        if (json) text.append("{\"workspaces\":[");
        var listed: u32 = 0;
        var workspace: u8 = 0;
        while (workspace < workspaces_max) : (workspace += 1) {
            if (!engine.workspace_listed(workspace)) continue;
            const count = engine.workspace_windows(workspace);
            const visible = engine.workspace_visible(workspace);
            const current = workspace == engine.workspace_current();
            const label = engine.workspaces[workspace].label.slice();
            const monitor =
                if (engine.monitors_count > 0) engine.workspace_monitor(workspace) + 1 else 0;
            if (json) {
                if (listed > 0) text.append(",");
                text.print("{{\"index\":{d},\"focused\":{s},\"visible\":{s},\"monitor\":{d}", .{
                    workspace + 1, bool_name(current), bool_name(visible), monitor,
                });
                text.print(",\"windows\":{d},\"accordion\":{s},\"label\":", .{
                    count, bool_name(engine.workspaces[workspace].accordion),
                });
                text.json_string(label);
                text.append("}");
            } else {
                const mark: u8 = if (current) '*' else ' ';
                const shown = if (visible) "visible" else "hidden";
                const name = if (label.len > 0) label else "-";
                text.print("{c}{d}\tmonitor={d}\t{s}\twindows={d}\t{s}\n", .{
                    mark, workspace + 1, monitor, shown, count, name,
                });
            }
            listed += 1;
        }
        if (json) text.append("]}\n");
    }

    fn query_monitors(engine: *Engine, text: *stdx.Text, json: bool) void {
        if (json) text.append("{\"monitors\":[");
        for (engine.monitors[0..engine.monitors_count], 0..) |*monitor, index| {
            const current = index == engine.focused_monitor;
            const frame = monitor.visible;
            if (json) {
                if (index > 0) text.append(",");
                text.print("{{\"index\":{d},\"focused\":{s},\"display\":{d},\"workspace\":{d}", .{
                    index + 1, bool_name(current), monitor.display, monitor.workspace + 1,
                });
                text.print(",\"frame\":{{\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d}}}}}", .{
                    frame.x, frame.y, frame.w, frame.h,
                });
            } else {
                const mark: u8 = if (current) '*' else ' ';
                text.print("{c}{d}\tdisplay={d}\t{d},{d} {d}x{d}\tworkspace={d}\n", .{
                    mark,    index + 1,             monitor.display, frame.x, frame.y, frame.w,
                    frame.h, monitor.workspace + 1,
                });
            }
        }
        if (json) text.append("]}\n");
    }

    fn query_focus(engine: *Engine, text: *stdx.Text, json: bool) void {
        const window = engine.focused() orelse {
            if (json) {
                const workspace = @as(u32, engine.workspace_current()) + 1;
                text.print("{{\"window\":null,\"workspace\":{d}}}\n", .{workspace});
            }
            return;
        };
        const app = &engine.apps[window.app];
        if (!json) {
            text.print("{d}\t{s}\t{s}\n", .{ window.id, app.name_slice(), window.title_slice() });
            return;
        }
        text.print("{{\"window\":{d},\"workspace\":{d}", .{ window.id, window.workspace + 1 });
        text.append(",\"app\":");
        text.json_string(app.name_slice());
        text.append(",\"title\":");
        text.json_string(window.title_slice());
        text.append("}\n");
    }

    fn query_stats(engine: *Engine, text: *stdx.Text, json: bool) void {
        const stats = &engine.stats;
        if (json) {
            text.append("{");
            inline for (@typeInfo(Stats).@"struct".field_names) |name| {
                text.print("\"{s}\":{d},", .{ name, @field(stats, name) });
            }
            text.print("\"revision\":{d}}}\n", .{engine.revision});
            return;
        }
        text.print("events={d} effects={d} frames_set={d} frames_retried={d}\n", .{
            stats.events, stats.effects, stats.frames_set, stats.frames_retried,
        });
        text.print("frames_corrected={d} windows_auto_floated={d} windows_dropped={d}\n", .{
            stats.frames_corrected, stats.windows_auto_floated, stats.windows_dropped,
        });
        text.print("focus_rejected={d} apps_suspended={d} frames_lifted={d}\n", .{
            stats.focus_rejected, stats.apps_suspended, stats.frames_lifted,
        });
    }

    /// The layout of every workspace in use: its splits, their shares and the windows in
    /// them, with the revision that tells this snapshot from a newer one.
    fn query_tree(engine: *Engine, text: *stdx.Text, json: bool) void {
        if (json) {
            text.print("{{\"revision\":{d},\"focused\":{d},\"workspaces\":[", .{
                engine.revision, engine.focused_window,
            });
        } else {
            text.print("revision={d}\n", .{engine.revision});
        }
        var listed: u32 = 0;
        var workspace: u8 = 0;
        while (workspace < workspaces_max) : (workspace += 1) {
            if (!engine.workspace_listed(workspace)) continue;
            if (json) {
                if (listed > 0) text.append(",");
                engine.tree_json(text, workspace);
            } else {
                engine.tree_lines(text, workspace);
            }
            listed += 1;
        }
        if (json) text.append("]}\n");
    }

    fn floating_in(window: *const Window, workspace: u8) bool {
        if (window.id == 0 or window.workspace != workspace) return false;
        return window.mode == .floating and window.managed();
    }

    fn tree_lines(engine: *Engine, text: *stdx.Text, workspace: u8) void {
        const forest = &engine.forest;
        const root = engine.workspaces[workspace].root;
        const visible = engine.workspace_visible(workspace);
        text.print("workspace {d} {s}{s}\n", .{
            workspace + 1,
            if (visible) "visible" else "hidden",
            if (engine.workspaces[workspace].accordion) " accordion" else "",
        });
        var index = root;
        var steps: u32 = 0;
        while (index != node_none) : (index = forest.next(root, index)) {
            assert(steps < tree.nodes_max);
            steps += 1;
            var up = index;
            text.append("  ");
            while (up != root) : (up = forest.nodes[up].parent) text.append("  ");
            const node = &forest.nodes[index];
            if (forest.is_leaf(index)) {
                text.print("window {d}\n", .{node.window});
            } else {
                const percent = (node.ratio * 100 + tree.ratio_half) / tree.ratio_unit;
                text.print("{s} {d}%\n", .{ @tagName(node.split), percent });
            }
        }
        for (&engine.windows) |*window| {
            if (floating_in(window, workspace)) text.print("  floating {d}\n", .{window.id});
        }
    }

    fn tree_json(engine: *Engine, text: *stdx.Text, workspace: u8) void {
        const visible = engine.workspace_visible(workspace);
        text.print("{{\"index\":{d},\"visible\":{s}", .{ workspace + 1, bool_name(visible) });
        text.append(",\"label\":");
        text.json_string(engine.workspaces[workspace].label.slice());
        text.print(",\"accordion\":{s}", .{bool_name(engine.workspaces[workspace].accordion)});
        text.append(",\"layout\":");
        engine.layout_json(text, engine.workspaces[workspace].root);
        text.append(",\"floating\":[");
        var count: u32 = 0;
        for (&engine.windows) |*window| {
            if (!floating_in(window, workspace)) continue;
            text.print("{s}{d}", .{ if (count > 0) "," else "", window.id });
            count += 1;
        }
        text.append("]}");
    }

    /// A split is {"split","ratio","first","second"}, a tile is {"window"}. Written in
    /// tree order without recursion: after a tile, close every split it completes.
    fn layout_json(engine: *Engine, text: *stdx.Text, root: NodeIndex) void {
        if (root == node_none) return text.append("null");
        const forest = &engine.forest;
        var index = root;
        var steps: u32 = 0;
        while (index != node_none) : (index = forest.next(root, index)) {
            assert(steps < tree.nodes_max);
            steps += 1;
            const node = &forest.nodes[index];
            if (!forest.is_leaf(index)) {
                const thousandths = node.ratio * 1000 / tree.ratio_unit;
                text.print("{{\"split\":\"{s}\",\"ratio\":0.{d:0>3},\"first\":", .{
                    @tagName(node.split), thousandths,
                });
                continue;
            }
            text.print("{{\"window\":{d}}}", .{node.window});
            var child = index;
            while (child != root and forest.nodes[forest.nodes[child].parent].second == child) {
                text.append("}");
                child = forest.nodes[child].parent;
            }
            if (child != root) text.append(",\"second\":");
        }
    }

    // Invariants. The simulator calls this after every step.

    pub fn verify(engine: *Engine) void {
        var leaves_expected: u32 = 0;
        for (&engine.windows) |*window| {
            if (window.id == 0) continue;
            assert(window.workspace < workspaces_max);
            assert(engine.apps[window.app].pid == window.pid);
            assert(!window.sticky or window.mode == .floating);
            assert(!window.auto_floated or window.mode == .floating);
            const leaf = engine.forest.leaf_find(window.id);
            assert(window.in_layout() == (leaf != node_none));
            if (leaf != node_none) {
                leaves_expected += 1;
                assert(engine.forest.root_of(leaf) == engine.workspaces[window.workspace].root);
            }
            if (window.tab_of != 0) {
                const leader = engine.window_find(window.tab_of).?;
                assert(leader.tab_of == 0);
                assert(leader.pid == window.pid);
                assert(leader.workspace == window.workspace);
                assert(!window.sticky);
            }
            if (window.zoom == .parent) assert(window.in_layout());
            if (window.set_pending) assert(window.desired_valid);
        }
        var leaves: u32 = 0;
        for (&engine.workspaces) |*workspace| leaves += engine.forest.verify(workspace.root);
        assert(leaves == leaves_expected);
        const nodes_used = tree.nodes_max - engine.forest.free_count;
        var roots: u32 = 0;
        for (&engine.workspaces) |*workspace| roots += @intFromBool(workspace.root != node_none);
        assert(nodes_used == 2 * leaves - roots);
        if (engine.focused_window != 0) {
            const window = engine.window_find(engine.focused_window).?;
            assert(window.tab_of == 0);
            assert(window.focusable());
            // The window with focus is never on a hidden workspace, and its monitor is the
            // focused monitor.
            if (engine.monitors_count > 0) {
                assert(engine.workspace_visible(window.workspace));
                assert(engine.workspace_monitor(window.workspace) == engine.focused_monitor);
            }
        }
        assert(engine.focus_pending_count <= focus_pending_max);
        for (engine.memories[0..engine.memories_count], 0..) |*memory, index| {
            assert(memory.id != 0 and memory.pid != 0);
            assert(memory.workspace < workspaces_max);
            assert(memory.ratio >= tree.ratio_min and memory.ratio <= tree.ratio_max);
            for (engine.memories[0..index]) |*other| assert(other.id != memory.id);
        }
        engine.verify_monitors();
    }

    fn verify_monitors(engine: *Engine) void {
        if (engine.monitors_count == 0) return;
        assert(engine.focused_monitor < engine.monitors_count);
        assert(engine.recent_monitor < engine.monitors_count);
        for (engine.monitors[0..engine.monitors_count], 0..) |*monitor, index| {
            assert(monitor.workspace < workspaces_max);
            assert(engine.workspace_monitor(monitor.workspace) == index);
            for (engine.monitors[0..index]) |*other| {
                assert(other.workspace != monitor.workspace);
                assert(other.display != monitor.display);
            }
            // The tiles of a visible workspace partition its area exactly.
            const root = engine.workspaces[monitor.workspace].root;
            const area = engine.workspace_rect(@intCast(index));
            var covered: i64 = 0;
            var leaf = engine.forest.leaf_first(root);
            while (leaf != node_none) : (leaf = engine.forest.leaf_next(root, leaf)) {
                const rect = engine.forest.nodes[leaf].rect;
                assert(rect.x >= area.x and rect.y >= area.y);
                assert(rect.right() <= area.right() and rect.bottom() <= area.bottom());
                covered += rect.area();
            }
            if (root != node_none and engine.gap_inner(monitor.workspace) == 0) {
                assert(covered == area.area());
            }
        }
    }
};
