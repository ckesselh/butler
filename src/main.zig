//! Entry point: argv parsing/validation, credential resolution, HTTP client
//! setup, and dispatch to the resource handlers. Owns the process arena that
//! the resource/output layer allocates from.

const std = @import("std");
const cli = @import("cli.zig");
const spec = @import("spec.zig");
const config = @import("config.zig");
const help = @import("help.zig");
const ui = @import("util/ui.zig");
const json = @import("util/json.zig");
const Client = @import("client.zig").Client;
const transactions = @import("resources/transactions.zig");
const receipts = @import("resources/receipts.zig");
const postings = @import("resources/postings.zig");
const accounts = @import("resources/accounts.zig");

/// Build version, injected from build.zig.zon via spec.zig.
pub const version = spec.version;

pub fn main(init: std.process.Init) !u8 {
    // Buffered stdout/stderr; flushed exactly once on every exit path.
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const code = run(init, stdout, stderr) catch |err| {
        stdout.flush() catch {};
        stderr.flush() catch {};
        return err;
    };
    // A failed stdout flush means the user did not get the output (e.g. a
    // closed pipe or a full disk) — exit non-zero rather than lie.
    stdout.flush() catch return 1;
    stderr.flush() catch {};
    return code;
}

fn run(init: std.process.Init, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    // One-shot CLI: the process arena means we allocate freely and reclaim
    // everything at exit — no per-allocation frees, no leak noise. Leaf
    // modules (config, util/*) are allocation-correct on their own; the
    // resource/output layer leans on the arena.
    const gpa = init.arena.allocator();
    const io = init.io;
    const env = init.environ_map;

    const style = ui.Style.detect(io, env);

    // Collect argv once as plain slices.
    var argv: std.ArrayList([]const u8) = .empty;
    var args_it = std.process.Args.Iterator.init(init.minimal.args);
    defer args_it.deinit();
    while (args_it.next()) |a| try argv.append(gpa, a);

    // Parse argv; bail out on the first malformed argument.
    var flags = try cli.Flags.parse(gpa, argv.items[@min(1, argv.items.len)..]);
    if (flags.parse_error) |e| {
        try stderr.print("error: {s}\n", .{e});
        try stderr.writeAll("see `butler --help`.\n");
        return 2;
    }

    // `--version` prints the version and exits.
    if (flags.has("version")) {
        try stdout.print("butler {s}\n", .{version});
        return 0;
    }

    const want_help = flags.has("help") or flags.has("h");

    // No resource → top-level overview.
    if (flags.positionals.items.len == 0) {
        try help.overview(stdout, style);
        return 0;
    }

    // Resolve the resource (bookings is an alias for postings) and verb.
    const resource = flags.positionals.items[0];
    const verb = flags.pos(1) orelse "";
    const r = std.meta.stringToEnum(spec.Resource, resource) orelse {
        if (want_help) {
            try help.overview(stdout, style);
            return 0;
        }
        try stderr.print("error: unknown resource '{s}'. see `butler --help`.\n", .{resource});
        return 2;
    };

    // `--help` prints command-specific help and never needs credentials.
    if (want_help) {
        try help.command(r, verb, stdout, style);
        return 0;
    }

    const profile = flags.opt("profile") orelse "default";

    // Validate everything the spec knows — verb existence, per-command flag
    // validity, required flags, closed value sets, int bounds, and positional
    // arity — BEFORE credentials are touched, so every usage error exits 2
    // without loading (or prompting for) secrets.
    if (spec.resolveCommand(resource)) |cmd| {
        if (cmd.verbs.len > 0) {
            const vs = spec.resolveVerb(cmd, verb) orelse {
                const names = try gpa.alloc([]const u8, cmd.verbs.len);
                for (cmd.verbs, 0..) |*v, i| names[i] = v.name;
                return cli.unknownVerb(stderr, verb, try std.mem.join(gpa, "|", names));
            };
            try flags.validate(vs);
            if (flags.parse_error) |e| {
                try stderr.print("error: {s}\n", .{e});
                try stderr.writeAll("see `butler --help`.\n");
                return 2;
            }
            // Extra positionals are almost always a quoting mistake; missing
            // ones are reported by the handler with a tailored message.
            const expected = 2 + vs.positionals.len;
            if (flags.positionals.items.len > expected) {
                try stderr.print("error: unexpected argument '{s}'\n", .{flags.positionals.items[expected]});
                return 2;
            }
        } else {
            // Verb-less commands (status/login/logout) accept only global
            // flags and no further positionals.
            var oit = flags.opts.iterator();
            while (oit.next()) |e| {
                if (spec.globalFlag(e.key_ptr.*) == null) {
                    try stderr.print("error: --{s} is not valid for `butler {s}`\n", .{ e.key_ptr.*, cmd.name });
                    return 2;
                }
            }
            var bit = flags.bools.keyIterator();
            while (bit.next()) |k| {
                if (spec.globalFlag(k.*) == null) {
                    try stderr.print("error: --{s} is not valid for `butler {s}`\n", .{ k.*, cmd.name });
                    return 2;
                }
            }
            if (flags.positionals.items.len > 1) {
                try stderr.print("error: unexpected argument '{s}'\n", .{flags.positionals.items[1]});
                return 2;
            }
        }
    }

    // login/logout manage credentials and need no client.
    switch (r) {
        .login => return doLogin(gpa, io, env, profile, stderr),
        .logout => return doLogout(gpa, env, profile, stderr),
        else => {},
    }

    // Decide the output format up front (rejects anything but table/json).
    const out_mode: spec.Output = blk: {
        const o = flags.opt("output") orelse "table";
        if (std.mem.eql(u8, o, "json")) break :blk .json;
        if (std.mem.eql(u8, o, "table")) break :blk .table;
        try stderr.writeAll("error: --output must be 'table' or 'json'\n");
        return 2;
    };

    // --filter is a client-side table feature; in JSON mode the raw body is
    // echoed untouched, so the combination would silently ignore the filter.
    if (out_mode == .json and flags.opt("filter") != null) {
        try stderr.writeAll("error: --filter applies to --output table only; filter JSON with jq\n");
        return 2;
    }

    // Load credentials for the profile (env BUTLER_* over file).
    const prof = config.loadProfile(gpa, io, env, profile) catch |err| {
        switch (err) {
            error.InsecureCredentialsFile => {
                // Name the actual file (XDG_CONFIG_HOME may move it).
                const dir = try config.configDir(gpa, env);
                try stderr.print("error: {s}/credentials is group/world-readable. Run: chmod 600 {s}/credentials\n", .{ dir, dir });
            },
            else => {
                try stderr.print("error: no credentials for profile '{s}' ({s}).\n", .{ profile, @errorName(err) });
                try stderr.writeAll("run `butler login` or set BUTLER_API_CLIENT / BUTLER_API_SECRET / BUTLER_API_KEY.\n");
            },
        }
        return 1;
    };

    // Refuse to send credentials over a non-HTTPS base unless overridden.
    const base = flags.opt("api-base") orelse config.default_base;
    if (!std.mem.startsWith(u8, base, "https://") and !flags.has("insecure")) {
        try stderr.print("error: refusing to send credentials over non-HTTPS api-base '{s}'. Pass --insecure to override.\n", .{base});
        return 2;
    }

    // One HTTP client for the whole invocation, so a multi-line `postings
    // create` reuses its connection pool / TLS session.
    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    // Honor SSL_CERT_FILE (Nix sandboxes, minimal containers, corporate CAs):
    // pre-seed the trust store and pin `now`, which makes the client skip its
    // system rescan — that rescan knows nothing about the override.
    if (config.getEnv(env, "SSL_CERT_FILE")) |cert_file| {
        const now = std.Io.Clock.real.now(io);
        http_client.ca_bundle.addCertsFromFilePathAbsolute(gpa, io, now, cert_file) catch |err| {
            try stderr.print("error: cannot load SSL_CERT_FILE '{s}': {s}\n", .{ cert_file, @errorName(err) });
            return 1;
        };
        http_client.now = now;
    }

    // Build the API client (Basic auth header + api_key body field).
    const basic = try config.basicAuth(gpa, prof.api_client, prof.api_secret);
    const client = Client{
        .gpa = gpa,
        .io = io,
        .http = &http_client,
        .base = base,
        .basic = basic,
        .api_key = prof.api_key,
    };

    if (flags.has("debug")) try stderr.print("→ {s} {s} (profile={s}, base={s})\n", .{ resource, verb, profile, base });

    // Dispatch to the resource handler. Errors that escape a handler are
    // transport-level (DNS, TLS, refused connection); render them as one line
    // instead of letting a raw error trace surface.
    const result: anyerror!u8 = switch (r) {
        .transactions => transactions.run(client, verb, &flags, stdout, stderr, out_mode),
        .receipts => receipts.run(client, verb, &flags, stdout, stderr, out_mode),
        .postings, .bookings => postings.run(client, verb, &flags, stdout, stderr, out_mode),
        .accounts => accounts.run(client, verb, &flags, stdout, stderr, out_mode),
        .status => doStatus(client, profile, prof.api_client, stdout, stderr, style),
        .login, .logout => unreachable,
    };
    return result catch |err| {
        try stderr.print("error: {s} (api base: {s})\n", .{ @errorName(err), base });
        return 1;
    };
}

