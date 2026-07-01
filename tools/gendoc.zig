//! Build-time documentation generator. Renders, from the single command spec
//! in src/spec.zig, two artifacts that are committed to the repo:
//!
//!   man/butler.1      — a roff man page (installed by build.zig → `man butler`)
//!   docs/commands.md  — a Markdown command reference (linked from the README)
//!
//! Invoked as: gendoc <man-out-path> <md-out-path>. Run via `zig build gen-docs`
//! (or `task docs`); CI regenerates and diffs to prevent drift. It is NOT part
//! of the install/nix build — that installs the committed man page — so
//! generation never runs in a read-only build sandbox.
//!
//! Pure Zig + the standard library; imports only the spec. No new dependency,
//! so butler's offline build is untouched.

const std = @import("std");
const spec = @import("spec");

/// Last-updated date stamped into the man page's .TH line. Bump on release
/// alongside the version in build.zig.zon (kept static for reproducible
/// output — no clock read).
const doc_date = "2026-07-01";

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    var argv: std.ArrayList([]const u8) = .empty;
    var args_it = std.process.Args.Iterator.init(init.minimal.args);
    defer args_it.deinit();
    while (args_it.next()) |a| try argv.append(gpa, a);

    if (argv.items.len < 3) {
        var ebuf: [128]u8 = undefined;
        var ew = std.Io.File.stderr().writer(io, &ebuf);
        try ew.interface.writeAll("usage: gendoc <man-out-path> <md-out-path>\n");
        try ew.interface.flush();
        return error.MissingArgs;
    }

    {
        var f = try std.Io.Dir.cwd().createFile(io, argv.items[1], .{});
        defer f.close(io);
        var fbuf: [4096]u8 = undefined;
        var fw = f.writer(io, &fbuf);
        try writeMan(&fw.interface);
        try fw.interface.flush();
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, argv.items[2], .{});
        defer f.close(io);
        var fbuf: [4096]u8 = undefined;
        var fw = f.writer(io, &fbuf);
        try writeMarkdown(gpa, &fw.interface);
        try fw.interface.flush();
    }
}

// --- man page (roff) ---

/// Write `s` with roff special characters escaped: backslash and the ASCII
/// hyphen (so flag names render as `--date-from`, not typographic dashes). Spec
/// strings are otherwise plain ASCII by convention, so this is sufficient.
fn roff(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '\\' => try w.writeAll("\\e"),
        '-' => try w.writeAll("\\-"),
        else => try w.writeByte(c),
    };
}

/// Like `roff`, for text that lands at the start of an output line: a leading
/// '.' or '\'' would be parsed as a roff request there, so neutralize it with
/// the \& zero-width character. (Spec prose is currently safe; this keeps a
/// future note from silently vanishing into a bogus macro.)
fn roffLine(w: *std.Io.Writer, s: []const u8) !void {
    if (s.len > 0 and (s[0] == '.' or s[0] == '\'')) try w.writeAll("\\&");
    try roff(w, s);
}

/// `--name <arg>` (value flag) or `--name` (boolean).
fn flagSyntax(w: *std.Io.Writer, f: spec.Flag) !void {
    try roff(w, "--");
    try roff(w, f.name);
    if (f.kind == .value and f.arg.len > 0) {
        try w.writeAll(" ");
        try roff(w, f.arg);
    }
}

fn manFlags(w: *std.Io.Writer, flags: []const spec.Flag) !void {
    for (flags) |f| {
        if (f.hidden) continue;
        try w.writeAll(".TP\n.B ");
        try flagSyntax(w, f);
        try w.writeAll("\n");
        try roffLine(w, f.help);
        if (f.required) try w.writeAll(" (required)");
        try w.writeAll("\n");
        if (f.choices.len > 0) {
            try w.writeAll(".br\nvalues: ");
            for (f.choices, 0..) |c, i| {
                if (i > 0) try w.writeAll(", ");
                try roff(w, c);
            }
            try w.writeAll("\n");
        }
    }
}

