//! Shared "open items" anti-join behind the `--unbooked` / `--missing-receipt`
//! list filters: list the rows of a primary collection (bank transactions, or
//! receipts) that no posting references over the same date window. The reference
//! set comes from one `/postings/get` sweep — an item is booked when its id
//! appears on any posting of any class. That is the true "has this been booked
//! at all?" signal; a receipt-less but booked payment (e.g. salary/tax) is
//! correctly excluded, where a payment-status heuristic would flag it open.

const std = @import("std");
const json = @import("../util/json.zig");
const output = @import("../output.zig");
const http = @import("../util/http.zig");
const spec = @import("../spec.zig");
const settings_paged = @import("settings_paged.zig");
const Client = @import("../client.zig").Client;

const Value = std.json.Value;

/// Shared usage error for the open-items list filters, whose anti-join needs a
/// bounded date window for the `/postings/get` sweep.
pub fn windowRequired(flag: []const u8, stderr: *std.Io.Writer) !u8 {
    try stderr.print("error: --{s} needs --date-from and --date-to (they bound the posting sweep)\n", .{flag});
    return 2;
}

/// The set of ids referenced by `field` across every `/postings/get` row over
/// [from, to]. `multi` tokenises whitespace/comma-separated id lists, which
/// `receipts_assigned_ids_by_customer` can carry. When `require_field` is given,
/// only postings whose `require_field` is non-empty count — e.g. collect the
/// transactions that carry a receipt (transaction_id where receipts_assigned is
/// set) to find those MISSING one. Keys alias the parse arena.
///
/// A failed sweep is an ERROR, never a silently-empty set: an empty reference
/// set inverts the anti-join into "everything is open", a dangerous false signal
/// to act on. Only a genuinely successful-but-empty sweep yields an empty set.
fn referencedIds(c: Client, stderr: *std.Io.Writer, from: []const u8, to: []const u8, field: []const u8, multi: bool, require_field: ?[]const u8) !std.StringHashMapUnmanaged(void) {
    var set: std.StringHashMapUnmanaged(void) = .empty;
    var o = try json.ObjBuilder.init(c.gpa);
    try o.str("api_key", c.api_key);
    try o.str("date_from", from);
    try o.str("date_to", to);
    try o.str("account", "all");
    try o.int("limit", 1000);
    try o.end();
    var r = try c.post("/postings/get", o.items());
    defer r.deinit(c.gpa);

    const parsed = std.json.parseFromSlice(Value, c.gpa, r.body, .{ .allocate = .alloc_always }) catch null;
    if (r.status != 200 or parsed == null or !json.envelopeSuccess(parsed.?.value)) {
        try stderr.writeAll("error: open-items posting sweep failed; cannot tell which items are booked\n");
        return error.PostingSweepFailed;
    }
    const rows = output.dataArray(parsed.?.value) orelse return set;
    // The endpoint caps at 1000 rows; past that the sweep is blind and would
    // report booked items as open. Warn rather than answer wrongly in silence.
    if (rows.len >= 1000)
        try stderr.writeAll("warning: posting sweep hit the 1000-row cap; items past it may show as falsely open — narrow the date window\n");
    try collectIds(c.gpa, &set, rows, field, multi, require_field);
    return set;
}

/// Add to `set` the ids that posting `rows` name in `field` (see
/// `referencedIds` for `multi` and `require_field`). Keys alias the rows.
fn collectIds(gpa: std.mem.Allocator, set: *std.StringHashMapUnmanaged(void), rows: []const Value, field: []const u8, multi: bool, require_field: ?[]const u8) !void {
    for (rows) |row| {
        const obj = switch (row) {
            .object => |x| x,
            else => continue,
        };
        if (require_field) |rf| {
            const guard = json.getStr(obj, rf) orelse "";
            if (guard.len == 0) continue;
        }
        const raw = json.getStr(obj, field) orelse continue;
        if (raw.len == 0) continue;
        if (multi) {
            var it = std.mem.tokenizeAny(u8, raw, " ,");
            while (it.next()) |id| try set.put(gpa, id, {});
        } else {
            try set.put(gpa, raw, {});
        }
    }
}