fn readLine(gpa: std.mem.Allocator, reader: *std.Io.Reader) !?[]const u8 {
    // takeDelimiter's slice lives in the reader's buffer only until the next
    // read, so each line is duped (the arena reclaims it at exit).
    const line = (try reader.takeDelimiter('\n')) orelse return null;
    return try gpa.dupe(u8, std.mem.trim(u8, line, " \t\r"));
}

/// Read one line with terminal echo disabled (so the secret stays out of the
/// scrollback) when stdin is a TTY; piped stdin reads normally. Echo is
/// restored before returning, and a newline is emitted because the user's
/// Enter prints nothing while echo is off. Falls back to echoed input if the
/// terminal refuses the termios calls.
fn readSecretLine(gpa: std.mem.Allocator, reader: *std.Io.Reader, tty: bool, stderr: *std.Io.Writer) !?[]const u8 {
    if (!tty) return readLine(gpa, reader);
    const fd = std.Io.File.stdin().handle;
    const old = std.posix.tcgetattr(fd) catch return readLine(gpa, reader);
    var noecho = old;
    noecho.lflag.ECHO = false;
    std.posix.tcsetattr(fd, .NOW, noecho) catch return readLine(gpa, reader);
    defer std.posix.tcsetattr(fd, .NOW, old) catch {};
    const line = try readLine(gpa, reader);
    try stderr.writeAll("\n");
    try stderr.flush();
    return line;
}

