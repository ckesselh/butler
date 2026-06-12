//! HTTPS transport: one function, `post`, over the process-wide
//! std.http.Client owned by main (so batches reuse the connection pool / TLS
//! session). Allocation-correct on any allocator.

const std = @import("std");

/// The largest response body accepted (the BHB API caps lists at 1000 rows;
/// this is orders of magnitude above any legitimate response). Past it,
/// `post` fails with error.ResponseTooLarge instead of allocating unboundedly
/// from a misbehaving server. The buffer is virtual address space — pages are
/// only committed as the body actually arrives.
pub const max_response_bytes = 64 << 20;

/// An HTTP response: status plus body. The body is heap-owned by the caller;
/// release it with `deinit`.
pub const Response = struct {
    status: u16,
    body: []u8,

    pub fn deinit(self: *Response, gpa: std.mem.Allocator) void {
        gpa.free(self.body);
    }
};

/// POST `json_body` to `base ++ path` with an `Authorization: Basic <b64>`
/// header and a JSON content type. Returns the HTTP status plus the owned
/// response body.
pub fn post(
    client: *std.http.Client,
    gpa: std.mem.Allocator,
    base: []const u8,
    path: []const u8,
    basic_b64: []const u8,
    json_body: []const u8,
) !Response {
    const url = try std.fmt.allocPrint(gpa, "{s}{s}", .{ base, path });
    defer gpa.free(url);
    const auth = try std.fmt.allocPrint(gpa, "Basic {s}", .{basic_b64});
    defer gpa.free(auth);

    const buf = try gpa.alloc(u8, max_response_bytes);
    defer gpa.free(buf);
    var body: std.Io.Writer = .fixed(buf);

    const res = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = json_body,
        .response_writer = &body,
        .headers = .{
            .authorization = .{ .override = auth },
            .content_type = .{ .override = "application/json" },
        },
    }) catch |err| switch (err) {
        // The fixed response buffer overflowed — the server sent more than
        // max_response_bytes.
        error.WriteFailed => return error.ResponseTooLarge,
        else => |e| return e,
    };

    return .{ .status = @intFromEnum(res.status), .body = try gpa.dupe(u8, body.buffered()) };
}
