//! Source preview for a list row: the lines around one line of one file, with
//! line numbers, syntax colours and the target line lifted.
//!
//! Text comes from the open buffer when the file has one -- so unsaved edits
//! show -- and from disk otherwise. The file is loaded and parsed once per path;
//! moving between rows of the same file only moves the window.

const std = @import("std");
const syntax = @import("syntax");
const file_type_config = @import("file_type_config");
const syntax_validator = @import("syntax_validator");
const root = @import("soft_root").root;
const Plane = @import("renderer").Plane;

const tui = @import("tui.zig");
const Widget = @import("Widget.zig");

const Self = @This();

/// Past this the preview says so instead of reading and parsing the file.
const max_file_size = 2 * 1024 * 1024;

allocator: std.mem.Allocator,
path: std.ArrayListUnmanaged(u8) = .empty,
content: []const u8 = &.{},
line_starts: std.ArrayListUnmanaged(usize) = .empty,
syn: ?*syntax = null,
problem: ?[]const u8 = null,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    self.unload();
    self.path.deinit(self.allocator);
    self.line_starts.deinit(self.allocator);
}

fn unload(self: *Self) void {
    if (self.syn) |s| s.destroy();
    self.syn = null;
    self.allocator.free(self.content);
    self.content = &.{};
    self.line_starts.clearRetainingCapacity();
    self.problem = null;
}

/// Load `path` unless it is the file already shown.
pub fn load(self: *Self, path_: []const u8) void {
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const project = tp_env_project();
    const path = if (std.fs.path.isAbsolute(path_) or project.len == 0)
        path_
    else
        std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ project, path_ }) catch path_;
    if (std.mem.eql(u8, path, self.path.items) and (self.content.len > 0 or self.problem != null)) return;

    self.unload();
    self.path.clearRetainingCapacity();
    self.path.appendSlice(self.allocator, path) catch return;

    self.content = self.read(path) catch |e| {
        self.problem = switch (e) {
            error.FileTooBig => "file too large to preview",
            error.Binary => "binary file",
            else => "cannot read file",
        };
        return;
    };

    self.line_starts.append(self.allocator, 0) catch return;
    for (self.content, 0..) |c, i| if (c == '\n')
        self.line_starts.append(self.allocator, i + 1) catch return;

    self.syn = file_type_config.create_syntax_guess_file_type(self.allocator, self.content, path, tui.query_cache()) catch null;
    if (self.syn) |s| s.refresh_full(self.content) catch {
        s.destroy();
        self.syn = null;
    };
}

fn tp_env_project() []const u8 {
    return @import("thespian").env.get().str("project");
}

fn read(self: *Self, path: []const u8) ![]const u8 {
    if (tui.mainview()) |mv| if (mv.buffer_manager.get_buffer_for_file(path)) |buffer| {
        return self.allocator.dupe(u8, buffer.store_to_string_cached(buffer.root, .lf));
    };
    const io = root.get_io();
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(max_file_size)) catch |e| switch (e) {
        error.StreamTooLong => return error.FileTooBig,
        else => return e,
    };
    if (std.mem.indexOfScalar(u8, content[0..@min(content.len, 8000)], 0) != null) {
        self.allocator.free(content);
        return error.Binary;
    }
    return content;
}

fn line_text(self: *const Self, line: usize) []const u8 {
    if (line >= self.line_starts.items.len) return "";
    const start = self.line_starts.items[line];
    const end = if (line + 1 < self.line_starts.items.len) self.line_starts.items[line + 1] - 1 else self.content.len;
    return std.mem.trimEnd(u8, self.content[start..@max(start, end)], "\r");
}

