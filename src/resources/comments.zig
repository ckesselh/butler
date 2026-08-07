//! Shared `comment` verb for the receipts and transactions resources, backed by
//! `/comments/add`. A comment is a free-text note the web app shows on a receipt
//! or a bank transaction ("Kommentar"); receipts.zig and transactions.zig are
//! thin wrappers that pin which of the two a given invocation targets.
//!
//! `/comments/add` is the only endpoint in the comments namespace — there is no
//! get, update or delete — so a comment can be written here but changed only in
//! the web UI. Reading one back goes through the postings view, where it arrives
//! as the row's `comment` field: see `bookings list --comments`
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

    fn target(self: Kind, id: i64) Target {
        return switch (self) {
            .receipt => .{ .receipt = id },
            .transaction => .{ .transaction = id },
        };
    }
};

/// BHB accepts a comment of 2..210 characters (`/comments/add` rejects anything
/// else). Counted in CHARACTERS, not bytes: a comment carrying umlauts or a `§`
/// is multi-byte in UTF-8 and would be refused well below the real limit if
/// measured with `.len`.
pub const min_len = 2;
pub const max_len = 210;

/// The verdict on a `--text` value. `.bad_length` carries the actual character
/// count so the error can report it.
pub const TextCheck = union(enum) {
    ok,
    not_utf8,
    bad_length: usize,
};

/// Validate `--text` against what the endpoint accepts. Pure, so the boundaries
/// are testable without a client.
pub fn checkText(s: []const u8) TextCheck {
    const view = std.unicode.Utf8View.init(s) catch return .not_utf8;
    var it = view.iterator();
    var n: usize = 0;
    while (it.nextCodepoint() != null) n += 1;
    if (n < min_len or n > max_len) return .{ .bad_length = n };
    return .ok;
}

/// The `/comments/add` request body. Split out from `run` so a test can assert
/// that exactly one id field is emitted, and that it is the right one.
fn buildBody(gpa: std.mem.Allocator, api_key: []const u8, target: Target, text: []const u8) ![]u8 {
    var o = try json.ObjBuilder.init(gpa);
    try o.str("api_key", api_key);
    try o.str("comment_text", text);
    try o.int(target.field(), target.id());
    try o.end();
    return o.toOwnedSlice();
}

/// Add a comment to the receipt / transaction named by the verb's positional.
/// `--text` carries the note; its length is validated locally so an over-long
/// comment is a usage error here rather than a round trip that the API rejects.
pub fn run(c: Client, kind: Kind, f: *const cli.Flags, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    const idn = f.posInt(2) orelse return cli.missing(stderr, kind.positional());
    const text = f.opt("text") orelse return cli.missing(stderr, "--text");

    switch (checkText(text)) {
        .ok => {},
        .not_utf8 => {
            try stderr.print("error: --text is not valid UTF-8\n", .{});
            return 2;
        },
        .bad_length => |n| {
            try stderr.print("error: --text must be {d}..{d} characters, got {d}\n", .{ min_len, max_len, n });
            return 2;
        },
    }

    const body = try buildBody(c.gpa, c.api_key, kind.target(idn), text);

    if (f.has("dry-run")) {
        const shown = try json.redactAlloc(c.gpa, body, c.api_key);
        try stdout.print("DRY RUN — would POST to {s}:\n{s}\n\n(nothing was sent)\n", .{ path, shown });
        return 0;
    }
    var r = try c.post(path, body);
    defer r.deinit(c.gpa);
    return output.reportWrite(c.gpa, stderr, r, "comment", c.api_key);
}

test "checkText counts characters, not bytes" {
    // "§" is two bytes in UTF-8, so a byte-length check would reject a comment
    // of 210 § (420 bytes) that the API accepts.
    const at_max = "§" ** max_len;
    try std.testing.expectEqual(@as(usize, 420), at_max.len);
    try std.testing.expectEqual(TextCheck.ok, checkText(at_max));

    const over = "§" ** (max_len + 1);
    try std.testing.expectEqual(@as(usize, max_len + 1), checkText(over).bad_length);
}

test "checkText boundaries" {
    try std.testing.expectEqual(@as(usize, 0), checkText("").bad_length);
    try std.testing.expectEqual(@as(usize, 1), checkText("x").bad_length);
    try std.testing.expectEqual(TextCheck.ok, checkText("ab"));
    try std.testing.expectEqual(TextCheck.ok, checkText("a" ** max_len));
    try std.testing.expectEqual(@as(usize, max_len + 1), checkText("a" ** (max_len + 1)).bad_length);
    try std.testing.expectEqual(TextCheck.not_utf8, checkText(&[_]u8{0xff}));
}

test "body carries exactly one id field" {
    const gpa = std.testing.allocator;

    const r = try buildBody(gpa, "KEY", (Kind.receipt).target(7), "hallo");
    defer gpa.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"receipt_id_by_customer\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "transaction_id_by_customer") == null);
    try std.testing.expect(std.mem.indexOf(u8, r, "null") == null);

    const t = try buildBody(gpa, "KEY", (Kind.transaction).target(9), "hallo");
    defer gpa.free(t);
    try std.testing.expect(std.mem.indexOf(u8, t, "\"transaction_id_by_customer\":9") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "receipt_id_by_customer") == null);
    try std.testing.expect(std.mem.indexOf(u8, t, "null") == null);
}
