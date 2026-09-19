//! Calendar-day arithmetic on `YYYY-MM-DD` strings, so a date window can be
//! widened locally instead of asking the server for more than it needs.

const std = @import("std");

const Civil = struct { y: i64, m: i64, d: i64 };

/// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's
/// days_from_civil), exact for every year this tool will ever see.
fn daysFromCivil(civil: Civil) i64 {
    const y = if (civil.m <= 2) civil.y - 1 else civil.y;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400; // [0, 399]
    const mp = @mod(civil.m + 9, 12); // March = 0
    const doy = @divFloor(153 * mp + 2, 5) + civil.d - 1; // [0, 365]
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

/// The inverse of daysFromCivil (civil_from_days).
fn civilFromDays(days: i64) Civil {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365); // [0, 399]
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100)); // [0, 365]
    const mp = @divFloor(5 * doy + 2, 153); // [0, 11]
    const d = doy - @divFloor(153 * mp + 2, 5) + 1; // [1, 31]
    const m = if (mp < 10) mp + 3 else mp - 9; // [1, 12]
    const y = yoe + era * 400;
    return .{ .y = if (m <= 2) y + 1 else y, .m = m, .d = d };
}

/// `YYYY-MM-DD` with four-two-two digits and dashes, or null for any other
/// shape. Month and day are range-checked only loosely; an impossible calendar
/// date is the server's to reject, as it is for every other date flag.
fn parseYmd(s: []const u8) ?Civil {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return null;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const m = std.fmt.parseInt(i64, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(i64, s[8..10], 10) catch return null;
    if (m < 1 or m > 12 or d < 1 or d > 31) return null;
    return .{ .y = y, .m = m, .d = d };
}

/// `ymd` moved by `delta` calendar days, as `YYYY-MM-DD`. A string that is not
/// a `YYYY-MM-DD` date comes back unchanged, so user input can pass through and
/// the server reports the malformed date exactly as it would without the shift.
pub fn shiftDays(gpa: std.mem.Allocator, ymd: []const u8, delta: i64) ![]const u8 {
    const civil = parseYmd(ymd) orelse return ymd;
    const r = civilFromDays(daysFromCivil(civil) + delta);
    if (r.y < 0) return ymd;
    return std.fmt.allocPrint(gpa, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(r.y)), @as(u64, @intCast(r.m)), @as(u64, @intCast(r.d)) });
}

test "epoch round trip" {
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(.{ .y = 1970, .m = 1, .d = 1 }));
    const c = civilFromDays(0);
    try std.testing.expectEqual(@as(i64, 1970), c.y);
    try std.testing.expectEqual(@as(i64, 1), c.m);
    try std.testing.expectEqual(@as(i64, 1), c.d);
    try std.testing.expectEqual(@as(i64, 20_000), daysFromCivil(civilFromDays(20_000)));
}

test "shiftDays crosses month, year and leap-day boundaries" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { in: []const u8, delta: i64, out: []const u8 }{
        .{ .in = "2026-06-01", .delta = -45, .out = "2026-04-17" },
        .{ .in = "2026-03-01", .delta = -1, .out = "2026-02-28" },
        .{ .in = "2024-03-01", .delta = -1, .out = "2024-02-29" },
        .{ .in = "2026-01-10", .delta = -45, .out = "2025-11-26" },
        .{ .in = "2026-12-31", .delta = 1, .out = "2027-01-01" },
        .{ .in = "2026-09-19", .delta = 0, .out = "2026-09-19" },
    };
    for (cases) |case| {
        const got = try shiftDays(gpa, case.in, case.delta);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(case.out, got);
    }
}

test "shiftDays leaves a non-date untouched" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "2026-1-1", "gestern", "", "2026-13-01" }) |s| {
        const got = try shiftDays(gpa, s, -45);
        try std.testing.expectEqualStrings(s, got);
        try std.testing.expect(got.ptr == s.ptr);
    }
}
