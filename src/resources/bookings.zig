//! `bookings` resource (alias: `postings`): list, add (single line or
//! --from-json split free booking, validated and canonicalized up front),
//! unconfirm, and assign (link a receipt to a free booking). The BHB API has no
//! delete endpoint — `delete` only explains the web-UI path. `add` is the FREE
//! booking class (the UI "Erweitertes Buchen" / "Hinzufügen"); receipt- and
//! transaction-anchored bookings live on `receipts book` / `transactions book`.

const std = @import("std");
const cli = @import("../cli.zig");
const spec = @import("../spec.zig");
const json = @import("../util/json.zig");
const money = @import("../util/money.zig");
const output = @import("../output.zig");
const Client = @import("../client.zig").Client;

// Table columns for `bookings list`. `vat` (a bare rate like "19.00", ambiguous
// between domestic input VAT, i.g.Erwerb and §13b) is replaced by the decoded
// `tax` label; `fixed`, `receipt` and `tx` show a posting's lock state and its
// receipt/transaction links; soll/haben resolve the debit/credit accounts to
// "NNNN Name". The header set does NOT depend on the name lookup succeeding —
// putNamed falls back to the bare number — so the output shape is stable.
// (JSON output ignores this set; it re-serialises the enriched envelope.)
const cols = [_][]const u8{ "date", "booking_number", "soll", "haben", "amount", "tax", "fixed", "receipt", "tx", "postingtext" };

const AccountNames = std.StringHashMapUnmanaged([]const u8);

/// Per-row decorator state for `bookings list`: the resolved chart of accounts
/// for the soll/haben columns (null falls back to bare numbers). Held by pointer
/// through the output.Decorator's type-erased ctx.
const ListDecor = struct {
    accounts: ?*const AccountNames = null,

    fn make(self: *ListDecor) output.Decorator {
        return .{ .ctx = self, .apply = apply };
    }

    fn apply(ctx: *anyopaque, gpa: std.mem.Allocator, row: *std.json.ObjectMap, mode: spec.Output) anyerror!void {
        const self: *ListDecor = @ptrCast(@alignCast(ctx));
        switch (mode) {
            .table => try self.applyTable(gpa, row),
            .json => try self.applyJson(gpa, row),
        }
    }

    // Table cells: the displayed columns, replacing the ambiguous raw fields.
    fn applyTable(self: *const ListDecor, gpa: std.mem.Allocator, row: *std.json.ObjectMap) !void {
        // tax: documented German label for the numeric tax_key, with the raw key
        // kept in brackets so a wrong or missing mapping can never hide the truth.
        if (json.getStr(row.*, "tax_key")) |k| {
            const cell = if (spec.taxKeyLabel(k)) |lbl| cell: {
                // Account-driven VAT: a "keine Ust." key with a non-zero rate is
                // VAT carried on the account (e.g. Sachbezug accounts), which BHB
                // shows as "NN% USt." — trust the rate, keep the raw key visible.
                if (std.mem.eql(u8, lbl, spec.no_vat_label))
                    if (spec.vatRatePrefix(json.getStr(row.*, "vat"))) |rate|
                        break :cell try std.fmt.allocPrint(gpa, "{s}% USt. [{s}]", .{ rate, k });
                break :cell try std.fmt.allocPrint(gpa, "{s} [{s}]", .{ lbl, k });
            } else try std.fmt.allocPrint(gpa, "[{s}] ?unmapped", .{k});
            try row.put(gpa, "tax", .{ .string = cell });
        }

        // fixed: 0/1 → readable lock state (festgeschrieben vs editable). getInt
        // accepts the number-or-numeric-string this field may arrive as.
        const locked = (json.getInt(row.*, "fixed") orelse 0) == 1;
        try row.put(gpa, "fixed", .{ .string = if (locked) "yes" else "no" });

        // receipt / tx: assigned invoice number and linked transaction, or an em
        // dash when none — the "is this booked / documented?" answer.
        try row.put(gpa, "receipt", .{ .string = dashIfEmpty(json.getStr(row.*, "receipts_assigned_invoice_numbers")) });
        try row.put(gpa, "tx", .{ .string = dashIfEmpty(json.getStr(row.*, "transaction_id_by_customer")) });

        // soll/haben: "NNNN Name" when the chart resolved, the bare number
        // otherwise — so the headers never depend on the lookup succeeding.
        try putNamed(gpa, self.accounts, row, "debit_postingaccount_number", "soll");
        try putNamed(gpa, self.accounts, row, "credit_postingaccount_number", "haben");
    }

    // JSON siblings: decoded values added BESIDE the raw fields, so the enriched
    // body is a superset of the API's. Added only when known, so a consumer can
    // still rely on the raw tax_key / account numbers when no decode exists.
    fn applyJson(self: *const ListDecor, gpa: std.mem.Allocator, row: *std.json.ObjectMap) !void {
        if (json.getStr(row.*, "tax_key")) |k| if (spec.taxKeyLabel(k)) |lbl| {
            // Mirror the table's account-driven-VAT handling (see applyTable).
            const label = if (std.mem.eql(u8, lbl, spec.no_vat_label))
                if (spec.vatRatePrefix(json.getStr(row.*, "vat"))) |rate|
                    try std.fmt.allocPrint(gpa, "{s}% USt.", .{rate})
                else
                    lbl
            else
                lbl;
            try row.put(gpa, "tax_label", .{ .string = label });
        };
        try putNameSibling(gpa, self.accounts, row, "debit_postingaccount_number", "debit_postingaccount_name");
        try putNameSibling(gpa, self.accounts, row, "credit_postingaccount_number", "credit_postingaccount_name");
    }
};

