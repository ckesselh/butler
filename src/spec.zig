//! The single source of truth for butler's command surface.
//!
//! Every (resource, verb) pair, its flags, positionals and help prose live here
//! as plain comptime data. Four consumers read this one table so a flag is
//! described in exactly one place:
//!   - cli.zig  — parses argv and validates it against the relevant verb
//!   - help.zig — renders `--help` (overview + per-command) from the tree
//!   - tools/gendoc.zig — renders the man page (roff) and docs/commands.md
//!   - the resource handlers — read already-validated flags, no re-validation
//!
//! Adding or changing a flag is a single edit here. There is deliberately no
//! metaprogramming: it is data, easy to read and easy to test.

const std = @import("std");

/// Build version, injected from build.zig.zon by build.zig — the one
/// authoritative copy. (package.nix repeats it for Nix; CI asserts they agree.)
pub const version: []const u8 = @import("build_options").version;

/// Output format selected by the global `--output` flag.
pub const Output = enum { table, json };

/// Top-level command groups. `postings` is an alias for the canonical
/// `bookings`; both map to the bookings handler in main.zig's dispatch switch.
/// `status`, `login` and
/// `logout` are verb-less commands — login/logout short-circuit in main before
/// any credentials are loaded.
pub const Resource = enum { transactions, receipts, postings, bookings, accounts, creditors, debtors, status, login, logout };

/// Whether a flag consumes an argv value (`.value`) or is a bare switch
/// (`.boolean`). Phase-1 parsing keys on this.
pub const Kind = enum { boolean, value };

/// One flag's single source of truth.
pub const Flag = struct {
    /// Long name as typed on the CLI, without leading dashes (e.g. "date-from").
    name: []const u8,
    kind: Kind = .value,
    /// Reported as "missing required flag" by the parser when absent. Only used
    /// for flags that are unconditionally required (postings list dates); flags
    /// that are conditionally required stay validated in the handler.
    required: bool = false,
    /// Value placeholder shown in help/usage, e.g. "YYYY-MM-DD". "" for booleans.
    arg: []const u8 = "",
    /// One-line description, rendered verbatim by the help/man generators.
    help: []const u8,
    /// Closed value set. When non-empty the parser rejects anything not in it,
    /// and help/man list the allowed values. Subsumes the old --output and
    /// --vat membership checks.
    choices: []const []const u8 = &.{},
    /// The value must parse as an integer. Validated at parse time so a bad
    /// numeric flag (e.g. `--limit abc`) yields a clean usage error instead of
    /// an error bubbling out of a handler's `addIntOpt`.
    int: bool = false,
    /// Lower bound for `int` flags (e.g. 0 for paging) — values below it are
    /// usage errors. Null means unbounded.
    min: ?i64 = null,
    /// Functional but not advertised — help/man skip it (e.g. the `--h` alias).
    hidden: bool = false,
};

/// A documented positional argument (e.g. <id>, <file>). Presence is still
/// enforced in the handler (with a tailored message); `int` is validated in
/// cli.Flags.validate like the Flag counterpart, so handlers read an
/// already-validated value via Flags.posInt.
pub const Positional = struct {
    name: []const u8,
    help: []const u8 = "",
    /// The value must parse as an integer (ids, account numbers). Validated at
    /// parse time so `receipts show abc` yields a clean usage error instead of
    /// a handler-specific one.
    int: bool = false,
};

/// A leaf command = one (resource, verb) pair, owning its flags.
pub const Verb = struct {
    name: []const u8,
    summary: []const u8,
    usage: []const u8,
    positionals: []const Positional = &.{},
    flags: []const Flag = &.{},
    /// Free-form prose appended under `--help`/man (caveats, JSON format, ...).
    notes: []const u8 = "",
};

/// A resource = a group of verbs, or a verb-less command (status/login/logout).
pub const Command = struct {
    name: []const u8,
    aliases: []const []const u8 = &.{},
    summary: []const u8,
    verbs: []const Verb = &.{},
    /// Description for verb-less commands; shown by `<command> --help`.
    about: []const u8 = "",
};

/// The symbolic VAT codes accepted by /postings/add/free. BHB exposes no
/// endpoint for these; they appear only in the free-text parameter description
/// of the API spec, so they are hard-coded. Re-verify on BHB API version bumps.
/// This is the one canonical copy — the --vat flag's choices and the JSON-line
/// validator in resources/bookings.zig both reference it.
/// The §13b family distinguishes where the supplier sits, because the UStVA
/// reports the two cases on different lines: a service from a supplier in
/// another EU member state (§ 13b Abs. 1) belongs in Kz 46/47, one from a
/// supplier abroad (§ 13b Abs. 2 Nr. 1) in Kz 84/85, with the input tax of both
/// in Kz 67. `19_both_1` predates the split and does not say which case it is;
/// `19_both_506` and `19_both_511` do.
pub const vat_codes = [_][]const u8{
    "0_none",        "19_vat",           "7_vat",
    "19_pre",        "7_pre",            "19_both_1",
    "19_both_506",   "19_both_511",      "19_both_2",
    "7_both",        "19_both_1_no_pre", "19_both_2_no_pre",
    "7_both_no_pre", "19_both_6501",     "19_both_6506",
    "19_both_6511",  "19_pre_app",       "7_pre_app",
    "19_both_app_1", "19_both_app_506",  "19_both_app_511",
    "19_both_app_2", "7_both_app",
};

pub fn isValidVat(v: []const u8) bool {
    return inChoices(&vat_codes, v);
}

