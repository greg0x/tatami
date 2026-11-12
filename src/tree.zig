//! Binary space partitioning trees over a single static node pool.
//!
//! Every workspace owns one tree, identified by its root index. Leaves hold a window id,
//! internal nodes hold a split and a ratio. Nothing here recurses or allocates: traversals
//! follow parent links and every loop is bounded by the pool size.
const std = @import("std");
const assert = std.debug.assert;
const geometry = @import("geometry.zig");
const Rect = geometry.Rect;
const Direction = geometry.Direction;

pub const nodes_max: u32 = 512;
pub const NodeIndex = u16;
pub const node_none: NodeIndex = std.math.maxInt(NodeIndex);
pub const WindowId = u32;

pub const ratio_unit: u32 = 1 << 16;
pub const ratio_half: u32 = ratio_unit / 2;
pub const ratio_min: u32 = ratio_unit / 10;
pub const ratio_max: u32 = ratio_unit - ratio_min;

comptime {
    assert(nodes_max < node_none);
    assert(ratio_min < ratio_half and ratio_half < ratio_max);
}

/// columns: children sit side by side, first on the left.
/// rows: children are stacked, first on top.
pub const Split = enum(u1) {
    columns,
    rows,

    pub fn flipped(split: Split) Split {
        return if (split == .columns) .rows else .columns;
    }
};

pub const Placement = union(enum) {
    /// Split along the longer side of the target; the new window becomes the second child.
    auto,
    /// Put the new window on the given side of the target.
    side: Direction,
};

pub const Node = struct {
    parent: NodeIndex = node_none,
    first: NodeIndex = node_none,
    second: NodeIndex = node_none,
    window: WindowId = 0,
    split: Split = .columns,
    ratio: u32 = ratio_half,
    rect: Rect = Rect.zero,
    in_use: bool = false,
};