fn dashIfEmpty(s: ?[]const u8) []const u8 {
    const v = s orelse "";
    return if (v.len == 0) "\xe2\x80\x94" else v; // — (em dash)
}

fn putNamed(gpa: std.mem.Allocator, names: ?*const AccountNames, row: *std.json.ObjectMap, src: []const u8, dst: []const u8) !void {
    const num = json.getStr(row.*, src) orelse return;
    const cell = if (names) |m|
        (if (m.get(num)) |name| try std.fmt.allocPrint(gpa, "{s} {s}", .{ num, name }) else num)
    else
        num;
    try row.put(gpa, dst, .{ .string = cell });
}

// JSON variant: set `dst` to the resolved account NAME only (the raw number
// lives in `src`), and only when a name is known.
fn putNameSibling(gpa: std.mem.Allocator, names: ?*const AccountNames, row: *std.json.ObjectMap, src: []const u8, dst: []const u8) !void {
    const m = names orelse return;
    const num = json.getStr(row.*, src) orelse return;
    const name = m.get(num) orelse return;
    try row.put(gpa, dst, .{ .string = name });
}

/// Fetch the chart of accounts and build a number→name map. Returns null (after
/// a one-line stderr warning) when the lookup itself fails or returns an error
/// envelope, so names degrade to bare numbers rather than failing the listing;
/// genuine allocation failures propagate. The parsed tree is left alive (the
/// process arena reclaims it at exit) since the map's keys/values alias it —
/// `.alloc_always` makes those strings independent of the freed response.
fn fetchAccountNames(c: Client, stderr: *std.Io.Writer) !?*AccountNames {
    var o = try json.ObjBuilder.init(c.gpa);
    try o.str("api_key", c.api_key);
    try o.int("limit", 5000);
    try o.end();
    var r = c.post("/settings/get/postingaccounts", o.items()) catch {
        try stderr.writeAll("warning: account-name lookup failed; showing bare numbers\n");
        return null;
    };
    defer r.deinit(c.gpa);

    // alloc_always so every string is arena-owned, independent of r.body (freed
    // by the defer above). A non-200 / error envelope degrades to bare numbers.
    const parsed = std.json.parseFromSlice(std.json.Value, c.gpa, r.body, .{ .allocate = .alloc_always }) catch null;
    if (r.status != 200 or parsed == null or !json.envelopeSuccess(parsed.?.value)) {
        try stderr.writeAll("warning: account-name lookup failed; showing bare numbers\n");
        return null;
    }
    const rows = switch (parsed.?.value) {
        .object => |obj| switch (obj.get("data") orelse return null) {
            .array => |a| a.items,
            else => return null,
        },
        else => return null,
    };
    const map = try c.gpa.create(AccountNames);
    map.* = .empty;
    for (rows) |row| {
        const obj = switch (row) {
            .object => |x| x,
            else => continue,
        };
        const num = json.getStr(obj, "postingaccount_number") orelse continue;
        const name = json.getStr(obj, "name") orelse continue;
        try map.put(c.gpa, num, name);
    }
    return map;
}

