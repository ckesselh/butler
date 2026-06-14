//! Shared per-line gathering for the array-shaped posting endpoints
//! (`/postings/add/receipt`, `/postings/add/transaction`): each line charges one
//! account `amount` at `vat` with `postingtext`, taken from single-line flags or
//! a --from-json array. The endpoint-specific envelope (anchor id, creditor /
//! debtor, oi nulls) is built by the caller around these parallel arrays.

const std = @import("std");
const cli = @import("../cli.zig");
const spec = @import("../spec.zig");
const json = @import("../util/json.zig");
const money = @import("../util/money.zig");
const Client = @import("../client.zig").Client;

pub const Line = struct {
    account: []const u8,
    postingtext: []const u8,
    amount: []const u8,
    vat: []const u8,
};

/// The validated lines, or the process exit code to return when the input was
/// malformed (the diagnostic is already printed).
pub const Result = union(enum) { lines: []Line, fail: u8 };

/// Build the JSON arrays a caller passes to ObjBuilder.arrStr.
pub const Arrays = struct {
    accounts: [][]const u8,
    texts: [][]const u8,
    vats: [][]const u8,
    amounts: [][]const u8,
};

pub fn toArrays(gpa: std.mem.Allocator, lines: []const Line) !Arrays {
    const n = lines.len;
    var a: Arrays = .{
        .accounts = try gpa.alloc([]const u8, n),
        .texts = try gpa.alloc([]const u8, n),
        .vats = try gpa.alloc([]const u8, n),
        .amounts = try gpa.alloc([]const u8, n),
    };
    for (lines, 0..) |l, i| {
        a.accounts[i] = l.account;
        a.texts[i] = l.postingtext;
        a.vats[i] = l.vat;
        a.amounts[i] = l.amount;
    }
    return a;
}

/// Gather the lines from --from-json or the single-line flags, validate each
/// (positive amount, known vat) and canonicalize the amount so the bytes sent
/// are exactly the bytes checked.
pub fn gather(c: Client, f: *const cli.Flags, stderr: *std.Io.Writer) !Result {
    const gpa = c.gpa;
    var lines: std.ArrayList(Line) = .empty;

    if (f.opt("from-json")) |path| {
        // The two input modes are exclusive; a stray line flag would otherwise
        // be silently ignored in favour of the file.
        for ([_][]const u8{ "account", "amount", "vat", "text" }) |name| {
            if (f.opt(name) != null) {
                try stderr.print("error: --{s} cannot be combined with --from-json (the file defines the lines)\n", .{name});
                return .{ .fail = 2 };
            }
        }
        const text = std.Io.Dir.cwd().readFileAlloc(c.io, path, gpa, .limited(1 << 20)) catch |e| {
            try stderr.print("error: cannot read {s}: {s}\n", .{ path, @errorName(e) });
            return .{ .fail = 1 };
        };
        // Not deinit-ed: the returned Line slices reference this parse tree, which
        // the process arena reclaims at exit.
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch |e| {
            try stderr.print("error: invalid JSON in {s}: {s}\n", .{ path, @errorName(e) });
            return .{ .fail = 1 };
        };
        const arr = switch (parsed.value) {
            .array => |a| a,
            else => {
                try stderr.writeAll("error: --from-json must contain a JSON array of posting lines\n");
                return .{ .fail = 1 };
            },
        };
        for (arr.items, 0..) |item, idx| {
            const o = switch (item) {
                .object => |x| x,
                else => {
                    try stderr.print("line {d}: not a JSON object\n", .{idx});
                    return .{ .fail = 1 };
                },
            };
            const line: Line = .{
                .account = json.getStr(o, "account") orelse return lineMissing(stderr, idx, "account"),
                .postingtext = json.getStr(o, "postingtext") orelse return lineMissing(stderr, idx, "postingtext"),
                .amount = json.getStr(o, "amount") orelse return lineMissing(stderr, idx, "amount"),
                .vat = json.getStr(o, "vat") orelse return lineMissing(stderr, idx, "vat"),
            };
            try lines.append(gpa, line);
        }
    } else {
        const line: Line = .{
            .account = f.opt("account") orelse return flagMissing(stderr, "--account (or --from-json)"),
            .postingtext = f.opt("text") orelse return flagMissing(stderr, "--text"),
            .amount = f.opt("amount") orelse return flagMissing(stderr, "--amount"),
            .vat = f.opt("vat") orelse return flagMissing(stderr, "--vat (e.g. 0_none, 19_pre)"),
        };
        try lines.append(gpa, line);
    }

    if (lines.items.len == 0) {
        try stderr.writeAll("error: no posting lines\n");
        return .{ .fail = 1 };
    }
    for (lines.items, 0..) |*l, i| {
        const cents = money.parseCents(l.amount) orelse {
            try stderr.print("line {d}: amount '{s}' is not a valid decimal\n", .{ i, l.amount });
            return .{ .fail = 1 };
        };
        if (cents <= 0) {
            try stderr.print("line {d}: amount must be positive\n", .{i});
            return .{ .fail = 1 };
        }
        if (!spec.isValidVat(l.vat)) {
            try stderr.print("line {d}: invalid vat '{s}'. valid:", .{ i, l.vat });
            for (spec.vat_codes) |v| try stderr.print(" {s}", .{v});
            try stderr.writeByte('\n');
            return .{ .fail = 1 };
        }
        l.amount = try money.renderCentsAlloc(gpa, cents);
    }
    return .{ .lines = lines.items };
}

fn lineMissing(stderr: *std.Io.Writer, idx: usize, field: []const u8) !Result {
    try stderr.print("line {d}: missing string '{s}'\n", .{ idx, field });
    return .{ .fail = 1 };
}

fn flagMissing(stderr: *std.Io.Writer, what: []const u8) !Result {
    try stderr.print("error: missing {s}\n", .{what});
    return .{ .fail = 2 };
}
