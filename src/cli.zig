//! Strict, spec-driven argv parser (two phases; see `Flags`).

const std = @import("std");
const spec = @import("spec.zig");

/// Strict argv parser. Parsing happens in two phases so flag validity can be
/// per-subcommand without a bootstrap problem:
///
///   1. `parse` walks argv generically, using spec.lookupFlag to learn each
///      flag's kind (whether it consumes a value). It collects opts/bools/
///      positionals and rejects flags unknown to the *entire* command tree.
///   2. `validate` (called once the resource+verb are resolved) checks the
///      collected flags against that one verb: flag-valid-for-this-command,
///      required flags present, closed `choices` membership, and int bounds.
///
/// On the first error either phase records `parse_error` and stops; the caller
/// prints it and exits with a usage error (2).
///
/// Limitation: a value that itself starts with `--` must be passed inline
/// (`--filter=--foo`); in the space-separated form it reads as the next flag
/// and yields "missing value".
pub const Flags = struct {
    gpa: std.mem.Allocator,
    opts: std.StringHashMapUnmanaged([]const u8) = .empty,
    // Value is the parsed boolean: bare/`=true` → true, `=false` → false. We
    // store `=false` (rather than dropping it) so validate() can still reject a
    // boolean supplied to a verb that doesn't accept it.
    bools: std.StringHashMapUnmanaged(bool) = .empty,
    positionals: std.ArrayList([]const u8) = .empty,
    parse_error: ?[]const u8 = null,

    // Propagates OOM rather than falling back to a static message: parse_error
    // is then uniformly heap-owned, so callers (and failure-injection tests)
    // never face mixed ownership.
    fn fail(self: *Flags, comptime fmt: []const u8, args: anytype) !void {
        self.parse_error = try std.fmt.allocPrint(self.gpa, fmt, args);
    }

    pub fn deinit(self: *Flags) void {
        self.opts.deinit(self.gpa);
        self.bools.deinit(self.gpa);
        self.positionals.deinit(self.gpa);
        if (self.parse_error) |e| self.gpa.free(e);
    }

    pub fn parse(gpa: std.mem.Allocator, args: []const []const u8) !Flags {
        var f = Flags{ .gpa = gpa };
        var i: usize = 0;
        var only_pos = false;
        while (i < args.len) : (i += 1) {
            const a = args[i];

            // A bare "--" turns off flag parsing for the rest of argv.
            if (!only_pos and std.mem.eql(u8, a, "--")) {
                only_pos = true;
                continue;
            }
            if (!only_pos and std.mem.startsWith(u8, a, "--") and a.len > 2) {
                // Split off an inline `--name=value`, if present.
                var name = a[2..];
                var inline_val: ?[]const u8 = null;
                if (std.mem.indexOfScalar(u8, name, '=')) |e| {
                    inline_val = name[e + 1 ..];
                    name = name[0..e];
                }

                const fl = spec.lookupFlag(name) orelse {
                    try f.fail("unknown flag --{s}", .{name});
                    return f;
                };

                switch (fl.kind) {
                    // Boolean: present means true; only =true/=false allowed inline.
                    .boolean => {
                        if (inline_val) |v| {
                            if (std.mem.eql(u8, v, "true")) {
                                try f.bools.put(gpa, name, true);
                            } else if (std.mem.eql(u8, v, "false")) {
                                try f.bools.put(gpa, name, false);
                            } else {
                                try f.fail("invalid boolean for --{s} (use true/false)", .{name});
                                return f;
                            }
                        } else {
                            try f.bools.put(gpa, name, true);
                        }
                    },
                    // Value: take the inline value or consume the next arg.
                    .value => {
                        if (inline_val) |v| {
                            try f.opts.put(gpa, name, v);
                        } else if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "--")) {
                            i += 1;
                            try f.opts.put(gpa, name, args[i]);
                        } else {
                            try f.fail("missing value for --{s}", .{name});
                            return f;
                        }
                    },
                }
            } else {
                // Anything else is a positional argument.
                try f.positionals.append(gpa, a);
            }
        }
        return f;
    }

    /// Phase 2: validate the collected flags against a resolved verb. Records
    /// the first error in `parse_error`. Safe to call only after `parse`
    /// succeeded (parse_error == null).
    pub fn validate(self: *Flags, verb: *const spec.Verb) !void {
        // Every supplied flag must be valid for THIS command (or be global),
        // and any closed value set must be satisfied.
        var oit = self.opts.iterator();
        while (oit.next()) |e| {
            const name = e.key_ptr.*;
            const fl = spec.verbFlag(verb, name) orelse {
                try self.fail("--{s} is not valid for `{s}`", .{ name, verb.usage });
                return;
            };
            if (fl.choices.len > 0 and !spec.inChoices(fl.choices, e.value_ptr.*)) {
                const allowed = try std.mem.join(self.gpa, ", ", fl.choices);
                try self.fail("invalid value '{s}' for --{s} (allowed: {s})", .{ e.value_ptr.*, name, allowed });
                return;
            }
            if (fl.int) {
                // Match addIntOpt's trim so validate and the handler agree.
                const parsed = std.fmt.parseInt(i64, std.mem.trim(u8, e.value_ptr.*, " \t"), 10) catch {
                    try self.fail("--{s} must be an integer (got '{s}')", .{ name, e.value_ptr.* });
                    return;
                };
                if (fl.min) |m| {
                    if (parsed < m) {
                        try self.fail("--{s} must be >= {d} (got {d})", .{ name, m, parsed });
                        return;
                    }
                }
            }
        }
        var bit = self.bools.keyIterator();
        while (bit.next()) |k| {
            if (spec.verbFlag(verb, k.*) == null) {
                try self.fail("--{s} is not valid for `{s}`", .{ k.*, verb.usage });
                return;
            }
        }

        // Required flags must be present.
        for (verb.flags) |fl| {
            if (!fl.required) continue;
            const present = switch (fl.kind) {
                .boolean => self.bools.contains(fl.name),
                .value => self.opts.contains(fl.name),
            };
            if (!present) {
                try self.fail("missing required flag --{s}", .{fl.name});
                return;
            }
        }
    }

    pub fn opt(self: *const Flags, name: []const u8) ?[]const u8 {
        return self.opts.get(name);
    }

    pub fn has(self: *const Flags, name: []const u8) bool {
        return self.bools.get(name) orelse false;
    }

    pub fn pos(self: *const Flags, idx: usize) ?[]const u8 {
        if (idx < self.positionals.items.len) return self.positionals.items[idx];
        return null;
    }
};

