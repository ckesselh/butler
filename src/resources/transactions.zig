//! `transactions` resource: list with server-side filters, and show via the
//! direct `/transactions/get/<id>` route (path-segment id, object-shaped
//! `data`; see docs/bhb-api-quirks.md).

const std = @import("std");
const cli = @import("../cli.zig");
const spec = @import("../spec.zig");
const json = @import("../util/json.zig");
const output = @import("../output.zig");
const comments = @import("comments.zig");
const openitems = @import("openitems.zig");
const postingline = @import("postingline.zig");
const receipts = @import("receipts.zig");
const Client = @import("../client.zig").Client;

const cols = [_][]const u8{ "booking_date", "value_date", "amount", "to_from", "purpose" };

// Columns for the receipts assigned to a transaction (`transactions receipts`).
const receipt_cols = [_][]const u8{ "id_by_customer", "invoicenumber", "amount", "filename" };

fn listBody(c: Client, f: *const cli.Flags) ![]u8 {
    var o = try json.ObjBuilder.init(c.gpa);
    try o.str("api_key", c.api_key);
    try o.strOpt("date_from", f.opt("date-from"));
    try o.strOpt("date_to", f.opt("date-to"));
    try o.strOpt("to_from", f.opt("to-from"));
    try json.addIntOpt(&o, "account", f.opt("account"));
    try json.addIntOpt(&o, "id_by_customer_from", f.opt("id-from"));
    try json.addIntOpt(&o, "id_by_customer_to", f.opt("id-to"));
    try json.addIntOpt(&o, "limit", f.opt("limit"));
    try json.addIntOpt(&o, "offset", f.opt("offset"));
    try o.end();
    return o.toOwnedSlice();
}

const Verb = enum { list, show, book, settle, link, unlink, receipts, comment };

pub fn run(c: Client, verb: []const u8, f: *const cli.Flags, stdout: *std.Io.Writer, stderr: *std.Io.Writer, out_mode: spec.Output) !u8 {
    const v = std.meta.stringToEnum(Verb, verb) orelse return cli.unknownVerb(stderr, verb, "list|show|book|settle|link|unlink|receipts|comment");
    switch (v) {
        .book => return book(c, f, stdout, stderr),
        .settle => return settle(c, f, stdout, stderr),
        .comment => return comments.run(c, .transaction, f, stdout, stderr),
        .link => return assign(c, f, stderr, "/transactions/assign/receipt", "link"),
        .unlink => return assign(c, f, stderr, "/transactions/unassign/receipt", "unlink"),
        .receipts => return assignedReceipts(c, f, stdout, stderr, out_mode),
        .list => {
            // Open-item filters (UI "Ungebucht" / "Fehlender Beleg") anti-join a
            // /postings/get sweep, so they need a bounded window — checked before
            // any request so a missing window fails without a call.
            //   --unbooked       : no posting of any class references the payment.
            //   --missing-receipt: no posting carries a receipt for the payment —
            //                      a superset of --unbooked (an unbooked payment
            //                      has no receipt either).
            const open_filter: ?[]const u8 = if (f.has("unbooked")) "unbooked" else if (f.has("missing-receipt")) "missing-receipt" else null;
            if (open_filter) |flag| {
                const from = f.opt("date-from") orelse return openitems.windowRequired(flag, stderr);
                const to = f.opt("date-to") orelse return openitems.windowRequired(flag, stderr);
                var r = try c.post("/transactions/get", try listBody(c, f));
                defer r.deinit(c.gpa);
                // For --missing-receipt, only postings that carry a receipt count
                // as "has a receipt"; the anti-join then returns those without one.
                const require_field: ?[]const u8 = if (f.has("missing-receipt")) "receipts_assigned_ids_by_customer" else null;
                return openitems.emit(c, stdout, stderr, r, &cols, out_mode, f.opt("filter"), from, to, "transaction_id_by_customer", false, require_field);
            }
            var r = try c.post("/transactions/get", try listBody(c, f));
            defer r.deinit(c.gpa);
            return output.emitList(c.gpa, stdout, stderr, r, &cols, out_mode, f.opt("filter"), c.api_key);
        },
        .show => {
            // Direct read: POST /transactions/get/<id> (path-segment id),
            // object-shaped `data`; a miss answers HTTP 400 "transaction not
            // found" (docs/bhb-api-quirks.md). Returns more fields than the
            // list rows (e.g. account_number, bank_code).
            const idn = f.posInt(2) orelse return cli.missing(stderr, "<id> (e.g. `transactions show 749`)");
            const path = try std.fmt.allocPrint(c.gpa, "/transactions/get/{d}", .{idn});
            var o = try json.ObjBuilder.init(c.gpa);
            try o.str("api_key", c.api_key);
            try o.end();
            var r = try c.post(path, o.items());
            defer r.deinit(c.gpa);
            return (try output.emitShowObject(c.gpa, stdout, stderr, r, out_mode, c.api_key)) orelse {
                try stderr.writeAll("not found.\n");
                return 1;
            };
        },
    }
}

