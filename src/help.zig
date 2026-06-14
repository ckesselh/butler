//! `--help` rendering (overview and per-command), driven entirely by the
//! command spec — the same data the man page and docs/commands.md come from.

const std = @import("std");
const spec = @import("spec.zig");
const ui = @import("util/ui.zig");

const flag_col = 24; // left column width for flag/verb listings

fn head(w: *std.Io.Writer, s: ui.Style, title: []const u8) !void {
    try w.print("{s}{s}{s}\n", .{ s.head, title, s.reset });
}

/// One aligned "  name<pad>desc" row, name bolded.
fn row(w: *std.Io.Writer, s: ui.Style, name: []const u8, desc: []const u8) !void {
    try w.print("  {s}{s}{s}", .{ s.bold, name, s.reset });
    if (name.len + 2 < flag_col) {
        for (0..flag_col - (name.len + 2)) |_| try w.writeByte(' ');
    } else {
        try w.writeByte(' ');
    }
    try w.print("{s}\n", .{desc});
}

fn usage(w: *std.Io.Writer, s: ui.Style, line: []const u8) !void {
    try head(w, s, "USAGE");
    try w.print("  {s}\n\n", .{line});
}

/// "--name <arg>" label for a flag.
fn flagLabel(buf: []u8, f: spec.Flag) []const u8 {
    if (f.kind == .value and f.arg.len > 0) {
        return std.fmt.bufPrint(buf, "--{s} <{s}>", .{ f.name, f.arg }) catch f.name;
    }
    return std.fmt.bufPrint(buf, "--{s}", .{f.name}) catch f.name;
}

/// Render a flag row plus, when present, "(required)" and a wrapped values line.
fn flagRow(w: *std.Io.Writer, s: ui.Style, f: spec.Flag) !void {
    var buf: [64]u8 = undefined;
    if (f.required) {
        var hbuf: [256]u8 = undefined;
        const desc = std.fmt.bufPrint(&hbuf, "{s} (required)", .{f.help}) catch f.help;
        try row(w, s, flagLabel(&buf, f), desc);
    } else {
        try row(w, s, flagLabel(&buf, f), f.help);
    }
    if (f.choices.len > 0) {
        try w.print("  {s}", .{s.dim});
        for (0..flag_col - 2) |_| try w.writeByte(' ');
        try w.writeAll("values: ");
        for (f.choices, 0..) |c, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(c);
        }
        try w.print("{s}\n", .{s.reset});
    }
}

/// `butler --help` — overview; points at per-command help.
pub fn overview(w: *std.Io.Writer, s: ui.Style) !void {
    try w.print(
        \\{[d]s} _           _   _
        \\| |__  _   _| |_| | ___ _ __
        \\| '_ \| | | | __| |/ _ \ '__|
        \\| |_) | |_| | |_| |  __/ |
        \\|_.__/ \__,_|\__|_|\___|_|{[r]s}
        \\
        \\butler — CLI for the BuchhaltungsButler (BHB) accounting API
        \\
        \\
    , .{ .d = s.dim, .r = s.reset });

    try usage(w, s, "butler <resource> <verb> [flags]");

    try head(w, s, "RESOURCES");
    for (spec.commands) |c| try row(w, s, c.name, c.summary);
    try w.writeByte('\n');

    try head(w, s, "GLOBAL FLAGS");
    var buf: [64]u8 = undefined;
    for (spec.global_flags) |f| {
        if (f.hidden) continue;
        try row(w, s, flagLabel(&buf, f), f.help);
    }
    try w.writeByte('\n');

    try w.print("{s}Run `butler <resource> <verb> --help` for command-specific flags.{s}\n\n", .{ s.dim, s.reset });

    try head(w, s, "EXAMPLES");
    try w.writeAll("  butler bookings list --date-from 2026-04-01 --date-to 2026-04-30\n");
    try w.writeAll("  butler transactions show 417\n");
    try w.writeAll("  butler bookings add --help\n");
}

/// `butler <resource> [verb] --help` — command-specific help. With no/unknown
/// verb, prints the command's `about` (verb-less commands) or lists its verbs.
pub fn command(r: spec.Resource, verb: []const u8, w: *std.Io.Writer, s: ui.Style) !void {
    const cmd = spec.resolveCommand(@tagName(r)) orelse return overview(w, s);

    if (spec.resolveVerb(cmd, verb)) |v| {
        try usage(w, s, v.usage);
        if (v.positionals.len > 0) {
            try head(w, s, "ARGUMENTS");
            for (v.positionals) |p| try row(w, s, p.name, p.help);
            try w.writeByte('\n');
        }
        if (v.flags.len > 0) {
            try head(w, s, "FLAGS");
            for (v.flags) |f| {
                if (f.hidden) continue;
                try flagRow(w, s, f);
            }
            try w.writeByte('\n');
        }
        if (v.notes.len > 0) {
            try w.writeAll(v.notes);
            try w.writeByte('\n');
        }
        return;
    }

    // No (or unknown) verb. Verb-less commands print their about text; grouped
    // commands list their verbs.
    if (cmd.about.len > 0) {
        try usage(w, s, cmd.name);
        try w.writeAll(cmd.about);
        try w.writeByte('\n');
        return;
    }
    var ubuf: [64]u8 = undefined;
    try usage(w, s, std.fmt.bufPrint(&ubuf, "butler {s} <verb>", .{cmd.name}) catch cmd.name);
    try head(w, s, "VERBS");
    for (cmd.verbs) |v| try row(w, s, v.name, v.summary);
}