const FreeLine = struct {
    date: []const u8,
    postingtext: []const u8,
    amount: []const u8,
    debit: i64,
    credit: i64,
    vat: []const u8,
    cost_location: ?[]const u8 = null,
};

fn buildFreeBody(c: Client, line: FreeLine) ![]u8 {
    var o = try json.ObjBuilder.init(c.gpa);
    try o.str("api_key", c.api_key);
    try o.str("date", line.date);
    try o.str("postingtext", line.postingtext);
    try o.str("amount", line.amount); // string per /postings/add/free
    try o.int("postingaccount_debit", line.debit);
    try o.int("postingaccount_credit", line.credit);
    try o.str("vat", line.vat);
    try o.strOpt("cost_location", line.cost_location);
    try o.end();
    return o.toOwnedSlice();
}

const Verb = enum { list, add, unconfirm, delete, assign };

pub fn run(c: Client, verb: []const u8, f: *const cli.Flags, stdout: *std.Io.Writer, stderr: *std.Io.Writer, out_mode: spec.Output) !u8 {
    const v = std.meta.stringToEnum(Verb, verb) orelse return cli.unknownVerb(stderr, verb, "list|add|unconfirm|delete|assign");
    switch (v) {
        .assign => {
            // Link a receipt to an existing free posting made before it arrived.
            const rid = f.pos(2) orelse return cli.missing(stderr, "<receipt-id>");
            const pid = f.pos(3) orelse return cli.missing(stderr, "<posting-id>");
            const ridn = std.fmt.parseInt(i64, rid, 10) catch return cli.missing(stderr, "<receipt-id> to be an integer");
            const pidn = std.fmt.parseInt(i64, pid, 10) catch return cli.missing(stderr, "<posting-id> to be an integer");

            var o = try json.ObjBuilder.init(c.gpa);
            try o.str("api_key", c.api_key);
            try o.int("receipt_id_by_customer", ridn);
            try o.int("posting_id_by_customer", pidn);
            try o.end();
            var r = try c.post("/postings/assign/receipt-to-free-posting", o.items());
            defer r.deinit(c.gpa);
            return output.reportWrite(c.gpa, stderr, r, "assign", c.api_key);
        },
        .list => {
            // The mandatory --date-from/--date-to span is enforced by the spec
            // (cli.Flags.validate) before we get here.

            // Build the query body from the supplied filters.
            var o = try json.ObjBuilder.init(c.gpa);
            try o.str("api_key", c.api_key);
            try o.str("date_from", f.opt("date-from").?);
            try o.str("date_to", f.opt("date-to").?);
            try o.strOpt("account", f.opt("account"));
            try o.strOpt("postingaccount", f.opt("postingaccount"));
            try o.strOpt("posting_status", f.opt("status"));
            try o.strOpt("order", f.opt("order"));
            try o.strOpt("cost_location", f.opt("cost-location"));
            try json.addIntOpt(&o, "limit", f.opt("limit"));
            try json.addIntOpt(&o, "offset", f.opt("offset"));
            try o.end();

            var r = try c.post("/postings/get", o.items());
            defer r.deinit(c.gpa);

            // The decorator decodes tax_key / fixed / receipt / tx for every
            // listing: as table cells in table mode, as JSON sibling fields in
            // json mode. The debit/credit accounts resolve to names via one extra
            // API call; if that lookup fails, putNamed falls back to bare numbers.
            var decor = ListDecor{ .accounts = try fetchAccountNames(c, stderr) };
            return output.emitListDecorated(c.gpa, stdout, stderr, r, &cols, out_mode, f.opt("filter"), c.api_key, decor.make());
        },
        .add => return add(c, f, stdout, stderr),
        .unconfirm => {
            // Require a numeric posting id.
            const id = f.pos(2) orelse return cli.missing(stderr, "<id>");
            const idn = std.fmt.parseInt(i64, id, 10) catch return cli.missing(stderr, "<id> to be an integer");

            // Build the unconfirm body and report the result.
            var o = try json.ObjBuilder.init(c.gpa);
            try o.str("api_key", c.api_key);
            try o.int("posting_id_by_customer", idn);
            try o.end();
            var r = try c.post("/postings/unconfirm/free", o.items());
            defer r.deinit(c.gpa);
            return output.reportWrite(c.gpa, stderr, r, "unconfirm", c.api_key);
        },
        .delete => {
            try stderr.writeAll("bookings delete: not supported by the BHB API — delete in the web UI.\n");
            return 2;
        },
    }
}