/// Print a "<thing> required" usage error and return exit code 2.
pub fn missing(stderr: *std.Io.Writer, what: []const u8) !u8 {
    try stderr.print("error: {s} required\n", .{what});
    return 2;
}

/// Print an "unknown verb" usage error and return exit code 2.
pub fn unknownVerb(stderr: *std.Io.Writer, verb: []const u8, allowed: []const u8) !u8 {
    try stderr.print("error: unknown verb '{s}'. allowed: {s}\n", .{ verb, allowed });
    return 2;
}

test "parse basics" {
    const gpa = std.testing.allocator;
    var f = try Flags.parse(gpa, &.{ "postings", "list", "--date-from", "2026-05-01", "--dry-run", "--limit=10" });
    defer f.deinit();
    try std.testing.expect(f.parse_error == null);
    try std.testing.expectEqualStrings("postings", f.pos(0).?);
    try std.testing.expectEqualStrings("2026-05-01", f.opt("date-from").?);
    try std.testing.expectEqualStrings("10", f.opt("limit").?);
    try std.testing.expect(f.has("dry-run"));
}

test "missing value errors" {
    const gpa = std.testing.allocator;
    var f = try Flags.parse(gpa, &.{ "postings", "list", "--date-from", "--date-to", "x" });
    defer f.deinit();
    try std.testing.expect(f.parse_error != null);
}

test "unknown flag errors" {
    const gpa = std.testing.allocator;
    var f = try Flags.parse(gpa, &.{ "postings", "list", "--bogus", "x" });
    defer f.deinit();
    try std.testing.expect(f.parse_error != null);
}

test "validate: int bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const cmd = spec.resolveCommand("postings").?;
    var f = try Flags.parse(gpa, &.{ "postings", "list", "--date-from", "a", "--date-to", "b", "--limit", "-5" });
    try std.testing.expect(f.parse_error == null);
    try f.validate(spec.resolveVerb(cmd, "list").?);
    try std.testing.expect(f.parse_error != null);
}

// validate() allocates transient strings (joined choice lists, error text) the
// same way main() does — under an arena that frees them at exit. The tests use
// an arena to mirror that, so no per-allocation frees are needed.

test "validate: per-verb flag rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    // --vat is a postings-create flag; it must be rejected on `accounts list`.
    var f = try Flags.parse(gpa, &.{ "accounts", "list", "--vat", "0_none" });
    try std.testing.expect(f.parse_error == null);
    const cmd = spec.resolveCommand("accounts").?;
    try f.validate(spec.resolveVerb(cmd, "list").?);
    try std.testing.expect(f.parse_error != null);
}

test "validate: false boolean still rejected on the wrong verb" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    // --dry-run=false is inactive but must still be rejected where it isn't a flag.
    var f = try Flags.parse(gpa, &.{ "accounts", "list", "--dry-run=false" });
    try std.testing.expect(f.parse_error == null);
    try std.testing.expect(!f.has("dry-run")); // =false ⇒ inactive
    const cmd = spec.resolveCommand("accounts").?;
    try f.validate(spec.resolveVerb(cmd, "list").?);
    try std.testing.expect(f.parse_error != null);
}

test "validate: missing required and bad choice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const cmd = spec.resolveCommand("postings").?;
    {
        var f = try Flags.parse(gpa, &.{ "postings", "list" });
        try f.validate(spec.resolveVerb(cmd, "list").?); // missing --date-from/--date-to
        try std.testing.expect(f.parse_error != null);
    }
    {
        var f = try Flags.parse(gpa, &.{ "postings", "add", "--vat", "99_bad" });
        try f.validate(spec.resolveVerb(cmd, "add").?); // invalid --vat choice
        try std.testing.expect(f.parse_error != null);
    }
}
