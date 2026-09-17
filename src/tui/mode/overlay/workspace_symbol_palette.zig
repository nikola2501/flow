//! Symbols across the whole project, from the language server's
//! workspace/symbol -- no tag files, the server keeps its own index.
//!
//! The server does the matching, so every change to the query is a new request.
//! Only one runs at a time; when it finishes and the query has moved on, the
//! current text is sent next. Answers carry a request id, and anything from an
//! older request is dropped.

const std = @import("std");
const cbor = @import("cbor");
const tp = @import("thespian");
const command = @import("command");
const project_manager = @import("project_manager");
const SymbolKind = @import("lsp_types").SymbolKind;

const tui = @import("../../tui.zig");
const MessageFilter = @import("../../MessageFilter.zig");
pub const Type = @import("palette.zig").Create(@This());
const module_name = @typeName(@This());
const Widget = @import("../../Widget.zig");

pub const label = "Search workspace symbols";
pub const name = "󰊕 workspace symbols";
pub const description = "workspace symbols";
pub const icon = "󱎸  ";

pub const Entry = struct { label: []const u8 };

pub const ValueType = struct {
    file_path: []const u8 = "", // owned; picks the language server
    request_id: usize = 0,
    pending: bool = false,
    need_reset: bool = false,
    count: usize = 0,
};
pub const defaultValue: ValueType = .{};

pub fn load_entries(palette: *Type) !usize {
    palette.quick_activate_enabled = false;
    const editor = tui.get_active_editor() orelse {
        palette.logger.print("workspace symbols: open a file first, its language server answers", .{});
        tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch {};
        return 0;
    };
    const file_path = editor.file_path orelse return 0;
    palette.value.file_path = try palette.allocator.dupe(u8, file_path);
    tui.message_filters().add(MessageFilter.bind(palette, receive)) catch {};
    return 40;
}

pub fn deinit(palette: *Type) void {
    tui.message_filters().remove_ptr(palette);
    palette.allocator.free(palette.value.file_path);
    palette.value.file_path = "";
}

pub fn add_menu_entry(_: *Type, _: *Entry, _: ?[]const usize) !void {}

pub fn query(palette: *Type, query_text: []const u8) MessageFilter.Error!void {
    palette.total_items = 0;
    if (palette.value.pending) return;
    if (query_text.len == 0) {
        // Most servers answer an empty query with nothing, or with everything.
        reset_results(palette);
        palette.inputbox.hint.clearRetainingCapacity();
        return;
    }
    palette.value.pending = true;
    palette.value.need_reset = true;
    palette.value.count = 0;
    palette.value.request_id += 1;
    project_manager.workspace_symbols(palette.value.file_path, query_text, palette.value.request_id) catch |e| {
        palette.value.pending = false;
        palette.logger.err("workspace_symbols", e);
    };
}

fn reset_results(palette: *Type) void {
    palette.value.need_reset = false;
    palette.items = 0;
    palette.total_items = 0;
    palette.menu.reset_items();
    palette.menu.selected = null;
    // Lay the overlay out now: an async palette is otherwise only sized when a
    // result arrives, so with no query yet -- as on opening -- the input box
    // would not appear until the first keystroke brought results.
    palette.refresh_layout();
}