fn add(c: Client, f: *const cli.Flags, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    const gpa = c.gpa;
    var lines: std.ArrayList(FreeLine) = .empty;

    // Gather posting lines: either a JSON array file or a single line from flags.
    if (f.opt("from-json")) |path| {
        // The two input modes are exclusive; silently ignoring the line flags
        // would post something other than what the command line says.
        const single_line_flags = [_][]const u8{ "date", "debit", "credit", "amount", "vat", "text", "cost-location" };
        for (single_line_flags) |name| {
            if (f.opt(name) != null) {
                try stderr.print("error: --{s} cannot be combined with --from-json (the file defines the lines)\n", .{name});
                return 2;
            }
        }
        const text = std.Io.Dir.cwd().readFileAlloc(c.io, path, gpa, .limited(1 << 20)) catch |e| {
            try stderr.print("error: cannot read {s}: {s}\n", .{ path, @errorName(e) });
            return 1;
        };
        // NOTE: not deinit-ed — line slices reference this parse tree (arena frees it).
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch |e| {
            try stderr.print("error: invalid JSON in {s}: {s}\n", .{ path, @errorName(e) });
            return 1;
        };
        const arr = switch (parsed.value) {
            .array => |a| a,
            else => {
                try stderr.writeAll("error: --from-json must contain a JSON array of posting lines\n");
                return 1;
            },
        };

        // Each array element must be an object with the required fields.
        for (arr.items, 0..) |item, idx| {
            const o = switch (item) {
                .object => |x| x,
                else => {
                    try stderr.print("line {d}: not a JSON object\n", .{idx});
                    return 1;
                },
            };
            const line = FreeLine{
                .date = json.getStr(o, "date") orelse return lineErr(stderr, idx, "string 'date'"),
                .postingtext = json.getStr(o, "postingtext") orelse return lineErr(stderr, idx, "string 'postingtext'"),
                .amount = json.getStr(o, "amount") orelse return lineErr(stderr, idx, "string 'amount' (e.g. \"6003.47\")"),
                .debit = json.getInt(o, "debit") orelse return lineErr(stderr, idx, "integer 'debit'"),
                .credit = json.getInt(o, "credit") orelse return lineErr(stderr, idx, "integer 'credit'"),
                .vat = json.getStr(o, "vat") orelse return lineErr(stderr, idx, "string 'vat'"),
                .cost_location = json.getStr(o, "cost_location"),
            };
            try lines.append(gpa, line);
        }
    } else {
        // Single line built from the individual --debit/--credit/... flags.
        const debit = std.fmt.parseInt(i64, f.opt("debit") orelse return cli.missing(stderr, "--debit (or --from-json)"), 10) catch return cli.missing(stderr, "--debit to be an account number");
        const credit = std.fmt.parseInt(i64, f.opt("credit") orelse return cli.missing(stderr, "--credit"), 10) catch return cli.missing(stderr, "--credit to be an account number");
        try lines.append(gpa, .{
            .date = f.opt("date") orelse return cli.missing(stderr, "--date"),
            .postingtext = f.opt("text") orelse return cli.missing(stderr, "--text"),
            .amount = f.opt("amount") orelse return cli.missing(stderr, "--amount"),
            .debit = debit,
            .credit = credit,
            .vat = f.opt("vat") orelse return cli.missing(stderr, "--vat (e.g. 0_none, 19_vat)"),
            .cost_location = f.opt("cost-location"),
        });
    }

    // Nothing to do without at least one line.
    if (lines.items.len == 0) {
        try stderr.writeAll("error: no posting lines\n");
        return 1;
    }

    // Validate every line up front (BHB rejects negatives / equal accounts / bad vat).
    if (try validateLines(gpa, lines.items, stderr)) |code| return code;

    // Optional clearing-account net-zero sanity check (exact cents).
    if (f.opt("clearing")) |cs| {
        const clearing = std.fmt.parseInt(i64, cs, 10) catch return cli.missing(stderr, "--clearing to be an account number");
        var net: i64 = 0;
        var touched = false;
        for (lines.items) |l| {
            const cents = money.parseCents(l.amount).?;
            // Checked arithmetic: a saturated sum could land back on zero and
            // fake a balanced booking; overflow must be its own error.
            if (l.debit == clearing) {
                net = std.math.add(i64, net, cents) catch {
                    try stderr.writeAll("error: clearing-account sum overflows\n");
                    return 1;
                };
                touched = true;
            }
            if (l.credit == clearing) {
                net = std.math.sub(i64, net, cents) catch {
                    try stderr.writeAll("error: clearing-account sum overflows\n");
                    return 1;
                };
                touched = true;
            }
        }
        // An account that appears on no line nets to zero vacuously — that is
        // virtually always a typo'd account number, not a balanced booking.
        if (!touched) {
            try stderr.print("error: clearing account {d} appears on no line\n", .{clearing});
            return 1;
        }
        if (net != 0) {
            try stderr.print("error: clearing account {d} does not net to zero (residual {d} cents)\n", .{ clearing, net });
            return 1;
        }
        try stderr.print("clearing account {d} nets to zero \xe2\x9c\x93\n", .{clearing});
    }

    // Dry run prints the redacted payload for each line and sends nothing.
    if (f.has("dry-run")) {
        try stdout.print("DRY RUN — would POST {d} line(s) to /postings/add/free:\n\n", .{lines.items.len});
        for (lines.items, 0..) |l, i| {
            const body = try buildFreeBody(c, l);
            const shown = try json.redactAlloc(gpa, body, c.api_key);
            try stdout.print("[{d}] {s}\n", .{ i + 1, shown });
        }
        try stdout.writeAll("\n(nothing was sent)\n");
        return 0;
    }

    // POST each line. New postings land CONFIRMED — visible to both the API and
    // the UI, and still unfixed so they remain reviewable/editable/deletable in
    // the UI. To stage one for UI-only review afterwards, run a separate
    // `butler bookings unconfirm <id>` (note: that hides it from the API —
    // BHB ticket 443636).
    try stderr.print("posting {d} line(s)...\n", .{lines.items.len});
    var created: usize = 0;
    for (lines.items, 0..) |l, i| {
        var r = try c.post("/postings/add/free", try buildFreeBody(c, l));
        defer r.deinit(gpa);
        if (r.status == 200 and json.bodySuccess(gpa, r.body)) {
            created += 1;
            try stderr.print("[{d}/{d}] created: {s} {d}->{d} {s}\n", .{ i + 1, lines.items.len, l.date, l.debit, l.credit, l.amount });
        } else {
            // Stop on the first failure; report how many already went through.
            const shown = try json.redactAlloc(gpa, r.body, c.api_key);
            try stderr.print("[{d}/{d}] FAILED: {s}\n", .{ i + 1, lines.items.len, shown });
            try stderr.print("created {d}/{d} line(s) before the failure; review the BHB UI.\n", .{ created, lines.items.len });
            return 1;
        }
    }
    try stderr.print("created {d} line(s) (confirmed). To stage for UI review: butler bookings unconfirm <id>\n", .{created});
    return 0;
}