pub const Forest = struct {
    nodes: [nodes_max]Node,
    free: [nodes_max]NodeIndex,
    free_count: u32,

    pub fn init(forest: *Forest) void {
        for (&forest.nodes) |*node| node.* = .{};
        for (&forest.free, 0..) |*slot, index| {
            slot.* = @intCast(nodes_max - 1 - index);
        }
        forest.free_count = nodes_max;
    }

    fn acquire(forest: *Forest) NodeIndex {
        assert(forest.free_count > 0);
        forest.free_count -= 1;
        const index = forest.free[forest.free_count];
        assert(!forest.nodes[index].in_use);
        forest.nodes[index] = .{ .in_use = true };
        return index;
    }

    fn release(forest: *Forest, index: NodeIndex) void {
        assert(index < nodes_max);
        assert(forest.nodes[index].in_use);
        assert(forest.free_count < nodes_max);
        forest.nodes[index] = .{};
        forest.free[forest.free_count] = index;
        forest.free_count += 1;
    }

    pub fn is_leaf(forest: *const Forest, index: NodeIndex) bool {
        const node = &forest.nodes[index];
        assert(node.in_use);
        assert((node.first == node_none) == (node.second == node_none));
        assert((node.first == node_none) == (node.window != 0));
        return node.first == node_none;
    }

    /// The leaf holding the window, or node_none. Window ids are unique across the forest.
    pub fn leaf_find(forest: *const Forest, window: WindowId) NodeIndex {
        assert(window != 0);
        for (&forest.nodes, 0..) |*node, index| {
            if (node.in_use and node.window == window) return @intCast(index);
        }
        return node_none;
    }

    pub fn root_of(forest: *const Forest, index: NodeIndex) NodeIndex {
        var current = index;
        var steps: u32 = 0;
        while (forest.nodes[current].parent != node_none) : (steps += 1) {
            assert(steps < nodes_max);
            current = forest.nodes[current].parent;
        }
        return current;
    }

    fn depth(forest: *const Forest, index: NodeIndex) u32 {
        var current = index;
        var steps: u32 = 0;
        while (forest.nodes[current].parent != node_none) : (steps += 1) {
            assert(steps < nodes_max);
            current = forest.nodes[current].parent;
        }
        return steps;
    }

    /// The root of the smallest subtree that holds both nodes, which are in one tree.
    pub fn ancestor_common(forest: *const Forest, a: NodeIndex, b: NodeIndex) NodeIndex {
        var first = a;
        var second = b;
        var depth_first = forest.depth(first);
        var depth_second = forest.depth(second);
        while (depth_first > depth_second) : (depth_first -= 1) {
            first = forest.nodes[first].parent;
        }
        while (depth_second > depth_first) : (depth_second -= 1) {
            second = forest.nodes[second].parent;
        }
        while (first != second) : (depth_first -= 1) {
            assert(depth_first > 0);
            first = forest.nodes[first].parent;
            second = forest.nodes[second].parent;
        }
        return first;
    }

    /// Next node of the tree in preorder, or node_none after the last one.
    pub fn next(forest: *const Forest, root: NodeIndex, index: NodeIndex) NodeIndex {
        assert(forest.nodes[index].in_use);
        if (!forest.is_leaf(index)) return forest.nodes[index].first;
        var current = index;
        var steps: u32 = 0;
        while (current != root) : (steps += 1) {
            assert(steps < nodes_max);
            const parent = forest.nodes[current].parent;
            assert(parent != node_none);
            if (forest.nodes[parent].first == current) return forest.nodes[parent].second;
            current = parent;
        }
        return node_none;
    }

    pub fn leaf_first(forest: *const Forest, root: NodeIndex) NodeIndex {
        if (root == node_none) return node_none;
        var current = root;
        var steps: u32 = 0;
        while (!forest.is_leaf(current)) : (steps += 1) {
            assert(steps < nodes_max);
            current = forest.nodes[current].first;
        }
        return current;
    }

    pub fn leaf_next(forest: *const Forest, root: NodeIndex, leaf: NodeIndex) NodeIndex {
        assert(forest.is_leaf(leaf));
        var current = forest.next(root, leaf);
        var steps: u32 = 0;
        while (current != node_none and !forest.is_leaf(current)) : (steps += 1) {
            assert(steps < nodes_max);
            current = forest.next(root, current);
        }
        return current;
    }

    pub fn leaf_last(forest: *const Forest, root: NodeIndex) NodeIndex {
        if (root == node_none) return node_none;
        var current = root;
        var steps: u32 = 0;
        while (!forest.is_leaf(current)) : (steps += 1) {
            assert(steps < nodes_max);
            current = forest.nodes[current].second;
        }
        return current;
    }

    /// The leaf before this one in preorder, or node_none for the first.
    pub fn leaf_prev(forest: *const Forest, root: NodeIndex, leaf: NodeIndex) NodeIndex {
        assert(forest.is_leaf(leaf));
        var current = leaf;
        var steps: u32 = 0;
        while (current != root) : (steps += 1) {
            assert(steps < nodes_max);
            const parent = forest.nodes[current].parent;
            assert(parent != node_none);
            const node = &forest.nodes[parent];
            if (node.second == current) return forest.leaf_last(node.first);
            current = parent;
        }
        return node_none;
    }

    pub fn leaf_count(forest: *const Forest, root: NodeIndex) u32 {
        var count: u32 = 0;
        var leaf = forest.leaf_first(root);
        while (leaf != node_none) : (leaf = forest.leaf_next(root, leaf)) {
            count += 1;
            assert(count <= nodes_max);
        }
        return count;
    }

    /// Adds a window next to the target leaf, or as the root of an empty tree.
    pub fn insert(
        forest: *Forest,
        root: *NodeIndex,
        target: NodeIndex,
        window: WindowId,
        placement: Placement,
    ) void {
        assert(window != 0);
        assert(forest.leaf_find(window) == node_none);
        assert(forest.free_count >= 2);
        if (root.* == node_none) {
            assert(target == node_none);
            const leaf = forest.acquire();
            forest.nodes[leaf].window = window;
            root.* = leaf;
            return;
        }
        assert(forest.is_leaf(target));
        assert(forest.root_of(target) == root.*);
        const kept = forest.acquire();
        const added = forest.acquire();
        const node = &forest.nodes[target];
        forest.nodes[kept] = .{ .in_use = true, .parent = target, .window = node.window };
        forest.nodes[added] = .{ .in_use = true, .parent = target, .window = window };
        node.window = 0;
        node.ratio = ratio_half;
        switch (placement) {
            .auto => {
                node.split = if (node.rect.w >= node.rect.h) .columns else .rows;
                node.first = kept;
                node.second = added;
            },
            .side => |direction| {
                node.split = if (direction.axis() == .x) .columns else .rows;
                node.first = if (direction.is_leading()) added else kept;
                node.second = if (direction.is_leading()) kept else added;
            },
        }
        forest.layout_node(target, 0);
    }

    /// Adds a window beside a whole subtree: the subtree and the window become the two
    /// halves of a new split, which takes the subtree's place in the tree.
    pub fn insert_beside(
        forest: *Forest,
        root: *NodeIndex,
        target: NodeIndex,
        window: WindowId,
        direction: Direction,
    ) void {
        assert(window != 0);
        assert(forest.leaf_find(window) == node_none);
        assert(forest.free_count >= 2);
        assert(target != node_none and forest.nodes[target].in_use);
        assert(forest.root_of(target) == root.*);
        const split = forest.acquire();
        const added = forest.acquire();
        const parent = forest.nodes[target].parent;
        const leading = direction.is_leading();
        forest.nodes[split] = .{
            .in_use = true,
            .parent = parent,
            .split = if (direction.axis() == .x) .columns else .rows,
            .rect = forest.nodes[target].rect,
            .first = if (leading) added else target,
            .second = if (leading) target else added,
        };
        forest.nodes[added] = .{ .in_use = true, .parent = split, .window = window };
        forest.nodes[target].parent = split;
        if (parent == node_none) {
            assert(root.* == target);
            root.* = split;
        } else if (forest.nodes[parent].first == target) {
            forest.nodes[parent].first = split;
        } else {
            assert(forest.nodes[parent].second == target);
            forest.nodes[parent].second = split;
        }
        forest.layout_node(split, 0);
    }

    /// Removes the window's leaf; its sibling takes the place of their parent.
    pub fn remove(forest: *Forest, root: *NodeIndex, window: WindowId) void {
        const leaf = forest.leaf_find(window);
        assert(leaf != node_none);
        assert(forest.root_of(leaf) == root.*);
        const parent = forest.nodes[leaf].parent;
        if (parent == node_none) {
            assert(root.* == leaf);
            root.* = node_none;
            forest.release(leaf);
            return;
        }
        const parent_node = forest.nodes[parent];
        const sibling = if (parent_node.first == leaf) parent_node.second else parent_node.first;
        assert(sibling != leaf and sibling != node_none);
        const grandparent = parent_node.parent;
        forest.nodes[sibling].parent = grandparent;
        forest.nodes[sibling].rect = parent_node.rect;
        if (grandparent == node_none) {
            assert(root.* == parent);
            root.* = sibling;
        } else if (forest.nodes[grandparent].first == parent) {
            forest.nodes[grandparent].first = sibling;
        } else {
            assert(forest.nodes[grandparent].second == parent);
            forest.nodes[grandparent].second = sibling;
        }
        forest.release(leaf);
        forest.release(parent);
    }

    /// Releases every node of the tree.
    pub fn clear(forest: *Forest, root: *NodeIndex) void {
        var steps: u32 = 0;
        while (root.* != node_none) : (steps += 1) {
            assert(steps < nodes_max);
            const leaf = forest.leaf_first(root.*);
            forest.remove(root, forest.nodes[leaf].window);
        }
    }

    fn layout_node(forest: *Forest, index: NodeIndex, gap: i32) void {
        assert(!forest.is_leaf(index));
        assert(gap >= 0);
        const node = forest.nodes[index];
        assert(node.ratio >= ratio_min and node.ratio <= ratio_max);
        const rect = node.rect;
        const length = if (node.split == .columns) rect.w else rect.h;
        const usable: i64 = @max(0, length - gap);
        const used_gap = length - @as(i32, @intCast(usable));
        const first_length: i32 = @intCast((usable * node.ratio + ratio_half) >> 16);
        const second_length: i32 = @as(i32, @intCast(usable)) - first_length;
        assert(first_length >= 0 and second_length >= 0);
        const first = &forest.nodes[node.first];
        const second = &forest.nodes[node.second];
        if (node.split == .columns) {
            first.rect = .{ .x = rect.x, .y = rect.y, .w = first_length, .h = rect.h };
            second.rect = .{
                .x = rect.x + first_length + used_gap,
                .y = rect.y,
                .w = second_length,
                .h = rect.h,
            };
        } else {
            first.rect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = first_length };
            second.rect = .{
                .x = rect.x,
                .y = rect.y + first_length + used_gap,
                .w = rect.w,
                .h = second_length,
            };
        }
    }

    /// Assigns a rect to every node of the tree.
    pub fn layout(forest: *Forest, root: NodeIndex, rect: Rect, gap: i32) void {
        if (root == node_none) return;
        assert(rect.w >= 0 and rect.h >= 0);
        forest.nodes[root].rect = rect;
        var current = root;
        var steps: u32 = 0;
        while (current != node_none) : (steps += 1) {
            assert(steps < nodes_max);
            if (!forest.is_leaf(current)) forest.layout_node(current, gap);
            current = forest.next(root, current);
        }
    }

    /// Gives a leaf this share of the split it is one half of, in percent.
    pub fn share_set(forest: *Forest, leaf: NodeIndex, percent: u32) void {
        assert(forest.is_leaf(leaf));
        assert(percent >= 1 and percent <= 99);
        const parent = forest.nodes[leaf].parent;
        if (parent == node_none) return;
        const share = ratio_unit * percent / 100;
        const ratio = if (forest.nodes[parent].first == leaf) share else ratio_unit - share;
        forest.nodes[parent].ratio = std.math.clamp(ratio, ratio_min, ratio_max);
    }

    pub fn swap_windows(forest: *Forest, a: NodeIndex, b: NodeIndex) void {
        assert(forest.is_leaf(a) and forest.is_leaf(b));
        assert(a != b);
        const window = forest.nodes[a].window;
        forest.nodes[a].window = forest.nodes[b].window;
        forest.nodes[b].window = window;
    }

    /// Rotates the tree clockwise by a multiple of 90 degrees.
    pub fn rotate(forest: *Forest, root: NodeIndex, degrees: u32) void {
        assert(degrees == 90 or degrees == 180 or degrees == 270);
        var current = root;
        var steps: u32 = 0;
        while (current != node_none) : (steps += 1) {
            assert(steps < nodes_max);
            if (!forest.is_leaf(current)) {
                var turn: u32 = 0;
                while (turn < degrees / 90) : (turn += 1) {
                    const node = &forest.nodes[current];
                    // Left|right becomes top/bottom as is; top/bottom becomes right|left.
                    if (node.split == .rows) swap_children(node);
                    node.split = node.split.flipped();
                }
            }
            current = forest.next(root, current);
        }
    }

    fn swap_children(node: *Node) void {
        const first = node.first;
        node.first = node.second;
        node.second = first;
        node.ratio = ratio_unit - node.ratio;
        assert(node.ratio >= ratio_min and node.ratio <= ratio_max);
    }

    /// Flips the tree: .x mirrors left and right, .y mirrors top and bottom.
    pub fn mirror(forest: *Forest, root: NodeIndex, across: geometry.Axis) void {
        const split: Split = if (across == .x) .columns else .rows;
        var current = root;
        var steps: u32 = 0;
        while (current != node_none) : (steps += 1) {
            assert(steps < nodes_max);
            if (!forest.is_leaf(current) and forest.nodes[current].split == split) {
                swap_children(&forest.nodes[current]);
            }
            current = forest.next(root, current);
        }
    }

    pub fn toggle_split(forest: *Forest, leaf: NodeIndex) bool {
        assert(forest.is_leaf(leaf));
        const parent = forest.nodes[leaf].parent;
        if (parent == node_none) return false;
        forest.nodes[parent].split = forest.nodes[parent].split.flipped();
        return true;
    }

    /// Sets every ratio so that windows in the same row or column get equal sizes.
    pub fn balance(forest: *Forest, root: NodeIndex) void {
        if (root == node_none) return;
        var order: [nodes_max]NodeIndex = undefined;
        var order_count: u32 = 0;
        var current = root;
        while (current != node_none) : (current = forest.next(root, current)) {
            assert(order_count < nodes_max);
            order[order_count] = current;
            order_count += 1;
        }
        // Reverse preorder visits children before their parent.
        var span_columns: [nodes_max]u16 = undefined;
        var span_rows: [nodes_max]u16 = undefined;
        var remaining = order_count;
        while (remaining > 0) : (remaining -= 1) {
            const index = order[remaining - 1];
            if (forest.is_leaf(index)) {
                span_columns[index] = 1;
                span_rows[index] = 1;
                continue;
            }
            const node = &forest.nodes[index];
            const columns = [2]u16{ span_columns[node.first], span_columns[node.second] };
            const rows = [2]u16{ span_rows[node.first], span_rows[node.second] };
            const along = if (node.split == .columns) columns else rows;
            span_columns[index] = if (node.split == .columns)
                columns[0] + columns[1]
            else
                @max(columns[0], columns[1]);
            span_rows[index] =
                if (node.split == .rows) rows[0] + rows[1] else @max(rows[0], rows[1]);
            const total = @as(u32, along[0]) + along[1];
            const ratio = (@as(u32, along[0]) * ratio_unit + total / 2) / total;
            node.ratio = std.math.clamp(ratio, ratio_min, ratio_max);
        }
    }

    /// Moves one edge of the leaf by delta pixels (positive is right or down) by changing
    /// the ratio of the nearest ancestor that owns that edge. False when no ancestor does.
    pub fn resize_edge(
        forest: *Forest,
        leaf: NodeIndex,
        edge: Direction,
        delta: i32,
        gap: i32,
    ) bool {
        assert(forest.is_leaf(leaf));
        assert(gap >= 0);
        const split: Split = if (edge.axis() == .x) .columns else .rows;
        var child = leaf;
        var steps: u32 = 0;
        while (forest.nodes[child].parent != node_none) : (steps += 1) {
            assert(steps < nodes_max);
            const parent = forest.nodes[child].parent;
            const node = &forest.nodes[parent];
            const owns_edge = if (edge.is_leading()) node.second == child else node.first == child;
            if (node.split == split and owns_edge) {
                const length = if (split == .columns) node.rect.w else node.rect.h;
                const usable: i64 = length - gap;
                if (usable <= 0) return false;
                const first_rect = forest.nodes[node.first].rect;
                const first_length: i64 = if (split == .columns) first_rect.w else first_rect.h;
                const target = std.math.clamp(first_length + delta, 0, usable);
                const ratio: u32 =
                    @intCast(@divTrunc(target * ratio_unit + @divTrunc(usable, 2), usable));
                node.ratio = std.math.clamp(ratio, ratio_min, ratio_max);
                return true;
            }
            child = parent;
        }
        return false;
    }

    /// Asserts the structural invariants of one tree and returns its leaf count.
    pub fn verify(forest: *const Forest, root: NodeIndex) u32 {
        if (root == node_none) return 0;
        assert(forest.nodes[root].in_use);
        assert(forest.nodes[root].parent == node_none);
        var leaves: u32 = 0;
        var visited: u32 = 0;
        var current = root;
        while (current != node_none) : (current = forest.next(root, current)) {
            visited += 1;
            assert(visited <= nodes_max);
            const node = &forest.nodes[current];
            assert(node.in_use);
            if (forest.is_leaf(current)) {
                leaves += 1;
                assert(forest.leaf_find(node.window) == current);
                continue;
            }
            assert(node.ratio >= ratio_min and node.ratio <= ratio_max);
            assert(node.first != node.second);
            assert(forest.nodes[node.first].parent == current);
            assert(forest.nodes[node.second].parent == current);
        }
        assert(visited == 2 * leaves - 1);
        return leaves;
    }
};

