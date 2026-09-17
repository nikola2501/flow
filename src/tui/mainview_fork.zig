//! Features this fork adds to mainview, kept out of mainview.zig so upstream
//! changes to that file rarely meet fork code. mainview.zig holds only the
//! hooks: the `fork` state field, a second command collection, and two calls
//! from its diagnostics handlers.
//!
//! See "About this fork" in README.md.

const std = @import("std");
const root = @import("soft_root").root;
const tp = @import("thespian");
const cbor = @import("cbor");
const log = @import("log");
const shell = @import("shell");
const builtin = @import("builtin");
const command = @import("command");
const project_manager = @import("project_manager");
const Buffer = @import("Buffer");

const tui = @import("tui.zig");
const ed = @import("editor.zig");
const FileList = @import("FileList.zig");
const MainView = @import("mainview.zig");

pub const State = struct {
    /// Every diagnostic the language servers have published, by file, whether the
    /// file is open or not. The per-editor lists only exist for open files, and the
    /// diagnostics panel is rebuilt from whichever file was published last, so
    /// neither can answer "what is wrong across the project".
    project_diagnostics: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(StoredDiagnostic)) = .empty,
    /// State of the running show_vcs_hunks, which parses git's output as it streams
    /// in. The generation discards output from a run that a newer one replaced.
    hunks_generation: usize = 0,
    hunks_root: std.ArrayListUnmanaged(u8) = .empty,
    hunks_file: std.ArrayListUnmanaged(u8) = .empty,
    hunks_count: usize = 0,
    /// Output of the running open_vcs_blame_in_browser lookup, collected until git
    /// exits. Same generation scheme as the hunk list.
    blame_web_generation: usize = 0,
    blame_web_output: std.ArrayListUnmanaged(u8) = .empty,
    /// State of the running show_changed_files, which folds git diff's output
    /// into one row per file as it streams in.
    changes_generation: usize = 0,
    changes_count: usize = 0,
    changes_root: std.ArrayListUnmanaged(u8) = .empty,
    changes_ref: std.ArrayListUnmanaged(u8) = .empty,
    changes_path: std.ArrayListUnmanaged(u8) = .empty,
    changes_file: ChangedFile = .{},

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        var it = self.project_diagnostics.iterator();
        while (it.next()) |kv| {
            for (kv.value_ptr.items) |d| allocator.free(d.message);
            kv.value_ptr.deinit(allocator);
            allocator.free(kv.key_ptr.*);
        }
        self.project_diagnostics.deinit(allocator);
        self.hunks_root.deinit(allocator);
        self.hunks_file.deinit(allocator);
        self.blame_web_output.deinit(allocator);
        self.changes_root.deinit(allocator);
        self.changes_ref.deinit(allocator);
        self.changes_path.deinit(allocator);
    }
};

/// mainview's add_diagnostic, for every diagnostic published.
pub fn on_add_diagnostic(self: *MainView, file_path: []const u8, severity: i32, message: []const u8, sel: ed.Selection) !void {
    try project_diagnostics_store(self, file_path, severity, message, sel);
    if (self.filelists.find_by_kind(.project_diagnostics)) |list| if (self.filelist_view_for(list.list_id) != null)
        try project_diagnostics_add_entry(self, list.list_id, file_path, self.fork.project_diagnostics.get(file_path).?.getLast(), .background);
}

/// mainview's clear_diagnostics. A publish is a clear followed by the file's
/// new diagnostics, so the project list drops only this file and the adds that
/// follow refill it.
pub fn on_clear_diagnostics(self: *MainView, file_path: []const u8) !void {
    const had_any = self.fork.project_diagnostics.contains(file_path);
    project_diagnostics_forget(self, file_path);
    if (had_any) try project_diagnostics_refresh(self);
}

const ChangedFile = struct {
    open: bool = false,
    status: u8 = 'M',
    added: usize = 0,
    removed: usize = 0,
    first_line: usize = 0,
};

/// Emit the row for the file show_changed_files has been folding, if any.
fn changed_files_flush(self: *MainView) !void {
    defer {
        self.fork.changes_file = .{};
        self.fork.changes_path.clearRetainingCapacity();
    }
    if (!self.fork.changes_file.open or self.fork.changes_path.items.len == 0) return;
    const list = self.filelists.find_by_kind(.changed_files) orelse return;
    const f = self.fork.changes_file;

    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ self.fork.changes_root.items, self.fork.changes_path.items }) catch return;
    var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = project_manager.normalize_file_path(full, &rel_buf);

    var text_buf: [128]u8 = undefined;
    const status_name = switch (f.status) {
        'A' => "added",
        'D' => "deleted",
        'R' => "renamed",
        else => "modified",
    };
    const text = std.fmt.bufPrint(&text_buf, "{c}  +{d} -{d}  {s}", .{ f.status, f.added, f.removed, status_name }) catch return;
    // Colour by status through the severity the list already knows how to
    // draw: added blue, modified and renamed yellow, deleted red.
    const severity: ed.Diagnostic.Severity = switch (f.status) {
        'A' => .Information,
        'D' => .Error,
        else => .Warning,
    };
    const at = @max(1, f.first_line);
    try self.add_filelist_entry(list.list_id, path, at, 1, at, 1, text, severity, .foreground);
    self.fork.changes_count += 1;
}

const StoredDiagnostic = struct {
    begin_row: usize,
    begin_col: usize,
    end_row: usize,
    end_col: usize,
    severity: i32,
    message: []const u8, // owned
};

fn project_diagnostics_store(self: *MainView, file_path: []const u8, severity: i32, message: []const u8, sel: ed.Selection) !void {
    const gop = try self.fork.project_diagnostics.getOrPut(self.allocator, file_path);
    if (!gop.found_existing) {
        gop.key_ptr.* = try self.allocator.dupe(u8, file_path);
        gop.value_ptr.* = .empty;
    }
    try gop.value_ptr.append(self.allocator, .{
        .begin_row = sel.begin.row,
        .begin_col = sel.begin.col,
        .end_row = sel.end.row,
        .end_col = sel.end.col,
        .severity = severity,
        .message = try self.allocator.dupe(u8, message),
    });
}

