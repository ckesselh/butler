//! `accounts` resource: the chart of accounts (read-only list and show).

const std = @import("std");
const cli = @import("../cli.zig");
const spec = @import("../spec.zig");
const json = @import("../util/json.zig");
const output = @import("../output.zig");
const Client = @import("../client.zig").Client;

const cols = [_][]const u8{ "postingaccount_number", "name", "type" };

const Verb = enum { list, show };

pub fn run(c: Client, verb: []const u8, f: *const cli.Flags, stdout: *std.Io.Writer, stderr: *std.Io.Writer, out_mode: spec.Output) !u8 {
    const v = std.meta.stringToEnum(Verb, verb) orelse return cli.unknownVerb(stderr, verb, "list|show");
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
            // client-side, like the other show verbs.
            const acct = f.pos(2) orelse return cli.missing(stderr, "<account>");
            var o = try json.ObjBuilder.init(c.gpa);
            try o.str("api_key", c.api_key);
            try o.end();

            var r = try c.post("/settings/get/postingaccounts", o.items());
            defer r.deinit(c.gpa);
            return output.emitShowBy(c.gpa, stdout, stderr, r, out_mode, "postingaccount_number", acct, c.api_key);
        },
    }
}
