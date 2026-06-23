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
const Client = @import("../client.zig").Client;

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

/// Apply the `--type` filter to a postingaccounts query: to keep only `want`,
/// exclude every other kind. No-op when `want` is null ("all") or "all", so the
/// full chart comes back. `want` is validated against `kinds` by the spec's
/// `choices`, so an unknown value never reaches here.
fn applyTypeFilter(o: *json.ObjBuilder, want: ?[]const u8) !void {
    const t = want orelse return;
    if (std.mem.eql(u8, t, "all")) return;
    for (kinds) |k| {
        if (!std.mem.eql(u8, k.name, t)) try o.boolean(k.exclude_flag, true);
    }
}

pub fn run(c: Client, verb: []const u8, f: *const cli.Flags, stdout: *std.Io.Writer, stderr: *std.Io.Writer, out_mode: spec.Output) !u8 {
    const v = std.meta.stringToEnum(Verb, verb) orelse return cli.unknownVerb(stderr, verb, "list|show|add|update");
    switch (v) {
        .list => {
            // The full chart of accounts: Sachkonten, the base cash/bank accounts,
            // and the creditor/debtor Personenkonten as ledger rows. `--type`
            // narrows to one kind (default: all).
            var o = try json.ObjBuilder.init(c.gpa);
            try o.str("api_key", c.api_key);
            try applyTypeFilter(&o, f.opt("type"));
            try json.addIntOpt(&o, "limit", f.opt("limit"));
            try json.addIntOpt(&o, "offset", f.opt("offset"));
            try o.end();

            var r = try c.post("/settings/get/postingaccounts", o.items());
            defer r.deinit(c.gpa);
            return output.emitList(c.gpa, stdout, stderr, r, &cols, out_mode, f.opt("filter"), c.api_key);
        },
        .show => {
            // Look up one account by its number — any kind (Sachkonto or a
            // creditor/debtor Personenkonto), returning its ledger row. For a
            // party's master data (address, IBAN, VAT id) use `creditors show` /
            // `debtors show`. The endpoint has no by-number filter and no
            // get-by-id route, so fetch the chart and match client-side; it
            // defaults to 1000 rows (which would omit higher-numbered accounts),
            // so ask for a generous page.
            const acct = f.pos(2) orelse return cli.missing(stderr, "<account>");
            var o = try json.ObjBuilder.init(c.gpa);
            try o.str("api_key", c.api_key);
            try o.int("limit", 5000);
            try o.end();

            var r = try c.post("/settings/get/postingaccounts", o.items());
            defer r.deinit(c.gpa);
            return output.emitShowBy(c.gpa, stdout, stderr, r, out_mode, "postingaccount_number", acct, c.api_key);
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
