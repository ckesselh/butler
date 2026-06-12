//! Response rendering: aligned tables (UTF-8-aware widths), single-record
//! key/value output, client-side filtering, and the shared success-envelope
//! check. This layer leans on main's process arena — render scratch is not
//! individually freed (see src/main.zig).

const std = @import("std");
const json = @import("util/json.zig");
const spec = @import("spec.zig");
const http = @import("util/http.zig");

fn writeRepeat(writer: *std.Io.Writer, c: u8, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try writer.writeByte(c);
}

/// Display width = number of UTF-8 codepoints — good enough for the Latin text
/// BHB serves, and fixes the bytes-vs-columns misalignment every umlaut caused
/// under byte-length padding. Invalid UTF-8 falls back to byte length.
fn displayWidth(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

fn writePadded(writer: *std.Io.Writer, s: []const u8, width: usize) !void {
    try writer.writeAll(s);
    const w = displayWidth(s);
    if (w < width) try writeRepeat(writer, ' ', width - w);
}

/// Lowercase `s` for filter matching: ASCII A–Z plus the Latin-1 supplement
/// (À–Þ → à–þ), which covers the umlauts ubiquitous in German accounting data.
/// Other scripts pass through unchanged.
fn allocFoldLower(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try gpa.dupe(u8, s);
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const c = out[i];
        if (c >= 'A' and c <= 'Z') {
            out[i] = c + 32;
        } else if (c == 0xC3 and i + 1 < out.len) {
            // U+00C0–U+00DE encode as C3 80–C3 9E; +0x20 lowercases.
            // Skip 0x97 (×, U+00D7), which has no lowercase form.
            const n = out[i + 1];
            if (n >= 0x80 and n <= 0x9E and n != 0x97) out[i + 1] = n + 0x20;
            i += 1;
        }
    }
    return out;
}

/// Render an array of JSON objects as an aligned, left-justified table.
pub fn renderTable(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    rows: []const std.json.Value,
    columns: []const []const u8,
) !void {
    // Seed each column width with its header length.
    const n = columns.len;
    const widths = try gpa.alloc(usize, n);
    for (columns, 0..) |c, i| widths[i] = displayWidth(c);

    // Render every cell once, widening each column to fit its content.
    const cells = try gpa.alloc([]const u8, rows.len * n);
    for (rows, 0..) |row, r| {
        for (columns, 0..) |col, i| {
            const v: std.json.Value = switch (row) {
                .object => |o| o.get(col) orelse std.json.Value{ .null = {} },
                else => std.json.Value{ .null = {} },
            };
            const s = try json.valueToAlloc(gpa, v);
            cells[r * n + i] = s;
            const w = displayWidth(s);
            if (w > widths[i]) widths[i] = w;
        }
    }

    // Header row.
    for (columns, 0..) |c, i| {
        try writePadded(writer, c, widths[i]);
        if (i + 1 < n) try writer.writeAll("  ");
    }
    try writer.writeByte('\n');

    // Separator rule under the header.
    for (0..n) |i| {
        try writeRepeat(writer, '-', widths[i]);
        if (i + 1 < n) try writer.writeAll("  ");
    }
    try writer.writeByte('\n');

    // Data rows.
    for (0..rows.len) |r| {
        for (0..n) |i| {
            try writePadded(writer, cells[r * n + i], widths[i]);
            if (i + 1 < n) try writer.writeAll("  ");
        }
        try writer.writeByte('\n');
    }
    try writer.print("\n({d} rows)\n", .{rows.len});
}

fn fail(gpa: std.mem.Allocator, stderr: *std.Io.Writer, resp: http.Response, secret: []const u8) !u8 {
    const shown = try json.redactAlloc(gpa, resp.body, secret);
    try stderr.print("HTTP {d}: {s}\n", .{ resp.status, shown });
    return 1;
}

fn dataArray(v: std.json.Value) ?[]std.json.Value {
    return switch (v) {
        .object => |o| switch (o.get("data") orelse std.json.Value{ .null = {} }) {
            .array => |a| a.items,
            else => null,
        },
        else => null,
    };
}

