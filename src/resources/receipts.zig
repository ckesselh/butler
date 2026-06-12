//! `receipts` resource: list, show (via the list endpoint — get-by-id is
//! broken server-side), upload (base64 JSON payload), delete.

const std = @import("std");
const cli = @import("../cli.zig");
const spec = @import("../spec.zig");
const json = @import("../util/json.zig");
const output = @import("../output.zig");
const Client = @import("../client.zig").Client;

const cols = [_][]const u8{ "date", "type", "counterparty", "invoicenumber", "amount", "id_by_customer" };

fn listBody(c: Client, f: *const cli.Flags, direction: []const u8) ![]u8 {
    var o = try json.ObjBuilder.init(c.gpa);
    try o.str("api_key", c.api_key);
    try o.str("list_direction", direction);
    try o.strOpt("payment_status", f.opt("payment-status"));
    try o.strOpt("counterparty", f.opt("counterparty"));
    try o.strOpt("date_from", f.opt("date-from"));
    try o.strOpt("date_to", f.opt("date-to"));
    try o.strOpt("invoicenumber", f.opt("invoice-number"));
    try o.strOpt("due_date", f.opt("due-date"));
    if (f.has("include-offers")) try o.boolean("include_offers", true);
    if (f.has("deleted")) try o.boolean("deleted", true);
    try json.addIntOpt(&o, "limit", f.opt("limit"));
    try json.addIntOpt(&o, "offset", f.opt("offset"));
    try o.end();
    return o.toOwnedSlice();
}

fn upload(c: Client, f: *const cli.Flags, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    // Resolve the file path (positional) and receipt type.
    const path = f.pos(2) orelse return cli.missing(stderr, "<file path>");
    const rtype = f.opt("type") orelse return cli.missing(stderr, "--type (e.g. \"invoice inbound\")");

    // Read the file (cap 32 MiB) and base64-encode it for the JSON payload.
    const bytes = std.Io.Dir.cwd().readFileAlloc(c.io, path, c.gpa, .limited(32 << 20)) catch |e| {
        try stderr.print("error: cannot read {s}: {s}\n", .{ path, @errorName(e) });
        return 1;
    };
    const enc = std.base64.standard.Encoder;
    const b64 = try c.gpa.alloc(u8, enc.calcSize(bytes.len));
    _ = enc.encode(b64, bytes);
    const name = std.fs.path.basename(path);

    // Build the upload body.
    var o = try json.ObjBuilder.init(c.gpa);
    try o.str("api_key", c.api_key);
    try o.str("file", b64);
    try o.str("file_name", name);
    try o.str("type", rtype);
    try o.strOpt("counterparty", f.opt("counterparty"));
    try o.strOpt("invoice_number", f.opt("invoice-number"));
    try o.strOpt("date", f.opt("date"));
    try o.strOpt("amount", f.opt("amount"));
    try o.strOpt("vat_rate", f.opt("vat-rate"));
    try o.end();

    // Dry run prints what would be sent and stops.
    if (f.has("dry-run")) {
        try stdout.print("DRY RUN — would POST /receipts/upload  file_name='{s}'  type='{s}'  ({d} bytes)\n", .{ name, rtype, bytes.len });
        return 0;
    }

    var r = try c.post("/receipts/upload", o.items());
    defer r.deinit(c.gpa);
    return output.reportWrite(c.gpa, stderr, r, "upload", c.api_key);
}

const Verb = enum { list, show, upload, delete };

pub fn run(c: Client, verb: []const u8, f: *const cli.Flags, stdout: *std.Io.Writer, stderr: *std.Io.Writer, out_mode: spec.Output) !u8 {
    const v = std.meta.stringToEnum(Verb, verb) orelse return cli.unknownVerb(stderr, verb, "list|show|upload|delete");
    switch (v) {
        .list => {
            // Require and validate the inbound/outbound direction (positional).
            const dir = f.pos(2) orelse return cli.missing(stderr, "<inbound|outbound>");
            if (!std.mem.eql(u8, dir, "inbound") and !std.mem.eql(u8, dir, "outbound"))
                return cli.missing(stderr, "direction to be inbound|outbound");

            var r = try c.post("/receipts/get", try listBody(c, f, dir));
            defer r.deinit(c.gpa);
            return output.emitList(c.gpa, stdout, stderr, r, &cols, out_mode, f.opt("filter"), c.api_key);
        },
        .show => {
            // The get-by-id route 404s server-side (docs/bhb-api-quirks.md), so
            // fetch via the list endpoint and match the id client-side, like
            // transactions show. /receipts/get requires list_direction: query
            // the given --direction, or both. The API caps a page at 500 rows,
            // so the lookup sees at most 500 receipts per direction.
            const id = f.pos(2) orelse return cli.missing(stderr, "<id>");
            const idn = std.fmt.parseInt(i64, id, 10) catch return cli.missing(stderr, "<id> to be an integer");
            const canon = try std.fmt.allocPrint(c.gpa, "{d}", .{idn});

            const both = [_][]const u8{ "inbound", "outbound" };
            var one: [1][]const u8 = .{""};
            var directions: []const []const u8 = &both;
            if (f.opt("direction")) |d| {
                one[0] = d;
                directions = &one;
            }

            for (directions) |dir| {
                var o = try json.ObjBuilder.init(c.gpa);
                try o.str("api_key", c.api_key);
                try o.str("list_direction", dir);
                try o.int("limit", 500);
                try o.end();
                var r = try c.post("/receipts/get", o.items());
                defer r.deinit(c.gpa);
                if (try output.tryEmitShow(c.gpa, stdout, stderr, r, out_mode, canon, c.api_key)) |code| return code;
            }
            try stderr.writeAll("not found.\n");
            return 1;
        },
        .upload => return upload(c, f, stdout, stderr),
        .delete => {
            // Build the delete body from the id.
            const id = f.pos(2) orelse return cli.missing(stderr, "<id>");
            var o = try json.ObjBuilder.init(c.gpa);
            try o.str("api_key", c.api_key);
            try o.str("id_by_customer", id);
            try o.end();

            var r = try c.post("/receipts/delete/id_by_customer", o.items());
            defer r.deinit(c.gpa);
            return output.reportWrite(c.gpa, stderr, r, "delete", c.api_key);
        },
    }
}
