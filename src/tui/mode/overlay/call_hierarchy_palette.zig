//! Call hierarchy as a tree: the function under the cursor at the root, the
//! functions that call it (or that it calls) below, each expandable in turn.
//!
//! Shaped after file_tree_palette -- the only tree flow already draws -- with
//! the language server in place of the filesystem. Children load lazily, one
//! request at a time, and answer with "CH" messages keyed by the node's
//! address, so a late answer for a node that is no longer pending is dropped.
//!
//!   Right  expand     Left   collapse, or go to the parent
//!   Enter  jump to the call site (the definition, for the root)

const std = @import("std");
const cbor = @import("cbor");
const tp = @import("thespian");
const project_manager = @import("project_manager");
const command = @import("command");

const tui = @import("../../tui.zig");
const MessageFilter = @import("../../MessageFilter.zig");
pub const Type = @import("palette.zig").Create(@This());
const module_name = @typeName(@This());
const Widget = @import("../../Widget.zig");

pub const label = "Call hierarchy";
pub const name = "󰘦 calls";
pub const description = "call hierarchy";
pub const icon = "󰘦  ";
pub const preserve_entry_order = true;

pub const Direction = project_manager.CallDirection;

pub const Node = struct {
    name: []const u8,
    detail: []const u8,
    path: []const u8, // where the function itself lives
    line: usize,
    jump_path: []const u8, // the call site (the definition, for the root)
    jump_line: usize,
    jump_col: usize,
    sites: usize,
    item: []const u8, // raw CallHierarchyItem, echoed back on expand
    expanded: bool = false,
    loaded: bool = false,
    children: std.ArrayListUnmanaged(*Node) = .empty,
    parent: ?*Node = null,
};

pub const Entry = struct {
    label: []const u8,
    indent: usize,
    node: *Node,
};

pub const ValueType = struct {
    direction: Direction = .incoming,
    root: ?*Node = null,
    pending: ?*Node = null,
    file_path: []const u8 = "", // owned; picks the language server
};
pub const defaultValue: ValueType = .{};

fn free_node(allocator: std.mem.Allocator, node: *Node) void {
    for (node.children.items) |child| free_node(allocator, child);
    node.children.deinit(allocator);
    for ([_][]const u8{ node.name, node.detail, node.path, node.jump_path, node.item }) |owned| allocator.free(owned);
    allocator.destroy(node);
}

pub fn deinit(palette: *Type) void {
    tui.message_filters().remove_ptr(palette);
    palette.value.pending = null;
    if (palette.value.root) |root| free_node(palette.allocator, root);
    palette.value.root = null;
    palette.allocator.free(palette.value.file_path);
    palette.value.file_path = "";
}

pub fn load_entries_with_args(palette: *Type, ctx: command.Context) !usize {
    var direction_name: []const u8 = "incoming";
    _ = ctx.args.match(.{tp.extract(&direction_name)}) catch false;
    palette.value.direction = std.meta.stringToEnum(Direction, direction_name) orelse .incoming;
    palette.quick_activate_enabled = false;
    palette.entries.clearRetainingCapacity();

    const editor = tui.get_active_editor() orelse return 0;
    const file_path = editor.file_path orelse return 0;
    palette.value.file_path = try palette.allocator.dupe(u8, file_path);

    tui.message_filters().add(MessageFilter.bind(palette, receive)) catch {};

    const cursor = editor.get_primary().cursor;
    const root = editor.buf_root() catch return 0;
    const col = root.get_line_width_to_pos(cursor.row, cursor.col, editor.metrics) catch return 0;
    project_manager.call_hierarchy_prepare(.{ .src = .{ .path = file_path, .line = cursor.row, .column = col } }) catch |e| {
        palette.logger.err("call_hierarchy_prepare", e);
    };
    return 0;
}

fn node_id(node: *Node) usize {
    return @intFromPtr(node);
}

fn request_children(palette: *Type, node: *Node) void {
    palette.value.pending = node;
    project_manager.call_hierarchy_calls(palette.value.file_path, palette.value.direction, node_id(node), node.item) catch |e| {
        palette.value.pending = null;
        palette.logger.err("call_hierarchy_calls", e);
    };
}

fn new_node(palette: *Type, fields: struct {
    name: []const u8,
    detail: []const u8,
    path: []const u8,
    line: usize,
    jump_path: []const u8,
    jump_line: usize,
    jump_col: usize,
    sites: usize,
    item: []const u8,
    parent: ?*Node,
}) !*Node {
    const a = palette.allocator;
    const node = try a.create(Node);
    node.* = .{
        .name = try a.dupe(u8, fields.name),
        .detail = try a.dupe(u8, fields.detail),
        .path = try a.dupe(u8, fields.path),
        .line = fields.line,
        .jump_path = try a.dupe(u8, fields.jump_path),
        .jump_line = fields.jump_line,
        .jump_col = fields.jump_col,
        .sites = fields.sites,
        .item = try a.dupe(u8, fields.item),
        .parent = fields.parent,
    };
    return node;
}

