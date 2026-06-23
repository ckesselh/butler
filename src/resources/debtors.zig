//! `debtors` resource: list and look up debtor accounts.
//! Backed by `/settings/get/debtors`; the paging and rendering live in
//! subledger.zig, shared with the creditors resource.

const std = @import("std");
const cli = @import("../cli.zig");
const spec = @import("../spec.zig");
const subledger = @import("subledger.zig");
const Client = @import("../client.zig").Client;

pub fn run(c: Client, verb: []const u8, f: *const cli.Flags, stdout: *std.Io.Writer, stderr: *std.Io.Writer, out_mode: spec.Output) !u8 {
    return subledger.run(c, "/settings/get/debtors", verb, f, stdout, stderr, out_mode);
}
