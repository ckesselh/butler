//! Shared list/show for the creditor and debtor subledgers. Both are
//! `/settings/get/<kind>` list endpoints with an identical record shape and
//! limit/offset paging (the API defaults to 25 rows per page); creditors.zig
//! and debtors.zig are thin wrappers that pin the endpoint. The dedicated
//! subledger account sits in `postingaccount_number` — the value you hand to
//! `receipts book --creditor` / `--debtor`.

const std = @import("std");
const cli = @import("../cli.zig");
const spec = @import("../spec.zig");
const json = @import("../util/json.zig");
const output = @import("../output.zig");
const http = @import("../util/http.zig");
const Client = @import("../client.zig").Client;

const cols = [_][]const u8{ "postingaccount_number", "name", "city", "sales_tax_id_eu", "iban" };

// Rows requested per page during the auto-paging sweep. The endpoints default to
// 25; we ask for more per round-trip but advance the offset by the rows actually
// returned (not by this constant), so a smaller server-side cap can never skip
// rows. `page_guard` caps the number of round-trips: a well-behaved server ends
// the sweep with an empty page long before this, so hitting it means the server
// is ignoring `offset` (or the dataset is implausibly large) — treated as an
// error, never as a complete result.
const page_size = 500;
const page_guard = 10_000;

const Verb = enum { list, show };

/// The decision after a page comes back: stop (the sweep is complete), continue
/// from a new offset, or give up because the round-trip guard tripped. Pure and
/// unit-tested — it is the crux of the paging loop's correctness.
const Step = union(enum) { stop, again: i64, give_up };

fn nextStep(offset: i64, page_len: usize, iters: usize) Step {
    if (page_len == 0) return .stop; // an empty page is the only "complete" signal
    if (iters >= page_guard) return .give_up; // a non-empty page past the guard ⇒ server not advancing
    return .{ .again = offset + @as(i64, @intCast(page_len)) };
}

const Fetched = union(enum) {
    merged: []u8, // synthetic success envelope carrying every row
    failed: http.Response, // a page that did not succeed; render its error via emitList
    incomplete, // the round-trip guard tripped before an empty page — result would be wrong
};

/// Page `path` to completion starting at `start_offset`, accumulating every row
/// into one synthetic success envelope. The offset advances by the page's own
/// length, so the sweep stays correct even if the server caps a page below
/// `page_size`; `nextStep` bounds the loop and flags a never-terminating server.
fn fetchAll(c: Client, path: []const u8, start_offset: i64) !Fetched {
    var rows: std.ArrayList([]const u8) = .empty;
    var offset: i64 = start_offset;
    var iters: usize = 0;
    while (true) {
        var o = try json.ObjBuilder.init(c.gpa);
        try o.str("api_key", c.api_key);
        try o.int("limit", page_size);
        try o.int("offset", offset);
        try o.end();
        var r = try c.post(path, o.items());
        const parsed: ?std.json.Parsed(std.json.Value) =
            std.json.parseFromSlice(std.json.Value, c.gpa, r.body, .{ .allocate = .alloc_always }) catch null;
        if (r.status != 200 or parsed == null or !json.envelopeSuccess(parsed.?.value))
            return .{ .failed = r }; // ownership passes to the caller, which renders + frees it
        const data = output.dataArray(parsed.?.value) orelse &[_]std.json.Value{};
        for (data) |row| try rows.append(c.gpa, try std.json.Stringify.valueAlloc(c.gpa, row, .{}));
        r.deinit(c.gpa);
        iters += 1;
        switch (nextStep(offset, data.len, iters)) {
            .stop => break,
            .give_up => return .incomplete,
            .again => |next| offset = next,
        }
    }
    return .{ .merged = try mergeEnvelope(c.gpa, rows.items) };
}

/// Wrap accumulated row JSON in `{"success":true,"rows":N,"message":"","data":[...]}`
/// so the merged page renders through the same emitList/emitShow path as a real
/// API response.
fn mergeEnvelope(gpa: std.mem.Allocator, rows: []const []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.print(gpa, "{{\"success\":true,\"rows\":{d},\"message\":\"\",\"data\":[", .{rows.len});
    for (rows, 0..) |s, i| {
        if (i != 0) try buf.append(gpa, ',');
        try buf.appendSlice(gpa, s);
    }
    try buf.appendSlice(gpa, "]}");
    return buf.toOwnedSlice(gpa);
}

/// The `--offset` value as an i64 (default 0). The parse cannot fail: the spec
/// marks --offset as an int ≥ 0, so cli.validate has already checked it.
fn startOffset(f: *const cli.Flags) i64 {
    const s = f.opt("offset") orelse return 0;
    return std.fmt.parseInt(i64, std.mem.trim(u8, s, " \t"), 10) catch 0;
}