/// Global flags accepted by every command, merged into each verb's set at
/// validation time. They keep their handling in main.zig; listing them here
/// makes them known to the parser and auto-documents them.
pub const global_flags = [_]Flag{
    .{ .name = "profile", .arg = "name", .help = "credentials profile (default: default)" },
    .{ .name = "output", .arg = "table|json", .help = "output format (default: table)", .choices = &.{ "table", "json" } },
    .{ .name = "api-base", .arg = "url", .help = "override API base URL (https unless --insecure)" },
    .{ .name = "debug", .kind = .boolean, .help = "print the request line to stderr" },
    .{ .name = "insecure", .kind = .boolean, .help = "allow sending credentials over a non-HTTPS api-base" },
    .{ .name = "help", .kind = .boolean, .help = "show help; per command: `<resource> <verb> --help`" },
    .{ .name = "h", .kind = .boolean, .help = "show help (alias for --help)", .hidden = true },
    .{ .name = "version", .kind = .boolean, .help = "print the butler version" },
};

// --- shared flags reused across verbs (one definition, many references) ---

const filter_flag = Flag{ .name = "filter", .arg = "text", .help = "case-insensitive substring over the shown columns" };
const limit_flag = Flag{ .name = "limit", .arg = "n", .int = true, .min = 1, .help = "max rows" };
const offset_flag = Flag{ .name = "offset", .arg = "n", .int = true, .min = 0, .help = "skip the first n rows" };

// `receipts comment` / `transactions comment` — the same two flags on both, since
// /comments/add differs only in which id field names the target.
const comment_flags = [_]Flag{
    .{ .name = "text", .required = true, .arg = "s", .help = "comment text (2-210 characters)" },
    .{ .name = "dry-run", .kind = .boolean, .help = "print the redacted payload, send nothing" },
};

// Shared tail for both comment verbs: what the endpoint does and does not offer.
const comment_note =
    \\
    \\The comment is 2-210 characters, counted as characters rather than bytes,
    \\and is checked before anything is sent.
    \\
    \\/comments/add is the only endpoint in the comments namespace: no get, no
    \\update, no delete. Reading a comment back goes through the postings view,
    \\which carries it as the row's `comment` field (`bookings list --comments`);
    \\changing or removing one is a web-UI job (docs/bhb-api-quirks.md).
;

// --- the command tree ---

