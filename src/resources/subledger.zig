//! Shared list/show/add/update for the creditor and debtor subledgers. Both are
//! `/settings/{get,add,update}/<kind>` endpoints with an identical record shape
//! and limit/offset paging on get (the API defaults to 25 rows per page);
//! creditors.zig and debtors.zig are thin wrappers that pin the endpoints. The
//! dedicated subledger account sits in `postingaccount_number` — the value you
//! hand to `receipts book --creditor` / `--debtor`. The exhaustive paging lives
//! in settings_paged.zig (shared with the accounts resource).

const std = @import("std");
const cli = @import("../cli.zig");
const spec = @import("../spec.zig");
const json = @import("../util/json.zig");
const output = @import("../output.zig");
const paged = @import("settings_paged.zig");
const Client = @import("../client.zig").Client;

const cols = [_][]const u8{ "postingaccount_number", "name", "city", "sales_tax_id_eu", "iban" };

// The optional field flags a creditor/debtor `update` may change. `update`
// requires at least one of these (an empty update is a user mistake we reject
// locally rather than sending a no-op to the API).
const update_fields = [_][]const u8{
    "name",   "contact", "street", "address2", "zip",      "city",            "country",
    "vat-id", "email",   "iban",   "bic",      "due-days", "customer-number",
};

const Verb = enum { list, show, add, update };

/// The per-resource endpoints + display noun a wrapper (creditors.zig /
/// debtors.zig) hands to `run`. `get` backs list/show; `add`/`update` back the
/// write verbs; `noun` ("creditor" / "debtor") is used in result messages.
pub const Endpoints = struct {
    noun: []const u8,
    get: []const u8,
    add: []const u8,
    update: []const u8,
};

pub fn run(c: Client, ep: Endpoints, verb: []const u8, f: *const cli.Flags, stdout: *std.Io.Writer, stderr: *std.Io.Writer, out_mode: spec.Output) !u8 {
    const v = std.meta.stringToEnum(Verb, verb) orelse return cli.unknownVerb(stderr, verb, "list|show|add|update");
    switch (v) {
        .list => {
            // --filter is a case-insensitive client-side substring match over the
            // shown columns (number, name, city, VAT-id, IBAN). --output json +
            // --filter is rejected upstream in main.zig.
            // An explicit --limit means "one bounded page" (honouring --offset);
            // without it, page the endpoint to completion so the list is
            // exhaustive — --offset then skips that many rows before the sweep.
            if (f.opt("limit") != null) {
                var o = try json.ObjBuilder.init(c.gpa);
                try o.str("api_key", c.api_key);
                try json.addIntOpt(&o, "limit", f.opt("limit"));
                try json.addIntOpt(&o, "offset", f.opt("offset"));
                try o.end();
                var r = try c.post(ep.get, o.items());
                defer r.deinit(c.gpa);
                return output.emitList(c.gpa, stdout, stderr, r, &cols, out_mode, f.opt("filter"), c.api_key);
            }
            switch (try paged.fetchAll(c, ep.get, paged.startOffset(f), &.{})) {
                .failed => |resp| {
                    var r = resp;
                    defer r.deinit(c.gpa);
                    return output.emitList(c.gpa, stdout, stderr, r, &cols, out_mode, f.opt("filter"), c.api_key);
                },
                .incomplete => return paged.incompleteError(stderr),
                .merged => |body| return output.emitList(c.gpa, stdout, stderr, .{ .status = 200, .body = body }, &cols, out_mode, f.opt("filter"), c.api_key),
            }
        },
        .show => {
            // Match on the canonical account number: parse to int (reject a
            // non-numeric arg as a usage error) and compare its decimal form, so
            // "0540" finds account 540 — like transactions show.
            const acct = f.pos(2) orelse return cli.missing(stderr, "<account>");
            const acctn = std.fmt.parseInt(i64, acct, 10) catch return cli.missing(stderr, "<account> to be an integer");
            const canon = try std.fmt.allocPrint(c.gpa, "{d}", .{acctn});
            switch (try paged.fetchAll(c, ep.get, 0, &.{})) {
                .failed => |resp| {
                    var r = resp;
                    defer r.deinit(c.gpa);
                    // Surface the API error rather than a misleading "not found".
                    return output.emitList(c.gpa, stdout, stderr, r, &cols, out_mode, null, c.api_key);
                },
                .incomplete => return paged.incompleteError(stderr),
                .merged => |body| return output.emitShowBy(c.gpa, stdout, stderr, .{ .status = 200, .body = body }, out_mode, "postingaccount_number", canon, c.api_key),
            }
        },
        .add => return write(c, ep, f, stdout, stderr, false),
        .update => return write(c, ep, f, stdout, stderr, true),
    }
}

