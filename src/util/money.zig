//! Exact money handling: decimal strings <-> integer cents, no floats.

const std = @import("std");

/// Parse a decimal money string ("6003.47", "-12", "0.5") into integer cents.
/// Returns null for anything that isn't a clean decimal with at most two
/// fraction digits (rejects letters, nan/inf, empty, ">2 decimals", "1e3").
pub fn parseCents(s_in: []const u8) ?i64 {
    const s = std.mem.trim(u8, s_in, " \t");
    if (s.len == 0) return null;

    // Consume an optional leading sign.
    var i: usize = 0;
    var neg = false;
    if (s[0] == '+' or s[0] == '-') {
        neg = s[0] == '-';
        i = 1;
    }

    var int_part: i64 = 0;
    var frac: i64 = 0;
    var seen_digit = false;

    // Accumulate the integer part up to the decimal point. Checked arithmetic:
    // an absurdly long amount overflows i64 and is reported as invalid (null)
    // rather than trapping under -OReleaseSafe.
    while (i < s.len and s[i] != '.') : (i += 1) {
        if (s[i] < '0' or s[i] > '9') return null;
        const scaled = std.math.mul(i64, int_part, 10) catch return null;
        int_part = std.math.add(i64, scaled, @as(i64, s[i] - '0')) catch return null;
        seen_digit = true;
    }

    // Accumulate up to two fraction digits after the decimal point.
    if (i < s.len and s[i] == '.') {
        i += 1;
        var digits: usize = 0;
        while (i < s.len) : (i += 1) {
            if (s[i] < '0' or s[i] > '9') return null;
            if (digits >= 2) return null; // more than 2 fraction digits
            frac = frac * 10 + @as(i64, s[i] - '0');
            digits += 1;
            seen_digit = true;
        }
        if (digits == 1) frac *= 10; // "x.5" -> 50 cents
    }

    // Require at least one digit, then combine into signed cents (checked).
    if (!seen_digit) return null;
    const scaled = std.math.mul(i64, int_part, 100) catch return null;
    const cents = std.math.add(i64, scaled, frac) catch return null;
    return if (neg) -cents else cents;
}

/// Render non-negative integer cents as a canonical decimal string
/// (600347 -> "6003.47"). Sending the canonical rendering of what was
/// validated keeps a payload from diverging from the check (e.g. an amount
/// that parsed despite a leading '+' or surrounding whitespace).
pub fn renderCentsAlloc(gpa: std.mem.Allocator, cents: i64) ![]u8 {
    std.debug.assert(cents >= 0);
    // Unsigned operands: zero-fill of a signed integer renders a forced sign.
    const c: u64 = @intCast(cents);
    return std.fmt.allocPrint(gpa, "{d}.{d:0>2}", .{ c / 100, c % 100 });
}

test "parseCents" {
    try std.testing.expectEqual(@as(?i64, 600347), parseCents("6003.47"));
    try std.testing.expectEqual(@as(?i64, 8433), parseCents("84.33"));
    try std.testing.expectEqual(@as(?i64, 25000), parseCents("250"));
    try std.testing.expectEqual(@as(?i64, 50), parseCents("0.5"));
    try std.testing.expectEqual(@as(?i64, -1200), parseCents("-12"));
    try std.testing.expectEqual(@as(?i64, null), parseCents("nan"));
    try std.testing.expectEqual(@as(?i64, null), parseCents("1.234"));
    try std.testing.expectEqual(@as(?i64, null), parseCents(""));
    try std.testing.expectEqual(@as(?i64, null), parseCents("1e3"));
    // Overflow is reported as invalid, not a trap.
    try std.testing.expectEqual(@as(?i64, null), parseCents("999999999999999999999"));
}

test "renderCentsAlloc" {
    const gpa = std.testing.allocator;
    const a = try renderCentsAlloc(gpa, 600347);
    defer gpa.free(a);
    try std.testing.expectEqualStrings("6003.47", a);
    const b = try renderCentsAlloc(gpa, 50);
    defer gpa.free(b);
    try std.testing.expectEqualStrings("0.50", b);
    const c = try renderCentsAlloc(gpa, 25000);
    defer gpa.free(c);
    try std.testing.expectEqualStrings("250.00", c);
}