/// Draw into `box` of `plane`, centred on zero-based `target` line.
pub fn render(self: *Self, plane: *Plane, box: Widget.Box, theme: *const Widget.Theme, target: usize) void {
    if (box.w < 8 or box.h == 0) return;
    const base = theme.panel;
    const gutter_style: Widget.Theme.Style = .{ .fg = theme.editor_gutter.fg, .bg = base.bg };
    const separator: Widget.Theme.Style = .{ .fg = theme.editor_selection.bg, .bg = base.bg };

    for (0..box.h) |y| {
        plane.cursor_move_yx(@intCast(box.y + y), @intCast(box.x));
        plane.set_style(separator);
        _ = plane.putstr("▏") catch {};
    }

    if (self.problem) |problem| {
        plane.cursor_move_yx(@intCast(box.y), @intCast(box.x + 2));
        plane.set_style(gutter_style);
        _ = plane.print("{s}", .{problem}) catch {};
        return;
    }
    const lines = self.line_starts.items.len;
    if (lines == 0) return;

    const first = @min(target -| box.h / 2, lines -| box.h);
    const last = @min(first + box.h, lines);
    var digits: usize = 1;
    var n = last;
    while (n >= 10) : (n /= 10) digits += 1;
    const text_x = box.x + 1 + digits + 2;
    if (text_x >= box.x + box.w) return;
    const text_w = box.x + box.w - text_x;

    // Per-byte style for the visible lines, filled from the syntax tree.
    const window_start = self.line_starts.items[first];
    const window_end = if (last < lines) self.line_starts.items[last] else self.content.len;
    const styles = self.allocator.alloc(?Widget.Theme.Style, window_end - window_start) catch return;
    defer self.allocator.free(styles);
    @memset(styles, null);
    if (self.syn) |s| self.fill_styles(s, theme, styles, first, last, window_start);

    const tab_width = tui.config().tab_width;
    for (first..last) |line| {
        const y = box.y + (line - first);
        const is_target = line == target;
        const row_bg = if (is_target) theme.editor_line_highlight.bg orelse theme.editor_selection.bg else base.bg;

        plane.cursor_move_yx(@intCast(y), @intCast(box.x + 1));
        plane.set_styles(.{});
        plane.set_style(.{ .fg = if (is_target) theme.editor_gutter_active.fg else gutter_style.fg, .bg = row_bg });
        _ = plane.print("{d: >[1]} ", .{ line + 1, digits + 1 }) catch {};

        const text = self.line_text(line);
        const line_start = self.line_starts.items[line];
        var col: usize = 0;
        var i: usize = 0;
        while (i < text.len and col < text_w) {
            const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            const end = @min(i + len, text.len);
            const byte_style = styles[line_start - window_start + i];
            var style: Widget.Theme.Style = byte_style orelse .{ .fg = base.fg };
            style.bg = row_bg;
            // set_style only ever adds attributes -- an underlined or bold token
            // would otherwise carry on into every character after it.
            plane.set_styles(.{});
            plane.set_style(style);
            if (text[i] == '\t') {
                const spaces = tab_width - (col % tab_width);
                for (0..spaces) |_| if (col < text_w) {
                    _ = plane.putstr(" ") catch {};
                    col += 1;
                };
            } else if (text[i] < 0x20) {
                _ = plane.putstr("?") catch {};
                col += 1;
            } else {
                _ = plane.putstr(text[i..end]) catch {};
                col += 1;
            }
            i = end;
        }
        if (is_target) {
            plane.set_style(.{ .bg = row_bg });
            while (col < text_w) : (col += 1) _ = plane.putstr(" ") catch {};
        }
    }
}

fn fill_styles(self: *const Self, s: *syntax, theme: *const Widget.Theme, styles: []?Widget.Theme.Style, first: usize, last: usize, window_start: usize) void {
    const Ctx = struct {
        preview: *const Self,
        theme: *const Widget.Theme,
        styles: []?Widget.Theme.Style,
        window_start: usize,
        rank: []i64,

        fn cb(ctx: *@This(), range: syntax.Range, scope: []const u8, _: u32, idx: usize, priority: i32, pattern_index: u32, _: *const syntax.Node) error{Stop}!void {
            if (idx > 0) return;
            const token = tui.find_scope_style(ctx.theme, scope) orelse return;
            const rank: i64 = (@as(i64, priority) << 32) | @as(i64, pattern_index);
            const starts = ctx.preview.line_starts.items;
            const begin_row: usize = range.start_point.row;
            const end_row: usize = range.end_point.row;
            if (begin_row >= starts.len) return;
            const begin = starts[begin_row] + range.start_point.column;
            const end = if (end_row < starts.len) starts[end_row] + range.end_point.column else ctx.preview.content.len;
            var b = @max(begin, ctx.window_start);
            const e = @min(end, ctx.window_start + ctx.styles.len);
            while (b < e) : (b += 1) {
                const i = b - ctx.window_start;
                if (rank < ctx.rank[i]) continue;
                ctx.rank[i] = rank;
                ctx.styles[i] = token.style;
            }
        }
    };
    const rank = self.allocator.alloc(i64, styles.len) catch return;
    defer self.allocator.free(rank);
    @memset(rank, std.math.minInt(i64));
    var ctx: Ctx = .{ .preview = self, .theme = theme, .styles = styles, .window_start = window_start, .rank = rank };
    const range: syntax.Range = .{
        .start_point = .{ .row = @intCast(first), .column = 0 },
        .end_point = .{ .row = @intCast(last), .column = 0 },
        .start_byte = 0,
        .end_byte = 0,
    };
    s.render(&ctx, Ctx.cb, syntax_validator.Validator(*Ctx), range) catch {};
}
