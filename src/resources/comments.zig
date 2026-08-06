//! Shared `comment` verb for the receipts and transactions resources, backed by
//! `/comments/add`. A comment is a free-text note the web app shows on a receipt
//! or a bank transaction ("Kommentar"); receipts.zig and transactions.zig are
//! thin wrappers that pin which of the two a given invocation targets.
//!
//! The endpoint is write-only: BHB exposes no comments get/update/delete route,
//! so a comment can be added and then only READ BACK as the `comment` field on
//! the posting that carries the commented receipt or transaction — see
//! `bookings list --comments`. Fixing a wrong comment is a web-UI job
//! (docs/bhb-api-quirks.md).

const std = @import("std");
const cli = @import("../cli.zig");
const json = @import("../util/json.zig");
const output = @import("../output.zig");
const Client = @import("../client.zig").Client;

const path = "/comments/add";

/// Which object a comment is attached to. The API takes EXACTLY ONE of
/// `receipt_id_by_customer` / `transaction_id_by_customer`, so the target is a
/// tagged union rather than two optionals: no representable state sends both,
/// neither, or a null placeholder.
const Target = union(enum) {
    receipt: i64,
    transaction: i64,

    fn field(self: Target) []const u8 {
        return switch (self) {
            .receipt => "receipt_id_by_customer",
            .transaction => "transaction_id_by_customer",
        };
    }

    fn id(self: Target) i64 {
        return switch (self) {
            .receipt, .transaction => |v| v,
        };
    }
};

/// Which resource the wrapper is calling on behalf of. Also picks the
/// positional's name in usage errors, matching that verb's spec entry.
pub const Kind = enum {
    receipt,
    transaction,

    fn positional(self: Kind) []const u8 {
        return switch (self) {
            .receipt => "<id>",
            .transaction => "<tx>",
        };
    }
};

/// BHB accepts a comment of 2..210 characters (`/comments/add` rejects anything
/// else with error 12). Counted in CHARACTERS, not bytes: a comment carrying
/// umlauts or a `§` is multi-byte in UTF-8 and would be refused well below the
/// real limit if measured with `.len`.
pub const min_len = 2;
pub const max_len = 210;

/// Character count of a UTF-8 string, or null when it is not valid UTF-8.
fn charLen(s: []const u8) ?usize {
    const view = std.unicode.Utf8View.init(s) catch return null;
    var it = view.iterator();
    var n: usize = 0;
    while (it.nextCodepoint() != null) n += 1;
    return n;
}

/// Add a comment to the receipt / transaction named by the verb's positional.
/// `--text` carries the note; its length is validated locally so an over-long
/// comment is a usage error here rather than a round trip that comes back as
/// API error 12.
pub fn run(c: Client, kind: Kind, f: *const cli.Flags, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    const idn = f.posInt(2) orelse return cli.missing(stderr, kind.positional());
    const target: Target = switch (kind) {
        .receipt => .{ .receipt = idn },
        .transaction => .{ .transaction = idn },
    };
    const text = f.opt("text") orelse return cli.missing(stderr, "--text");

    const n = charLen(text) orelse {
        try stderr.print("error: --text is not valid UTF-8\n", .{});
        return 2;
    };
    if (n < min_len or n > max_len) {
        try stderr.print("error: --text must be {d}..{d} characters, got {d}\n", .{ min_len, max_len, n });
        return 2;
    }

    var o = try json.ObjBuilder.init(c.gpa);
    try o.str("api_key", c.api_key);
    try o.str("comment_text", text);
    try o.int(target.field(), target.id());
    try o.end();
    const body = try o.toOwnedSlice();

    if (f.has("dry-run")) {
        const shown = try json.redactAlloc(c.gpa, body, c.api_key);
        try stdout.print("DRY RUN — would POST to {s}:\n{s}\n\n(nothing was sent)\n", .{ path, shown });
        return 0;
    }
    var r = try c.post(path, body);
    defer r.deinit(c.gpa);
    return output.reportWrite(c.gpa, stderr, r, "comment", c.api_key);
}

test "charLen counts codepoints, not bytes" {
    try std.testing.expectEqual(@as(?usize, 3), charLen("abc"));
    // "§ 3a" is 4 characters but 5 bytes — the § is two bytes in UTF-8.
    try std.testing.expectEqual(@as(?usize, 4), charLen("§ 3a"));
    try std.testing.expectEqual(@as(usize, 5), "§ 3a".len);
    try std.testing.expectEqual(@as(?usize, null), charLen(&[_]u8{0xff}));
}

test "target carries exactly one id field" {
    try std.testing.expectEqualStrings("receipt_id_by_customer", (Target{ .receipt = 7 }).field());
    try std.testing.expectEqualStrings("transaction_id_by_customer", (Target{ .transaction = 9 }).field());
    try std.testing.expectEqual(@as(i64, 7), (Target{ .receipt = 7 }).id());
    try std.testing.expectEqual(@as(i64, 9), (Target{ .transaction = 9 }).id());
}
