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

/// Top-level command groups. `bookings` is an alias for `postings`; both map to
/// the postings handler in main.zig's dispatch switch. `status`, `login` and
/// `logout` are verb-less commands — login/logout short-circuit in main before
/// any credentials are loaded.
pub const Resource = enum { transactions, receipts, postings, bookings, accounts, status, login, logout };

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
/// enforced in the handler; this entry drives help/man rendering only.
pub const Positional = struct {
    name: []const u8,
    help: []const u8 = "",
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
/// validator in resources/postings.zig both reference it.
pub const vat_codes = [_][]const u8{
    "0_none",           "19_vat",           "7_vat",         "19_pre",
    "7_pre",            "19_both_1",        "19_both_2",     "7_both",
    "19_both_1_no_pre", "19_both_2_no_pre", "7_both_no_pre", "19_pre_app",
    "7_pre_app",        "19_both_app_1",    "19_both_app_2", "7_both_app",
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
            filter_flag,
            limit_flag,
            offset_flag,
        },
    },
    .{
        .name = "show",
        .summary = "a single transaction",
        .usage = "butler transactions show <id>",
        .positionals = &.{.{ .name = "id", .help = "transaction id_by_customer" }},
        .notes = "Show a single transaction by its id_by_customer.",
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
            filter_flag,
            limit_flag,
            offset_flag,
        },
    },
    .{
        .name = "show",
        .summary = "a single receipt",
        .usage = "butler receipts show <id> [--direction inbound|outbound]",
        .positionals = &.{.{ .name = "id", .help = "receipt id_by_customer" }},
        .flags = &.{
            .{ .name = "direction", .arg = "inbound|outbound", .help = "narrow the lookup", .choices = &.{ "inbound", "outbound" } },
        },
        .notes =
        \\Show a single receipt by its id_by_customer.
        \\
        \\BHB's get-by-id route returns HTTP 404 (server-side bug), so butler looks
        \\the id up via the list endpoint; at most 500 receipts per direction are
        \\searched. Pass --direction to narrow the lookup.
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
            .{ .name = "dry-run", .kind = .boolean, .help = "print what would be sent, send nothing" },
        },
    },
    .{
        .name = "delete",
        .summary = "delete a receipt",
        .usage = "butler receipts delete <id>",
        .positionals = &.{.{ .name = "id", .help = "receipt id_by_customer" }},
        .notes = "Delete a receipt by its id_by_customer.",
    },
};

const postings_verbs = [_]Verb{
    .{
        .name = "list",
        .summary = "list postings (with filters)",
        .usage = "butler postings list --date-from D --date-to D [flags]",
        .flags = &.{
            .{ .name = "date-from", .required = true, .arg = "YYYY-MM-DD", .help = "earliest date" },
            .{ .name = "date-to", .required = true, .arg = "YYYY-MM-DD", .help = "latest date" },
            .{ .name = "account", .arg = "csv", .help = "accounts filter (e.g. \"free booking\")" },
            .{ .name = "postingaccount", .arg = "csv", .help = "posting-account filter (e.g. 3790)" },
            .{ .name = "status", .arg = "s", .help = "all | fixed | unfixed" },
            .{ .name = "order", .arg = "s", .help = "e.g. \"date ASC\"" },
            .{ .name = "cost-location", .arg = "s", .help = "cost location filter" },
            filter_flag,
            limit_flag,
            offset_flag,
        },
    },
    .{
        .name = "create",
        .summary = "create a posting / split booking",
        .usage = "butler postings create (--from-json <file> | <line flags>) [flags]",
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
        \\New postings are created CONFIRMED (visible to the API and the web UI,
        \\still unfixed so they stay editable/deletable in the UI). To stage one
        \\for UI-only review, unconfirm it afterwards: butler postings unconfirm <id>.
        \\
        \\--from-json FORMAT
        \\  [ {"date":"2026-05-31","postingtext":"...","amount":"5000.00",
        \\     "debit":6020,"credit":3790,"vat":"0_none"} , ... ]
        ,
    },
    .{
        .name = "unconfirm",
        .summary = "set a posting back to unconfirmed",
        .usage = "butler postings unconfirm <id>",
        .positionals = &.{.{ .name = "id", .help = "posting id" }},
        .notes = "Set a free posting back to unconfirmed by its posting id.",
    },
    .{
        .name = "delete",
        .summary = "not supported by the BHB API (explains the web-UI path)",
        .usage = "butler postings delete [id]",
        .positionals = &.{.{ .name = "id", .help = "posting id (unused — deletion is web-UI only)" }},
        .notes = "The BHB API has no posting-delete endpoint; this command only explains\nthat deletion must happen in the web UI, and exits with a usage error.",
    },
};

const accounts_verbs = [_]Verb{
    .{
        .name = "list",
        .summary = "list the chart of accounts (postingaccounts)",
        .usage = "butler accounts list [flags]",
        .flags = &.{ filter_flag, limit_flag, offset_flag },
    },
};

pub const commands = [_]Command{
    .{ .name = "transactions", .summary = "bank transactions (list, show)", .verbs = &transactions_verbs },
    .{ .name = "receipts", .summary = "receipts / documents (list, show, upload, delete)", .verbs = &receipts_verbs },
    .{ .name = "postings", .aliases = &.{"bookings"}, .summary = "extended bookings (list, create, unconfirm), alias: bookings", .verbs = &postings_verbs },
    .{ .name = "accounts", .summary = "chart of accounts (list)", .verbs = &accounts_verbs },
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
    const c = resolveCommand("bookings").?; // alias resolves to postings
    try std.testing.expectEqualStrings("postings", c.name);
    try std.testing.expect(resolveVerb(c, "create") != null);
    try std.testing.expect(resolveVerb(c, "bogus") == null);
    try std.testing.expectEqual(Kind.value, lookupFlag("date-from").?.kind);
    try std.testing.expectEqual(Kind.boolean, lookupFlag("dry-run").?.kind);
    try std.testing.expect(lookupFlag("nope") == null);
    try std.testing.expect(isValidVat("0_none"));
    try std.testing.expect(!isValidVat("99_made_up"));
}