fn receive(palette: *Type, _: tp.pid_ref, m: tp.message) MessageFilter.Error!bool {
    if (!(cbor.match(m.buf, .{ "CH", tp.more }) catch false)) return false;

    var id: usize = 0;
    var name_: []const u8 = undefined;
    var detail: []const u8 = undefined;
    var path: []const u8 = undefined;
    var line: usize = 0;
    var col: usize = 0;
    var jump_path: []const u8 = undefined;
    var jump_line: usize = 0;
    var jump_col: usize = 0;
    var sites: usize = 0;
    var item: []const u8 = undefined;
    var message: []const u8 = undefined;

    if (try cbor.match(m.buf, .{ "CH", "root", tp.extract(&id), tp.extract(&name_), tp.extract(&detail), tp.extract(&path), tp.extract(&line), tp.extract(&col), tp.extract(&item) })) {
        if (palette.value.root != null) return true;
        const root = try new_node(palette, .{
            .name = name_,
            .detail = detail,
            .path = path,
            .line = line,
            .jump_path = path,
            .jump_line = line,
            .jump_col = col,
            .sites = 0,
            .item = item,
            .parent = null,
        });
        root.expanded = true;
        palette.value.root = root;
        rebuild(palette, root);
        request_children(palette, root);
    } else if (try cbor.match(m.buf, .{ "CH", "child", tp.extract(&id), tp.extract(&name_), tp.extract(&detail), tp.extract(&path), tp.extract(&line), tp.extract(&jump_path), tp.extract(&jump_line), tp.extract(&jump_col), tp.extract(&sites), tp.extract(&item) })) {
        const parent = palette.value.pending orelse return true;
        if (node_id(parent) != id) return true;
        const child = try new_node(palette, .{
            .name = name_,
            .detail = detail,
            .path = path,
            .line = line,
            .jump_path = jump_path,
            .jump_line = jump_line,
            .jump_col = jump_col,
            .sites = sites,
            .item = item,
            .parent = parent,
        });
        try parent.children.append(palette.allocator, child);
    } else if (try cbor.match(m.buf, .{ "CH", "done", tp.extract(&id) })) {
        const node = palette.value.pending orelse return true;
        if (node_id(node) != id) return true;
        palette.value.pending = null;
        node.loaded = true;
        node.expanded = true;
        rebuild(palette, node);
    } else if (try cbor.match(m.buf, .{ "CH", "error", tp.extract(&id), tp.extract(&message) })) {
        palette.value.pending = null;
        palette.logger.print("call hierarchy: {s}", .{message});
        // Nothing to show without a root; don't leave an empty overlay behind.
        if (palette.value.root == null)
            tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch {};
    }
    return true;
}

fn build_visible(palette: *Type, node: *Node, depth: usize) !void {
    try palette.entries.append(palette.allocator, .{ .label = node.name, .indent = depth, .node = node });
    if (node.expanded) for (node.children.items) |child| try build_visible(palette, child, depth + 1);
}

/// Redraw the tree and keep `focus` selected.
fn rebuild(palette: *Type, focus: *Node) void {
    palette.entries.clearRetainingCapacity();
    if (palette.value.root) |root| build_visible(palette, root, 0) catch return;
    for (palette.entries.items, 0..) |entry, i| if (entry.node == focus) {
        palette.initial_selected = i + 1;
        break;
    };
    palette.longest_hint = max_hint(palette);
    palette.start_query(0) catch {};
    tui.need_render(@src());
}

fn max_hint(palette: *Type) usize {
    var longest: usize = 0;
    for (palette.entries.items) |entry| {
        const base = std.fs.path.basename(entry.node.path);
        longest = @max(longest, entry.indent * 2 + base.len + 16);
    }
    return longest;
}

fn selected_node(palette: *Type) ?*Node {
    const button = palette.menu.get_selected() orelse return null;
    var iter = button.opts.label;
    var label_str: []const u8 = undefined;
    var idx: usize = 0;
    if (!(cbor.matchString(&iter, &label_str) catch false)) return null;
    if (!(cbor.matchInt(usize, &iter, &idx) catch false)) return null;
    if (idx >= palette.entries.items.len) return null;
    return palette.entries.items[idx].node;
}