/// Emit free-form notes as roff, one input line per output line, escaped. Blank
/// lines become paragraph breaks (.PP).
fn manNotes(w: *std.Io.Writer, notes: []const u8) !void {
    var it = std.mem.splitScalar(u8, notes, '\n');
    while (it.next()) |line| {
        if (line.len == 0) {
            try w.writeAll(".PP\n");
        } else {
            try roffLine(w, line);
            try w.writeAll("\n.br\n");
        }
    }
}

fn writeMan(w: *std.Io.Writer) !void {
    try w.print(".TH BUTLER 1 \"{s}\" \"butler {s}\" \"User Commands\"\n", .{ doc_date, spec.version });
    try w.writeAll(
        \\.SH NAME
        \\butler \- command\-line client for the BuchhaltungsButler (BHB) accounting API
        \\.SH SYNOPSIS
        \\.B butler
        \\.I resource verb
        \\.RI [ flags ]
        \\.SH DESCRIPTION
        \\.B butler
        \\is a small, dependency\-free client for the BuchhaltungsButler accounting
        \\API. It lists, searches and books entries from the terminal using an
        \\AWS/\fBgh\fR\-style
        \\.I "resource verb"
        \\grammar. Output is an aligned table by default, or raw JSON with
        \\.B \-\-output json
        \\for piping into \fBjq\fR.
        \\.SH RESOURCES
        \\
    );
    for (spec.commands) |c| {
        try w.writeAll(".TP\n.B ");
        try roff(w, c.name);
        try w.writeAll("\n");
        try roffLine(w, c.summary);
        try w.writeAll("\n");
    }

    try w.writeAll(".SH COMMANDS\n");
    for (spec.commands) |c| {
        if (c.verbs.len == 0) {
            // Verb-less command (status/login/logout).
            try w.writeAll(".SS ");
            try roff(w, c.name);
            try w.writeAll("\n");
            if (c.about.len > 0) {
                try manNotes(w, c.about);
            }
            continue;
        }
        for (c.verbs) |v| {
            try w.writeAll(".SS ");
            try roff(w, v.usage);
            try w.writeAll("\n");
            if (v.positionals.len > 0) {
                for (v.positionals) |p| {
                    try w.writeAll(".TP\n.B ");
                    try roff(w, p.name);
                    try w.writeAll("\n");
                    try roffLine(w, p.help);
                    try w.writeAll("\n");
                }
            }
            try manFlags(w, v.flags);
            if (v.notes.len > 0) {
                try w.writeAll(".PP\n");
                try manNotes(w, v.notes);
            }
        }
    }

    try w.writeAll(".SH GLOBAL FLAGS\n");
    try manFlags(w, &spec.global_flags);

    try w.writeAll(
        \\.SH AUTHENTICATION
        \\butler needs an API client id, an API client secret (HTTP Basic auth) and
        \\an account api_key (sent in each request body). Store them with
        \\.B butler login
        \\or via the
        \\.BR BUTLER_API_CLIENT ", " BUTLER_API_SECRET " and " BUTLER_API_KEY
        \\environment variables (which take precedence over the file).
        \\.SH FILES
        \\.TP
        \\.I ~/.config/butler/credentials
        \\INI file of profiles, mode 0600 (honours \fB$XDG_CONFIG_HOME\fR).
        \\.SH EXIT STATUS
        \\.TP
        \\.B 0
        \\success
        \\.TP
        \\.B 1
        \\API or HTTP error
        \\.TP
        \\.B 2
        \\usage error
        \\.SH SEE ALSO
        \\Full reference and examples: the project README and docs/commands.md.
        \\.SH AUTHOR
        \\An independent, unofficial client; not affiliated with BuchhaltungsButler GmbH.
        \\
    );
}

// --- markdown reference ---

