//! The per-invocation API client handed to every resource module.

const std = @import("std");
const http = @import("util/http.zig");

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
};
