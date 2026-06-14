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
            while (it.next()) |id| try set.put(c.gpa, id, {});
        } else {
            try set.put(c.gpa, raw, {});
        }
    }
    return set;
}

/// Render the rows of `primary` whose `id_by_customer` is NOT referenced by any
/// posting's `posting_field` over [from, to]. A failed/empty primary response is
/// passed through to the normal list path so its error/edge handling is reused.
/// Note: `/postings/get` caps at 1000 rows, so a window wider than that many
/// postings can mis-report items as open — keep the window bounded.
pub fn emit(
    c: Client,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    primary: http.Response,
    cols: []const []const u8,
    out_mode: spec.Output,
    search: ?[]const u8,
    from: []const u8,
    to: []const u8,
    posting_field: []const u8,
    multi: bool,
    require_field: ?[]const u8,
) !u8 {
    const gpa = c.gpa;

    var parsed = std.json.parseFromSlice(Value, gpa, primary.body, .{ .allocate = .alloc_always }) catch
        return output.emitList(gpa, stdout, stderr, primary, cols, out_mode, search, c.api_key);
    if (primary.status != 200 or !json.envelopeSuccess(parsed.value) or parsed.value != .object)
        return output.emitList(gpa, stdout, stderr, primary, cols, out_mode, search, c.api_key);
    const rows = output.dataArray(parsed.value) orelse
        return output.emitList(gpa, stdout, stderr, primary, cols, out_mode, search, c.api_key);

    var referenced = try referencedIds(c, stderr, from, to, posting_field, multi, require_field);

    // std.json.Value.array is a *managed* ArrayList, so build the kept set as one.
    var kept = std.json.Array.init(gpa);
    for (rows) |row| {
        const ro = switch (row) {
            .object => |x| x,
            else => continue,
        };
        // id_by_customer is a number on transactions, a string on receipts;
        // compare via the rendered decimal form either way.
        const idv = ro.get("id_by_customer") orelse {
            try kept.append(row);
            continue;
        };
        const id = try json.valueToAlloc(gpa, idv);
        if (!referenced.contains(id)) try kept.append(row);
    }

    // Re-emit the filtered envelope through the normal list path so table
    // rendering, `--filter`, and json passthrough behave exactly as for a
    // plain `list`. The `rows` count is corrected to the kept length so a json
    // consumer reading `.rows` matches `.data`.
    try parsed.value.object.put(gpa, "rows", .{ .integer = @intCast(kept.items.len) });
    try parsed.value.object.put(gpa, "data", .{ .array = kept });
    const body = try std.json.Stringify.valueAlloc(gpa, parsed.value, .{});
    return output.emitList(gpa, stdout, stderr, .{ .status = 200, .body = body }, cols, out_mode, search, c.api_key);
}