fn doLogin(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, profile: []const u8, stderr: *std.Io.Writer) !u8 {
    // Read the three credential fields from stdin (secrets unechoed on a TTY).
    var stdin_buffer: [8192]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    const r = &stdin_reader.interface;
    const tty = std.Io.File.stdin().isTty(io) catch false;
    try stderr.print("Configuring profile '{s}'.\n", .{profile});
    try stderr.writeAll("API Client: ");
    try stderr.flush();
    const client = (try readLine(gpa, r)) orelse return error.NoInput;
    try stderr.writeAll("API Secret: ");
    try stderr.flush();
    const secret = (try readSecretLine(gpa, r, tty, stderr)) orelse return error.NoInput;
    try stderr.writeAll("API Key: ");
    try stderr.flush();
    const key = (try readSecretLine(gpa, r, tty, stderr)) orelse return error.NoInput;

    // Reject empties, then persist atomically at mode 0600.
    if (client.len == 0 or secret.len == 0 or key.len == 0) {
        try stderr.writeAll("error: empty value.\n");
        return 1;
    }
    config.saveProfile(gpa, io, env, profile, client, secret, key) catch |e| {
        try stderr.print("error: could not save credentials: {s}\n", .{@errorName(e)});
        return 1;
    };
    const dir = try config.configDir(gpa, env);
    try stderr.print("saved to {s}/credentials (0600).\n", .{dir});
    return 0;
}

