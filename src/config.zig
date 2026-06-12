//! Credential storage and lookup: BUTLER_* environment variables over an
//! INI-style credentials file under $XDG_CONFIG_HOME/butler (mode 0600,
//! written atomically). Allocation-correct on any allocator — no arena
//! assumptions in this module.

const std = @import("std");

pub const default_base = "https://webapp.buchhaltungsbutler.de/api/v1";

/// One profile's credentials. All three fields are heap-owned by the caller
/// (that is why `deinit` exists); see `loadProfile`.
pub const Profile = struct {
    api_client: []u8,
    api_secret: []u8,
    api_key: []u8,

    pub fn deinit(self: *Profile, gpa: std.mem.Allocator) void {
        gpa.free(self.api_client);
        gpa.free(self.api_secret);
        gpa.free(self.api_key);
    }
};

/// Env lookup via the process environ map. Missing or set-but-empty -> null:
/// an exported-but-empty BUTLER_* must fall through to the file, not shadow it
/// with "". The returned slice aliases the environ map (process lifetime).
pub fn getEnv(env: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const v = env.get(name) orelse return null;
    return if (v.len == 0) null else v;
}

/// ~/.config/butler (honors XDG_CONFIG_HOME). Caller owns the result.
pub fn configDir(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (getEnv(env, "XDG_CONFIG_HOME")) |x| {
        return std.fs.path.join(gpa, &.{ x, "butler" });
    }
    const home = getEnv(env, "HOME") orelse return error.NoHome;
    return std.fs.path.join(gpa, &.{ home, ".config", "butler" });
}

/// Strip an optional `profile ` prefix from a bracketed section name.
fn bareSection(name: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, name, "profile "))
        std.mem.trim(u8, name["profile ".len..], " \t")
    else
        name;
}

/// If `line` is a `[section]` header, return its bare name; else null.
fn sectionHeader(line: []const u8) ?[]const u8 {
    if (line.len >= 2 and line[0] == '[' and line[line.len - 1] == ']') {
        return bareSection(std.mem.trim(u8, line[1 .. line.len - 1], " \t"));
    }
    return null;
}

fn findInSection(text: []const u8, section: []const u8, key: []const u8) ?[]const u8 {
    var in_section = false;
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (sectionHeader(line)) |name| {
            in_section = std.mem.eql(u8, name, section);
            continue;
        }
        if (!in_section) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const k = std.mem.trim(u8, line[0..eq], " \t");
        if (std.mem.eql(u8, k, key)) return std.mem.trim(u8, line[eq + 1 ..], " \t");
    }
    return null;
}

/// Resolve credentials for `profile`. Precedence: env BUTLER_* over file.
/// Rejects a credentials file that is group/world-accessible.
pub fn loadProfile(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    profile: []const u8,
) !Profile {
    // Env wins: read each credential from BUTLER_* first.
    var client: ?[]u8 = if (getEnv(env, "BUTLER_API_CLIENT")) |v| try gpa.dupe(u8, v) else null;
    errdefer if (client) |s| gpa.free(s);
    var secret: ?[]u8 = if (getEnv(env, "BUTLER_API_SECRET")) |v| try gpa.dupe(u8, v) else null;
    errdefer if (secret) |s| gpa.free(s);
    var key: ?[]u8 = if (getEnv(env, "BUTLER_API_KEY")) |v| try gpa.dupe(u8, v) else null;
    errdefer if (key) |s| gpa.free(s);

    // Fall back to the credentials file for anything env didn't supply. Only
    // a genuinely absent dir/file means "no stored credentials" — anything
    // else (permissions, I/O) must surface, not masquerade as a missing key.
    if (client == null or secret == null or key == null) {
        const dir = try configDir(gpa, env);
        defer gpa.free(dir);
        const opened: ?std.Io.Dir = std.Io.Dir.cwd().openDir(io, dir, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => null,
            else => return err,
        };
        if (opened) |dd| {
            defer dd.close(io);
            const stat_result: ?std.Io.Dir.Stat = if (dd.statFile(io, "credentials", .{})) |st| st else |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            if (stat_result) |st| {
                // Refuse a group/world-readable credentials file.
                if ((st.permissions.toMode() & 0o077) != 0) return error.InsecureCredentialsFile;
                const text = try dd.readFileAlloc(io, "credentials", gpa, .limited(1 << 16));
                defer gpa.free(text);

                // Pull each still-missing field from the profile's section.
                if (client == null) {
                    if (findInSection(text, profile, "api_client")) |v| client = try gpa.dupe(u8, v);
                }
                if (secret == null) {
                    if (findInSection(text, profile, "api_secret")) |v| secret = try gpa.dupe(u8, v);
                }
                if (key == null) {
                    if (findInSection(text, profile, "api_key")) |v| key = try gpa.dupe(u8, v);
                }
            }
        }
    }

    // Require all three fields; report which one is missing.
    return .{
        .api_client = client orelse return error.MissingApiClient,
        .api_secret = secret orelse return error.MissingApiSecret,
        .api_key = key orelse return error.MissingApiKey,
    };
}

