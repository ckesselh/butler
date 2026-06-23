//! `accounts` resource: the chart of accounts — list, show, add and update
//! postingaccounts (Sachkonten). Creditor/debtor subledgers live on their own
//! resources; the API has no account-delete route.

const std = @import("std");
const cli = @import("../cli.zig");
const spec = @import("../spec.zig");
const json = @import("../util/json.zig");
const output = @import("../output.zig");
const Client = @import("../client.zig").Client;

const cols = [_][]const u8{ "postingaccount_number", "name", "type" };

const Verb = enum { list, show, add, update };

pub fn run(c: Client, verb: []const u8, f: *const cli.Flags, stdout: *std.Io.Writer, stderr: *std.Io.Writer, out_mode: spec.Output) !u8 {
    const v = std.meta.stringToEnum(Verb, verb) orelse return cli.unknownVerb(stderr, verb, "list|show|add|update");
    switch (v) {
        .list => {
            // Build the query body (paging only).
            var o = try json.ObjBuilder.init(c.gpa);
            try o.str("api_key", c.api_key);
            try json.addIntOpt(&o, "limit", f.opt("limit"));
            try json.addIntOpt(&o, "offset", f.opt("offset"));
            try o.end();

            var r = try c.post("/settings/get/postingaccounts", o.items());
            defer r.deinit(c.gpa);
            return output.emitList(c.gpa, stdout, stderr, r, &cols, out_mode, f.opt("filter"), c.api_key);
        },
        .show => {
            // Look up one account by its number among what `accounts list`
            // returns — the same /settings/get/postingaccounts set (Sachkonten
            // plus the cash/bank accounts), NOT the creditor/debtor subledgers.
            // There is no get-by-id route, so fetch the list and match the number
            // client-side, like the other show verbs. The endpoint defaults to
            // 1000 rows, which silently omits higher-numbered accounts, so ask for
            // a generous page (matching bookings.zig's chart-of-accounts fetch).
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
