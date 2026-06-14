//! `receipts` resource: list, show (via the list endpoint — get-by-id is
//! broken server-side), upload (base64 JSON payload), delete.

const std = @import("std");
const cli = @import("../cli.zig");
const spec = @import("../spec.zig");
const json = @import("../util/json.zig");
const money = @import("../util/money.zig");
const output = @import("../output.zig");
const openitems = @import("openitems.zig");
const postingline = @import("postingline.zig");
const Client = @import("../client.zig").Client;

const cols = [_][]const u8{ "date", "type", "counterparty", "invoicenumber", "amount", "id_by_customer" };

// BHB's fixed collective creditor account ("Kreditoren-Sammelkonto", 70000 — a
// standard account it does not let you renumber). A receipt not booked to a
// dedicated creditor lands here, so `book` defaults the creditor side to it.
// (The debtor counterpart for outbound invoices is 10000.)
const default_creditor = "70000";

fn listBody(c: Client, f: *const cli.Flags, direction: []const u8) ![]u8 {
    var o = try json.ObjBuilder.init(c.gpa);
    try o.str("api_key", c.api_key);
    try o.str("list_direction", direction);
    // --unpaid is the UI "Unbezahlt" shorthand for --payment-status unpaid.
    try o.strOpt("payment_status", if (f.has("unpaid")) "unpaid" else f.opt("payment-status"));
    try o.strOpt("counterparty", f.opt("counterparty"));
    try o.strOpt("date_from", f.opt("date-from"));
    try o.strOpt("date_to", f.opt("date-to"));
    try o.strOpt("invoicenumber", f.opt("invoice-number"));
    try o.strOpt("due_date", f.opt("due-date"));
    if (f.has("include-offers")) try o.boolean("include_offers", true);
    if (f.has("deleted")) try o.boolean("deleted", true);
    try json.addIntOpt(&o, "limit", f.opt("limit"));
    try json.addIntOpt(&o, "offset", f.opt("offset"));
    try o.end();
    return o.toOwnedSlice();
}

// Make a money string negative ("8.31" -> "-8.31"; an already-negative or empty
// value is left as-is). Used by --credit-note so a Gutschrift is uploaded with
// the negative amount BHB needs to reverse its booking, whether or not the user
// typed the minus.
fn ensureNegative(gpa: std.mem.Allocator, s: ?[]const u8) !?[]const u8 {
    const v = s orelse return null;
    const t = std.mem.trim(u8, v, " \t");
    if (t.len == 0 or t[0] == '-') return v;
    return try std.fmt.allocPrint(gpa, "-{s}", .{t});
}

fn upload(c: Client, f: *const cli.Flags, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    // Resolve the file path (positional) and receipt type.
    const path = f.pos(2) orelse return cli.missing(stderr, "<file path>");
    const rtype = f.opt("type") orelse return cli.missing(stderr, "--type (e.g. \"invoice inbound\")");

    // Read the file (cap 32 MiB) and base64-encode it for the JSON payload.
    const bytes = std.Io.Dir.cwd().readFileAlloc(c.io, path, c.gpa, .limited(32 << 20)) catch |e| {
        try stderr.print("error: cannot read {s}: {s}\n", .{ path, @errorName(e) });
        return 1;
    };
    const enc = std.base64.standard.Encoder;
    const b64 = try c.gpa.alloc(u8, enc.calcSize(bytes.len));
    _ = enc.encode(b64, bytes);
    const name = std.fs.path.basename(path);

    // Build the upload body.
    var o = try json.ObjBuilder.init(c.gpa);
    try o.str("api_key", c.api_key);
    try o.str("file", b64);
    try o.str("file_name", name);
    try o.str("type", rtype);
    try o.strOpt("counterparty", f.opt("counterparty"));
    try o.strOpt("invoice_number", f.opt("invoice-number"));
    try o.strOpt("date", f.opt("date"));
    // A credit note (Gutschrift) is a receipt with a negative amount; BHB then
    // reverses its booking automatically. --credit-note sends --amount negative
    // so the user can pass the gross amount without a leading minus.
    const amount_field = if (f.has("credit-note")) try ensureNegative(c.gpa, f.opt("amount")) else f.opt("amount");
    try o.strOpt("amount", amount_field);
    try o.strOpt("vat_rate", f.opt("vat-rate"));
    try o.end();

    // Dry run prints what would be sent and stops.
    if (f.has("dry-run")) {
        try stdout.print("DRY RUN — would POST /receipts/upload  file_name='{s}'  type='{s}'  ({d} bytes)\n", .{ name, rtype, bytes.len });
        return 0;
    }

    var r = try c.post("/receipts/upload", o.items());
    defer r.deinit(c.gpa);
    return output.reportWrite(c.gpa, stderr, r, "upload", c.api_key);
}

