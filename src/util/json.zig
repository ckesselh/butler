//! JSON helpers: a minimal streaming object builder for request bodies (full
//! control over value types — e.g. money amounts serialized as strings on
//! purpose), envelope/value accessors for parsed responses, and api_key
//! redaction. Allocation-correct on any allocator.

const std = @import("std");

/// Append a JSON-escaped, double-quoted string to `buf`. Rejects invalid
/// UTF-8 (which would produce an invalid JSON document the server may
/// mis-handle) — argv and --from-json content arrive unvalidated.
pub fn writeString(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUtf8;
    try buf.append(gpa, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(gpa, "\\\""),
            '\\' => try buf.appendSlice(gpa, "\\\\"),
            '\n' => try buf.appendSlice(gpa, "\\n"),
            '\r' => try buf.appendSlice(gpa, "\\r"),
            '\t' => try buf.appendSlice(gpa, "\\t"),
            else => {
                if (c < 0x20) {
                    try buf.print(gpa, "\\u{x:0>4}", .{c});
                } else {
                    try buf.append(gpa, c);
                }
            },
        }
    }
    try buf.append(gpa, '"');
}

/// Minimal streaming JSON object builder. Full control over value types so we
/// can serialize, e.g., a money `amount` as a JSON string deliberately. Owns
/// its buffer: read via items() (or take it via toOwnedSlice()) after end().
pub const ObjBuilder = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    first: bool = true,

    pub fn init(gpa: std.mem.Allocator) !ObjBuilder {
        var b = ObjBuilder{ .gpa = gpa };
        try b.buf.append(gpa, '{');
        return b;
    }

    fn key(self: *ObjBuilder, k: []const u8) !void {
        if (!self.first) try self.buf.append(self.gpa, ',');
        self.first = false;
        try writeString(self.gpa, &self.buf, k);
        try self.buf.append(self.gpa, ':');
    }

    pub fn str(self: *ObjBuilder, k: []const u8, v: []const u8) !void {
        try self.key(k);
        try writeString(self.gpa, &self.buf, v);
    }

    pub fn strOpt(self: *ObjBuilder, k: []const u8, v: ?[]const u8) !void {
        if (v) |val| try self.str(k, val);
    }

    pub fn int(self: *ObjBuilder, k: []const u8, v: i64) !void {
        try self.key(k);
        try self.buf.print(self.gpa, "{d}", .{v});
    }

    pub fn boolean(self: *ObjBuilder, k: []const u8, v: bool) !void {
        try self.key(k);
        try self.buf.appendSlice(self.gpa, if (v) "true" else "false");
    }

    /// `"k": ["a","b",...]` with JSON-escaped string elements. The BHB
    /// receipt/transaction posting endpoints take their per-line fields
    /// (postingaccounts, vats, amounts, postingtexts) as parallel arrays.
    pub fn arrStr(self: *ObjBuilder, k: []const u8, vals: []const []const u8) !void {
        try self.key(k);
        try self.buf.append(self.gpa, '[');
        for (vals, 0..) |v, i| {
            if (i != 0) try self.buf.append(self.gpa, ',');
            try writeString(self.gpa, &self.buf, v);
        }
        try self.buf.append(self.gpa, ']');
    }

    /// `"k": [null, null, ...]` with `n` JSON nulls. `/postings/add/transaction`
    /// requires `oi_receipts_ids_by_customer` even when open-item postings are
    /// off, in which case it is one null per line.
    pub fn arrNull(self: *ObjBuilder, k: []const u8, n: usize) !void {
        try self.key(k);
        try self.buf.append(self.gpa, '[');
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (i != 0) try self.buf.append(self.gpa, ',');
            try self.buf.appendSlice(self.gpa, "null");
        }
        try self.buf.append(self.gpa, ']');
    }

    pub fn end(self: *ObjBuilder) !void {
        try self.buf.append(self.gpa, '}');
    }

    /// The serialized object; valid after end().
    pub fn items(self: *const ObjBuilder) []const u8 {
        return self.buf.items;
    }

    /// Take ownership of the serialized object; valid after end(). The
    /// builder is reset; deinit stays safe to call.
    pub fn toOwnedSlice(self: *ObjBuilder) ![]u8 {
        return self.buf.toOwnedSlice(self.gpa);
    }

    pub fn deinit(self: *ObjBuilder) void {
        self.buf.deinit(self.gpa);
    }
};