/// base64("client:secret") for HTTP Basic auth. Caller owns the result.
pub fn basicAuth(gpa: std.mem.Allocator, client: []const u8, secret: []const u8) ![]u8 {
    const raw = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ client, secret });
    defer gpa.free(raw);
    const enc = std.base64.standard.Encoder;
    const out = try gpa.alloc(u8, enc.calcSize(raw.len));
    _ = enc.encode(out, raw);
    return out;
}

fn hasControl(s: []const u8) bool {
    for (s) |c| {
        if (c == '\n' or c == '\r') return true;
    }
    return false;
}

/// Create/replace a `[profile]` section, written atomically (temp + rename) at
/// mode 0600. Rejects values containing newlines or a profile name with INI
/// metacharacters (would corrupt the file / inject sections).
pub fn saveProfile(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    profile: []const u8,
    api_client: []const u8,
    api_secret: []const u8,
    api_key: []const u8,
) !void {
    // Reject inputs that would corrupt the INI file or inject sections, plus
    // names that would not round-trip through the reader: a leading
    // "profile " (bareSection strips it), surrounding whitespace
    // (sectionHeader trims it), and the empty name.
    if (profile.len == 0 or
        hasControl(profile) or
        std.mem.indexOfAny(u8, profile, "[]") != null or
        std.mem.startsWith(u8, profile, "profile ") or
        !std.mem.eql(u8, profile, std.mem.trim(u8, profile, " \t")))
        return error.InvalidProfileName;
    if (hasControl(api_client) or hasControl(api_secret) or hasControl(api_key)) return error.InvalidCredentialValue;

    // Ensure the config directory exists.
    const dir = try configDir(gpa, env);
    defer gpa.free(dir);
    var d = try std.Io.Dir.cwd().createDirPathOpen(io, dir, .{});
    defer d.close(io);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    // Copy the existing file forward, dropping the section we're replacing.
    // Only a missing file may be ignored: any other read failure (permissions,
    // I/O, a file over the size cap) would otherwise silently DROP every other
    // profile when the rename below replaces the file.
    if (d.readFileAlloc(io, "credentials", gpa, .limited(1 << 16))) |text| {
        defer gpa.free(text);
        var skip = false;
        // trimRight: the final newline would otherwise yield an empty trailing
        // segment, accreting one blank line per save.
        const body = std.mem.trimEnd(u8, text, "\n");
        if (body.len > 0) {
            var it = std.mem.splitScalar(u8, body, '\n');
            while (it.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (sectionHeader(trimmed)) |name| skip = std.mem.eql(u8, name, profile);
                if (!skip) {
                    try out.appendSlice(gpa, line);
                    try out.append(gpa, '\n');
                }
            }
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    // Append the fresh section.
    try out.print(gpa, "[{s}]\napi_client = {s}\napi_secret = {s}\napi_key = {s}\n", .{ profile, api_client, api_secret, api_key });

    // Atomic: write temp 0600, then rename over the real file. Delete any
    // stale temp first — createFile's permissions only apply on creation, so
    // an old looser-mode leftover would survive into the rename.
    d.deleteFile(io, "credentials.tmp") catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    errdefer d.deleteFile(io, "credentials.tmp") catch {};
    {
        var f = try d.createFile(io, "credentials.tmp", .{ .truncate = true, .permissions = .fromMode(0o600) });
        defer f.close(io);
        try f.writeStreamingAll(io, out.items);
    }
    try d.rename("credentials.tmp", d, "credentials", io);
}

test "section parsing" {
    const text = "[default]\napi_client = abc\n[profile other]\napi_key = xyz\n";
    try std.testing.expectEqualStrings("abc", findInSection(text, "default", "api_client").?);
    try std.testing.expectEqualStrings("xyz", findInSection(text, "other", "api_key").?);
    try std.testing.expectEqual(@as(?[]const u8, null), findInSection(text, "default", "api_key"));
}
