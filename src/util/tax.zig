//! Decoding of BHB's numeric posting `tax_key` into the documented German
//! VAT-treatment labels, plus the account-driven-VAT rate helper. This is
//! BHB domain knowledge (not command surface — that lives in spec.zig);
//! consumed by the bookings listing.

const std = @import("std");

/// Documented German label for a posting's numeric `tax_key` (returned by
/// `/postings/get`).
///
/// PROVENANCE — read carefully before trusting or extending this table:
///   The numeric `tax_key` is UNDOCUMENTED. The BHB OpenAPI spec
///   (app.buchhaltungsbutler.de/docs/api/v1.de.json) lists `tax_key` only with
///   the placeholder example value "1" — no enum, no description. The symbolic
///   WRITE-side codes (`spec.vat_codes`) ARE documented: the
///   `/postings/add/free` `vat` parameter description spells out a German
///   label for each, e.g. `19_both_2 → 'I.g.E. 19% USt./VSt.'`,
///   `19_both_1 → '§13b 19% USt./VSt.'`, `19_pre → '19% Vst.'`. This table
///   maps each observed numeric READ key to that symbolic code; each `.label`
///   follows the wording BHB shows in its web UI (e.g. "i.g.E. 19%
///   USt./VSt."), which matches the documented spec labels up to minor casing
///   ("I.g.E.", "keine Ust.").
///
///   The numeric `tax_key` is a tax-treatment key, independent of the chart of
///   accounts — it does not change between SKR03, SKR04, etc. (account NUMBERS
///   do; the tax key does not). The numeric→symbolic mapping is nonetheless a
///   best-effort decode of an undocumented field: callers MUST keep showing the
///   raw key alongside the label so a wrong row can never hide ground truth, keys
///   absent here render as unmapped rather than guessed, and the table should be
///   extended only against a known-good reference.
///
///   The §13b rows are the exception to "undocumented": those symbolic codes
///   carry the numeric key in their own name (`19_both_511` ↔ key 511), so the
///   spec pins the number and its label together.
///
///   TWO NUMBERING SCHEMES — the same tax treatment reads back under different
///   numeric keys depending on how the posting was CREATED:
///     - Web UI / DATEV import → single-digit legacy keys (0, 8, 9, 18, 19, …).
///     - API `/postings/add/*` (i.e. every posting butler writes) → 4xx/7xx
///       keys (401, 402, 701, 702), plus 94 for §13b which is shared.
///   The §13b 5xx keys sit in neither scheme: they distinguish the place of
///   supply, not the origin of the posting, and both schemes can produce them.
///   The label is identical per treatment; only the number differs by origin.
///   Both schemes are listed below so butler can decode the very postings it
///   writes — without the 4xx/7xx rows, every butler-created booking would show
///   as "?unmapped". The write side is unaffected: butler always sends the
///   documented symbolic `vat` code; BHB picks the numeric key. The legacy
///   scheme is NOT selectable over the API — passing a numeric key ("9", "19")
///   as the `vat` option is rejected ("invalid vat option for given account"),
///   so an API posting always lands under the 4xx/7xx scheme.
pub const TaxKey = struct { key: []const u8, symbolic: []const u8, label: []const u8 };
pub const tax_keys = [_]TaxKey{
    // Legacy single-digit keys (web UI / DATEV origin).
    .{ .key = "0", .symbolic = "0_none", .label = "keine Ust." },
    .{ .key = "8", .symbolic = "7_pre", .label = "7% Vst." },
    .{ .key = "9", .symbolic = "19_pre", .label = "19% Vst." },
    .{ .key = "18", .symbolic = "7_both", .label = "i.g.E. 7% USt./VSt." },
    .{ .key = "19", .symbolic = "19_both_2", .label = "i.g.E. 19% USt./VSt." },
    // Lower confidence (sparse evidence). Benign — 0% like key 0 — and the raw
    // key stays visible if it is ever the wrong label.
    .{ .key = "20", .symbolic = "0_none", .label = "keine Ust." },
    // Shared between both schemes.
    .{ .key = "94", .symbolic = "19_both_1", .label = "§13b 19% USt./VSt." },
    // §13b split by where the supplier sits, which decides the UStVA line
    // (Abs. 1 → Kz 46/47, Abs. 2 Nr. 1 → Kz 84/85). Key and label both come
    // from the documented symbolic code; 511 also observed on a posting the web
    // UI labels "Drittland (§ 13b Abs. 2 Nr. 1)".
    .{ .key = "506", .symbolic = "19_both_506", .label = "§13b 19% USt./VSt. (EU §13b Abs. 1)" },
    .{ .key = "511", .symbolic = "19_both_511", .label = "§13b 19% USt./VSt. (Drittland §13b Abs. 2 Nr. 1)" },
    // API-write keys (every posting butler creates). Same treatment/label as
    // the legacy keys above, distinct number. 401 and 702 confirmed against the
    // BHB web UI; 402 and 701 follow from the documented label of the symbolic
    // code that produces them (7_pre → "7% Vst.", 19_both_2 → i.g.E. 19%).
    .{ .key = "401", .symbolic = "19_pre", .label = "19% Vst." },
    .{ .key = "402", .symbolic = "7_pre", .label = "7% Vst." },
    .{ .key = "701", .symbolic = "19_both_2", .label = "i.g.E. 19% USt./VSt." },
    .{ .key = "702", .symbolic = "7_both", .label = "i.g.E. 7% USt./VSt." },
};