/// Paging for one primary request.
pub const Page = struct { limit: i64, offset: i64 };

/// One request for a page of the primary collection. `limit`/`offset` are the
/// paging the open-items filter chooses itself; every other list filter
/// (direction, counterparty, date window) is the caller's to put in the body.
pub const PageFetcher = struct {
    ctx: *const anyopaque,
    fetch: *const fn (ctx: *const anyopaque, limit: i64, offset: i64) anyerror!http.Response,
};

/// How a primary row is matched against the posting sweep.
///   posting_field : the posting field that names a primary row's id.
///   multi         : that field may hold a whitespace/comma-separated id list.
///   require_field : only postings with this field non-empty count (see
///                   `referencedIds`).
///   drop_nonempty : a primary field whose non-empty rows are left out on top of
///                   the anti-join (a receipt that already hangs on a payment is
///                   not open, even when no posting names it).
pub const Join = struct {
    posting_field: []const u8,
    multi: bool = false,
    require_field: ?[]const u8 = null,
    drop_nonempty: ?[]const u8 = null,
};

// Rows requested per primary page: the maximum `/transactions/get` and
// `/receipts/get` accept (a larger limit is rejected with "invalid limit").
const primary_page_size: i64 = 500;

const Primary = union(enum) {
    rows: []Value, // every primary row in the window, in server order
    failed: http.Response, // a page that did not succeed; rendered via emitList
    incomplete, // the round-trip guard tripped before an empty page
};

/// Page the primary collection to completion: request `primary_page_size` rows
/// at a time, advance by the rows actually returned, and stop at the first
/// empty page (the same rule as `settings_paged.fetchAll`). The anti-join must
/// see the whole window: a filter over one page reports the items on the other
/// pages as neither open nor booked, just absent.
fn fetchWindow(gpa: std.mem.Allocator, src: PageFetcher) !Primary {
    var rows: std.ArrayList(Value) = .empty;
    var offset: i64 = 0;
    var iters: usize = 0;
    while (true) {
        var r = try src.fetch(src.ctx, primary_page_size, offset);
        const parsed = std.json.parseFromSlice(Value, gpa, r.body, .{ .allocate = .alloc_always }) catch
            return .{ .failed = r };
        if (r.status != 200 or !json.envelopeSuccess(parsed.value))
            return .{ .failed = r }; // ownership passes to the caller, which renders it
        const data = output.dataArray(parsed.value) orelse &[_]Value{};
        try rows.appendSlice(gpa, data);
        r.deinit(gpa);
        iters += 1;
        switch (settings_paged.nextStep(offset, data.len, iters)) {
            .stop => break,
            .give_up => return .incomplete,
            .again => |next| offset = next,
        }
    }
    return .{ .rows = rows.items };
}

/// The rows of `rows` that are open: not dropped by `drop_nonempty`, and whose
/// `id_by_customer` is not in `referenced`. A row without an id is kept (it
/// cannot be proven booked). Server order is preserved.
fn selectOpen(gpa: std.mem.Allocator, rows: []const Value, referenced: *const std.StringHashMapUnmanaged(void), drop_nonempty: ?[]const u8) !std.json.Array {
    // std.json.Value.array is a *managed* ArrayList, so build the kept set as one.
    var kept = std.json.Array.init(gpa);
    for (rows) |row| {
        const ro = switch (row) {
            .object => |x| x,
            else => continue,
        };
        if (drop_nonempty) |field| {
            const value: []const u8 = json.getStr(ro, field) orelse "";
            if (value.len != 0) continue;
        }
        // id_by_customer is a number on transactions, a string on receipts;
        // compare via the rendered decimal form either way.
        const idv = ro.get("id_by_customer") orelse {
            try kept.append(row);
            continue;
        };
        const id = try json.valueToAlloc(gpa, idv);
        if (!referenced.contains(id)) try kept.append(row);
    }
    return kept;
}

