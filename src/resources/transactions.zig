//! `transactions` resource: list with server-side filters, and show via the
//! list endpoint id-range workaround (the get-by-id route is broken server-side).

const std = @import("std");
const cli = @import("../cli.zig");
const spec = @import("../spec.zig");
const json = @import("../util/json.zig");
const output = @import("../output.zig");
const Client = @import("../client.zig").Client;

const cols = [_][]const u8{ "booking_date", "value_date", "amount", "to_from", "purpose" };

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

const Verb = enum { list, show };

pub fn run(c: Client, verb: []const u8, f: *const cli.Flags, stdout: *std.Io.Writer, stderr: *std.Io.Writer, out_mode: spec.Output) !u8 {
    const v = std.meta.stringToEnum(Verb, verb) orelse return cli.unknownVerb(stderr, verb, "list|show");
    switch (v) {
        .list => {
            var r = try c.post("/transactions/get", try listBody(c, f));
            defer r.deinit(c.gpa);
            return output.emitList(c.gpa, stdout, stderr, r, &cols, out_mode, f.opt("filter"), c.api_key);
        },
        .show => {
            // Require a numeric id.
            const id = f.pos(2) orelse return cli.missing(stderr, "<id> (e.g. `transactions show 749`)");
            const idn = std.fmt.parseInt(i64, id, 10) catch return cli.missing(stderr, "<id> to be an integer");

            // /…/get/id_by_customer 404s; id bounds are BOTH exclusive → [id-1, id+1].
            // Saturating ±1 so an i64-extremity id can't trap under ReleaseSafe.
            var o = try json.ObjBuilder.init(c.gpa);
            try o.str("api_key", c.api_key);
            try o.int("id_by_customer_from", idn -| 1);
            try o.int("id_by_customer_to", idn +| 1);
            try o.end();
            var r = try c.post("/transactions/get", o.items());
            defer r.deinit(c.gpa);
            // Match canonically: argv may carry "0417"/"+417"; the API says 417.
            const canon = try std.fmt.allocPrint(c.gpa, "{d}", .{idn});
            return output.emitShow(c.gpa, stdout, stderr, r, out_mode, canon, c.api_key);
        },
    }
}