const testing = std.testing;

fn test_forest() Forest {
    var forest: Forest = undefined;
    forest.init();
    return forest;
}

fn rect_of(forest: *const Forest, window: WindowId) Rect {
    return forest.nodes[forest.leaf_find(window)].rect;
}

test "insert splits along the longer side, like yabai bsp" {
    var forest = test_forest();
    var root: NodeIndex = node_none;
    const screen = Rect.init(0, 0, 1600, 1000);
    forest.insert(&root, node_none, 1, .auto);
    forest.layout(root, screen, 0);
    forest.insert(&root, forest.leaf_find(1), 2, .auto);
    forest.layout(root, screen, 0);
    forest.insert(&root, forest.leaf_find(2), 3, .auto);
    forest.layout(root, screen, 0);
    try testing.expect(rect_of(&forest, 1).eql(Rect.init(0, 0, 800, 1000)));
    try testing.expect(rect_of(&forest, 2).eql(Rect.init(800, 0, 800, 500)));
    try testing.expect(rect_of(&forest, 3).eql(Rect.init(800, 500, 800, 500)));
    try testing.expectEqual(@as(u32, 3), forest.verify(root));
}

test "remove promotes the sibling and frees both nodes" {
    var forest = test_forest();
    var root: NodeIndex = node_none;
    const screen = Rect.init(0, 0, 1600, 1000);
    forest.insert(&root, node_none, 1, .auto);
    forest.layout(root, screen, 0);
    forest.insert(&root, forest.leaf_find(1), 2, .auto);
    forest.insert(&root, forest.leaf_find(2), 3, .auto);
    forest.remove(&root, 2);
    forest.layout(root, screen, 0);
    try testing.expect(rect_of(&forest, 3).eql(Rect.init(800, 0, 800, 1000)));
    forest.remove(&root, 1);
    forest.remove(&root, 3);
    try testing.expectEqual(node_none, root);
    try testing.expectEqual(nodes_max, forest.free_count);
}

