//! `accounts` resource: the chart of accounts (read-only list).

const std = @import("std");
const cli = @import("../cli.zig");
const spec = @import("../spec.zig");
const json = @import("../util/json.zig");
const output = @import("../output.zig");
const Client = @import("../client.zig").Client;

const cols = [_][]const u8{ "postingaccount_number", "name", "type" };

const Verb = enum { list };

pub fn run(c: Client, verb: []const u8, f: *const cli.Flags, stdout: *std.Io.Writer, stderr: *std.Io.Writer, out_mode: spec.Output) !u8 {
    const v = std.meta.stringToEnum(Verb, verb) orelse return cli.unknownVerb(stderr, verb, "list");
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
    }
}