/// Create (`add`) or modify (`update`) a creditor/debtor. On update the account
/// number is the positional key and at least one field flag must be given; on
/// add `--name` is required and `--account` optionally pins the number (else the
/// API assigns the next free one). The address/banking fields are optional in
/// both cases, and a field flag absent for this resource (e.g. --customer-number
/// on a creditor) is simply never set. Mirrors the codebase's write-verb shape:
/// build the body, honour --dry-run (redacted echo), POST, then output.reportWrite.
fn write(c: Client, ep: Endpoints, f: *const cli.Flags, stdout: *std.Io.Writer, stderr: *std.Io.Writer, is_update: bool) !u8 {
    const gpa = c.gpa;
    var o = try json.ObjBuilder.init(gpa);
    try o.str("api_key", c.api_key);
    if (is_update) {
        const acct = f.pos(2) orelse return cli.missing(stderr, "<account>");
        const acctn = std.fmt.parseInt(i64, acct, 10) catch return cli.missing(stderr, "<account> to be an integer");
        // Reject an empty update locally rather than sending a no-op.
        var any = false;
        for (update_fields) |name| if (f.opt(name) != null) {
            any = true;
            break;
        };
        if (!any) {
            try stderr.writeAll("error: nothing to update — pass at least one field (e.g. --name, --iban, --city)\n");
            return 2;
        }
        try o.int("postingaccount_number", acctn);
        try o.strOpt("name", f.opt("name"));
    } else {
        const name = f.opt("name") orelse return cli.missing(stderr, "--name");
        try o.str("name", name);
        // --account is validated numeric by the spec (.int); the add endpoint types
        // postingaccount_number as a string, so it is sent as one (update takes it
        // as the integer key above).
        try o.strOpt("postingaccount_number", f.opt("account"));
    }
    try o.strOpt("contact_person_name", f.opt("contact"));
    try o.strOpt("street", f.opt("street"));
    try o.strOpt("additional_address_line", f.opt("address2"));
    try o.strOpt("zip", f.opt("zip"));
    try o.strOpt("city", f.opt("city"));
    try o.strOpt("country", f.opt("country"));
    try o.strOpt("sales_tax_id", f.opt("vat-id"));
    try o.strOpt("email", f.opt("email"));
    try o.strOpt("iban", f.opt("iban"));
    try o.strOpt("bic", f.opt("bic"));
    // Resource-specific fields: each flag is declared only for the resource that
    // accepts it (creditor: due_in_days; debtor: customer_number), so the other
    // is always null here and stays out of the payload.
    try json.addIntOpt(&o, "due_in_days", f.opt("due-days"));
    try o.strOpt("customer_number", f.opt("customer-number"));
    try o.end();
    const body = try o.toOwnedSlice();

    const endpoint = if (is_update) ep.update else ep.add;
    if (f.has("dry-run")) {
        const shown = try json.redactAlloc(gpa, body, c.api_key);
        try stdout.print("DRY RUN — would POST to {s}:\n{s}\n\n(nothing was sent)\n", .{ endpoint, shown });
        return 0;
    }
    var r = try c.post(endpoint, body);
    defer r.deinit(gpa);
    const what = try std.fmt.allocPrint(gpa, "{s} {s}", .{ if (is_update) "update" else "add", ep.noun });
    return output.reportWrite(gpa, stderr, r, what, c.api_key);
}