fn mdFlagLine(w: *std.Io.Writer, f: spec.Flag) !void {
    if (f.hidden) return;
    try w.writeAll("- `--");
    try w.writeAll(f.name);
    if (f.kind == .value and f.arg.len > 0) {
        try w.print(" <{s}>", .{f.arg});
    }
    try w.print("` — {s}", .{f.help});
    if (f.required) try w.writeAll(" *(required)*");
    if (f.choices.len > 0) {
        try w.writeAll(". Values: ");
        for (f.choices, 0..) |c, i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("`{s}`", .{c});
        }
    }
    try w.writeAll("\n");
}

/// GitHub-Flavored-Markdown heading anchor for `slug`, replicating GFM's
/// duplicate handling: the first occurrence is bare, later ones get `-1`,
/// `-2`, … (in document order). `counts` must be fed headings in the same
/// order the body emits them so the TOC anchors match. Slugs here are already
/// lowercase single words (command/verb names), so no further slugifying.
fn mdAnchor(gpa: std.mem.Allocator, counts: *std.StringHashMapUnmanaged(usize), slug: []const u8) ![]const u8 {
    const gop = try counts.getOrPut(gpa, slug);
    if (!gop.found_existing) {
        gop.value_ptr.* = 1;
        return slug;
    }
    const n = gop.value_ptr.*;
    gop.value_ptr.* = n + 1;
    return std.fmt.allocPrint(gpa, "{s}-{d}", .{ slug, n });
}

fn writeMarkdown(gpa: std.mem.Allocator, w: *std.Io.Writer) !void {
    try w.print(
        \\# butler command reference
        \\
        \\Generated from `src/spec.zig` by `zig build gen-docs` — do not edit by hand.
        \\This is the same source the `--help` text and the `man butler` page render
        \\from. butler {s}.
        \\
        \\```
        \\butler <resource> <verb> [flags]
        \\```
        \\
        \\## Contents
        \\
        \\- [Global flags](#global-flags)
        \\
    , .{spec.version});
    // Nested TOC: bold command links, with each command's verbs as sub-links.
    // Anchors are computed in body order so duplicate verb names (list, show)
    // resolve to the right command section.
    var counts: std.StringHashMapUnmanaged(usize) = .empty;
    for (spec.commands) |c| {
        const ca = try mdAnchor(gpa, &counts, c.name);
        try w.print("- [**{s}**](#{s})\n", .{ c.name, ca });
        for (c.verbs) |v| {
            const va = try mdAnchor(gpa, &counts, v.name);
            try w.print("  - [`{s}`](#{s})\n", .{ v.name, va });
        }
    }
    try w.writeAll("\n---\n\n## Global flags\n\n");
    for (spec.global_flags) |f| try mdFlagLine(w, f);

    for (spec.commands) |c| {
        try w.print("\n---\n\n## {s}\n\n{s}\n", .{ c.name, c.summary });
        if (c.aliases.len > 0) {
            try w.writeAll("\nAliases: ");
            for (c.aliases, 0..) |a, i| {
                if (i > 0) try w.writeAll(", ");
                try w.print("`{s}`", .{a});
            }
            try w.writeAll("\n");
        }
        if (c.verbs.len == 0) {
            if (c.about.len > 0) try w.print("\n{s}\n", .{c.about});
            continue;
        }
        for (c.verbs) |v| {
            try w.print("\n### `{s}`\n\n{s}\n\n```\n{s}\n```\n", .{ v.name, v.summary, v.usage });
            if (v.positionals.len > 0) {
                try w.writeAll("\n**Arguments:**\n\n");
                for (v.positionals) |p| {
                    try w.print("- `{s}` — {s}\n", .{ p.name, p.help });
                }
            }
            var any = false;
            for (v.flags) |f| {
                if (!f.hidden) any = true;
            }
            if (any) {
                try w.writeAll("\n**Flags:**\n\n");
                for (v.flags) |f| try mdFlagLine(w, f);
            }
            if (v.notes.len > 0) try w.print("\n{s}\n", .{v.notes});
        }
    }
}