pub fn menu_right(palette: *Type) void {
    const node = selected_node(palette) orelse return;
    if (palette.value.pending != null) return;
    if (!node.loaded) return request_children(palette, node);
    node.expanded = true;
    rebuild(palette, node);
}

pub fn menu_left(palette: *Type) void {
    const node = selected_node(palette) orelse return;
    if (node.expanded and node.parent != null) {
        node.expanded = false;
        return rebuild(palette, node);
    }
    if (node.parent) |parent| rebuild(palette, parent);
}

pub fn add_menu_entry(palette: *Type, entry: *Entry, matches: ?[]const usize) !void {
    var value: std.Io.Writer.Allocating = .init(palette.allocator);
    defer value.deinit();
    const writer = &value.writer;
    try cbor.writeValue(writer, entry.label);
    const entry_idx = for (palette.entries.items, 0..) |existing, idx| {
        if (existing.node == entry.node) break idx;
    } else palette.entries.items.len;
    try cbor.writeValue(writer, entry_idx);
    try cbor.writeValue(writer, matches orelse &[_]usize{});
    try palette.menu.add_item_with_handler(value.written(), select);
    palette.items += 1;
}

pub fn clear_entries(palette: *Type) void {
    palette.entries.clearRetainingCapacity();
}

pub fn on_render_menu(palette: *Type, button: *Type.ButtonType, theme: *const Widget.Theme, selected: bool) bool {
    const style_base = theme.editor_widget;
    const style_label = if (button.active) theme.editor_cursor else if (button.hover or selected) theme.editor_selection else theme.editor_widget;
    const style_hint = if (tui.find_scope_style(theme, "entity.name")) |sty| sty.style else style_label;
    button.plane.set_base_style(style_base);
    button.plane.erase();
    button.plane.home();
    button.plane.set_style(style_label);
    if (button.active or button.hover or selected) {
        button.plane.fill(" ");
        button.plane.home();
    }

    var iter = button.opts.label;
    var label_str: []const u8 = undefined;
    var idx: usize = 0;
    if (!(cbor.matchString(&iter, &label_str) catch false)) return false;
    if (!(cbor.matchInt(usize, &iter, &idx) catch false)) return false;
    if (idx >= palette.entries.items.len) return false;
    const entry = palette.entries.items[idx];
    const node = entry.node;

    button.plane.set_style(style_hint);
    tui.render_pointer(&button.plane, selected);
    for (0..entry.indent) |_| _ = button.plane.print("  ", .{}) catch {};
    const marker = if (palette.value.pending == node)
        "… "
    else if (!node.loaded)
        "▸ "
    else if (node.children.items.len == 0)
        "  "
    else if (node.expanded)
        "▾ "
    else
        "▸ ";
    _ = button.plane.print("{s}", .{marker}) catch {};

    button.plane.set_style(style_label);
    _ = button.plane.print("{s}", .{node.name}) catch {};
    button.plane.set_style(style_hint);
    const at = if (entry.indent == 0) "definition" else if (node.sites > 1) "calls" else "call";
    if (node.sites > 1)
        _ = button.plane.print("  {s}:{d}  {d} {s}", .{ std.fs.path.basename(node.jump_path), node.jump_line + 1, node.sites, at }) catch {}
    else
        _ = button.plane.print("  {s}:{d}", .{ std.fs.path.basename(node.jump_path), node.jump_line + 1 }) catch {};

    var len = cbor.decodeArrayHeader(&iter) catch return false;
    while (len > 0) : (len -= 1) {
        var match_idx: usize = 0;
        if (cbor.matchValue(&iter, cbor.extract(&match_idx)) catch break) {
            tui.render_match_cell(&button.plane, 0, match_idx + 4 + entry.indent * 2, theme) catch break;
        } else break;
    }
    return false;
}

fn select(menu: **Type.MenuType, button: *Type.ButtonType, _: Type.Pos) void {
    const palette = menu.*.opts.ctx;
    var iter = button.opts.label;
    var label_str: []const u8 = undefined;
    var idx: usize = 0;
    if (!(cbor.matchString(&iter, &label_str) catch false)) return;
    if (!(cbor.matchInt(usize, &iter, &idx) catch false)) return;
    if (idx >= palette.entries.items.len) return;
    const node = palette.entries.items[idx].node;
    tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| palette.logger.err(module_name, e);
    tp.self_pid().send(.{ "cmd", "navigate", .{
        .file = node.jump_path,
        .line = @as(i64, @intCast(node.jump_line + 1)),
        .column = @as(i64, @intCast(node.jump_col + 1)),
    } }) catch |e| palette.logger.err(module_name, e);
}
