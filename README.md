# Flow Control: a programmer's text editor

This is my Zig text editor. It is under active development, but very stable
and is my daily driver for almost everything.

[![Announcement](https://img.youtube.com/vi/Mf3k2uFkyK4/maxresdefault.jpg)](https://www.youtube.com/watch?v=Mf3k2uFkyK4)



# About this fork

This is a personal fork of [neurocyte/flow](https://github.com/neurocyte/flow),
kept for my own use rather than for upstream pull requests. It adds
git-review and code-navigation features I missed coming from another editor.
Everything below is additive: no upstream command or binding changes meaning.
The one exception is Enter, which learns to jump from diff buffers and does
exactly what it did before everywhere else.

The fork lives on the `diff-against-ref` branch.

## What the fork adds

| Feature | Command | flow keys | vim keys |
|---|---|---|---|
| Diff against a branch | `diff_against_ref [ref]` | palette | palette |
| Jump from a diff line to the source | `goto_diff_location` | `enter` in a diff buffer | `<CR>` in a diff buffer |
| Changed files list | `show_changed_files [ref]` | `ctrl+alt+c` | `<Space>gc` |
| All changed hunks | `show_vcs_hunks [ref]` | `ctrl+alt+h` | `<Space>gh` |
| Project diagnostics | `show_project_diagnostics` | `ctrl+alt+m` | `<Space>sD` |
| Call hierarchy, incoming | `show_incoming_calls` | `ctrl+shift+f12` | `<Space>ci` |
| Call hierarchy, outgoing | `show_outgoing_calls` | `ctrl+alt+f12` | `<Space>co` |
| Line blame in the browser | `open_vcs_blame_in_browser` | `alt+shift+b` | `<Space>gb` |
| Jump to buffer by number | `goto_buffer N` | `ctrl+shift+1..9` | `ctrl+shift+1..9`, `alt+1..9` |
| Source preview beside file lists | automatic | | |

Commands that take `[ref]` can be run from the command palette with an
argument, or bound with one, for example `["ctrl+k ctrl+d", "diff_against_ref", "main"]`.

### Diff against a branch

`diff_against_ref` opens `git diff <ref>...HEAD` in a read-only scratch buffer
with diff highlighting. Three dots, so the comparison starts at the merge base:
it shows this branch's own work, not what landed on the other branch since.
The output streams in as git produces it.

Without an argument the ref is resolved from `origin/HEAD`, `origin/master`,
`origin/main`, `master`, `main`, in that order. Remote-tracking refs come first
because a local `master` that nobody pulled sits behind the remote, and a merge
base against it reaches back past the fork point.

In a fork of someone else's repository `origin` is your copy and may be the stale
one. Pass the ref explicitly there, for example `diff_against_ref upstream/master`.

### Jump from a diff to the source

Enter on a line of any diff buffer (`diff_against_ref`, `show_changed_files`)
opens the file at that line. The line number is counted from the hunk header:
context and added lines advance it, removed lines do not. On a removed line the
jump lands where that line used to be. Paths are resolved against the git
repository root, so this works when flow was started in a subdirectory.

In every other buffer Enter runs the command it ran before. The keymap passes
that command as the argument: `smart_insert_line` in the flow keymap, and
`move_down` followed by `move_begin` in vim.

If your own `~/.config/flow/keys/flow.json` defines the `normal` mode, it
replaces the fork's Enter binding. Use the same form there:

```json
["enter", "goto_diff_location", "smart_insert_line"]
```

### Changed files

`show_changed_files` lists each changed file once. A row shows the status (`A`
added, `M` modified, `R` renamed, `D` deleted), the added and removed line
counts, and the first changed line. Enter opens that file's diff, and Enter in
the diff continues to the source.

Without an argument the list compares the working tree against `HEAD`, staged
and unstaged changes included. With a ref it uses `git diff --merge-base <ref>`:
the comparison starts where the branch left the ref and includes uncommitted work.
Line numbers match the files as they are on disk. Untracked files are not part of
`git diff` and are not listed.

### All changed hunks

`show_vcs_hunks` lists every hunk in the repository. A row shows the file, the
first changed line, the added and removed counts, and git's function context.
Enter opens the hunk. It accepts the same optional ref as `show_changed_files`.

### Project diagnostics

Upstream `show_diagnostics` covers only the active file. The fork keeps every
diagnostic the language servers publish, per file, including files that are not
open. `show_project_diagnostics` lists them all. While the panel is open it
updates as the servers publish, but it never opens by itself.

The list is only as complete as the servers make it. Many analyse only files
they were told about. flow also does not tell servers when an unopened file
changes on disk, so those entries update only after the file is opened or saved
in flow.

### Call hierarchy

`show_incoming_calls` opens a tree rooted at the function under the cursor,
with its callers below. `show_outgoing_calls` shows the functions it calls
instead. The keys work as follows:

- Right expands a node and loads its children on demand.
- Left collapses a node, or moves to its parent.
- Enter jumps to the call site, or to the definition for the root.
- Typing filters the tree.

A row shows the call site and, when there is more than one, the number of calls.

The language server must support call hierarchy. gopls, clangd and
rust-analyzer do. ols (Odin) does not, and flow says so.

### Line blame in the browser

`open_vcs_blame_in_browser` traces the line under the cursor to the commit that
last changed it. It opens that commit's blame page on the `origin` remote, at the
file path and line number from that commit, so the link stays correct after
renames and after lines above it moved. Lines changed locally have no commit and
open nothing.

GitHub and GitLab URLs are supported. Remotes can be `git@host:owner/repo`,
`ssh://user@host[:port]/owner/repo`, or `https://`. The page opens with `open` on
macOS and `xdg-open` elsewhere.

### Jump to a buffer by number

`goto_buffer N` switches to the Nth open buffer, counted in the order buffers
were opened, like tabs:

- Visiting a buffer does not renumber the others.
- Closing a buffer shifts the later numbers down by one.
- A reopened buffer goes to the end.
- Sessions store buffers in this order.

`ctrl+<digit>` still focuses splits. `ctrl+shift+<digit>` needs a terminal with
the kitty keyboard protocol. Most macOS terminals do not have it, and there
`alt+<digit>` works in the vim keymap. The flow keymap already uses `alt+<digit>`
for numeric arguments.

### Source preview beside file lists

File lists in the bottom panel show the code around the selected row to the
right of the list: find in files, references, diagnostics, project diagnostics,
hunks and changed files. The preview has line numbers and syntax highlighting,
centres the target line and highlights it, and follows the selection.

- **Text source:** an open buffer supplies its text, including unsaved edits.
  Other files are read from disk, up to 2 MiB.
- **Binary and oversized files:** the preview shows a note instead of text.
- **Narrow panels:** below 100 columns the preview is hidden and the list uses the
  full width.
- **Caching:** each file is loaded and parsed once per path. Edits made while the
  list stays on that file appear after you move to another file.

## Where the code lives

| Area | Files |
|---|---|
| Diff, changed files, hunks, blame, project diagnostics, buffer numbers | `src/tui/mainview.zig` (commands in `cmds`, state fields on the view) |
| Call hierarchy requests | `src/LSP.zig` (`send_request_raw`), `src/LSPClient.zig`, `src/Project.zig`, `src/project_manager.zig` |
| Call hierarchy tree | `src/tui/mode/overlay/call_hierarchy_palette.zig`, left/right hooks in `palette.zig` |
| Source preview | `src/tui/FilePreview.zig`, layout in `src/tui/filelist_view.zig` |
| Buffer open order | `src/buffer/Buffer.zig` (`open_seq`), `src/buffer/Manager.zig` |
| New list kinds | `src/tui/FileList.zig` |
| Diff row mapping to HEAD | `src/tui/editor.zig` (`head_row_for`) |
| Bindings | `src/keybind/builtin/flow.json`, `src/keybind/builtin/vim.json` |

Git and language-server work runs in the background: git as child processes
through `shell.execute`, and LSP requests through the existing language-server
actors. Results stream back as messages. The source preview is the exception:
the first time it shows a file, it reads and parses that file on the UI thread.

## Keeping up with upstream

```sh
git remote add upstream https://github.com/neurocyte/flow.git   # once
git config rerere.enabled true                                  # once: git remembers resolved conflicts

git fetch upstream
git checkout diff-against-ref
git merge upstream/master
zig build && zig build test
```

Merge rather than rebase. A merge resolves conflicts once for the whole range.
A rebase replays each fork commit and can raise the same conflict in several of
them.

The fork is about 2,000 added lines in 16 files, with 8 upstream lines changed.
Two files are entirely new, and most of the rest is new code added at the end of
existing blocks. Conflicts therefore tend to be small: a field or import added
next to a line upstream also touched. The resolution is usually to keep both
sides.

Expect more work from upstream refactors than from textual conflicts. Flow is
under active development, and a rewrite of an API the fork calls, such as the
panel system or `add_filelist_entry`, can merge cleanly and then fail to compile.
Always build after merging. The files upstream changes most often are
`src/tui/tui.zig`, `src/tui/mainview.zig`, `src/tui/editor.zig` and
`src/keybind/builtin/flow.json`.

# Features

- **Lightning Fast** TUI with ≤6ms frame times, **low latency** input
  handling and smooth **animated scrolling**
- Intuitive UI with **tabs**, **scrollbars** and **palettes** with full
  **mouse** support for all UI elements
- Support for more than **70 programming languages**, **zero
  configuration** needed, via **tree-sitter** powered syntax highlighting
- **Language Server Protocol** pre configured support for most language
  servers
- Powerful **multi-cursor** editing and integrated **clipboard history**
- Powerful configurable keybinding system that supports **modal** and
  **non-modal** editing styles
- Multiple pre-configured **keybinding modes**
    - Flow Control - GUI IDE style bindings (similar to vscode)
    - Emacs
    - Vim
    - Helix
    - User created
- Hybrid rope/piece-table buffer system, edit **very large files** with
  **thousands of cursors**
- Infinite **undo** (at least until you run out of ram)
- Full **unicode** support, including support for the kitty text sizing
  protocol
- Plenty of **themes** included and support for vscode themes via the
  flow-themes project
- Runs on **Linux, FreeBSD, MacOS, Windows and Android** (under termux)
  with easy **cross-compilation** to all supported targets


# Requirements

- A modern terminal with **24bit color** and, ideally, **kitty keyboard
  protocol** support. **Kitty**, **Foot** and **Ghostty** are the
  recommended terminals at this time. **Zellij** also works well. Most
  other terminals will work, but likely with reduced functionality.
- **NerdFont** support. Either via terminal font fallback or a patched
  font.
- A **UTF-8** locale


# Roadmap

See our [devlog](https://flow-control.dev/devlog/2026/) for on-going
updates from the development team.

## In Development

- LSP completion support
- Persistent undo/redo
- File watcher integration

## Future

- Collaborative editing
- Plugin system
- Multi-terminal sessions


# Installer and manual downloads

There is an [installation guide](https://flow-control.dev/installation) on
the main website with instructions for using the installer script. Direct
downloads of source tarballs and release and nightly binary builds are
listed on the [downloads](https://flow-control.dev/downloads) page.

Or check your favorite local system package repository.

[![Packaging status](https://repology.org/badge/vertical-allrepos/flow-control.svg)](https://repology.org/project/flow-control/versions)


# Building

Make sure your system meets the requirements listed above.

Flow builds with zig 0.16 at this time. Build with:

```shell
zig build -Doptimize=ReleaseSafe
```

Zig will by default build a binary optimized for your specific CPU. If you
get illegal instruction errors add `-Dcpu=baseline` to the build command to
produce a binary with generic CPU support.


Thanks to Zig you may also cross-compile from any host to pretty much any
target. For example:

```shell
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-windows --prefix zig-out/x86_64-windows
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-macos-none --prefix zig-out/x86_64-macos
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-musl --prefix zig-out/aarch64-linux
```

When cross-compiling zig will build a binary with generic CPU support.


The output binary is:

```
zig-out/bin/flow
```

It is statically built (by default) and contains all the required
tree-sitter parsers and queries. No additional runtime files are required.


# Running Flow Control

The Flow Control binary is called `flow`.

Place it in your path for convenient access:

```shell
sudo cp zig-out/bin/flow /usr/local/bin
```

Or if you prefer, let zig install it in your home directory:

```shell
zig build -Doptimize=ReleaseSafe --prefix ~/.local
```

Flow Control is a single statically linked binary. No further runtime files
are required. You may install it on another system by simply copying the
binary.

```shell
scp zig-out/bin/flow root@otherhost:/usr/local/bin
```

Files to load may be specifed on the command line:

```shell
flow fileA.zig fileB.zig
```

The last file will be opened and the previous files will be placed in
reverse order at the top of the recent files list. Switch to recent files
with Ctrl-e.

Common target line specifiers are supported too:

```shell
flow file.txt:123
```

Or Vim style:

```shell
flow file.txt +123
```

Use the --language option to force the file type of a file:

```shell
flow --language bash ~/.bash_profile
```

Show supported language names with `--list-languages`.

See `flow --help` for the full list of command line options.


# Documentation

## User manual

A basic user manual is available inside flow. You can open it with the
`Open help` command (F1).

It is also available in the website
[documentation](https://flow-control.dev/docs/) section.

## Development Resources

Additional [developer](https://flow-control.dev/docs/#resources) resources
can be found on the Flow Control website at.

There is also an AI generated developer guide at
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/neurocyte/flow).
Accuracy may vary. Check details against the referenced source code.


# Configuration

Configuration is mostly dynamically maintained with various commands in the
UI. It is stored under the standard user configuration path. Usually
`~/.config/flow` on Linux. %APPDATA%\Roaming\flow on Windows. Somewhere
magical on MacOS.

There are commands to open the various configuration files, so you don't
have to manually find them. Look for commands starting with `Edit` in the
command palette.

File types may be configured with the `Edit file type configuration`
command. You can also create a new file type by adding a new `.conf` file
to the `file_type` directory. Have a look at an existing file type to see
what options are available.

Logs, traces and per-project most recently used file lists are stored in
the standard user application state directory. Usually
`~/.local/state/flow` on Linux and %APPDATA%\Roaming\flow on Windows.


# Key bindings and commands

Press `F1` to view the online manual.
Press `F4` to switch the current keybinding mode. (flow, vim, emacs, etc.)
Press `ctrl+shift+p` or `alt+x` to show the command palette.
Press `ctrl+F2` to see a full list of all current keybindings and commands.

Run the `Edit keybindings` command to customize the current keybinding
mode. It opens a file in your `keys` directory (under the same name) that
inherits from the built-in mode, so you can add or override individual
keybindings. Keybindings added by future updates ar inherited
automatically. Keybinding changes take effect on restart.


# Terminal configuration

Kitty, Ghostty and most other terminals have default keybindings that
conflict with common editor commands. I highly recommend rebinding them to
keys that are not generally used anywhere else.

For Kitty rebinding `kitty_mod` is usually enough:
```
kitty_mod ctrl+alt
```

For Ghostty each conflicting binding has to be reconfigured individually.


# Community

![Discord](https://img.shields.io/discord/1214308467553341470)

Join our [Discord](https://discord.com/invite/4wvteUPphx) server or use the
discussions section here on GitHub to meet with other Flow users!