/// `transactions book <tx>` — post one or more lines directly onto a bank
/// transaction (`/postings/add/transaction`). Single line from
/// --account/--amount/--vat/--text, or a split from --from-json. New postings
/// land confirmed, like a free booking. A line carries the receipt whose open
/// item it clears in `oi_receipts_ids_by_customer`, null where it clears none,
/// so one payment can settle a receipt and book an extra amount beside it.
fn book(c: Client, f: *const cli.Flags, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    const gpa = c.gpa;
    const txn = f.posInt(2) orelse return cli.missing(stderr, "<transaction-id>");

    const lines = switch (try postingline.gather(c, f, stderr, .{ .receipt_refs = true })) {
        .lines => |l| l,
        .fail => |code| return code,
    };
    const a = try postingline.toArrays(gpa, lines);

    var o = try json.ObjBuilder.init(gpa);
    try o.str("api_key", c.api_key);
    try o.int("transaction_id_by_customer", txn);
    try o.arrStr("postingaccounts", a.accounts);
    try o.arrStr("postingtexts", a.texts);
    try o.arrStr("vats", a.vats);
    try o.arrStr("amounts", a.amounts);
    try o.arrStrOrNull("oi_receipts_ids_by_customer", a.receipts);
    try o.end();
    const body = try o.toOwnedSlice();

    if (f.has("dry-run")) {
        const shown = try json.redactAlloc(gpa, body, c.api_key);
        try stdout.print("DRY RUN — would POST to /postings/add/transaction:\n{s}\n\n(nothing was sent)\n", .{shown});
        return 0;
    }
    var r = try c.post("/postings/add/transaction", body);
    defer r.deinit(gpa);
    return output.reportWrite(gpa, stderr, r, "book transaction", c.api_key);
}

/// `transactions link`/`unlink <tx> <receipt>` — link or unlink a receipt and a
/// bank transaction (`/transactions/{assign,unassign}/receipt`). A soft pointer
/// only (sets payment_date); it does NOT settle — that is `settle` / `receipts
/// pay`.
fn assign(c: Client, f: *const cli.Flags, stderr: *std.Io.Writer, path: []const u8, what: []const u8) !u8 {
    const txn = f.posInt(2) orelse return cli.missing(stderr, "<transaction-id>");
    const ridn = f.posInt(3) orelse return cli.missing(stderr, "<receipt-id>");

    var o = try json.ObjBuilder.init(c.gpa);
    try o.str("api_key", c.api_key);
    try o.int("transaction_id_by_customer", txn);
    try o.int("receipt_id_by_customer", ridn);
    try o.end();
    var r = try c.post(path, o.items());
    defer r.deinit(c.gpa);
    return output.reportWrite(c.gpa, stderr, r, what, c.api_key);
}

/// `transactions settle <tx> --receipts <id,id,...>` — settle one or more booked
/// receipts against a bank payment (the payment-first view of `receipts pay`).
/// One bank line can clear several invoices; their amounts must sum to the
/// transaction. Delegates to the shared settle core in the receipts module.
fn settle(c: Client, f: *const cli.Flags, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    const txn = f.posInt(2) orelse return cli.missing(stderr, "<transaction-id>");
    const csv = f.opt("receipts") orelse return cli.missing(stderr, "--receipts <id,id,...>");

    var rids: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, csv, ", ");
    while (it.next()) |id| try rids.append(c.gpa, id);
    if (rids.items.len == 0) return cli.missing(stderr, "--receipts <id,id,...>");

    return receipts.settle(c, f, stdout, stderr, txn, rids.items);
}

/// `transactions receipts <tx>` — list the receipts assigned to a transaction
/// (`/transactions/assigned-receipts/get`).
fn assignedReceipts(c: Client, f: *const cli.Flags, stdout: *std.Io.Writer, stderr: *std.Io.Writer, out_mode: spec.Output) !u8 {
    const txn = f.posInt(2) orelse return cli.missing(stderr, "<transaction-id>");

    var o = try json.ObjBuilder.init(c.gpa);
    try o.str("api_key", c.api_key);
    try o.int("transaction_id_by_customer", txn);
    if (f.has("confirmed-only")) try o.boolean("confirmed_only", true);
    try o.end();
    var r = try c.post("/transactions/assigned-receipts/get", o.items());
    defer r.deinit(c.gpa);
    return output.emitList(c.gpa, stdout, stderr, r, &receipt_cols, out_mode, f.opt("filter"), c.api_key);
}