/// `receipts book <id>` — book a receipt onto account(s) via
/// `/postings/add/receipt`. The counterparty Sammelkonto defaults to the standard
/// Kreditoren-Sammelkonto; --creditor names a dedicated creditor, --debtor
/// switches to the debtor side. Single line from flags, or a split via
/// --from-json.
fn book(c: Client, f: *const cli.Flags, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    const gpa = c.gpa;
    const rid = f.pos(2) orelse return cli.missing(stderr, "<receipt-id>");
    const ridn = std.fmt.parseInt(i64, rid, 10) catch return cli.missing(stderr, "<receipt-id> to be an integer");

    // Default to the Kreditoren-Sammelkonto (an Eingangsrechnung) when neither
    // side is given; --creditor names a dedicated creditor, --debtor switches to
    // the debtor side (Ausgangsrechnung).
    const cred_default = if (f.opt("debtor") != null) "0" else default_creditor;
    const cred = std.fmt.parseInt(i64, f.opt("creditor") orelse cred_default, 10) catch return cli.missing(stderr, "--creditor to be an account number");
    const deb = std.fmt.parseInt(i64, f.opt("debtor") orelse "0", 10) catch return cli.missing(stderr, "--debtor to be an account number");

    const lines = switch (try postingline.gather(c, f, stderr)) {
        .lines => |l| l,
        .fail => |code| return code,
    };
    const a = try postingline.toArrays(gpa, lines);

    var o = try json.ObjBuilder.init(gpa);
    try o.str("api_key", c.api_key);
    try o.int("receipt_id_by_customer", ridn);
    try o.arrStr("postingaccounts", a.accounts);
    try o.arrStr("postingtexts", a.texts);
    try o.arrStr("vats", a.vats);
    try o.arrStr("amounts", a.amounts);
    try o.int("creditor", cred);
    try o.int("debtor", deb);
    try o.end();
    const body = try o.toOwnedSlice();

    if (f.has("dry-run")) {
        const shown = try json.redactAlloc(gpa, body, c.api_key);
        try stdout.print("DRY RUN — would POST to /postings/add/receipt:\n{s}\n\n(nothing was sent)\n", .{shown});
        return 0;
    }
    var r = try c.post("/postings/add/receipt", body);
    defer r.deinit(gpa);
    return output.reportWrite(gpa, stderr, r, "book receipt", c.api_key);
}

/// `receipts pay <id> --with <tx>` — settle a single booked receipt against a
/// bank payment. Convenience wrapper over `settle` for the receipt-first view;
/// the receipt's open amount must equal the transaction amount.
fn pay(c: Client, f: *const cli.Flags, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    const rid = f.pos(2) orelse return cli.missing(stderr, "<receipt-id>");
    const txs = f.opt("with") orelse return cli.missing(stderr, "--with <transaction-id>");
    const txn = std.fmt.parseInt(i64, txs, 10) catch return cli.missing(stderr, "--with to be an integer");
    return settle(c, f, stdout, stderr, txn, &.{rid});
}