/// Add an optional integer field, parsing `raw` (a CLI string) to i64.
pub fn addIntOpt(o: *ObjBuilder, key: []const u8, raw: ?[]const u8) !void {
    if (raw) |s| {
        const v = std.fmt.parseInt(i64, std.mem.trim(u8, s, " \t"), 10) catch return error.InvalidInteger;
        try o.int(key, v);
    }
}

/// Return a copy of `text` with every occurrence of `secret` replaced by
/// "<redacted>". Keeps the api_key out of dry-run payloads and logs.
pub fn redactAlloc(gpa: std.mem.Allocator, text: []const u8, secret: []const u8) ![]u8 {
    if (secret.len == 0 or std.mem.indexOf(u8, text, secret) == null) return gpa.dupe(u8, text);
    const repl = "<redacted>";
    const size = std.mem.replacementSize(u8, text, secret, repl);
    const out = try gpa.alloc(u8, size);
    _ = std.mem.replace(u8, text, secret, repl, out);
    return out;
}

/// Render a parsed JSON value to a freshly-allocated display string. Non-scalar
/// values (arrays/objects) render as their compact JSON so nothing is silently
/// dropped from `show`/table output.
pub fn valueToAlloc(gpa: std.mem.Allocator, v: std.json.Value) ![]u8 {
    return switch (v) {
        .string => |s| try gpa.dupe(u8, s),
        .integer => |i| try std.fmt.allocPrint(gpa, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(gpa, "{d}", .{f}),
        .number_string => |s| try gpa.dupe(u8, s),
        .bool => |b| try gpa.dupe(u8, if (b) "true" else "false"),
        .null => try gpa.dupe(u8, ""),
        .array, .object => try std.json.Stringify.valueAlloc(gpa, v, .{}),
    };
}

/// Field `k` as a string, or null when absent or not a string. The returned
/// slice aliases the parsed tree — it lives only as long as the Parsed value.
pub fn getStr(o: std.json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Field `k` as an i64. BHB sends most numbers as strings, so a string value
/// that parses as base-10 is accepted too; anything else is null.
pub fn getInt(o: std.json.ObjectMap, k: []const u8) ?i64 {
    const v = o.get(k) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

/// True if an already-parsed BHB envelope has `"success": true`.
pub fn envelopeSuccess(v: std.json.Value) bool {
    return switch (v) {
        .object => |o| switch (o.get("success") orelse std.json.Value{ .null = {} }) {
            .bool => |b| b,
            else => false,
        },
        else => false,
    };
}

/// True if `body` parses as a BHB envelope with `"success": true`. Anything
/// unparseable counts as failure (the API always sends the envelope).
pub fn bodySuccess(gpa: std.mem.Allocator, body: []const u8) bool {
    var p = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return false;
    defer p.deinit();
    return envelopeSuccess(p.value);
}

test "writeString escapes" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try writeString(gpa, &buf, "a\"b\\c\n");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\n\"", buf.items);
}

test "ObjBuilder builds an object" {
    const gpa = std.testing.allocator;
    var o = try ObjBuilder.init(gpa);
    defer o.deinit();
    try o.str("a", "x");
    try o.int("b", 42);
    try o.boolean("c", true);
    try o.end();
    try std.testing.expectEqualStrings("{\"a\":\"x\",\"b\":42,\"c\":true}", o.items());
}

test "writeString rejects invalid UTF-8" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try std.testing.expectError(error.InvalidUtf8, writeString(gpa, &buf, "\xff\xfe"));
}

test "bodySuccess parses the envelope and frees it" {
    const gpa = std.testing.allocator;
    try std.testing.expect(bodySuccess(gpa, "{\"success\":true}"));
    try std.testing.expect(!bodySuccess(gpa, "{\"success\":false}"));
    try std.testing.expect(!bodySuccess(gpa, "not json"));
}

test "redactAlloc" {
    const gpa = std.testing.allocator;
    const out = try redactAlloc(gpa, "key=SEKRET end", "SEKRET");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("key=<redacted> end", out);
    const same = try redactAlloc(gpa, "no secret here", "SEKRET");
    defer gpa.free(same);
    try std.testing.expectEqualStrings("no secret here", same);
}