const transactions_verbs = [_]Verb{
    .{
        .name = "list",
        .summary = "list transactions (with filters)",
        .usage = "butler transactions list [flags]",
        .flags = &.{
            .{ .name = "date-from", .arg = "YYYY-MM-DD", .help = "earliest booking date" },
            .{ .name = "date-to", .arg = "YYYY-MM-DD", .help = "latest booking date" },
            .{ .name = "account", .arg = "n", .int = true, .min = 0, .help = "bank account number" },
            .{ .name = "to-from", .arg = "text", .help = "counterparty filter (server-side)" },
            .{ .name = "id-from", .arg = "n", .int = true, .min = 0, .help = "lowest id (exclusive)" },
            .{ .name = "id-to", .arg = "n", .int = true, .min = 0, .help = "highest id (exclusive)" },
            .{ .name = "unbooked", .kind = .boolean, .help = "only payments with no posting of any class — UI \"Ungebucht\" (needs the date window)" },
            .{ .name = "missing-receipt", .kind = .boolean, .help = "only payments no posting carries a receipt for — UI \"Fehlender Beleg\" (needs the date window)" },
            filter_flag,
            limit_flag,
            offset_flag,
        },
        .notes =
        \\The open-items filters mirror the "Zahlungen" screen and anti-join a
        \\second /postings/get sweep over the window:
        \\  --unbooked         no posting of any class references the payment
        \\                     (keys on posting linkage, not receipt assignment, so
        \\                     a receipt-less but booked payment like salary/tax is
        \\                     correctly treated as booked).
        \\  --missing-receipt  no posting carries a receipt for the payment — the
        \\                     "Fehlender Beleg" case. A superset of --unbooked, since
        \\                     an unbooked payment has no receipt either.
        \\Because /postings/get caps at 1000 rows, keep the window bounded or items
        \\past the cap may show as falsely open.
        ,
    },
    .{
        .name = "show",
        .summary = "a single transaction",
        .usage = "butler transactions show <id>",
        .positionals = &.{.{ .name = "id", .help = "transaction id_by_customer", .int = true }},
        .notes = "Show a single transaction by its id_by_customer.",
    },
    .{
        .name = "book",
        .summary = "book a payment directly onto account(s)",
        .usage = "butler transactions book <tx> (--account A --amount N --vat V --text T [--receipt R] | --from-json <file>)",
        .positionals = &.{.{ .name = "tx", .help = "transaction id_by_customer", .int = true }},
        .flags = &.{
            .{ .name = "from-json", .arg = "file", .help = "JSON array of {account, postingtext, vat, amount, receipt?} split lines" },
            .{ .name = "account", .arg = "acct", .help = "single line: posting account (e.g. 3841)" },
            .{ .name = "amount", .arg = "n", .help = "single line: positive amount, e.g. 9.70" },
            .{ .name = "vat", .arg = "code", .help = "single line: vat code", .choices = &vat_codes },
            .{ .name = "text", .arg = "s", .help = "single line: posting text" },
            .{ .name = "receipt", .arg = "id", .help = "single line: clear this receipt's open item with the line" },
            .{ .name = "dry-run", .kind = .boolean, .help = "print the redacted payload, send nothing" },
        },
        .notes =
        \\Posts directly onto a bank transaction (/postings/add/transaction) — the
        \\web UI "book on a payment" action. The transaction is the contra side,
        \\so you give only the account(s) being charged: a single --account books
        \\the whole payment, or --from-json splits it across accounts. New postings
        \\land confirmed (see `bookings add`). The booking is a transaction-class
        \\posting, so it shows under `--account "all financial accounts"`, not
        \\under "Erweitertes Buchen".
        \\
        \\A line may name a `receipt`, which clears that receipt's open item —
        \\the same line `receipts pay` would post, with its creditor as the
        \\account. Use it when a payment does NOT equal its receipt: both
        \\`receipts book` and `receipts pay` reject a mismatch (error_code 37 and
        \\27), because the postings must sum to the receipt and to the payment
        \\respectively. Booking the payment instead lets the receipt line settle
        \\at the receipt's amount while a second line takes the difference:
        \\
        \\  [ {"account":"70000","amount":"29.99","vat":"0_none",
        \\     "postingtext":"Ausgleich Beleg 000128","receipt":"292"},
        \\    {"account":"6390","amount":"0.01","vat":"0_none",
        \\     "postingtext":"Aufrundungsspende"} ]
        \\
        \\Rounding, a tip or a bank charge collected with the invoice all fit this
        \\shape. Lines without `receipt` post plainly, as they always did.
        ,
    },
    .{
        .name = "settle",
        .summary = "settle booked receipt(s) against a payment",
        .usage = "butler transactions settle <tx> --receipts <id,id,...> [--dry-run]",
        .positionals = &.{.{ .name = "tx", .help = "transaction id_by_customer", .int = true }},
        .flags = &.{
            .{ .name = "receipts", .required = true, .arg = "csv", .help = "receipt id_by_customer(s), comma-separated" },
            .{ .name = "dry-run", .kind = .boolean, .help = "print the derived payload, send nothing" },
        },
        .notes =
        \\Payment-first settlement: clears the open items of the listed receipts by
        \\posting one creditor->bank line each, in a single /postings/add/transaction
        \\that marks them paid. Use when one payment covers several invoices; the
        \\receipt amounts must sum to the transaction (the API rejects a mismatch).
        \\For a single receipt, `receipts pay <id> --with <tx>` reads more naturally.
        ,
    },
    .{
        .name = "link",
        .summary = "link a receipt to a transaction (no booking)",
        .usage = "butler transactions link <tx> <receipt>",
        .positionals = &.{ .{ .name = "tx", .help = "transaction id_by_customer", .int = true }, .{ .name = "receipt", .help = "receipt id_by_customer", .int = true } },
        .notes = "A soft pointer (/transactions/assign/receipt): it sets the payment date but\ndoes NOT settle — no posting, the receipt stays unpaid. To actually settle, use\n`transactions settle` / `receipts pay`.",
    },
    .{
        .name = "unlink",
        .summary = "remove a receipt link from a transaction",
        .usage = "butler transactions unlink <tx> <receipt>",
        .positionals = &.{ .{ .name = "tx", .help = "transaction id_by_customer", .int = true }, .{ .name = "receipt", .help = "receipt id_by_customer", .int = true } },
        .notes = "Inverse of `link`. The API rejects it (error 10) once a confirmed posting\nexists on the link.",
    },
    .{
        .name = "receipts",
        .summary = "list receipts assigned to a transaction",
        .usage = "butler transactions receipts <tx> [--confirmed-only]",
        .positionals = &.{.{ .name = "tx", .help = "transaction id_by_customer", .int = true }},
        .flags = &.{
            .{ .name = "confirmed-only", .kind = .boolean, .help = "only confirmed assignments" },
            filter_flag,
        },
    },
    .{
        .name = "comment",
        .summary = "attach a comment to a transaction",
        .usage = "butler transactions comment <tx> --text <s> [--dry-run]",
        .positionals = &.{.{ .name = "tx", .help = "transaction id_by_customer", .int = true }},
        .flags = &comment_flags,
        .notes = "Add a comment to a bank transaction (the web app's \"Kommentar\" on the\nZahlung).\n" ++ comment_note,
    },
};