/// The `[start, end)` slice of `len` open items that `--offset`/`--limit`
/// select. No limit means everything from the offset on.
const Slice = struct { start: usize, end: usize };

fn sliceBounds(len: usize, offset: i64, limit: ?i64) Slice {
    const start: usize = @min(len, @as(usize, @intCast(@max(offset, 0))));
    const end: usize = if (limit) |l| @min(len, start + @as(usize, @intCast(@max(l, 0)))) else len;
    return .{ .start = start, .end = end };
}

/// Render the open rows of the primary collection over its whole date window:
/// page the primary endpoint to completion (`fetchWindow`), drop every row a
/// posting over [from, to] references (`referencedIds`), and only then apply
/// `offset`/`limit` to the open rows. [from, to] is the sweep window, which a
/// caller may start earlier than the primary window when postings tend to
/// predate their documents. When `limit` cuts the open rows short, a note on
/// stderr says how many there are. A failed primary page is rendered through
/// the normal list path so its error handling is reused. `/postings/get` caps
/// at 1000 rows; past that `referencedIds` warns that items may show as
/// falsely open.
pub fn emit(
    c: Client,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    primary: PageFetcher,
    cols: []const []const u8,
    out_mode: spec.Output,
    search: ?[]const u8,
    from: []const u8,
    to: []const u8,
    join: Join,
    offset: i64,
    limit: ?i64,
) !u8 {
    const gpa = c.gpa;

    const rows = switch (try fetchWindow(gpa, primary)) {
        .rows => |r| r,
        .failed => |r| return output.emitList(gpa, stdout, stderr, r, cols, out_mode, search, c.api_key),
        .incomplete => {
            try stderr.writeAll("error: the list did not terminate (the server kept returning pages); cannot tell which items are open\n");
            return 1;
        },
    };

    var referenced = try referencedIds(c, stderr, from, to, join.posting_field, join.multi, join.require_field);
    const kept = try selectOpen(gpa, rows, &referenced, join.drop_nonempty);
    const b = sliceBounds(kept.items.len, offset, limit);
    if (limit != null and b.end < kept.items.len)
        try stderr.print("note: showing {d} of {d} open items in the window; continue with --offset {d}\n", .{ b.end - b.start, kept.items.len, b.end });

    // Emit a success envelope through the normal list path so table rendering,
    // `--filter`, and json passthrough behave exactly as for a plain `list`.
    // `rows` matches the length of `data`.
    var shown = std.json.Array.init(gpa);
    try shown.appendSlice(kept.items[b.start..b.end]);
    var env: std.json.ObjectMap = .empty;
    try env.put(gpa, "success", .{ .bool = true });
    try env.put(gpa, "rows", .{ .integer = @intCast(shown.items.len) });
    try env.put(gpa, "message", .{ .string = "" });
    try env.put(gpa, "data", .{ .array = shown });
    const body = try std.json.Stringify.valueAlloc(gpa, Value{ .object = env }, .{});
    return output.emitList(gpa, stdout, stderr, .{ .status = 200, .body = body }, cols, out_mode, search, c.api_key);
}

// --- tests ---

