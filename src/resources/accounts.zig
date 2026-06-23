//! `accounts` resource: the chart of accounts — the ledger view of EVERY numbered
//! account (Sachkonten, base cash/bank accounts, and the creditor/debtor
//! Personenkonten). `list` (optionally narrowed by `--type`), `show <number>`,
//! `add` and `update` postingaccounts (Sachkonten). The richer party master data
//! (address, IBAN, VAT id) lives on the `creditors`/`debtors` resources; here a
//! creditor/debtor is just its ledger row. The API has no account-delete route.

const std = @import("std");
const cli = @import("../cli.zig");
const spec = @import("../spec.zig");
const json = @import("../util/json.zig");
const output = @import("../output.zig");
const paged = @import("settings_paged.zig");
const Client = @import("../client.zig").Client;

const get_path = "/settings/get/postingaccounts";
const cols = [_][]const u8{ "postingaccount_number", "name", "type" };

const Verb = enum { list, show, add, update };

// The account categories /settings/get/postingaccounts can return, each with a
// matching `exclude_*` request flag. `--type <kind>` keeps one kind by excluding
// the others; the default (no --type) keeps them all. These are also the spec's
// `--type` choices (kept in sync there).
const Kind = struct { name: []const u8, exclude_flag: []const u8 };
const kinds = [_]Kind{
    .{ .name = "postingaccount", .exclude_flag = "exclude_postingaccounts" },
    .{ .name = "account", .exclude_flag = "exclude_accounts" },
    .{ .name = "creditor", .exclude_flag = "exclude_creditors" },
    .{ .name = "debtor", .exclude_flag = "exclude_debtors" },
};

/// The `exclude_*` flags that narrow the chart to `--type want`: every kind
/// EXCEPT the wanted one. Returns an empty slice for null/"all" (full chart).
/// Fills `buf` (caller-owned, lives for the request) and returns the used prefix.
/// `want` is validated against `kinds` by the spec's `choices`, so an unknown
/// value never reaches here.
fn excludeKeys(want: ?[]const u8, buf: *[kinds.len]([]const u8)) []const []const u8 {
    const t = want orelse return buf[0..0];
    if (std.mem.eql(u8, t, "all")) return buf[0..0];
    var n: usize = 0;
    for (kinds) |k| {
        if (!std.mem.eql(u8, k.name, t)) {
            buf[n] = k.exclude_flag;
            n += 1;
        }
    }
    return buf[0..n];
}

pub fn run(c: Client, verb: []const u8, f: *const cli.Flags, stdout: *std.Io.Writer, stderr: *std.Io.Writer, out_mode: spec.Output) !u8 {
    const v = std.meta.stringToEnum(Verb, verb) orelse return cli.unknownVerb(stderr, verb, "list|show|add|update");
    switch (v) {
        .list => {
            // The full chart of accounts: Sachkonten, the base cash/bank accounts,
            // and the creditor/debtor Personenkonten as ledger rows. `--type`
            // narrows to one kind (default: all); `--filter` is a case-insensitive
            // client-side substring match over the shown columns (number, name,
            // type), rejected with --output json upstream in main.zig.
            var buf: [kinds.len]([]const u8) = undefined;
            const excludes = excludeKeys(f.opt("type"), &buf);

            // An explicit --limit means "one bounded page" (honouring --offset);
            // without it, page the endpoint to completion (its default is only 1000
            // rows, which would silently truncate the full chart).
            if (f.opt("limit") != null) {
                var o = try json.ObjBuilder.init(c.gpa);
                try o.str("api_key", c.api_key);
                for (excludes) |k| try o.boolean(k, true);
                try json.addIntOpt(&o, "limit", f.opt("limit"));
                try json.addIntOpt(&o, "offset", f.opt("offset"));
                try o.end();
                var r = try c.post(get_path, o.items());
                defer r.deinit(c.gpa);
                return output.emitList(c.gpa, stdout, stderr, r, &cols, out_mode, f.opt("filter"), c.api_key);
            }
            switch (try paged.fetchAll(c, get_path, paged.startOffset(f), excludes)) {
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
            // Look up one account by its number — any kind (Sachkonto or a
            // creditor/debtor Personenkonto), returning its ledger row. For a
            // party's master data (address, IBAN, VAT id) use `creditors show` /
            // `debtors show`. The endpoint has no by-number filter and no
            // get-by-id route, so page the whole chart and match the canonical
            // number client-side (so "0540" finds account 540).
            const acct = f.pos(2) orelse return cli.missing(stderr, "<account>");
            const acctn = std.fmt.parseInt(i64, acct, 10) catch return cli.missing(stderr, "<account> to be an integer");
            const canon = try std.fmt.allocPrint(c.gpa, "{d}", .{acctn});
            switch (try paged.fetchAll(c, get_path, 0, &.{})) {
                .failed => |resp| {
                    var r = resp;
                    defer r.deinit(c.gpa);
                    return output.emitList(c.gpa, stdout, stderr, r, &cols, out_mode, null, c.api_key);
                },
                .incomplete => return paged.incompleteError(stderr),
                .merged => |body| return output.emitShowBy(c.gpa, stdout, stderr, .{ .status = 200, .body = body }, out_mode, "postingaccount_number", canon, c.api_key),
            }
        },
        .add => return write(c, f, stdout, stderr, false),
        .update => return write(c, f, stdout, stderr, true),
    }
}

/// Create (`add`) or rename (`update`) a postingaccount (Sachkonto). The API
/// requires `name` and the account number for both; `add` also requires a
/// `--parent` (the account it nests under). The account number is the positional
/// key in both cases. Mirrors the codebase's write-verb shape: build the body,
/// honour --dry-run (redacted echo), POST, then output.reportWrite.
fn write(c: Client, f: *const cli.Flags, stdout: *std.Io.Writer, stderr: *std.Io.Writer, is_update: bool) !u8 {
    const gpa = c.gpa;
    const acct = f.pos(2) orelse return cli.missing(stderr, "<account>");
    const acctn = std.fmt.parseInt(i64, acct, 10) catch return cli.missing(stderr, "<account> to be an integer");
    const name = f.opt("name") orelse return cli.missing(stderr, "--name");

    var o = try json.ObjBuilder.init(gpa);
    try o.str("api_key", c.api_key);
    try o.str("name", name);
    try o.int("postingaccount_number", acctn);
    if (!is_update) {
        // The API requires a parent account on create (the chart node it nests
        // under); update keeps the existing parent.
        const parent = f.opt("parent") orelse return cli.missing(stderr, "--parent");
        const parentn = std.fmt.parseInt(i64, parent, 10) catch return cli.missing(stderr, "--parent to be an integer");
        try o.int("parent_postingaccount_number", parentn);
    }
    try o.end();
    const body = try o.toOwnedSlice();

    const endpoint = if (is_update) "/settings/update/postingaccount" else "/settings/add/postingaccount";
    if (f.has("dry-run")) {
        const shown = try json.redactAlloc(gpa, body, c.api_key);
        try stdout.print("DRY RUN — would POST to {s}:\n{s}\n\n(nothing was sent)\n", .{ endpoint, shown });
        return 0;
    }
    var r = try c.post(endpoint, body);
    defer r.deinit(gpa);
    return output.reportWrite(gpa, stderr, r, if (is_update) "update account" else "add account", c.api_key);
}