/// List rendering: table (with optional substring filter over the columns) or raw JSON.
pub fn emitList(
    gpa: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    resp: http.Response,
    columns: []const []const u8,
    out_mode: spec.Output,
    search: ?[]const u8,
    secret: []const u8,
) !u8 {
    // Parse once; both the success check and the table rendering read from
    // this tree. HTTP 200 + "success": false is how BHB signals most errors —
    // a bare status check would render an auth failure as an empty table,
    // exit 0. An unparseable body counts as failure (the API always sends
    // the envelope).
    const parsed: ?std.json.Parsed(std.json.Value) =
        std.json.parseFromSlice(std.json.Value, gpa, resp.body, .{}) catch null;
    if (resp.status != 200 or parsed == null or !json.envelopeSuccess(parsed.?.value))
        return fail(gpa, stderr, resp, secret);

    // JSON mode echoes the raw body untouched.
    if (out_mode == .json) {
        try stdout.writeAll(resp.body);
        try stdout.writeByte('\n');
        return 0;
    }

    // An envelope without a data array: echo the raw body — deliberate
    // degraded output, not error suppression.
    const arr = dataArray(parsed.?.value) orelse {
        try stdout.writeAll(resp.body);
        try stdout.writeByte('\n');
        return 0;
    };

    // Render the table, optionally filtered by a case-insensitive substring.
    if (search) |term| {
        const needle = try allocFoldLower(gpa, term);
        var filtered: std.ArrayList(std.json.Value) = .empty;
        for (arr) |row| {
            if (try rowMatches(gpa, row, columns, needle)) try filtered.append(gpa, row);
        }
        try renderTable(gpa, stdout, filtered.items, columns);
    } else {
        try renderTable(gpa, stdout, arr, columns);
    }
    return 0;
}

/// Single-record rendering. If `match_id` is given, pick the row whose
/// id_by_customer equals it (so we never show the wrong record); else row 0.
pub fn emitShow(
    gpa: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    resp: http.Response,
    out_mode: spec.Output,
    match_id: ?[]const u8,
    secret: []const u8,
) !u8 {
    return (try tryEmitShow(gpa, stdout, stderr, resp, out_mode, match_id, secret)) orelse {
        try stderr.writeAll("not found.\n");
        return 1;
    };
}

/// Like emitShow, but a valid response that merely lacks the requested row
/// yields null instead of printing "not found." — callers that probe several
/// queries (receipts show tries both directions) decide when the search ends.
pub fn tryEmitShow(
    gpa: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    resp: http.Response,
    out_mode: spec.Output,
    match_id: ?[]const u8,
    secret: []const u8,
) !?u8 {
    // Parse once; see emitList for why success:false and unparseable bodies
    // are failures.
    const parsed: ?std.json.Parsed(std.json.Value) =
        std.json.parseFromSlice(std.json.Value, gpa, resp.body, .{}) catch null;
    if (resp.status != 200 or parsed == null or !json.envelopeSuccess(parsed.?.value))
        return try fail(gpa, stderr, resp, secret);

    const arr = dataArray(parsed.?.value) orelse return null;

    // Pick the row matching match_id (by rendered id), else the first row.
    var chosen: ?std.json.Value = null;
    if (match_id) |id| {
        for (arr) |row| {
            switch (row) {
                .object => |o| {
                    // id_by_customer is a string in some resources, a number in
                    // others — compare via the rendered form.
                    if (o.get("id_by_customer")) |idv| {
                        const rid = try json.valueToAlloc(gpa, idv);
                        if (std.mem.eql(u8, rid, id)) {
                            chosen = row;
                            break;
                        }
                    }
                },
                else => {},
            }
        }
    } else if (arr.len > 0) {
        chosen = arr[0];
    }

    const row = chosen orelse return null;

    // JSON mode emits just the matched object: the show lookups go through
    // list endpoints, so echoing the whole envelope could dump a full page
    // around the one requested record.
    if (out_mode == .json) {
        const s = try json.valueToAlloc(gpa, row);
        try stdout.print("{s}\n", .{s});
        return 0;
    }

    const o = switch (row) {
        .object => |x| x,
        else => return null,
    };

    // Print the chosen object as one key/value line per field.
    var it = o.iterator();
    while (it.next()) |e| {
        const v = try json.valueToAlloc(gpa, e.value_ptr.*);
        try stdout.print("{s}: {s}\n", .{ e.key_ptr.*, v });
    }
    return 0;
}