const receipts_verbs = [_]Verb{
    .{
        .name = "list",
        .summary = "list receipts (with filters)",
        .usage = "butler receipts list <inbound|outbound> [flags]",
        .positionals = &.{.{ .name = "inbound|outbound", .help = "receipt direction (required)" }},
        .flags = &.{
            .{ .name = "counterparty", .arg = "text", .help = "counterparty filter" },
            .{ .name = "date-from", .arg = "YYYY-MM-DD", .help = "earliest date" },
            .{ .name = "date-to", .arg = "YYYY-MM-DD", .help = "latest date" },
            .{ .name = "payment-status", .arg = "s", .help = "e.g. paid | unpaid" },
            .{ .name = "invoice-number", .arg = "s", .help = "invoice number filter" },
            .{ .name = "due-date", .arg = "YYYY-MM-DD", .help = "due-date filter" },
            .{ .name = "include-offers", .kind = .boolean, .help = "include offers" },
            .{ .name = "deleted", .kind = .boolean, .help = "include deleted receipts" },
            .{ .name = "unbooked", .kind = .boolean, .help = "only receipts with no posting referencing them — UI \"Ungebucht\" (needs the date window)" },
            .{ .name = "unpaid", .kind = .boolean, .help = "only unpaid receipts — UI \"Unbezahlt\" (shorthand for --payment-status unpaid)" },
            filter_flag,
            limit_flag,
            offset_flag,
        },
        .notes =
        \\Two distinct open-items filters, matching the "Eingangsbelege" screen:
        \\  --unbooked  ("Ungebucht") no posting references the receipt over the
        \\              window — a /postings/get sweep + id anti-join.
        \\  --unpaid    ("Unbezahlt") the receipt's own payment status is unpaid
        \\              (server-side; same as --payment-status unpaid).
        \\They are NOT the same: a receipt can be booked yet unpaid, or paid yet
        \\(rarely) unbooked. --unbooked caps at /postings/get's 1000 rows, so keep
        \\the window bounded.
        ,
    },
    .{
        .name = "show",
        .summary = "a single receipt",
        .usage = "butler receipts show <id>",
        .positionals = &.{.{ .name = "id", .help = "receipt id_by_customer", .int = true }},
        .notes =
        \\Show a single receipt by its id_by_customer, fetched directly.
        \\Deleted receipts are shown too (deleted: 1).
        ,
    },
    .{
        .name = "download",
        .summary = "save a receipt's stored file",
        .usage = "butler receipts download <id> [--file <path>]",
        .positionals = &.{.{ .name = "id", .help = "receipt id_by_customer", .int = true }},
        .flags = &.{
            .{ .name = "file", .arg = "path", .help = "destination path (default: the receipt's filename in BHB)" },
        },
        .notes =
        \\Save the receipt's stored document — the file shown in the web app's
        \\receipt preview — to a local file. Without --file the document is named
        \\like the receipt in BHB (PDF, or XML for an xRechnung receipt) and
        \\written to the current directory. An existing file is overwritten.
        ,
    },
    .{
        .name = "upload",
        .summary = "upload a receipt file",
        .usage = "butler receipts upload <file> --type <type> [flags]",
        .positionals = &.{.{ .name = "file", .help = "path to the receipt file" }},
        .flags = &.{
            .{ .name = "type", .required = true, .arg = "type", .help = "receipt type, e.g. \"invoice inbound\"" },
            .{ .name = "counterparty", .arg = "text", .help = "counterparty" },
            .{ .name = "invoice-number", .arg = "s", .help = "invoice number" },
            .{ .name = "date", .arg = "YYYY-MM-DD", .help = "document date" },
            .{ .name = "amount", .arg = "n", .help = "gross amount" },
            .{ .name = "vat-rate", .arg = "n", .help = "vat rate" },
            .{ .name = "credit-note", .kind = .boolean, .help = "a Gutschrift: send --amount negative (BHB reverses the booking)" },
            .{ .name = "dry-run", .kind = .boolean, .help = "print what would be sent, send nothing" },
        },
    },
    .{
        .name = "delete",
        .summary = "delete a receipt",
        .usage = "butler receipts delete <id>",
        .positionals = &.{.{ .name = "id", .help = "receipt id_by_customer", .int = true }},
        .notes = "Delete a receipt by its id_by_customer.",
    },
    .{
        .name = "book",
        .summary = "book a receipt onto account(s)",
        .usage = "butler receipts book <id> (--account A --amount N --vat V --text T | --from-json <file>) [--creditor C | --debtor D]",
        .positionals = &.{.{ .name = "id", .help = "receipt id_by_customer", .int = true }},
        .flags = &.{
            .{ .name = "from-json", .arg = "file", .help = "JSON array of {account, postingtext, vat, amount} split lines" },
            .{ .name = "account", .arg = "acct", .help = "single line: posting account (e.g. 6815)" },
            .{ .name = "amount", .arg = "n", .help = "single line: positive amount, e.g. 36.97" },
            .{ .name = "vat", .arg = "code", .help = "single line: vat code", .choices = &vat_codes },
            .{ .name = "text", .arg = "s", .help = "single line: posting text" },
            .{ .name = "creditor", .arg = "acct", .help = "creditor Sammelkonto (inbound invoice)" },
            .{ .name = "debtor", .arg = "acct", .help = "debtor Sammelkonto (outbound invoice)" },
            .{ .name = "dry-run", .kind = .boolean, .help = "print the redacted payload, send nothing" },
        },
        .notes =
        \\Books a receipt (/postings/add/receipt): the account line(s) for the
        \\expense/revenue. The counterparty Sammelkonto defaults to the standard
        \\Kreditoren-Sammelkonto (70000); pass --creditor for a dedicated creditor,
        \\or --debtor for an outbound invoice (Debitoren-Sammelkonto 10000). Then
        \\settle it against the payment with `receipts pay <id> --with <tx>`.
        ,
    },
    .{
        .name = "pay",
        .summary = "settle a booked receipt against a bank payment",
        .usage = "butler receipts pay <id> --with <tx> [flags]",
        .positionals = &.{.{ .name = "id", .help = "receipt id_by_customer", .int = true }},
        .flags = &.{
            .{ .name = "with", .required = true, .arg = "tx", .help = "the bank transaction id_by_customer that pays it", .int = true },
            .{ .name = "amount", .arg = "n", .help = "part-payment amount (default: the receipt's open amount)" },
            .{ .name = "account", .arg = "acct", .help = "override the creditor account (default: from the receipt's booking)" },
            .{ .name = "text", .arg = "s", .help = "posting text (default: counterparty + invoice number)" },
            .{ .name = "dry-run", .kind = .boolean, .help = "print the derived payload, send nothing" },
        },
        .notes =
        \\Mirrors the UI "Beleg einer Zahlung zuordnen": it settles the receipt's
        \\open item by posting the creditor->bank line carrying the receipt
        \\(/postings/add/transaction with the receipt as an open item), which marks
        \\it paid. The account, amount and text are resolved from the receipt's own
        \\booking, so the happy path is just the two ids. This is NOT
        \\/transactions/assign/receipt, which only links without settling.
        ,
    },
    .{
        .name = "comment",
        .summary = "attach a comment to a receipt",
        .usage = "butler receipts comment <id> --text <s> [--dry-run]",
        .positionals = &.{.{ .name = "id", .help = "receipt id_by_customer", .int = true }},
        .flags = &comment_flags,
        .notes = "Add a comment to a receipt (the web app's \"Kommentar\" on the Beleg).\n" ++ comment_note,
    },
};