/// Settle one or more booked receipts against bank transaction `txn` in a SINGLE
/// `/postings/add/transaction`: one creditor->bank line per receipt, each
/// carrying it as an open item so the receipt is marked paid. Each line is
/// resolved from the receipt's own booking (open amount, the creditor it was
/// booked to). The line amounts must sum to the transaction amount — the API
/// rejects a mismatch (error 27) — so a payment covering several invoices must
/// list all of them here. With a single receipt, --account/--amount/--text
/// override the derived values; --dry-run prints the payload.
pub fn settle(c: Client, f: *const cli.Flags, stdout: *std.Io.Writer, stderr: *std.Io.Writer, txn: i64, rids: []const []const u8) !u8 {
    const gpa = c.gpa;
    if (rids.len == 0) return cli.missing(stderr, "at least one receipt id");
    const single = rids.len == 1;

    var accounts: std.ArrayList([]const u8) = .empty;
    var texts: std.ArrayList([]const u8) = .empty;
    var vats: std.ArrayList([]const u8) = .empty;
    var amounts: std.ArrayList([]const u8) = .empty;
    for (rids) |rid| {
        _ = std.fmt.parseInt(i64, rid, 10) catch return cli.missing(stderr, "receipt id to be an integer");
        const receipt = (try findReceipt(c, rid, stderr)) orelse return 1;
        const counterparty = json.getStr(receipt, "counterparty") orelse "";
        const invnum = json.getStr(receipt, "invoicenumber") orelse "";
        const rdate = json.getStr(receipt, "date") orelse "";

        // The still-open amount, as a magnitude: a normal receipt carries a
        // positive amount, a credit note a negative one, so take |amount| less
        // what is already paid.
        const open_cents = absCents(json.getStr(receipt, "amount")) - absCents(json.getStr(receipt, "amount_paid"));
        if (open_cents <= 0) {
            try stderr.print("error: receipt {s} has nothing open to settle\n", .{rid});
            return 1;
        }

        // Default to the receipt's open amount. A single-receipt --amount
        // override (a part-payment) goes through the same parse+canonicalise as
        // every other amount, so the payload never diverges from what was checked.
        const cents = if (single) blk: {
            const raw = f.opt("amount") orelse break :blk open_cents;
            const c2 = money.parseCents(raw) orelse {
                try stderr.print("error: --amount '{s}' is not a valid decimal\n", .{raw});
                return 1;
            };
            if (c2 <= 0) {
                try stderr.writeAll("error: --amount must be positive\n");
                return 1;
            }
            break :blk c2;
        } else open_cents;
        const amount = try money.renderCentsAlloc(gpa, cents);
        const text = if (single and f.opt("text") != null) f.opt("text").? else if (invnum.len > 0)
            try std.fmt.allocPrint(gpa, "Ausgleich {s} ({s})", .{ counterparty, invnum })
        else
            try std.fmt.allocPrint(gpa, "Ausgleich {s}", .{counterparty});

        // The line clears the creditor the receipt was booked against. A normal
        // invoice books Soll expense / Haben creditor, so the creditor is the
        // credit side; a credit note (negative amount) books it reversed, so the
        // creditor is the debit side. Pick the side from the receipt's sign.
        const credit_note = (money.parseCents(json.getStr(receipt, "amount") orelse "0") orelse 0) < 0;
        const creditor = (if (single) f.opt("account") else null) orelse (try findReceiptCreditor(c, rid, rdate, credit_note)) orelse {
            try stderr.print("error: receipt {s} is not booked yet (cannot derive its creditor); book it first, or pass --account\n", .{rid});
            return 1;
        };

        try accounts.append(gpa, creditor);
        try texts.append(gpa, text);
        try vats.append(gpa, "0_none");
        try amounts.append(gpa, amount);
    }

    var o = try json.ObjBuilder.init(gpa);
    try o.str("api_key", c.api_key);
    try o.int("transaction_id_by_customer", txn);
    try o.arrStr("postingaccounts", accounts.items);
    try o.arrStr("postingtexts", texts.items);
    try o.arrStr("vats", vats.items);
    try o.arrStr("amounts", amounts.items);
    try o.arrStr("oi_receipts_ids_by_customer", rids);
    try o.end();
    const body = try o.toOwnedSlice();

    if (f.has("dry-run")) {
        const shown = try json.redactAlloc(gpa, body, c.api_key);
        try stdout.print("DRY RUN — settle receipt(s) against transaction {d} via /postings/add/transaction:\n{s}\n\n(nothing was sent)\n", .{ txn, shown });
        return 0;
    }
    var r = try c.post("/postings/add/transaction", body);
    defer r.deinit(gpa);
    return output.reportWrite(gpa, stderr, r, "settle", c.api_key);
}