/// A fake primary endpoint over `total` synthetic receipts (ids "1".."total",
/// ascending), serving at most `cap` rows per page whatever the request asks,
/// so paging must advance by the rows actually returned. `fail_at` turns the
/// page at that offset into an API error. Records each request.
const FakePrimary = struct {
    gpa: std.mem.Allocator,
    total: usize,
    cap: usize,
    fail_at: ?i64 = null,
    calls: *std.ArrayList(Page),

    fn fetch(ctx: *const anyopaque, limit: i64, offset: i64) anyerror!http.Response {
        const self: *const FakePrimary = @ptrCast(@alignCast(ctx));
        try self.calls.append(self.gpa, .{ .limit = limit, .offset = offset });
        if (self.fail_at) |at| if (at == offset)
            return .{ .status = 200, .body = try self.gpa.dupe(u8, "{\"success\":false,\"error_code\":10,\"message\":\"invalid limit specified\"}") };
        const start: usize = @min(self.total, @as(usize, @intCast(offset)));
        const end: usize = @min(self.total, start + @min(self.cap, @as(usize, @intCast(limit))));
        var buf: std.ArrayList(u8) = .empty;
        try buf.print(self.gpa, "{{\"success\":true,\"rows\":{d},\"data\":[", .{end - start});
        for (start..end) |i| {
            if (i != start) try buf.append(self.gpa, ',');
            try buf.print(self.gpa, "{{\"id_by_customer\":\"{d}\",\"payment_date\":\"\"}}", .{i + 1});
        }
        try buf.appendSlice(self.gpa, "]}");
        return .{ .status = 200, .body = try buf.toOwnedSlice(self.gpa) };
    }
};

fn idsOf(gpa: std.mem.Allocator, rows: []const Value) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (rows) |r| try out.append(gpa, try json.valueToAlloc(gpa, r.object.get("id_by_customer").?));
    return out.items;
}

test "open items past the first page of the window are found (limit below the window size)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // 300 receipts in the window, the first 288 booked, the newest 12 open.
    var calls: std.ArrayList(Page) = .empty;
    const fake: FakePrimary = .{ .gpa = gpa, .total = 300, .cap = 120, .calls = &calls };
    const rows = switch (try fetchWindow(gpa, .{ .ctx = &fake, .fetch = FakePrimary.fetch })) {
        .rows => |r| r,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 300), rows.len);

    var referenced: std.StringHashMapUnmanaged(void) = .empty;
    for (1..289) |i| try referenced.put(gpa, try std.fmt.allocPrint(gpa, "{d}", .{i}), {});

    // A filter over only the first 200 rows (what `--limit 200` fetched)
    // finds nothing open: the failure this guards against.
    const first_page = try selectOpen(gpa, rows[0..200], &referenced, null);
    try std.testing.expectEqual(@as(usize, 0), first_page.items.len);

    // Over the whole window, --limit 200 shows all 12 open receipts.
    const kept = try selectOpen(gpa, rows, &referenced, null);
    const b = sliceBounds(kept.items.len, 0, 200);
    const ids = try idsOf(gpa, kept.items[b.start..b.end]);
    try std.testing.expectEqual(@as(usize, 12), ids.len);
    try std.testing.expectEqualStrings("289", ids[0]);
    try std.testing.expectEqualStrings("300", ids[11]);
}

test "fetchWindow asks for full pages, advances by the rows returned, stops on an empty page" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var calls: std.ArrayList(Page) = .empty;
    const fake: FakePrimary = .{ .gpa = gpa, .total = 250, .cap = 100, .calls = &calls };
    const rows = switch (try fetchWindow(gpa, .{ .ctx = &fake, .fetch = FakePrimary.fetch })) {
        .rows => |r| r,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 250), rows.len);
    const want = [_]i64{ 0, 100, 200, 250 };
    try std.testing.expectEqual(want.len, calls.items.len);
    for (want, calls.items) |off, call| {
        try std.testing.expectEqual(off, call.offset);
        try std.testing.expectEqual(primary_page_size, call.limit);
    }
}

test "fetchWindow on an empty window makes one request and returns no rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var calls: std.ArrayList(Page) = .empty;
    const fake: FakePrimary = .{ .gpa = gpa, .total = 0, .cap = 500, .calls = &calls };
    const rows = switch (try fetchWindow(gpa, .{ .ctx = &fake, .fetch = FakePrimary.fetch })) {
        .rows => |r| r,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 0), rows.len);
    try std.testing.expectEqual(@as(usize, 1), calls.items.len);
}