const bookings_verbs = [_]Verb{
    .{
        .name = "list",
        .summary = "list bookings (with filters)",
        .usage = "butler bookings list --date-from D --date-to D [flags]",
        .flags = &.{
            .{ .name = "date-from", .required = true, .arg = "YYYY-MM-DD", .help = "earliest date" },
            .{ .name = "date-to", .required = true, .arg = "YYYY-MM-DD", .help = "latest date" },
            .{ .name = "account", .arg = "csv", .help = "accounts filter (e.g. \"free booking\")" },
            .{ .name = "postingaccount", .arg = "csv", .help = "posting-account filter (e.g. 3790)" },
            .{ .name = "status", .arg = "s", .help = "all | fixed | unfixed" },
            .{ .name = "order", .arg = "s", .help = "e.g. \"date ASC\"" },
            .{ .name = "cost-location", .arg = "s", .help = "cost location filter" },
            .{ .name = "comments", .kind = .boolean, .help = "add the comment column" },
            filter_flag,
            limit_flag,
            offset_flag,
        },
        .notes =
        \\--comments adds the `comment` column: the note attached to the posting's
        \\receipt or transaction by `receipts comment` / `transactions comment`.
        \\/postings/get is the only endpoint that returns comments, so this is the
        \\only way to read one back. Off by default because a comment runs to 210
        \\characters and would dominate the table; --output json always carries
        \\the field regardless.
        \\
        \\Columns include a decoded `tax`: the posting's numeric tax_key mapped to
        \\BHB's documented vat-code label (e.g. "i.g.E. 19% USt./VSt. [19]"). The
        \\numeric key is undocumented, so the mapping is a best-effort, empirically
        \\derived bridge — the raw key stays in brackets and an unmapped key shows
        \\as "[N] ?unmapped", so a wrong/missing label can never hide it. Also
        \\`fixed` (yes = festgeschrieben/locked, no = still editable), `receipt`
        \\(assigned invoice number, or — if none) and `tx` (linked bank
        \\transaction id, or —). The debit/credit accounts resolve to "NNNN Name"
        \\(table columns; sibling *_name fields under --output json).
        ,
    },
    .{
        .name = "add",
        .summary = "add a free (extended) booking / split",
        .usage = "butler bookings add (--from-json <file> | <line flags>) [flags]",
        .flags = &.{
            .{ .name = "from-json", .arg = "file", .help = "JSON array of split lines (see FORMAT)" },
            .{ .name = "date", .arg = "YYYY-MM-DD", .help = "single line: date" },
            .{ .name = "debit", .arg = "acct", .help = "single line: debit account" },
            .{ .name = "credit", .arg = "acct", .help = "single line: credit account" },
            .{ .name = "amount", .arg = "n", .help = "single line: positive amount, e.g. 5000.00" },
            .{ .name = "vat", .arg = "code", .help = "single line: vat code", .choices = &vat_codes },
            .{ .name = "text", .arg = "s", .help = "single line: posting text" },
            .{ .name = "cost-location", .arg = "s", .help = "optional cost location" },
            .{ .name = "clearing", .arg = "acct", .help = "assert this account nets to zero before sending" },
            .{ .name = "dry-run", .kind = .boolean, .help = "print the redacted payload, send nothing" },
        },
        .notes =
        \\Most bookings should NOT use this command. An expense or income tied to
        \\an invoice is booked with `receipts book`, and one tied to a bank payment
        \\with `transactions book`, so the posting stays ANCHORED to its receipt or
        \\transaction and is re-booked / settled / decoded through it. Reach for
        \\`bookings add` ONLY for a free, standalone entry ("Erweitertes Buchen")
        \\that has neither a receipt nor a payment — e.g. accruals,
        \\reclassifications, or opening balances. A free booking cannot be deleted
        \\via the API (web UI only), so do not use it to experiment.
        \\New bookings are created CONFIRMED (visible to the API and the web UI,
        \\still unfixed so they stay editable/deletable in the UI). To stage one
        \\for UI-only review, unconfirm it afterwards: butler bookings unconfirm <id>.
        \\
        \\--from-json FORMAT
        \\  [ {"date":"2026-05-31","postingtext":"...","amount":"5000.00",
        \\     "debit":6020,"credit":3790,"vat":"0_none"} , ... ]
        ,
    },
    .{
        .name = "unconfirm",
        .summary = "set a free booking back to unconfirmed",
        .usage = "butler bookings unconfirm <id>",
        .positionals = &.{.{ .name = "id", .help = "posting id", .int = true }},
        .notes = "Set a free booking back to unconfirmed by its posting id.",
    },
    .{
        .name = "assign",
        .summary = "link a receipt to a free booking",
        .usage = "butler bookings assign <receipt-id> <posting-id>",
        .positionals = &.{ .{ .name = "receipt-id", .help = "receipt id_by_customer", .int = true }, .{ .name = "posting-id", .help = "posting id_by_customer", .int = true } },
        .notes = "Assign a receipt to an existing free booking\n(/postings/assign/receipt-to-free-posting) — e.g. a booking made before its\nreceipt arrived.",
    },
    .{
        .name = "delete",
        .summary = "not supported by the BHB API (explains the web-UI path)",
        .usage = "butler bookings delete [id]",
        .positionals = &.{.{ .name = "id", .help = "posting id (unused — deletion is web-UI only)" }},
        .notes = "The BHB API has no posting-delete endpoint; this command only explains\nthat deletion must happen in the web UI, and exits with a usage error.",
    },
};