/// Report a write-verb outcome (`<what>: ok` / redacted error) to stderr and
/// return the process exit code.
pub fn reportWrite(gpa: std.mem.Allocator, stderr: *std.Io.Writer, resp: http.Response, what: []const u8, secret: []const u8) !u8 {
    if (resp.status == 200 and json.bodySuccess(gpa, resp.body)) {
        try stderr.print("{s}: ok\n", .{what});
        return 0;
    }
    const shown = try json.redactAlloc(gpa, resp.body, secret);
    try stderr.print("{s}: HTTP {d} {s}\n", .{ what, resp.status, shown });
    return 1;
}

fn rowMatches(gpa: std.mem.Allocator, row: std.json.Value, cols: []const []const u8, needle_lower: []const u8) !bool {
    const o = switch (row) {
        .object => |x| x,
        else => return false,
    };
    for (cols) |c| {
        const v = o.get(c) orelse continue;
        const s = try json.valueToAlloc(gpa, v);
        const low = try allocFoldLower(gpa, s);
        if (std.mem.indexOf(u8, low, needle_lower) != null) return true;
    }
    return false;
}

test "displayWidth counts codepoints" {
    try std.testing.expectEqual(@as(usize, 26), displayWidth("Bürobedarf für Müller GmbH"));
    try std.testing.expectEqual(@as(usize, 3), displayWidth("abc"));
}

// The output layer leans on main's arena (it never frees render scratch), so
// these tests mirror that with an arena over the testing allocator.

test "renderTable pads by display width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\[{"a":"Müller","b":"1"},{"a":"x","b":"22"}]
    , .{});
    var sink: std.Io.Writer.Allocating = .init(gpa);
    try renderTable(gpa, &sink.writer, parsed.value.array.items, &.{ "a", "b" });
    const out = sink.written();
    // Column a is 6 codepoints wide (Müller); the separator shows the widths.
    try std.testing.expect(std.mem.indexOf(u8, out, "------  --\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Müller  1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(2 rows)") != null);
}

test "emitList fails on HTTP 200 with success:false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(gpa);
    var errw: std.Io.Writer.Allocating = .init(gpa);
    const body = try gpa.dupe(u8, "{\"success\":false,\"message\":\"API key invalid\",\"rows\":0,\"data\":[]}");
    const code = try emitList(gpa, &out.writer, &errw.writer, .{ .status = 200, .body = body }, &.{"a"}, .table, null, "sek");
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expectEqualStrings("", out.written());
    try std.testing.expect(std.mem.indexOf(u8, errw.written(), "API key invalid") != null);
}

test "emitList filter folds case incl. umlauts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(gpa);
    var errw: std.Io.Writer.Allocating = .init(gpa);
    const body = try gpa.dupe(u8, "{\"success\":true,\"rows\":2,\"data\":[{\"a\":\"Müller GmbH\"},{\"a\":\"ACME\"}]}");
    const code = try emitList(gpa, &out.writer, &errw.writer, .{ .status = 200, .body = body }, &.{"a"}, .table, "MÜLLER", "sek");
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Müller GmbH") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "(1 rows)") != null);
}

test "tryEmitShow matches the requested id and yields null on a miss" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(gpa);
    var errw: std.Io.Writer.Allocating = .init(gpa);
    const body = try gpa.dupe(u8, "{\"success\":true,\"rows\":2,\"data\":[{\"id_by_customer\":\"416\",\"x\":\"no\"},{\"id_by_customer\":417,\"x\":\"yes\"}]}");

    const hit = try tryEmitShow(gpa, &out.writer, &errw.writer, .{ .status = 200, .body = body }, .table, "417", "sek");
    try std.testing.expectEqual(@as(?u8, 0), hit);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "x: yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "x: no") == null);

    const body2 = try gpa.dupe(u8, "{\"success\":true,\"rows\":1,\"data\":[{\"id_by_customer\":\"416\"}]}");
    const miss = try tryEmitShow(gpa, &out.writer, &errw.writer, .{ .status = 200, .body = body2 }, .table, "999", "sek");
    try std.testing.expectEqual(@as(?u8, null), miss);
}

test "allocFoldLower folds ASCII and Latin-1" {
    const gpa = std.testing.allocator;
    const a = try allocFoldLower(gpa, "MÜLLER GmbH × Côte");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("müller gmbh × côte", a);
}
