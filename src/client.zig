//! The per-invocation API client handed to every resource module.

const std = @import("std");
const http = @import("util/http.zig");
const json = @import("util/json.zig");

/// Connection context shared by every resource module: base URL, the
/// pre-encoded Basic-auth blob, the account api_key, plus the process-wide
/// allocator/io/http handles. Resource modules build their own JSON request
/// bodies and call `post`.
pub const Client = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    http: *std.http.Client,
    base: []const u8,
    basic: []const u8,
    api_key: []const u8,

    /// POST `body` to `base ++ path`. Returns an owned Response — release it
    /// with `deinit` (a `defer r.deinit(c.gpa)` at the call site).
    pub fn post(self: Client, path: []const u8, body: []const u8) !http.Response {
        return http.post(self.http, self.gpa, self.base, path, self.basic, body);
    }

    /// POST to a path-segment by-id route (`<prefix>/<id>`, e.g.
    /// `/receipts/get/289`) with only `api_key` in the body — plus `get_file`
    /// when the caller wants the receipts get route to include the stored
    /// file. The spec writes these routes as `/…/get/id_by_customer`; that
    /// last segment is a path placeholder, not a literal
    /// (docs/bhb-api-quirks.md).
    pub fn postById(self: Client, prefix: []const u8, id: i64, get_file: bool) !http.Response {
        const path = try std.fmt.allocPrint(self.gpa, "{s}/{d}", .{ prefix, id });
        defer self.gpa.free(path);
        var o = try json.ObjBuilder.init(self.gpa);
        defer o.deinit();
        try o.str("api_key", self.api_key);
        if (get_file) try o.boolean("get_file", true);
        try o.end();
        return self.post(path, o.items());
    }
};