test "the smallest subtree that holds two windows" {
    var forest = test_forest();
    var root: NodeIndex = node_none;
    const screen = Rect.init(0, 0, 1600, 1000);
    forest.insert(&root, node_none, 1, .auto);
    forest.layout(root, screen, 0);
    forest.insert(&root, forest.leaf_find(1), 2, .auto);
    forest.layout(root, screen, 0);
    forest.insert(&root, forest.leaf_find(2), 3, .auto);
    forest.layout(root, screen, 0);
    // 1 beside the split that holds 2 above 3.
    const one = forest.leaf_find(1);
    const two = forest.leaf_find(2);
    const three = forest.leaf_find(3);
    try testing.expectEqual(one, forest.ancestor_common(one, one));
    try testing.expectEqual(forest.nodes[two].parent, forest.ancestor_common(two, three));
    try testing.expectEqual(forest.nodes[two].parent, forest.ancestor_common(three, two));
    try testing.expectEqual(root, forest.ancestor_common(one, three));
    try testing.expectEqual(root, forest.ancestor_common(root, three));
    try testing.expectEqual(two, forest.leaf_prev(root, three));
    try testing.expectEqual(one, forest.leaf_prev(root, two));
    try testing.expectEqual(node_none, forest.leaf_prev(root, one));
    try testing.expectEqual(three, forest.leaf_next(root, two));
}