fn lineErr(stderr: *std.Io.Writer, idx: usize, what: []const u8) !u8 {
    try stderr.print("line {d}: missing {s}\n", .{ idx, what });
    return 1;
}

/// Validate every line (BHB rejects negative amounts, equal debit/credit
/// accounts and bad vat codes) and canonicalize each amount, so the payload
/// sent later is exactly what was validated. Returns an exit code when a line
/// is rejected; null when all lines pass.
fn validateLines(gpa: std.mem.Allocator, lines: []FreeLine, stderr: *std.Io.Writer) !?u8 {
    for (lines, 0..) |*l, i| {
        const cents = money.parseCents(l.amount) orelse {
            try stderr.print("line {d}: amount '{s}' is not a valid decimal\n", .{ i, l.amount });
            return 1;
        };
        if (cents <= 0) {
            try stderr.print("line {d}: amount must be positive (direction comes from debit/credit)\n", .{i});
            return 1;
        }
        if (!spec.isValidVat(l.vat)) {
            try stderr.print("line {d}: invalid vat '{s}'. valid:", .{ i, l.vat });
            for (spec.vat_codes) |v| try stderr.print(" {s}", .{v});
            try stderr.writeByte('\n');
            return 1;
        }
        if (l.debit == l.credit) {
            try stderr.print("line {d}: debit and credit accounts must differ\n", .{i});
            return 1;
        }
        l.amount = try money.renderCentsAlloc(gpa, cents);
    }
    return null;
}

