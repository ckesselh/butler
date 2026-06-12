//! Terminal presentation: ANSI style detection (TTY + NO_COLOR).

const std = @import("std");

/// ANSI styles, resolved against the output terminal. All fields are empty
/// strings when output is not a TTY or `NO_COLOR` is set, so callers can splice
/// them in unconditionally.
pub const Style = struct {
    head: []const u8 = "",
    bold: []const u8 = "",
    dim: []const u8 = "",
    reset: []const u8 = "",

    pub fn detect(io: std.Io, env: *const std.process.Environ.Map) Style {
        // Honor https://no-color.org and skip colors when piped/redirected.
        if (env.get("NO_COLOR") != null) return .{};
        const tty = std.Io.File.stdout().isTty(io) catch return .{};
        if (!tty) return .{};
        return .{
            .head = "\x1b[1;36m", // bold cyan section headers
            .bold = "\x1b[1m",
            .dim = "\x1b[2m",
            .reset = "\x1b[0m",
        };
    }
};