fn project_diagnostics_forget(self: *MainView, file_path: []const u8) void {
    const kv = self.fork.project_diagnostics.fetchSwapRemove(file_path) orelse return;
    for (kv.value.items) |d| self.allocator.free(d.message);
    var list = kv.value;
    list.deinit(self.allocator);
    self.allocator.free(kv.key);
}

fn project_diagnostics_add_entry(self: *MainView, list_id: FileList.Id, file_path: []const u8, d: StoredDiagnostic, stream_type: anytype) !void {
    // add_filelist_entry takes one-based positions on both axes.
    try self.add_filelist_entry(
        list_id,
        file_path,
        d.begin_row + 1,
        d.begin_col + 1,
        d.end_row + 1,
        d.end_col + 1,
        d.message,
        ed.Diagnostic.to_severity(d.severity),
        stream_type,
    );
}

/// Rebuild the project list from the store, but only while its panel exists:
/// a server republishing a file must not pop the panel open by itself.
fn project_diagnostics_refresh(self: *MainView) !void {
    const list = self.filelists.find_by_kind(.project_diagnostics) orelse return;
    if (self.filelist_view_for(list.list_id) == null) return;
    self.clear_find_in_files_results(list.list_id);
    var it = self.fork.project_diagnostics.iterator();
    while (it.next()) |kv| for (kv.value_ptr.items) |d|
        try project_diagnostics_add_entry(self, list.list_id, kv.key_ptr.*, d, .background);
}

