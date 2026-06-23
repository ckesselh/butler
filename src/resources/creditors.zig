//! `creditors` resource: list and look up creditor accounts.
//! Backed by `/settings/get/creditors`; the paging and rendering live in
//! subledger.zig, shared with the debtors resource.

const std = @import("std");
const cli = @import("../cli.zig");
const spec = @import("../spec.zig");
const subledger = @import("subledger.zig");
const Client = @import("../client.zig").Client;

pub fn run(c: Client, verb: []const u8, f: *const cli.Flags, stdout: *std.Io.Writer, stderr: *std.Io.Writer, out_mode: spec.Output) !u8 {
    return subledger.run(c, "/settings/get/creditors", verb, f, stdout, stderr, out_mode);
}