test "gaps, placement by side, rotate and mirror" {
    var forest = test_forest();
    var root: NodeIndex = node_none;
    const screen = Rect.init(0, 0, 1010, 500);
    forest.insert(&root, node_none, 1, .auto);
    forest.layout(root, screen, 10);
    forest.insert(&root, forest.leaf_find(1), 2, .{ .side = .west });
    forest.layout(root, screen, 10);
    try testing.expect(rect_of(&forest, 2).eql(Rect.init(0, 0, 500, 500)));
    try testing.expect(rect_of(&forest, 1).eql(Rect.init(510, 0, 500, 500)));
    forest.mirror(root, .x);
    forest.layout(root, screen, 10);
    try testing.expect(rect_of(&forest, 1).eql(Rect.init(0, 0, 500, 500)));
    forest.rotate(root, 90);
    forest.layout(root, screen, 10);
    try testing.expect(rect_of(&forest, 1).eql(Rect.init(0, 0, 1010, 245)));
    try testing.expect(rect_of(&forest, 2).eql(Rect.init(0, 255, 1010, 245)));
    forest.rotate(root, 90);
    forest.layout(root, screen, 10);
    try testing.expect(rect_of(&forest, 2).eql(Rect.init(0, 0, 500, 500)));
    forest.rotate(root, 180);
    forest.layout(root, screen, 10);
    try testing.expect(rect_of(&forest, 1).eql(Rect.init(0, 0, 500, 500)));
}