/// The documented German label for a numeric `tax_key`, or null when the key is
/// not in our empirically-derived table (see `tax_keys` provenance). Null means
/// "unknown" — never a fabricated label; the caller shows the raw key instead.
pub fn taxKeyLabel(key: []const u8) ?[]const u8 {
    for (&tax_keys) |t| if (std.mem.eql(u8, t.key, key)) return t.label;
    return null;
}

/// The label the table uses for a VAT-free posting. Kept as a named constant so
/// the account-driven-VAT check compares against exactly one string.
pub const no_vat_label = "keine Ust.";

/// The integer part of a non-zero VAT rate string, or null when the rate is
/// missing or zero. "19.00" → "19", "7.00" → "7", "0.00"/"" → null.
///
/// Some VAT is ACCOUNT-DRIVEN, not keyed: a few accounts (e.g. "Verrechnete
/// sonstige Sachbezüge 19/16% USt", used for the geldwerter Vorteil of a company
/// car or a benefit) carry the rate on the account itself, so BHB returns the
/// posting with `tax_key` 0 (which decodes to "keine Ust.") yet a non-zero `vat`,
/// and shows e.g. "19% USt." in its own UI. Callers use this to surface that rate
/// instead of the misleading "no VAT" label; the raw key still stays visible.
pub fn vatRatePrefix(vat: ?[]const u8) ?[]const u8 {
    const v = vat orelse return null;
    var nonzero = false;
    for (v) |c| if (c >= '1' and c <= '9') {
        nonzero = true;
        break;
    };
    if (!nonzero) return null;
    const dot = std.mem.indexOfScalar(u8, v, '.') orelse v.len;
    return v[0..dot];
}

test "taxKeyLabel decodes known keys and rejects unknown" {
    // The distinction that matters: 9 is domestic input VAT, 19 is an
    // intra-community acquisition, 94 is a §13b reverse charge — all at 19%.
    try std.testing.expectEqualStrings("19% Vst.", taxKeyLabel("9").?);
    try std.testing.expectEqualStrings("i.g.E. 19% USt./VSt.", taxKeyLabel("19").?);
    try std.testing.expectEqualStrings("i.g.E. 7% USt./VSt.", taxKeyLabel("18").?);
    try std.testing.expectEqualStrings("§13b 19% USt./VSt.", taxKeyLabel("94").?);
    try std.testing.expectEqualStrings("keine Ust.", taxKeyLabel("0").?);
    // API-write keys decode to the same labels as their legacy counterparts, so
    // butler can read back the postings it writes (401/402/701/702 ↔ 9/8/19/18).
    try std.testing.expectEqualStrings("19% Vst.", taxKeyLabel("401").?);
    try std.testing.expectEqualStrings("7% Vst.", taxKeyLabel("402").?);
    try std.testing.expectEqualStrings("i.g.E. 19% USt./VSt.", taxKeyLabel("701").?);
    try std.testing.expectEqualStrings("i.g.E. 7% USt./VSt.", taxKeyLabel("702").?);
    // The §13b variants say where the supplier sits, which decides the UStVA
    // line: Abs. 1 (EU) is reported in Kz 46/47, Abs. 2 Nr. 1 (abroad) in
    // Kz 84/85. Key 94 predates the split and says neither.
    try std.testing.expectEqualStrings("§13b 19% USt./VSt. (EU §13b Abs. 1)", taxKeyLabel("506").?);
    try std.testing.expectEqualStrings("§13b 19% USt./VSt. (Drittland §13b Abs. 2 Nr. 1)", taxKeyLabel("511").?);
    // An undocumented key is reported as unknown, never guessed.
    try std.testing.expect(taxKeyLabel("23") == null);
}

test "vatRatePrefix surfaces account-driven VAT that tax_key 0 hides" {
    // Non-zero rates yield their integer part; used when tax_key decodes to
    // "keine Ust." but the posting carries a rate (Sachbezug accounts).
    try std.testing.expectEqualStrings("19", vatRatePrefix("19.00").?);
    try std.testing.expectEqualStrings("7", vatRatePrefix("7.00").?);
    try std.testing.expectEqualStrings("16", vatRatePrefix("16.00").?);
    // A truly VAT-free posting (rate 0 / missing) keeps the "keine Ust." label.
    try std.testing.expect(vatRatePrefix("0.00") == null);
    try std.testing.expect(vatRatePrefix("") == null);
    try std.testing.expect(vatRatePrefix(null) == null);
}