const accounts_verbs = [_]Verb{
    .{
        .name = "list",
        .summary = "list the chart of accounts (all numbered accounts)",
        .usage = "butler accounts list [--type kind] [flags]",
        .flags = &.{
            .{ .name = "type", .arg = "kind", .choices = &.{ "all", "postingaccount", "account", "creditor", "debtor" }, .help = "filter by account kind (default: all)" },
            filter_flag,
            limit_flag,
            offset_flag,
        },
        .notes =
        \\The full chart of accounts (/settings/get/postingaccounts): every numbered
        \\account, as a ledger row (number, name, type). This includes the
        \\creditor/debtor Personenkonten — here they are just ledger accounts; their
        \\master data (address, IBAN, VAT id) lives on `creditors` / `debtors`.
        \\
        \\--type narrows to one kind (default all):
        \\  postingaccount  Sachkonten
        \\  account         base cash/bank accounts (Kasse, Geschäftskonto, ...)
        \\  creditor        Kreditoren (incl. the collective account)
        \\  debtor          Debitoren (incl. the collective account)
        \\
        \\Without --limit butler pages the chart to completion (the endpoint
        \\defaults to 1000 rows); --limit fetches a single bounded page (with
        \\--offset). --filter is a case-insensitive substring match (client-side)
        \\over the shown columns — number, name, type.
        ,
    },
    .{
        .name = "show",
        .summary = "a single account by its number",
        .usage = "butler accounts show <account>",
        .positionals = &.{.{ .name = "account", .help = "postingaccount_number", .int = true }},
        .notes =
        \\Look up one account by its number in the chart of accounts
        \\(/settings/get/postingaccounts) — ANY kind: a Sachkonto, a base cash/bank
        \\account, or a creditor/debtor Personenkonto (returning its ledger row).
        \\For a creditor/debtor's master data (address, IBAN, VAT id) use
        \\`creditors show` / `debtors show`. The lookup matches client-side (the API
        \\has no get-by-id route).
        ,
    },
    .{
        .name = "add",
        .summary = "create a postingaccount (Sachkonto)",
        .usage = "butler accounts add <account> --name <s> --parent <n> [--dry-run]",
        .positionals = &.{.{ .name = "account", .help = "postingaccount_number to create", .int = true }},
        .flags = &.{
            .{ .name = "name", .required = true, .arg = "s", .help = "account name" },
            .{ .name = "parent", .required = true, .arg = "n", .int = true, .min = 0, .help = "parent postingaccount_number (the chart node it nests under)" },
            .{ .name = "dry-run", .kind = .boolean, .help = "print the redacted payload, send nothing" },
        },
        .notes =
        \\Create a Sachkonto via /settings/add/postingaccount. The account number,
        \\--name and --parent (the chart node it nests under) are all required.
        \\No delete endpoint exists (see docs/bhb-api-quirks.md).
        ,
    },
    .{
        .name = "update",
        .summary = "rename a postingaccount by its number",
        .usage = "butler accounts update <account> --name <s> [--dry-run]",
        .positionals = &.{.{ .name = "account", .help = "postingaccount_number", .int = true }},
        .flags = &.{
            .{ .name = "name", .required = true, .arg = "s", .help = "new account name" },
            .{ .name = "dry-run", .kind = .boolean, .help = "print the redacted payload, send nothing" },
        },
        .notes = "Rename a Sachkonto via /settings/update/postingaccount (name is the only\nupdatable field the API takes here).",
    },
};

// Shared paging note for the creditor/debtor list verbs: both endpoints default
// to 25 rows per page, so butler sweeps every page unless --limit bounds it.
const subledger_paging_note =
    \\Without --limit butler pages the endpoint to completion (the API defaults to
    \\25 rows per page); pass --limit for a single bounded page. --offset skips the
    \\first n rows in either mode.
;

// Shared note: what --filter searches on the creditor/debtor list verbs.
const subledger_filter_note =
    \\
    \\
    \\--filter is a case-insensitive substring match (client-side) over the shown
    \\columns — number, name, city, VAT-id and IBAN.
;

// Optional contact/banking fields shared by creditor/debtor `add` and `update`.
// Each is omitted from the request body when not given, so an update touches
// only the fields you pass.
const subledger_contact_flags = [_]Flag{
    .{ .name = "contact", .arg = "s", .help = "contact person name" },
    .{ .name = "street", .arg = "s", .help = "street" },
    .{ .name = "address2", .arg = "s", .help = "additional address line" },
    .{ .name = "zip", .arg = "s", .help = "postal / ZIP code" },
    .{ .name = "city", .arg = "s", .help = "city" },
    .{ .name = "country", .arg = "s", .help = "country" },
    .{ .name = "vat-id", .arg = "s", .help = "EU VAT id (sales_tax_id)" },
    .{ .name = "email", .arg = "s", .help = "email address" },
    .{ .name = "iban", .arg = "s", .help = "IBAN" },
    .{ .name = "bic", .arg = "s", .help = "BIC" },
};

const dry_run_flag = Flag{ .name = "dry-run", .kind = .boolean, .help = "print the redacted payload, send nothing" };

const creditor_add_flags = [_]Flag{
    .{ .name = "name", .required = true, .arg = "s", .help = "creditor name" },
    .{ .name = "account", .arg = "n", .int = true, .min = 0, .help = "postingaccount_number to assign (else auto-assigned)" },
} ++ subledger_contact_flags ++ [_]Flag{
    .{ .name = "due-days", .arg = "n", .int = true, .min = 0, .help = "default payment term in days" },
    dry_run_flag,
};

const creditor_update_flags = [_]Flag{
    .{ .name = "name", .arg = "s", .help = "new creditor name" },
} ++ subledger_contact_flags ++ [_]Flag{
    .{ .name = "due-days", .arg = "n", .int = true, .min = 0, .help = "default payment term in days" },
    dry_run_flag,
};

