//! `debtors` resource: list, look up, create and update debtor accounts.
//! Backed by the `/settings/{get,add,update}/debtor(s)` endpoints; the paging,
//! rendering and write logic live in subledger.zig, shared with the creditors
//! resource.

const std = @import("std");
const cli = @import("../cli.zig");
const spec = @import("../spec.zig");
const subledger = @import("subledger.zig");
const Client = @import("../client.zig").Client;

pub fn run(c: Client, verb: []const u8, f: *const cli.Flags, stdout: *std.Io.Writer, stderr: *std.Io.Writer, out_mode: spec.Output) !u8 {
    return subledger.run(c, .{
        .noun = "debtor",
        .get = "/settings/get/debtors",
        .add = "/settings/add/debtor",
        .update = "/settings/update/debtor",
    }, verb, f, stdout, stderr, out_mode);
}