test "fetchWindow: a failed later page is an error, never a partial result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var calls: std.ArrayList(Page) = .empty;
    const fake: FakePrimary = .{ .gpa = gpa, .total = 300, .cap = 100, .fail_at = 200, .calls = &calls };
    switch (try fetchWindow(gpa, .{ .ctx = &fake, .fetch = FakePrimary.fetch })) {
        .failed => |r| try std.testing.expect(!json.bodySuccess(gpa, r.body)),
        else => return error.TestUnexpectedResult,
    }
}

test "sliceBounds applies offset and limit to the open items" {
    try std.testing.expectEqual(Slice{ .start = 0, .end = 12 }, sliceBounds(12, 0, null));
    try std.testing.expectEqual(Slice{ .start = 0, .end = 12 }, sliceBounds(12, 0, 200));
    try std.testing.expectEqual(Slice{ .start = 0, .end = 5 }, sliceBounds(12, 0, 5));
    try std.testing.expectEqual(Slice{ .start = 10, .end = 12 }, sliceBounds(12, 10, 5));
    try std.testing.expectEqual(Slice{ .start = 4, .end = 12 }, sliceBounds(12, 4, null));
    // An offset past the end is an empty result, not an error.
    try std.testing.expectEqual(Slice{ .start = 12, .end = 12 }, sliceBounds(12, 50, 5));
    try std.testing.expectEqual(Slice{ .start = 0, .end = 0 }, sliceBounds(0, 0, 10));
}

test "selectOpen drops rows with drop_nonempty set and matches numeric ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const body =
        \\[{"id_by_customer":1,"payment_date":""},
        \\ {"id_by_customer":2,"payment_date":"2026-01-15"},
        \\ {"id_by_customer":3},
        \\ {"id_by_customer":4,"payment_date":""},
        \\ {"payment_date":""}]
    ;
    const parsed = try std.json.parseFromSlice(Value, gpa, body, .{});
    var referenced: std.StringHashMapUnmanaged(void) = .empty;
    try referenced.put(gpa, "4", {});

    const all = try idsOf(gpa, (try selectOpen(gpa, parsed.value.array.items, &referenced, null)).items[0..3]);
    try std.testing.expectEqualStrings("1", all[0]);
    try std.testing.expectEqualStrings("2", all[1]);
    try std.testing.expectEqualStrings("3", all[2]);

    // With drop_nonempty the linked receipt 2 goes; 4 is booked; the id-less
    // row stays (it cannot be proven booked).
    const kept = try selectOpen(gpa, parsed.value.array.items, &referenced, "payment_date");
    try std.testing.expectEqual(@as(usize, 3), kept.items.len);
    const ids = try idsOf(gpa, kept.items[0..2]);
    try std.testing.expectEqualStrings("1", ids[0]);
    try std.testing.expectEqualStrings("3", ids[1]);
}

test "collectIds: require_field keeps only postings that carry it; multi splits id lists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const body =
        \\[{"transaction_id_by_customer":"10","receipts_assigned_ids_by_customer":"7"},
        \\ {"transaction_id_by_customer":"11","receipts_assigned_ids_by_customer":""},
        \\ {"transaction_id_by_customer":"12","receipts_assigned_ids_by_customer":"8, 9"}]
    ;
    const parsed = try std.json.parseFromSlice(Value, gpa, body, .{});
    const rows = parsed.value.array.items;

    var with_receipt: std.StringHashMapUnmanaged(void) = .empty;
    try collectIds(gpa, &with_receipt, rows, "transaction_id_by_customer", false, "receipts_assigned_ids_by_customer");
    try std.testing.expect(with_receipt.contains("10"));
    try std.testing.expect(!with_receipt.contains("11"));
    try std.testing.expect(with_receipt.contains("12"));

    var receipts: std.StringHashMapUnmanaged(void) = .empty;
    try collectIds(gpa, &receipts, rows, "receipts_assigned_ids_by_customer", true, null);
    try std.testing.expectEqual(@as(u32, 3), receipts.count());
    try std.testing.expect(receipts.contains("8") and receipts.contains("9"));
}