const debtor_add_flags = [_]Flag{
    .{ .name = "name", .required = true, .arg = "s", .help = "debtor name" },
    .{ .name = "account", .arg = "n", .int = true, .min = 0, .help = "postingaccount_number to assign (else auto-assigned)" },
} ++ subledger_contact_flags ++ [_]Flag{
    .{ .name = "customer-number", .arg = "s", .help = "customer number" },
    dry_run_flag,
};

const debtor_update_flags = [_]Flag{
    .{ .name = "name", .arg = "s", .help = "new debtor name" },
} ++ subledger_contact_flags ++ [_]Flag{
    .{ .name = "customer-number", .arg = "s", .help = "customer number" },
    dry_run_flag,
};

// Shared write notes (per resource, with the German label substituted in).
const creditor_add_note = "Create a creditor via /settings/add/creditor. Only --name is required; omit\n--account to let BHB assign the next free Kreditoren number. The API returns no\nid — re-query with `creditors list --filter` / `creditors show`. No delete\nendpoint exists (see docs/bhb-api-quirks.md).";
const subledger_update_note = "Pass only the fields you want to change (at least one is required); omitted fields are left untouched.";
const debtor_add_note = "Create a debtor via /settings/add/debtor. Only --name is required; omit\n--account to let BHB assign the next free Debitoren number. The API returns no\nid — re-query with `debtors list --filter` / `debtors show`. No delete endpoint\nexists (see docs/bhb-api-quirks.md).";

const creditors_verbs = [_]Verb{
    .{
        .name = "list",
        .summary = "list creditors (Kreditoren)",
        .usage = "butler creditors list [flags]",
        .flags = &.{ filter_flag, limit_flag, offset_flag },
        .notes =
        \\Creditor accounts (Kreditoren) from /settings/get/creditors. The dedicated
        \\creditor account is in `postingaccount_number` — the value you pass to
        \\`receipts book --creditor`.
        \\
        ++ subledger_paging_note ++ subledger_filter_note,
    },
    .{
        .name = "show",
        .summary = "a single creditor by its account number",
        .usage = "butler creditors show <account>",
        .positionals = &.{.{ .name = "account", .help = "creditor postingaccount_number", .int = true }},
        .notes = "Look up one creditor by its account number (postingaccount_number);\nthe lookup pages the list endpoint, which has no get-by-id route.",
    },
    .{
        .name = "add",
        .summary = "create a creditor (Kreditor)",
        .usage = "butler creditors add --name <s> [--account n] [field flags] [--dry-run]",
        .flags = &creditor_add_flags,
        .notes = creditor_add_note,
    },
    .{
        .name = "update",
        .summary = "update a creditor by its account number",
        .usage = "butler creditors update <account> [field flags] [--dry-run]",
        .positionals = &.{.{ .name = "account", .help = "creditor postingaccount_number", .int = true }},
        .flags = &creditor_update_flags,
        .notes = "Update a creditor via /settings/update/creditor. " ++ subledger_update_note,
    },
};

const debtors_verbs = [_]Verb{
    .{
        .name = "list",
        .summary = "list debtors (Debitoren)",
        .usage = "butler debtors list [flags]",
        .flags = &.{ filter_flag, limit_flag, offset_flag },
        .notes =
        \\Debtor accounts (Debitoren) from /settings/get/debtors. The dedicated
        \\debtor account is in `postingaccount_number` — the value you pass to
        \\`receipts book --debtor`.
        \\
        ++ subledger_paging_note ++ subledger_filter_note,
    },
    .{
        .name = "show",
        .summary = "a single debtor by its account number",
        .usage = "butler debtors show <account>",
        .positionals = &.{.{ .name = "account", .help = "debtor postingaccount_number", .int = true }},
        .notes = "Look up one debtor by its account number (postingaccount_number);\nthe lookup pages the list endpoint, which has no get-by-id route.",
    },
    .{
        .name = "add",
        .summary = "create a debtor (Debitor)",
        .usage = "butler debtors add --name <s> [--account n] [field flags] [--dry-run]",
        .flags = &debtor_add_flags,
        .notes = debtor_add_note,
    },
    .{
        .name = "update",
        .summary = "update a debtor by its account number",
        .usage = "butler debtors update <account> [field flags] [--dry-run]",
        .positionals = &.{.{ .name = "account", .help = "debtor postingaccount_number", .int = true }},
        .flags = &debtor_update_flags,
        .notes = "Update a debtor via /settings/update/debtor. " ++ subledger_update_note,
    },
};

pub const commands = [_]Command{
    .{ .name = "transactions", .summary = "bank transactions (list, show, book, settle, link, unlink, receipts)", .verbs = &transactions_verbs },
    .{ .name = "receipts", .summary = "receipts / documents (list, show, download, upload, delete, book, pay)", .verbs = &receipts_verbs },
    .{ .name = "bookings", .aliases = &.{"postings"}, .summary = "bookings: add (free/extended), list, unconfirm, assign, delete; alias: postings", .verbs = &bookings_verbs },
    .{ .name = "accounts", .summary = "chart of accounts (list, show, add, update)", .verbs = &accounts_verbs },
    .{ .name = "creditors", .summary = "creditors / Kreditoren (list, show, add, update)", .verbs = &creditors_verbs },
    .{ .name = "debtors", .summary = "debtors / Debitoren (list, show, add, update)", .verbs = &debtors_verbs },
    .{
        .name = "status",
        .summary = "test API connectivity and show client info",
        .about = "Probe the BHB API (authenticated) and print the api base, profile, and butler/API\nversions. Exits non-zero if the call fails.",
    },
    .{
        .name = "login",
        .summary = "store credentials for a profile",
        .about = "Prompt for api_client / api_secret / api_key and store them in\n$XDG_CONFIG_HOME/butler/credentials (default ~/.config/butler/credentials),\nmode 0600.",
    },
    .{
        .name = "logout",
        .summary = "explain how to remove a profile's credentials",
        .about = "Explains how to remove a profile's [section] from the credentials file\n($XDG_CONFIG_HOME/butler/credentials, default ~/.config/butler/credentials).",
    },
};