pub const cmds = struct {
    pub const Target = MainView;
    const Ctx = command.Context;
    const Meta = command.Metadata;
    const Result = command.Result;

    /// Every diagnostic the language servers have reported, across all files,
    /// open or not. Stays live: it follows each new publish while it is open.
    ///
    /// Only as complete as the servers make it -- many analyse just the files
    /// they have been told about, so a file nobody opened may not appear.
    pub fn show_project_diagnostics(self: *MainView, _: Ctx) Result {
        const list = try self.filelists.get_or_create_singleton(.project_diagnostics);
        self.clear_find_in_files_results(list.list_id);
        if (self.fork.project_diagnostics.count() == 0) {
            const logger = log.logger("diagnostics");
            defer logger.deinit();
            logger.print("no diagnostics reported", .{});
            return;
        }
        var it = self.fork.project_diagnostics.iterator();
        while (it.next()) |kv| for (kv.value_ptr.items) |d|
            try project_diagnostics_add_entry(self, list.list_id, kv.key_ptr.*, d, .foreground);
    }
    pub const show_project_diagnostics_meta: Meta = .{ .description = "Show diagnostics for the whole project" };

    /// Every changed region in the repository as one list, file by file.
    ///
    /// Without an argument the changes are the working tree against HEAD,
    /// staged and unstaged alike. With a ref they are measured from where this
    /// branch left that ref (git diff --merge-base), and still against the
    /// working tree -- so the line numbers are the ones in the files you have
    /// open, not in some committed version of them.
    ///
    /// -U0 keeps each hunk to the changed lines themselves, which is what makes
    /// its header line number the place to jump to.
    pub fn show_vcs_hunks(self: *MainView, ctx: Ctx) Result {
        var ref: []const u8 = "";
        _ = ctx.args.match(.{tp.extract(&ref)}) catch false;

        const project = tp.env.get().str("project");
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const repo = cmds.repo_root(project, &root_buf) orelse {
            const logger = log.logger("hunks");
            defer logger.deinit();
            logger.print("not inside a git repository", .{});
            return;
        };

        self.fork.hunks_generation += 1;
        self.fork.hunks_count = 0;
        self.fork.hunks_file.clearRetainingCapacity();
        self.fork.hunks_root.clearRetainingCapacity();
        try self.fork.hunks_root.appendSlice(self.allocator, repo);

        const list = try self.filelists.get_or_create_singleton(.hunks);
        self.clear_find_in_files_results(list.list_id);

        var argv: std.Io.Writer.Allocating = .init(self.allocator);
        defer argv.deinit();
        const writer = &argv.writer;
        try cbor.writeArrayHeader(writer, if (ref.len > 0) 8 else 7);
        try cbor.writeValue(writer, "git");
        try cbor.writeValue(writer, "-C");
        try cbor.writeValue(writer, repo);
        try cbor.writeValue(writer, "--no-optional-locks");
        try cbor.writeValue(writer, "diff");
        try cbor.writeValue(writer, "-U0");
        if (ref.len > 0) {
            try cbor.writeValue(writer, "--merge-base");
            try cbor.writeValue(writer, ref);
        } else {
            try cbor.writeValue(writer, "HEAD");
        }

        const handlers = struct {
            fn out(context: usize, parent: tp.pid_ref, _: []const u8, output: []const u8) void {
                parent.send(.{ "cmd", "vcs_hunks_output", .{ context, output } }) catch {};
            }
            fn err(_: usize, _: tp.pid_ref, _: []const u8, output: []const u8) void {
                const logger = log.logger("hunks");
                defer logger.deinit();
                logger.print("{s}", .{std.mem.trimEnd(u8, output, "\n")});
            }
            fn exit(context: usize, parent: tp.pid_ref, _: []const u8, _: []const u8, exit_code: i64) void {
                parent.send(.{ "cmd", "vcs_hunks_done", .{ context, exit_code } }) catch {};
            }
        };
        try shell.execute(self.allocator, .{ .buf = argv.written() }, .{
            .context = self.fork.hunks_generation,
            .out = handlers.out,
            .err = handlers.err,
            .exit = handlers.exit,
        });
    }
    pub const show_vcs_hunks_meta: Meta = .{
        .description = "Show all changed hunks (optionally against a ref)",
        .arguments = &.{.string},
    };

    /// A batch of complete lines from show_vcs_hunks' git diff. Private
    /// continuation: no description, so the palette does not list it.
    pub fn vcs_hunks_output(self: *MainView, ctx: Ctx) Result {
        var generation: usize = 0;
        var output: []const u8 = undefined;
        if (!try ctx.args.match(.{ tp.extract(&generation), tp.extract(&output) })) return error.InvalidArgument;
        if (generation != self.fork.hunks_generation) return;
        const list = self.filelists.find_by_kind(.hunks) orelse return;

        var lines = std.mem.splitScalar(u8, output, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "diff --git ")) {
                self.fork.hunks_file.clearRetainingCapacity();
            } else if (std.mem.startsWith(u8, line, "--- a/") and self.fork.hunks_file.items.len == 0) {
                // Remembered in case the new side is /dev/null: a deleted file
                // still has a path worth listing.
                try self.fork.hunks_file.appendSlice(self.allocator, line[6..]);
            } else if (std.mem.startsWith(u8, line, "+++ b/")) {
                self.fork.hunks_file.clearRetainingCapacity();
                try self.fork.hunks_file.appendSlice(self.allocator, line[6..]);
            } else if (std.mem.startsWith(u8, line, "@@ ") and self.fork.hunks_file.items.len > 0) {
                const hunk = parse_hunk_header(line) orelse continue;
                var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                const full = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.fork.hunks_root.items, self.fork.hunks_file.items }) catch continue;
                // Relative to the project where it can be, the way the other
                // lists show paths; navigate resolves either form.
                var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
                const path = project_manager.normalize_file_path(full, &rel_buf);
                var text_buf: [512]u8 = undefined;
                const text = std.fmt.bufPrint(&text_buf, "+{d} -{d}  {s}", .{ hunk.added, hunk.removed, hunk.context }) catch continue;
                // A pure deletion reports the line before the gap, which is 0
                // when it removed the top of the file.
                const at = @max(1, hunk.new_start);
                try self.add_filelist_entry(list.list_id, path, at, 1, at, 1, text, .Information, .foreground);
                self.fork.hunks_count += 1;
            }
        }
    }
    pub const vcs_hunks_output_meta: Meta = .{ .arguments = &.{ .integer, .string } };

    pub fn vcs_hunks_done(self: *MainView, ctx: Ctx) Result {
        var generation: usize = 0;
        var exit_code: i64 = 0;
        if (!try ctx.args.match(.{ tp.extract(&generation), tp.extract(&exit_code) })) return error.InvalidArgument;
        if (generation != self.fork.hunks_generation) return;
        const logger = log.logger("hunks");
        defer logger.deinit();
        if (exit_code != 0)
            logger.print("git diff failed with exit code {d}", .{exit_code})
        else if (self.fork.hunks_count == 0)
            logger.print("no changes", .{})
        else
            logger.print("{d} hunks", .{self.fork.hunks_count});
    }
    pub const vcs_hunks_done_meta: Meta = .{ .arguments = &.{ .integer, .integer } };

    /// Open the line under the cursor in the origin remote's blame view.
    ///
    /// The line is traced to the commit that last changed it, and the page
    /// opened is that commit's blame at the file's path and line *in that
    /// commit* -- so it still lands on the right line after the file was
    /// renamed or lines above it moved. GitHub and GitLab URL shapes.
    ///
    /// Lines changed locally have no commit yet and open nothing.
    pub fn open_vcs_blame_in_browser(self: *MainView, _: Ctx) Result {
        const logger = log.logger("blame");
        defer logger.deinit();
        const editor = self.get_active_editor() orelse return;
        const file_path = editor.file_path orelse return;
        const row = editor.get_primary().cursor.row;
        const head_row = editor.head_row_for(row) orelse {
            logger.print("line {d} is a local change, not on the remote yet", .{row + 1});
            return;
        };

        var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
        const project = tp.env.get().str("project");
        const abs = if (std.fs.path.isAbsolute(file_path))
            file_path
        else
            std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ project, file_path }) catch return;
        const dir = std.fs.path.dirname(abs) orelse return;
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const repo = cmds.repo_root(dir, &root_buf) orelse {
            logger.print("not inside a git repository", .{});
            return;
        };
        if (abs.len <= repo.len + 1) return;
        const rel = abs[repo.len + 1 ..];

        var line_buf: [32]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{d}", .{head_row + 1}) catch return;

        // One round trip: the remote and the blame together, as key/value
        // lines. Paths travel as positional arguments, never spliced into the
        // script, so no quoting can break.
        const script =
            \\set -e
            \\url=$(git -C "$1" remote get-url origin)
            \\blame=$(git -C "$1" blame --porcelain -L "$3,$3" HEAD -- "$2")
            \\printf 'url %s\n' "$url"
            \\printf '%s\n' "$blame" | head -n 1 | { read -r sha orig rest; printf 'sha %s\nline %s\n' "$sha" "$orig"; }
            \\printf '%s\n' "$blame" | sed -n 's/^filename /file /p' | head -n 1
        ;

        self.fork.blame_web_generation += 1;
        self.fork.blame_web_output.clearRetainingCapacity();

        var argv: std.Io.Writer.Allocating = .init(self.allocator);
        defer argv.deinit();
        const writer = &argv.writer;
        try cbor.writeArrayHeader(writer, 7);
        try cbor.writeValue(writer, "sh");
        try cbor.writeValue(writer, "-c");
        try cbor.writeValue(writer, script);
        try cbor.writeValue(writer, "sh");
        try cbor.writeValue(writer, repo);
        try cbor.writeValue(writer, rel);
        try cbor.writeValue(writer, line);

        const handlers = struct {
            fn out(context: usize, parent: tp.pid_ref, _: []const u8, output: []const u8) void {
                parent.send(.{ "cmd", "vcs_blame_web_output", .{ context, output } }) catch {};
            }
            fn err(_: usize, _: tp.pid_ref, _: []const u8, output: []const u8) void {
                const l = log.logger("blame");
                defer l.deinit();
                l.print("{s}", .{std.mem.trimEnd(u8, output, "\n")});
            }
            fn exit(context: usize, parent: tp.pid_ref, _: []const u8, _: []const u8, exit_code: i64) void {
                parent.send(.{ "cmd", "vcs_blame_web_done", .{ context, exit_code } }) catch {};
            }
        };
        try shell.execute(self.allocator, .{ .buf = argv.written() }, .{
            .context = self.fork.blame_web_generation,
            .out = handlers.out,
            .err = handlers.err,
            .exit = handlers.exit,
        });
    }
    pub const open_vcs_blame_in_browser_meta: Meta = .{ .description = "Open blame for the current line in the browser" };

    pub fn vcs_blame_web_output(self: *MainView, ctx: Ctx) Result {
        var generation: usize = 0;
        var output: []const u8 = undefined;
        if (!try ctx.args.match(.{ tp.extract(&generation), tp.extract(&output) })) return error.InvalidArgument;
        if (generation != self.fork.blame_web_generation) return;
        try self.fork.blame_web_output.appendSlice(self.allocator, output);
    }
    pub const vcs_blame_web_output_meta: Meta = .{ .arguments = &.{ .integer, .string } };

    pub fn vcs_blame_web_done(self: *MainView, ctx: Ctx) Result {
        var generation: usize = 0;
        var exit_code: i64 = 0;
        if (!try ctx.args.match(.{ tp.extract(&generation), tp.extract(&exit_code) })) return error.InvalidArgument;
        if (generation != self.fork.blame_web_generation) return;
        const logger = log.logger("blame");
        defer logger.deinit();
        if (exit_code != 0) {
            logger.print("no origin remote, or git blame failed (exit {d})", .{exit_code});
            return;
        }

        var remote: []const u8 = "";
        var sha: []const u8 = "";
        var line: []const u8 = "";
        var file: []const u8 = "";
        var lines = std.mem.splitScalar(u8, self.fork.blame_web_output.items, '\n');
        while (lines.next()) |l| {
            if (std.mem.startsWith(u8, l, "url ")) remote = l[4..];
            if (std.mem.startsWith(u8, l, "sha ")) sha = l[4..];
            if (std.mem.startsWith(u8, l, "line ")) line = l[5..];
            if (std.mem.startsWith(u8, l, "file ")) file = l[5..];
        }
        if (remote.len == 0 or sha.len == 0 or line.len == 0 or file.len == 0) {
            logger.print("could not read the blame for this line", .{});
            return;
        }
        // git blame names a line that is only in the working tree with the
        // all-zero id; there is no remote page for it.
        if (std.mem.trim(u8, sha, "0").len == 0) {
            logger.print("this line is not committed yet", .{});
            return;
        }

        var url_buf: [4096]u8 = undefined;
        const url = blame_web_url(&url_buf, remote, sha, file, line) orelse {
            logger.print("unsupported remote: {s}", .{remote});
            return;
        };

        const opener = if (builtin.os.tag == .macos) "open" else "xdg-open";
        var argv: std.Io.Writer.Allocating = .init(self.allocator);
        defer argv.deinit();
        try cbor.writeArrayHeader(&argv.writer, 2);
        try cbor.writeValue(&argv.writer, opener);
        try cbor.writeValue(&argv.writer, url);
        const quiet = struct {
            fn out(_: usize, _: tp.pid_ref, _: []const u8, _: []const u8) void {}
        };
        try shell.execute(self.allocator, .{ .buf = argv.written() }, .{ .out = quiet.out });
        logger.print("{s}", .{url});
    }
    pub const vcs_blame_web_done_meta: Meta = .{ .arguments = &.{ .integer, .integer } };

    /// https base for a git remote: git@host:owner/repo(.git),
    /// ssh://git@host[:port]/owner/repo(.git), or http(s)://host/owner/repo(.git).
    fn remote_web_base(buf: []u8, remote_: []const u8) ?[]const u8 {
        var remote = std.mem.trim(u8, remote_, " \t\r");
        if (std.mem.endsWith(u8, remote, ".git")) remote = remote[0 .. remote.len - 4];
        if (std.mem.startsWith(u8, remote, "git@")) {
            const rest = remote[4..];
            const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
            return std.fmt.bufPrint(buf, "https://{s}/{s}", .{ rest[0..colon], rest[colon + 1 ..] }) catch null;
        }
        if (std.mem.startsWith(u8, remote, "ssh://")) {
            var rest = remote[6..];
            if (std.mem.indexOfScalar(u8, rest, '@')) |at| rest = rest[at + 1 ..];
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
            var host = rest[0..slash];
            // An ssh port means nothing to the web server.
            if (std.mem.indexOfScalar(u8, host, ':')) |colon| host = host[0..colon];
            return std.fmt.bufPrint(buf, "https://{s}{s}", .{ host, rest[slash..] }) catch null;
        }
        if (std.mem.startsWith(u8, remote, "https://") or std.mem.startsWith(u8, remote, "http://"))
            return std.fmt.bufPrint(buf, "{s}", .{remote}) catch null;
        return null;
    }

    fn blame_web_url(buf: []u8, remote: []const u8, sha: []const u8, file: []const u8, line: []const u8) ?[]const u8 {
        var base_buf: [1024]u8 = undefined;
        const base = remote_web_base(&base_buf, remote) orelse return null;
        const segment = if (std.mem.indexOf(u8, base, "gitlab") != null) "/-/blame/" else "/blame/";
        var w: std.Io.Writer = .fixed(buf);
        w.print("{s}{s}{s}/", .{ base, segment, sha }) catch return null;
        const hex = "0123456789ABCDEF";
        for (file) |c| switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.', '~', '/' => w.writeByte(c) catch return null,
            else => w.print("%{c}{c}", .{ hex[c >> 4], hex[c & 15] }) catch return null,
        };
        w.print("#L{s}", .{line}) catch return null;
        return w.buffered();
    }

    const HunkHeader = struct { new_start: usize, added: usize, removed: usize, context: []const u8 };

    /// "@@ -12,3 +14,0 @@ fn name()" -> new_start 14, added 0, removed 3,
    /// context "fn name()". An omitted count means one line.
    fn parse_hunk_header(line: []const u8) ?HunkHeader {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        _ = fields.next() orelse return null; // @@
        const old = fields.next() orelse return null;
        const new = fields.next() orelse return null;
        if (old.len < 2 or old[0] != '-' or new.len < 2 or new[0] != '+') return null;
        const old_range = parse_range(old[1..]) orelse return null;
        const new_range = parse_range(new[1..]) orelse return null;
        const close = std.mem.indexOfPos(u8, line, 2, "@@") orelse return null;
        return .{
            .new_start = new_range[0],
            .added = new_range[1],
            .removed = old_range[1],
            .context = std.mem.trim(u8, line[close + 2 ..], " "),
        };
    }

    fn parse_range(text: []const u8) ?[2]usize {
        if (std.mem.indexOfScalar(u8, text, ',')) |comma| {
            const start = std.fmt.parseInt(usize, text[0..comma], 10) catch return null;
            const count = std.fmt.parseInt(usize, text[comma + 1 ..], 10) catch return null;
            return .{ start, count };
        }
        const start = std.fmt.parseInt(usize, text, 10) catch return null;
        return .{ start, 1 };
    }

    /// Open `git diff <ref>...HEAD` in a read-only scratch buffer.
    ///
    /// Three dots rather than two: the comparison is against the merge base, so
    /// what you read is your own work, not everything that landed on the other
    /// branch since you left it.
    ///
    /// Without an argument the ref is resolved from diff_default_ref_candidates,
    /// see diff_against_ref_try_candidate.
    ///
    /// Streams into the buffer the same way shell_execute_stream does, so a
    /// large diff arrives progressively instead of blocking until git is done.
    pub fn diff_against_ref(self: *MainView, ctx: Ctx) Result {
        var ref: []const u8 = undefined;
        if (!(ctx.args.match(.{tp.extract(&ref)}) catch false))
            return cmds.diff_against_ref_try_candidate(self, 0);

        var spec_buf: [512]u8 = undefined;
        const spec = std.fmt.bufPrint(&spec_buf, "{s}...HEAD", .{ref}) catch return error.Stop;
        var name_buf: [512]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "*diff {s}*", .{spec}) catch return error.Stop;

        // -C the project directory rather than trusting the cwd: flow can be
        // pointed at a project with -p from anywhere, and the paths in the
        // output have to come from the same repository goto_diff_location
        // resolves them against.
        return stream_git_into_scratch(self, ctx, name, tp.env.get().str("project"), &.{ "diff", spec });
    }
    pub const diff_against_ref_meta: Meta = .{
        .description = "Diff against a branch or ref (default: the remote's default branch)",
        .arguments = &.{.string},
    };

    /// Open a read-only diff scratch buffer named `name` and stream
    /// `git -C dir --no-optional-locks <args>` into it.
    ///
    /// The scratch buffer has to exist before git starts: its ref is what the
    /// output handler streams into, and `diff` gives it tree-sitter highlighting
    /// for free. create_editor first, the way open_help does, so this also works
    /// from the home screen with nothing open yet.
    fn stream_git_into_scratch(self: *MainView, ctx: Ctx, name: []const u8, dir: []const u8, args: []const []const u8) Result {
        tui.reset_drag_context();
        try self.create_editor(ctx.now);
        try command.executeName("open_scratch_buffer", command.fmt(.{ name, "", "diff" }));
        const editor = self.get_active_editor() orelse return error.Stop;
        const buffer = editor.buffer orelse return error.Stop;
        const buffer_ref = buffer.to_ref();

        var argv: std.Io.Writer.Allocating = .init(self.allocator);
        defer argv.deinit();
        const writer = &argv.writer;
        try cbor.writeArrayHeader(writer, args.len + if (dir.len > 0) @as(usize, 4) else 2);
        try cbor.writeValue(writer, "git");
        if (dir.len > 0) {
            try cbor.writeValue(writer, "-C");
            try cbor.writeValue(writer, dir);
        }
        try cbor.writeValue(writer, "--no-optional-locks");
        for (args) |arg| try cbor.writeValue(writer, arg);

        const handlers = struct {
            fn out(context: usize, parent: tp.pid_ref, _: []const u8, output: []const u8) void {
                const ref_: Buffer.Ref = @enumFromInt(context);
                parent.send(.{ "cmd", "shell_execute_stream_output", .{ ref_, output } }) catch {};
            }
            fn exit(context: usize, parent: tp.pid_ref, _: []const u8, err_msg: []const u8, exit_code: i64) void {
                const ref_: Buffer.Ref = @enumFromInt(context);
                // A bad ref exits non-zero having written nothing, which would
                // otherwise leave an empty buffer and no reason for it.
                if (exit_code > 0) {
                    var buf: [512]u8 = undefined;
                    var stream: std.Io.Writer = .fixed(&buf);
                    stream.print("git diff failed: {s}\n", .{err_msg}) catch {};
                    parent.send(.{ "cmd", "shell_execute_stream_output", .{ ref_, stream.buffered() } }) catch {};
                }
                parent.send(.{ "cmd", "shell_execute_stream_output_complete", .{ref_} }) catch {};
            }
        };

        try shell.execute(self.allocator, .{ .buf = argv.written() }, .{
            .context = @intFromEnum(buffer_ref),
            .out = handlers.out,
            .err = handlers.out,
            .exit = handlers.exit,
        });
        tui.need_render(@src());
        self.location_update_from_editor();
    }

    /// Every changed file as a list: status, added and removed line counts,
    /// and the first changed line, which the preview shows and which is where
    /// the source opens. Enter opens that file's diff instead of the file.
    ///
    /// Without an argument the changes are the working tree against HEAD;
    /// with a ref they are measured from where this branch left it and include
    /// uncommitted work (git diff --merge-base), like show_vcs_hunks. Untracked
    /// files are not part of a git diff and do not appear.
    pub fn show_changed_files(self: *MainView, ctx: Ctx) Result {
        var ref: []const u8 = "";
        _ = ctx.args.match(.{tp.extract(&ref)}) catch false;

        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const repo = cmds.repo_root(tp.env.get().str("project"), &root_buf) orelse {
            const logger = log.logger("changes");
            defer logger.deinit();
            logger.print("not inside a git repository", .{});
            return;
        };

        self.fork.changes_generation += 1;
        self.fork.changes_count = 0;
        self.fork.changes_file = .{};
        self.fork.changes_path.clearRetainingCapacity();
        self.fork.changes_root.clearRetainingCapacity();
        try self.fork.changes_root.appendSlice(self.allocator, repo);
        self.fork.changes_ref.clearRetainingCapacity();
        try self.fork.changes_ref.appendSlice(self.allocator, ref);

        const list = try self.filelists.get_or_create_singleton(.changed_files);
        var label_buf: [256]u8 = undefined;
        list.set_label(if (ref.len > 0) std.fmt.bufPrint(&label_buf, "Changes vs {s}", .{ref}) catch "Changes" else "Changes") catch {};
        self.clear_find_in_files_results(list.list_id);

        var argv: std.Io.Writer.Allocating = .init(self.allocator);
        defer argv.deinit();
        const writer = &argv.writer;
        try cbor.writeArrayHeader(writer, if (ref.len > 0) 8 else 7);
        for ([_][]const u8{ "git", "-C", repo, "--no-optional-locks", "diff", "-U0" }) |arg| try cbor.writeValue(writer, arg);
        if (ref.len > 0) {
            try cbor.writeValue(writer, "--merge-base");
            try cbor.writeValue(writer, ref);
        } else {
            try cbor.writeValue(writer, "HEAD");
        }

        const handlers = struct {
            fn out(context: usize, parent: tp.pid_ref, _: []const u8, output: []const u8) void {
                parent.send(.{ "cmd", "changed_files_output", .{ context, output } }) catch {};
            }
            fn err(_: usize, _: tp.pid_ref, _: []const u8, output: []const u8) void {
                const logger = log.logger("changes");
                defer logger.deinit();
                logger.print("{s}", .{std.mem.trimEnd(u8, output, "\n")});
            }
            fn exit(context: usize, parent: tp.pid_ref, _: []const u8, _: []const u8, exit_code: i64) void {
                parent.send(.{ "cmd", "changed_files_done", .{ context, exit_code } }) catch {};
            }
        };
        try shell.execute(self.allocator, .{ .buf = argv.written() }, .{
            .context = self.fork.changes_generation,
            .out = handlers.out,
            .err = handlers.err,
            .exit = handlers.exit,
        });
    }
    pub const show_changed_files_meta: Meta = .{
        .description = "Show changed files (optionally against a ref)",
        .arguments = &.{.string},
    };

    pub fn changed_files_output(self: *MainView, ctx: Ctx) Result {
        var generation: usize = 0;
        var output: []const u8 = undefined;
        if (!try ctx.args.match(.{ tp.extract(&generation), tp.extract(&output) })) return error.InvalidArgument;
        if (generation != self.fork.changes_generation) return;

        var lines = std.mem.splitScalar(u8, output, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "diff --git ")) {
                try changed_files_flush(self);
                self.fork.changes_file = .{ .open = true };
                // The b/ side is the path if nothing later overrides it: a
                // rename or mode change without content has no +++ line.
                if (std.mem.lastIndexOf(u8, line, " b/")) |i| try self.fork.changes_path.appendSlice(self.allocator, line[i + 3 ..]);
            } else if (!self.fork.changes_file.open) {
                continue;
            } else if (std.mem.startsWith(u8, line, "new file mode")) {
                self.fork.changes_file.status = 'A';
            } else if (std.mem.startsWith(u8, line, "deleted file mode")) {
                self.fork.changes_file.status = 'D';
            } else if (std.mem.startsWith(u8, line, "rename to ")) {
                self.fork.changes_file.status = 'R';
                self.fork.changes_path.clearRetainingCapacity();
                try self.fork.changes_path.appendSlice(self.allocator, line["rename to ".len..]);
            } else if (std.mem.startsWith(u8, line, "+++ b/")) {
                self.fork.changes_path.clearRetainingCapacity();
                try self.fork.changes_path.appendSlice(self.allocator, line[6..]);
            } else if (std.mem.startsWith(u8, line, "@@ ")) {
                const hunk = parse_hunk_header(line) orelse continue;
                if (self.fork.changes_file.first_line == 0) self.fork.changes_file.first_line = @max(1, hunk.new_start);
                self.fork.changes_file.added += hunk.added;
                self.fork.changes_file.removed += hunk.removed;
            }
        }
    }
    pub const changed_files_output_meta: Meta = .{ .arguments = &.{ .integer, .string } };

    pub fn changed_files_done(self: *MainView, ctx: Ctx) Result {
        var generation: usize = 0;
        var exit_code: i64 = 0;
        if (!try ctx.args.match(.{ tp.extract(&generation), tp.extract(&exit_code) })) return error.InvalidArgument;
        if (generation != self.fork.changes_generation) return;
        try changed_files_flush(self);
        const logger = log.logger("changes");
        defer logger.deinit();
        if (exit_code != 0)
            logger.print("git diff failed with exit code {d}", .{exit_code})
        else if (self.fork.changes_count == 0)
            logger.print("no changes", .{})
        else
            logger.print("{d} files changed", .{self.fork.changes_count});
    }
    pub const changed_files_done_meta: Meta = .{ .arguments = &.{ .integer, .integer } };

    /// Open the diff of one file from the changed-files list, against the same
    /// base the list used.
    pub fn diff_changed_file(self: *MainView, ctx: Ctx) Result {
        var path: []const u8 = undefined;
        if (!try ctx.args.match(.{tp.extract(&path)})) return error.InvalidArgument;
        const repo = self.fork.changes_root.items;
        if (repo.len == 0) return;
        // The list shows project-relative paths; git wants them relative to
        // the repository it runs in.
        var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
        const project = tp.env.get().str("project");
        const abs = if (std.fs.path.isAbsolute(path)) path else std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ project, path }) catch return;
        const rel = if (std.mem.startsWith(u8, abs, repo) and abs.len > repo.len + 1) abs[repo.len + 1 ..] else path;

        const ref = self.fork.changes_ref.items;
        var name_buf: [std.fs.max_path_bytes + 64]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "*diff {s} {s}*", .{ if (ref.len > 0) ref else "HEAD", rel }) catch return;
        if (ref.len > 0)
            return stream_git_into_scratch(self, ctx, name, repo, &.{ "diff", "--merge-base", ref, "--", rel });
        return stream_git_into_scratch(self, ctx, name, repo, &.{ "diff", "HEAD", "--", rel });
    }
    pub const diff_changed_file_meta: Meta = .{ .arguments = &.{.string} };

    /// Where diff_against_ref looks for its default ref, most preferred first.
    ///
    /// origin/HEAD is what the remote calls its default branch, so it covers
    /// master and main alike. The remote-tracking refs come before the local
    /// branches on purpose: a local master only moves when someone pulls it, so
    /// it tends to be stale, and diffing against a stale base shows everyone
    /// else's commits since then as if they were yours.
    const diff_default_ref_candidates = [_][]const u8{
        "origin/HEAD",
        "origin/master",
        "origin/main",
        "master",
        "main",
    };

    /// Ask git whether candidate `index` exists. On success the resolved name
    /// (`origin/HEAD` comes back as e.g. `origin/master`) is fed to
    /// diff_against_ref; on failure the next candidate is tried. The chain runs
    /// through commands rather than a loop because each git call is async and
    /// reports back as a message.
    fn diff_against_ref_try_candidate(self: *MainView, index: usize) Result {
        if (index >= diff_default_ref_candidates.len) {
            const logger = log.logger("git");
            defer logger.deinit();
            logger.print_err("diff_against_ref", "no default ref found, pass one explicitly", .{});
            return;
        }

        var argv: std.Io.Writer.Allocating = .init(self.allocator);
        defer argv.deinit();
        const writer = &argv.writer;
        try cbor.writeArrayHeader(writer, 6);
        try cbor.writeValue(writer, "git");
        try cbor.writeValue(writer, "rev-parse");
        try cbor.writeValue(writer, "--verify");
        try cbor.writeValue(writer, "--quiet");
        try cbor.writeValue(writer, "--abbrev-ref");
        try cbor.writeValue(writer, diff_default_ref_candidates[index]);

        const handlers = struct {
            fn out(_: usize, parent: tp.pid_ref, _: []const u8, output: []const u8) void {
                const ref = std.mem.trim(u8, output, " \t\r\n");
                if (ref.len > 0)
                    parent.send(.{ "cmd", "diff_against_ref", .{ref} }) catch {};
            }
            fn err(_: usize, _: tp.pid_ref, _: []const u8, _: []const u8) void {}
            fn exit(context: usize, parent: tp.pid_ref, _: []const u8, _: []const u8, exit_code: i64) void {
                if (exit_code != 0)
                    parent.send(.{ "cmd", "diff_against_ref_next_candidate", .{context + 1} }) catch {};
            }
        };

        try shell.execute(self.allocator, .{ .buf = argv.written() }, .{
            .context = index,
            .out = handlers.out,
            .err = handlers.err,
            .exit = handlers.exit,
        });
    }

    /// Continuation of diff_against_ref_try_candidate. No description, so the
    /// command palette does not list it.
    pub fn diff_against_ref_next_candidate(self: *MainView, ctx: Ctx) Result {
        var index: usize = undefined;
        if (!try ctx.args.match(.{tp.extract(&index)}))
            return error.InvalidArgument;
        return cmds.diff_against_ref_try_candidate(self, index);
    }
    pub const diff_against_ref_next_candidate_meta: Meta = .{ .arguments = &.{.integer} };

    /// Jump to the nth open buffer, counting from 1, in the order they were
    /// opened -- the way a tab bar numbers tabs.
    ///
    /// Visiting a buffer does not renumber anything, so 3 stays the same file
    /// no matter which buffer you are in. Closed (hidden) buffers hold no number,
    /// so closing one shifts the later ones down, again like closing a tab.
    pub fn goto_buffer(self: *MainView, ctx: Ctx) Result {
        var n: usize = 0;
        if (!try ctx.args.match(.{tp.extract(&n)})) return error.InvalidArgument;
        if (n == 0) return;

        const buffers = try self.buffer_manager.list_in_open_order(self.allocator);
        defer self.allocator.free(buffers);
        var seen: usize = 0;
        for (buffers) |buffer| {
            if (buffer.hidden) continue;
            seen += 1;
            if (seen != n) continue;
            const file_path = buffer.get_file_path();
            if (file_path.len == 0) return;
            return tp.self_pid().send(.{ "cmd", "navigate", .{ .file = file_path } });
        }
        const logger = log.logger("buffer");
        defer logger.deinit();
        logger.print("no buffer {d}, {d} open", .{ n, seen });
    }
    pub const goto_buffer_meta: Meta = .{
        .description = "Jump to a buffer by number",
        .arguments = &.{.integer},
    };

    /// Enter, in a diff buffer: open the file the cursor is standing in, at the
    /// line the cursor is standing on.
    ///
    /// In any other buffer this is just smart_insert_line, so the one Enter
    /// binding keeps its ordinary meaning everywhere else.
    ///
    /// The line number is counted, not read: a hunk header gives the first line
    /// in the new file, and every context or added row below it advances by one
    /// while removed rows do not, because they are not in the new file at all.
    pub fn goto_diff_location(self: *MainView, ctx: Ctx) Result {
        // Every keymap binds Enter to something already, and that something
        // differs: smart_insert_line in flow, move_down in vim. Take it as the
        // argument rather than guessing, so one binding can front for both.
        var fallback: []const u8 = "smart_insert_line";
        _ = ctx.args.match(.{tp.extract(&fallback)}) catch false;

        const editor = self.get_active_editor() orelse return fallthrough(fallback, ctx);
        const buffer = editor.buffer orelse return fallthrough(fallback, ctx);
        const file_type = buffer.file_type_name orelse return fallthrough(fallback, ctx);
        if (!buffer.ephemeral or !std.mem.eql(u8, file_type, "diff")) return fallthrough(fallback, ctx);
        const buf_root = buffer.root;
        const cursor_row = editor.get_primary().cursor.row;

        var line: std.Io.Writer.Allocating = .init(self.allocator);
        defer line.deinit();
        const read = struct {
            fn f(l: *std.Io.Writer.Allocating, r: anytype, row: usize, metrics: anytype) []const u8 {
                l.clearRetainingCapacity();
                r.get_line(row, &l.writer, metrics) catch return "";
                return l.written();
            }
        }.f;

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        var path: ?[]const u8 = null;
        var hunk_row: ?usize = null;
        var hunk_line: usize = 1;

        var row = cursor_row + 1;
        while (row > 0 and path == null) {
            row -= 1;
            const text = read(&line, buf_root, row, editor.metrics);
            if (std.mem.startsWith(u8, text, "diff --git ")) {
                // Standing in a file header, above the first hunk: the nearest
                // +++ line belongs to the *previous* file, so read the path here
                // and settle for line 1.
                if (std.mem.lastIndexOf(u8, text, " b/")) |i|
                    path = copy(&path_buf, text[i + 3 ..]);
                break;
            }
            if (hunk_row == null and std.mem.startsWith(u8, text, "@@")) {
                hunk_line = parse_hunk_new_start(text) orelse continue;
                hunk_row = row;
                continue;
            }
            // A body line adding text that itself starts with "++ " would look
            // like a header, so require the --- line that always precedes one.
            if (std.mem.startsWith(u8, text, "+++ ") and row > 0 and
                std.mem.startsWith(u8, read(&line, buf_root, row - 1, editor.metrics), "--- "))
            {
                const p = read(&line, buf_root, row, editor.metrics)[4..];
                if (std.mem.eql(u8, p, "/dev/null")) {
                    const logger = log.logger("diff");
                    defer logger.deinit();
                    logger.print("file was deleted in this diff", .{});
                    return;
                }
                path = copy(&path_buf, if (std.mem.startsWith(u8, p, "b/")) p[2..] else p);
            }
        }

        const file = path orelse return;

        var target = hunk_line;
        if (hunk_row) |hr| {
            var r = hr + 1;
            while (r < cursor_row) : (r += 1) {
                const text = read(&line, buf_root, r, editor.metrics);
                // An empty line is an empty context line; git omits the space.
                if (text.len == 0) {
                    target += 1;
                } else switch (text[0]) {
                    ' ', '+' => target += 1,
                    '-', '\\' => {},
                    // A new file header means the hunk ended above the cursor.
                    else => break,
                }
            }
        }

        // git writes paths relative to the repository root, while navigate
        // resolves them against the project directory. Those are the same
        // directory only when flow was launched at the top of the repo, so
        // make the path absolute instead of hoping.
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        var full_buf: [std.fs.max_path_bytes]u8 = undefined;
        const target_file = if (repo_root(tp.env.get().str("project"), &root_buf)) |repo|
            std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ repo, file }) catch file
        else
            file;

        try tp.self_pid().send(.{ "cmd", "navigate", .{ .file = target_file, .line = @as(i64, @intCast(target)) } });
    }
    pub const goto_diff_location_meta: Meta = .{
        .description = "Open the file under the cursor in a diff",
        .arguments = &.{.string},
    };

    fn fallthrough(name: []const u8, ctx: Ctx) Result {
        return command.executeName(name, .empty_from(ctx));
    }

    /// Walk up from `dir` looking for a `.git` entry. It may be a directory or,
    /// in a worktree or submodule, a file -- statFile finds either.
    fn repo_root(dir: []const u8, buf: []u8) ?[]const u8 {
        if (dir.len == 0) return null;
        var end = dir.len;
        while (end > 0) {
            var probe: [std.fs.max_path_bytes]u8 = undefined;
            const git = std.fmt.bufPrint(&probe, "{s}/.git", .{dir[0..end]}) catch return null;
            if (std.Io.Dir.cwd().statFile(root.get_io(), git, .{})) |_| {
                return copy(buf, dir[0..end]);
            } else |_| {
                end = std.mem.lastIndexOfScalar(u8, dir[0..end], '/') orelse return null;
            }
        }
        return null;
    }

    fn copy(buf: []u8, src: []const u8) ?[]const u8 {
        if (src.len == 0 or src.len > buf.len) return null;
        @memcpy(buf[0..src.len], src);
        return buf[0..src.len];
    }

    /// "@@ -12,7 +34,9 @@ trailing" -> 34
    fn parse_hunk_new_start(text: []const u8) ?usize {
        const plus = std.mem.indexOfScalar(u8, text, '+') orelse return null;
        var rest = text[plus + 1 ..];
        const end = std.mem.indexOfAny(u8, rest, ",  @") orelse rest.len;
        rest = rest[0..end];
        const n = std.fmt.parseInt(usize, rest, 10) catch return null;
        // A hunk that adds at the very top of a file reports +0 for an empty
        // new side; line 0 does not exist, so clamp.
        return if (n == 0) 1 else n;
    }
};