/// Report a sweep that could not complete (round-trip guard tripped). Distinct
/// from an API error and from an empty result — the data we have is incomplete,
/// so we must not present it as the full ledger.
fn incompleteError(stderr: *std.Io.Writer) !u8 {
    try stderr.writeAll("error: the account list did not terminate (the server kept returning pages); results would be incomplete.\n");
    return 1;
}

pub fn run(c: Client, path: []const u8, verb: []const u8, f: *const cli.Flags, stdout: *std.Io.Writer, stderr: *std.Io.Writer, out_mode: spec.Output) !u8 {
    const v = std.meta.stringToEnum(Verb, verb) orelse return cli.unknownVerb(stderr, verb, "list|show");
    switch (v) {
        .list => {
            // An explicit --limit means "one bounded page" (honouring --offset);
            // without it, page the endpoint to completion so the list is
            // exhaustive — --offset then skips that many rows before the sweep.
            if (f.opt("limit") != null) {
                var o = try json.ObjBuilder.init(c.gpa);
                try o.str("api_key", c.api_key);
                try json.addIntOpt(&o, "limit", f.opt("limit"));
                try json.addIntOpt(&o, "offset", f.opt("offset"));
                try o.end();
                var r = try c.post(path, o.items());
                defer r.deinit(c.gpa);
                return output.emitList(c.gpa, stdout, stderr, r, &cols, out_mode, f.opt("filter"), c.api_key);
            }
            switch (try fetchAll(c, path, startOffset(f))) {
                .failed => |resp| {
                    var r = resp;
                    defer r.deinit(c.gpa);
                    return output.emitList(c.gpa, stdout, stderr, r, &cols, out_mode, f.opt("filter"), c.api_key);
                },
                .incomplete => return incompleteError(stderr),
                .merged => |body| return output.emitList(c.gpa, stdout, stderr, .{ .status = 200, .body = body }, &cols, out_mode, f.opt("filter"), c.api_key),
            }
        },
        .show => {
            const acct = f.pos(2) orelse return cli.missing(stderr, "<account>");
            switch (try fetchAll(c, path, 0)) {
                .failed => |resp| {
                    var r = resp;
                    defer r.deinit(c.gpa);
                    // Surface the API error rather than a misleading "not found".
                    return output.emitList(c.gpa, stdout, stderr, r, &cols, out_mode, null, c.api_key);
                },
                .incomplete => return incompleteError(stderr),
                .merged => |body| return output.emitShowBy(c.gpa, stdout, stderr, .{ .status = 200, .body = body }, out_mode, "postingaccount_number", acct, c.api_key),
            }
        },
    }
}

test "nextStep: empty page stops the sweep (even at the guard)" {
    try std.testing.expectEqual(Step.stop, nextStep(0, 0, 1));
    try std.testing.expectEqual(Step.stop, nextStep(5000, 0, page_guard));
}

test "nextStep: a full page advances the offset by the page length" {
    try std.testing.expectEqual(Step{ .again = 500 }, nextStep(0, 500, 1));
    // Advance by the ACTUAL rows returned, not page_size — robust to a server
    // that caps a page below what we asked for.
    try std.testing.expectEqual(Step{ .again = 125 }, nextStep(100, 25, 3));
}

test "nextStep: a non-empty page past the guard gives up (never a silent success)" {
    try std.testing.expectEqual(Step.give_up, nextStep(500, 500, page_guard));
    try std.testing.expectEqual(Step.give_up, nextStep(500, 1, page_guard + 1));
}

test "mergeEnvelope wraps accumulated rows into a valid success envelope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const rows = [_][]const u8{
        "{\"postingaccount_number\":\"70001\",\"name\":\"Amazon\"}",
        "{\"postingaccount_number\":\"70037\",\"name\":\"Skool.com Inc.\"}",
    };
    const body = try mergeEnvelope(gpa, &rows);
    // It must round-trip as a BHB envelope: success true, rows = count, data the
    // concatenated rows in order. The downstream emit* layer re-parses this.
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    try std.testing.expect(json.envelopeSuccess(parsed.value));
    try std.testing.expectEqual(@as(i64, 2), json.getInt(parsed.value.object, "rows").?);
    const data = output.dataArray(parsed.value).?;
    try std.testing.expectEqual(@as(usize, 2), data.len);
    try std.testing.expectEqualStrings("Skool.com Inc.", json.getStr(data[1].object, "name").?);
}

test "mergeEnvelope on no rows yields an empty data array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const body = try mergeEnvelope(gpa, &.{});
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    try std.testing.expect(json.envelopeSuccess(parsed.value));
    try std.testing.expectEqual(@as(usize, 0), output.dataArray(parsed.value).?.len);
}