fn absCents(s: ?[]const u8) i64 {
    const v = money.parseCents(s orelse "0") orelse 0;
    return if (v < 0) -v else v;
}

/// Find a receipt by id_by_customer, trying inbound then outbound (the get-by-id
/// route is broken; see receipts show). Returns its object, aliasing an arena
/// kept alive for the rest of the run.
fn findReceipt(c: Client, rid: []const u8, stderr: *std.Io.Writer) !?std.json.ObjectMap {
    for ([_][]const u8{ "inbound", "outbound" }) |dir| {
        var o = try json.ObjBuilder.init(c.gpa);
        try o.str("api_key", c.api_key);
        try o.str("list_direction", dir);
        try o.int("limit", 500);
        try o.end();
        var r = try c.post("/receipts/get", o.items());
        defer r.deinit(c.gpa);
        const parsed = std.json.parseFromSlice(std.json.Value, c.gpa, r.body, .{ .allocate = .alloc_always }) catch continue;
        const rows = output.dataArray(parsed.value) orelse continue;
        for (rows) |row| switch (row) {
            .object => |obj| {
                const id = json.getStr(obj, "id_by_customer") orelse continue;
                if (std.mem.eql(u8, id, rid)) return obj;
            },
            else => {},
        };
    }
    try stderr.print("error: receipt {s} not found (the lookup scans the 500 most recent per direction)\n", .{rid});
    return null;
}

/// The creditor account a receipt was booked against — the credit side of the
/// posting that references it for a normal invoice, the debit side for a credit
/// note (whose booking is reversed) — scanned over the receipt's year. Null if
/// not yet booked.
fn findReceiptCreditor(c: Client, rid: []const u8, rdate: []const u8, credit_note: bool) !?[]const u8 {
    if (rdate.len < 4) return null;
    const year = rdate[0..4];
    var o = try json.ObjBuilder.init(c.gpa);
    try o.str("api_key", c.api_key);
    try o.str("date_from", try std.fmt.allocPrint(c.gpa, "{s}-01-01", .{year}));
    try o.str("date_to", try std.fmt.allocPrint(c.gpa, "{s}-12-31", .{year}));
    try o.str("account", "all");
    try o.int("limit", 1000);
    try o.end();
    var r = try c.post("/postings/get", o.items());
    defer r.deinit(c.gpa);
    const parsed = std.json.parseFromSlice(std.json.Value, c.gpa, r.body, .{ .allocate = .alloc_always }) catch return null;
    const rows = output.dataArray(parsed.value) orelse return null;
    for (rows) |row| switch (row) {
        .object => |obj| {
            const assigned = json.getStr(obj, "receipts_assigned_ids_by_customer") orelse continue;
            var it = std.mem.tokenizeAny(u8, assigned, " ,");
            while (it.next()) |t| {
                if (std.mem.eql(u8, t, rid))
                    return json.getStr(obj, if (credit_note) "debit_postingaccount_number" else "credit_postingaccount_number");
            }
        },
        else => {},
    };
    return null;
}