test "resize moves exactly one edge and balance restores equal sizes" {
    var forest = test_forest();
    var root: NodeIndex = node_none;
    const screen = Rect.init(0, 0, 1200, 600);
    forest.insert(&root, node_none, 1, .auto);
    forest.layout(root, screen, 0);
    forest.insert(&root, forest.leaf_find(1), 2, .auto);
    forest.layout(root, screen, 0);
    forest.insert(&root, forest.leaf_find(2), 3, .{ .side = .east });
    forest.layout(root, screen, 0);
    try testing.expect(forest.resize_edge(forest.leaf_find(1), .east, 100, 0));
    forest.layout(root, screen, 0);
    try testing.expectEqual(@as(i32, 700), rect_of(&forest, 1).w);
    try testing.expect(!forest.resize_edge(forest.leaf_find(1), .west, -100, 0));
    try testing.expect(!forest.resize_edge(forest.leaf_find(1), .south, 100, 0));
    forest.balance(root);
    forest.layout(root, screen, 0);
    try testing.expectEqual(@as(i32, 400), rect_of(&forest, 1).w);
    try testing.expectEqual(@as(i32, 400), rect_of(&forest, 2).w);
    try testing.expectEqual(@as(i32, 400), rect_of(&forest, 3).w);
    try testing.expectEqual(@as(u32, 3), forest.verify(root));
}