// --- lookup helpers ---

pub fn inChoices(choices: []const []const u8, v: []const u8) bool {
    for (choices) |c| {
        if (std.mem.eql(u8, c, v)) return true;
    }
    return false;
}

/// Find the command for a resource name or alias.
pub fn resolveCommand(name: []const u8) ?*const Command {
    for (&commands) |*c| {
        if (std.mem.eql(u8, c.name, name)) return c;
        for (c.aliases) |a| {
            if (std.mem.eql(u8, a, name)) return c;
        }
    }
    return null;
}

/// Find a verb within a command by name.
pub fn resolveVerb(cmd: *const Command, verb: []const u8) ?*const Verb {
    for (cmd.verbs) |*v| {
        if (std.mem.eql(u8, v.name, verb)) return v;
    }
    return null;
}

/// Look up a flag by name across global flags and every verb. Used by the
/// parser to decide whether a flag consumes a value (its Kind). Flag names are
/// consistent in kind across the whole tree, so the first match is authoritative.
pub fn lookupFlag(name: []const u8) ?*const Flag {
    for (&global_flags) |*f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    for (&commands) |*c| {
        for (c.verbs) |*v| {
            for (v.flags) |*f| {
                if (std.mem.eql(u8, f.name, name)) return f;
            }
        }
    }
    return null;
}

/// Find a global flag by name (per-verb flags not considered). Used to
/// validate verb-less commands (status/login/logout), which accept only
/// global flags.
pub fn globalFlag(name: []const u8) ?*const Flag {
    for (&global_flags) |*f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

/// Find a flag accepted by `verb` (its own flags or a global flag).
pub fn verbFlag(verb: *const Verb, name: []const u8) ?*const Flag {
    for (verb.flags) |*f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return globalFlag(name);
}

// Spec invariants, enforced at compile time so an edit to the table cannot
// silently break parsing or dispatch:
//   (1) A flag name has exactly one Kind across the global flags and every
//       verb. Phase-1 parsing (cli.zig) decides whether a flag consumes a
//       value from the FIRST lookupFlag match, so a kind collision between two
//       same-named flags would misparse argv for one of them. (int/choices may
//       differ per verb — those are validated per-verb in phase 2.)
//   (2) The Resource enum and the commands table (names + aliases) agree.
//       main.zig dispatches via stringToEnum(Resource) while help/gendoc walk
//       this table; drift would make a documented command fail at runtime.
comptime {
    @setEvalBranchQuota(100_000);
    for (&commands) |*c| {
        for (c.verbs) |*v| {
            for (v.flags) |*f| {
                if (lookupFlag(f.name).?.kind != f.kind)
                    @compileError("flag --" ++ f.name ++ " is declared with conflicting kinds across the spec");
            }
        }
    }
    for (@typeInfo(Resource).@"enum".fields) |ef| {
        if (resolveCommand(ef.name) == null)
            @compileError("Resource." ++ ef.name ++ " has no entry in spec.commands");
    }
    for (&commands) |*c| {
        if (std.meta.stringToEnum(Resource, c.name) == null)
            @compileError("command '" ++ c.name ++ "' is missing from the Resource enum");
        for (c.aliases) |a| {
            if (std.meta.stringToEnum(Resource, a) == null)
                @compileError("alias '" ++ a ++ "' is missing from the Resource enum");
        }
    }
    // help.zig renders "--name <arg>" labels and "butler <name> <verb>" usage
    // lines into fixed 64-byte buffers; keep spec strings short enough that
    // its bufPrint truncation fallbacks stay dead code.
    for (&global_flags) |*f| {
        if (f.name.len + f.arg.len + 5 > 64)
            @compileError("flag --" ++ f.name ++ ": label exceeds help.zig's 64-byte buffer");
    }
    for (&commands) |*c| {
        if (c.name.len + 14 > 64)
            @compileError("command '" ++ c.name ++ "': usage line exceeds help.zig's 64-byte buffer");
        for (c.verbs) |*v| {
            for (v.flags) |*f| {
                if (f.name.len + f.arg.len + 5 > 64)
                    @compileError("flag --" ++ f.name ++ ": label exceeds help.zig's 64-byte buffer");
            }
        }
    }
}

test "tree lookups" {
    const c = resolveCommand("postings").?; // alias resolves to the canonical bookings
    try std.testing.expectEqualStrings("bookings", c.name);
    try std.testing.expect(resolveVerb(c, "add") != null);
    try std.testing.expect(resolveVerb(c, "bogus") == null);
    try std.testing.expectEqual(Kind.value, lookupFlag("date-from").?.kind);
    try std.testing.expectEqual(Kind.boolean, lookupFlag("dry-run").?.kind);
    try std.testing.expect(lookupFlag("nope") == null);
    try std.testing.expect(isValidVat("0_none"));
    try std.testing.expect(!isValidVat("99_made_up"));
}

// The tax-key decode table lives in util/tax.zig; this cross-check stays here
// because it ties that table to THIS file's documented vat codes.
test "tax table symbolic codes are documented vat codes" {
    const tax = @import("util/tax.zig");
    for (&tax.tax_keys) |t| try std.testing.expect(isValidVat(t.symbolic));
}