const Verb = enum { list, show, upload, delete, book, pay };

pub fn run(c: Client, verb: []const u8, f: *const cli.Flags, stdout: *std.Io.Writer, stderr: *std.Io.Writer, out_mode: spec.Output) !u8 {
    const v = std.meta.stringToEnum(Verb, verb) orelse return cli.unknownVerb(stderr, verb, "list|show|upload|delete|book|pay");
    switch (v) {
        .book => return book(c, f, stdout, stderr),
        .pay => return pay(c, f, stdout, stderr),
        .list => {
            // Require and validate the inbound/outbound direction (positional).
            const dir = f.pos(2) orelse return cli.missing(stderr, "<inbound|outbound>");
            if (!std.mem.eql(u8, dir, "inbound") and !std.mem.eql(u8, dir, "outbound"))
                return cli.missing(stderr, "direction to be inbound|outbound");

            // --unbooked (UI "Ungebucht") keeps only receipts that no posting
            // references over the window. The window bounds the posting sweep, so
            // it is required here — checked before any request so a missing window
            // fails without a call.
            if (f.has("unbooked")) {
                const from = f.opt("date-from") orelse return openitems.windowRequired("unbooked", stderr);
                const to = f.opt("date-to") orelse return openitems.windowRequired("unbooked", stderr);
                var r = try c.post("/receipts/get", try listBody(c, f, dir));
                defer r.deinit(c.gpa);
                return openitems.emit(c, stdout, stderr, r, &cols, out_mode, f.opt("filter"), from, to, "receipts_assigned_ids_by_customer", true, null);
            }
            var r = try c.post("/receipts/get", try listBody(c, f, dir));
            defer r.deinit(c.gpa);
            return output.emitList(c.gpa, stdout, stderr, r, &cols, out_mode, f.opt("filter"), c.api_key);
        },
        .show => {
            // The get-by-id route 404s server-side (docs/bhb-api-quirks.md), so
            // fetch via the list endpoint and match the id client-side, like
            // transactions show. /receipts/get requires list_direction: query
            // the given --direction, or both. The API caps a page at 500 rows,
            // so the lookup sees at most 500 receipts per direction.
            const id = f.pos(2) orelse return cli.missing(stderr, "<id>");
            const idn = std.fmt.parseInt(i64, id, 10) catch return cli.missing(stderr, "<id> to be an integer");
            const canon = try std.fmt.allocPrint(c.gpa, "{d}", .{idn});

            const both = [_][]const u8{ "inbound", "outbound" };
            var one: [1][]const u8 = .{""};
            var directions: []const []const u8 = &both;
            if (f.opt("direction")) |d| {
                one[0] = d;
                directions = &one;
            }

            for (directions) |dir| {
                var o = try json.ObjBuilder.init(c.gpa);
                try o.str("api_key", c.api_key);
                try o.str("list_direction", dir);
                try o.int("limit", 500);
                try o.end();
                var r = try c.post("/receipts/get", o.items());
                defer r.deinit(c.gpa);
                if (try output.tryEmitShow(c.gpa, stdout, stderr, r, out_mode, canon, c.api_key)) |code| return code;
            }
            try stderr.writeAll("not found.\n");
            return 1;
        },
        .upload => return upload(c, f, stdout, stderr),
        .delete => {
            // Build the delete body from the id.
            const id = f.pos(2) orelse return cli.missing(stderr, "<id>");
            var o = try json.ObjBuilder.init(c.gpa);
            try o.str("api_key", c.api_key);
            try o.str("id_by_customer", id);
            try o.end();

            var r = try c.post("/receipts/delete/id_by_customer", o.items());
            defer r.deinit(c.gpa);
            return output.reportWrite(c.gpa, stderr, r, "delete", c.api_key);
        },
    }
}