fn doLogout(gpa: std.mem.Allocator, env: *const std.process.Environ.Map, profile: []const u8, stderr: *std.Io.Writer) !u8 {
    const dir = try config.configDir(gpa, env);
    try stderr.print("logout: remove the [{s}] block from {s}/credentials.\n", .{ profile, dir });
    return 0;
}

/// Aligned `  label        value` line, label dimmed.
fn kv(w: *std.Io.Writer, s: ui.Style, label: []const u8, val: []const u8) !void {
    try w.print("  {s}{s}{s}", .{ s.dim, label, s.reset });
    var i: usize = label.len;
    while (i < 14) : (i += 1) try w.writeByte(' ');
    try w.print("{s}\n", .{val});
}

/// `butler status` — print client info and probe the API with an authenticated
/// /accounts/get (the BHB API has no dedicated status/version endpoint).
fn doStatus(c: Client, profile: []const u8, api_client: []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer, style: ui.Style) !u8 {
    // Static info about this client and the API we target.
    try stdout.print("{s}butler status{s}\n\n", .{ style.head, style.reset });
    try kv(stdout, style, "butler", version);
    try kv(stdout, style, "profile", profile);
    try kv(stdout, style, "api base", c.base);
    try kv(stdout, style, "api client", api_client);
    try kv(stdout, style, "API spec", "BuchhaltungsButler v1.9.1 (no live version endpoint)");

    // Probe connectivity with a cheap authenticated call.
    var o = try json.ObjBuilder.init(c.gpa);
    try o.str("api_key", c.api_key);
    try o.end();
    var r = try c.post("/accounts/get", o.items());
    defer r.deinit(c.gpa);

    // Non-success: report the redacted error and exit non-zero.
    if (!(r.status == 200 and json.bodySuccess(c.gpa, r.body))) {
        try kv(stdout, style, "connection", "FAILED");
        const shown = try json.redactAlloc(c.gpa, r.body, c.api_key);
        try stderr.print("  HTTP {d}: {s}\n", .{ r.status, shown });
        return 1;
    }
    try kv(stdout, style, "connection", "OK");
    return 0;
}

// The test root references every module (refAllDecls forces semantic analysis
// of each public declaration), so `zig build test` compile-checks the whole
// tree — without this, a type error in an unreferenced module would pass.
test {
    std.testing.refAllDecls(@import("spec.zig"));
    std.testing.refAllDecls(@import("cli.zig"));
    std.testing.refAllDecls(@import("config.zig"));
    std.testing.refAllDecls(@import("help.zig"));
    std.testing.refAllDecls(@import("output.zig"));
    std.testing.refAllDecls(@import("client.zig"));
    std.testing.refAllDecls(@import("resources/transactions.zig"));
    std.testing.refAllDecls(@import("resources/receipts.zig"));
    std.testing.refAllDecls(@import("resources/postings.zig"));
    std.testing.refAllDecls(@import("resources/accounts.zig"));
    std.testing.refAllDecls(@import("util/http.zig"));
    std.testing.refAllDecls(@import("util/json.zig"));
    std.testing.refAllDecls(@import("util/money.zig"));
    std.testing.refAllDecls(@import("util/ui.zig"));
}