test "validateLines accepts and canonicalizes a good line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var sink: std.Io.Writer.Allocating = .init(gpa);
    var lines = [_]FreeLine{
        .{ .date = "2026-05-31", .postingtext = "t", .amount = " +50.5 ", .debit = 6020, .credit = 3790, .vat = "0_none" },
    };
    try std.testing.expectEqual(@as(?u8, null), try validateLines(gpa, &lines, &sink.writer));
    try std.testing.expectEqualStrings("50.50", lines[0].amount);
}

test "validateLines rejects bad vat, equal accounts, nonpositive amounts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var sink: std.Io.Writer.Allocating = .init(gpa);
    const base = FreeLine{ .date = "2026-05-31", .postingtext = "t", .amount = "1.00", .debit = 6020, .credit = 3790, .vat = "0_none" };

    var bad_vat = [_]FreeLine{base};
    bad_vat[0].vat = "19";
    try std.testing.expectEqual(@as(?u8, 1), try validateLines(gpa, &bad_vat, &sink.writer));

    var equal_accounts = [_]FreeLine{base};
    equal_accounts[0].credit = 6020;
    try std.testing.expectEqual(@as(?u8, 1), try validateLines(gpa, &equal_accounts, &sink.writer));

    var negative = [_]FreeLine{base};
    negative[0].amount = "-1.00";
    try std.testing.expectEqual(@as(?u8, 1), try validateLines(gpa, &negative, &sink.writer));

    var garbage = [_]FreeLine{base};
    garbage[0].amount = "12,50";
    try std.testing.expectEqual(@as(?u8, 1), try validateLines(gpa, &garbage, &sink.writer));
}