fn receive(palette: *Type, _: tp.pid_ref, m: tp.message) MessageFilter.Error!bool {
    if (!(cbor.match(m.buf, .{ "WS", tp.more }) catch false)) return false;

    var id: usize = 0;
    var symbol: []const u8 = undefined;
    var container: []const u8 = undefined;
    var kind: u8 = 0;
    var path: []const u8 = undefined;
    var line: usize = 0;
    var col: usize = 0;
    var query_: []const u8 = undefined;
    var count: usize = 0;
    var message: []const u8 = undefined;

    if (try cbor.match(m.buf, .{ "WS", "symbol", tp.extract(&id), tp.extract(&symbol), tp.extract(&container), tp.extract(&kind), tp.extract(&path), tp.extract(&line), tp.extract(&col) })) {
        if (id != palette.value.request_id) return true;
        if (palette.value.need_reset) reset_results(palette);
        var value: std.Io.Writer.Allocating = .init(palette.allocator);
        defer value.deinit();
        const writer = &value.writer;
        try cbor.writeArrayHeader(writer, 6);
        try cbor.writeValue(writer, symbol);
        try cbor.writeValue(writer, container);
        try cbor.writeValue(writer, kind);
        try cbor.writeValue(writer, path);
        try cbor.writeValue(writer, line);
        try cbor.writeValue(writer, col);
        // Grow to the widest row seen so names, paths and containers fit; the
        // palette itself caps the width at the screen. Never shrink while the
        // picker is open, so the overlay does not jump as results change.
        var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
        const rel = project_manager.normalize_file_path(path, &rel_buf);
        palette.longest = @max(palette.longest, tui.egc_chunk_width(symbol, 0, 1) + 3);
        palette.longest_hint = @max(palette.longest_hint, rel.len + 8 + @max(container.len, 12));
        palette.append_async_item(value.written(), select) catch {};
        palette.value.count += 1;
        tui.need_render(@src());
    } else if (try cbor.match(m.buf, .{ "WS", "done", tp.extract(&id), tp.extract(&query_), tp.extract(&count) })) {
        if (id != palette.value.request_id) return true;
        palette.value.pending = false;
        // An empty answer still replaces the previous query's results.
        if (palette.value.need_reset) reset_results(palette);
        palette.inputbox.hint.clearRetainingCapacity();
        palette.inputbox.hint.print(palette.inputbox.allocator, "{d}", .{count}) catch {};
        if (!std.mem.eql(u8, palette.inputbox.text.items, query_))
            try query(palette, palette.inputbox.text.items);
        tui.need_render(@src());
    } else if (try cbor.match(m.buf, .{ "WS", "error", tp.extract(&id), tp.extract(&message) })) {
        if (id != palette.value.request_id) return true;
        palette.value.pending = false;
        palette.logger.print("workspace symbols: {s}", .{message});
    }
    return true;
}

const Item = struct { symbol: []const u8, container: []const u8, kind: SymbolKind, path: []const u8, line: usize, col: usize };

fn read_item(label_: []const u8) ?Item {
    var item: Item = .{ .symbol = "", .container = "", .kind = .None, .path = "", .line = 0, .col = 0 };
    var kind: u8 = 0;
    if (!(cbor.match(label_, .{
        tp.extract(&item.symbol),
        tp.extract(&item.container),
        tp.extract(&kind),
        tp.extract(&item.path),
        tp.extract(&item.line),
        tp.extract(&item.col),
    }) catch false)) return null;
    // SymbolKind covers 0..26; an unknown kind from a newer server draws as None.
    item.kind = if (kind <= 26) @enumFromInt(kind) else .None;
    return item;
}

pub fn on_render_menu(_: *Type, button: *Type.ButtonType, theme: *const Widget.Theme, selected: bool) bool {
    const item = read_item(button.opts.label) orelse return false;
    var where_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = project_manager.normalize_file_path(item.path, &rel_buf);
    const where = std.fmt.bufPrint(&where_buf, "{s}:{d}", .{ rel, item.line + 1 }) catch rel;
    var no_matches_buf: [8]u8 = undefined;
    var no_matches: std.Io.Writer = .fixed(&no_matches_buf);
    cbor.writeArrayHeader(&no_matches, 0) catch {};
    return tui.render_symbol(
        &button.plane,
        0,
        item.symbol,
        item.kind.icon(),
        0,
        where,
        if (item.container.len > 0) item.container else @tagName(item.kind),
        no_matches.buffered(),
        button.active,
        selected,
        button.hover,
        theme,
        &.{},
        &.{},
        "  ",
    );
}

fn select(menu: **Type.MenuType, button: *Type.ButtonType, _: Type.Pos) void {
    const item = read_item(button.opts.label) orelse return;
    tp.self_pid().send(.{ "cmd", "exit_overlay_mode" }) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
    tp.self_pid().send(.{ "cmd", "navigate", .{
        .file = item.path,
        .line = @as(i64, @intCast(item.line + 1)),
        .column = @as(i64, @intCast(item.col + 1)),
    } }) catch |e| menu.*.opts.ctx.logger.err(module_name, e);
}
