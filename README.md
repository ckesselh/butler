```
 _           _   _
| |__  _   _| |_| | ___ _ __
| '_ \| | | | __| |/ _ \ '__|
| |_) | |_| | |_| |  __/ |
|_.__/ \__,_|\__|_|\___|_|

                  …your books, at your service.
```

# butler

A small, fast command-line client for the API of
[BuchhaltungsButler](https://www.buchhaltungsbutler.de/) (BHB), a German cloud
bookkeeping SaaS — list, search, and book entries from your terminal or
scripts, in an AWS/`gh`-style `resource verb` grammar.

```console
$ butler postings list --date-from 2026-05-01 --date-to 2026-05-31 --postingaccount 3790
$ butler transactions list --filter ACME
$ butler receipts show 162
$ butler postings create --from-json payroll.json --clearing 3790 --dry-run
```

> **Unofficial.** This is an independent client and is not affiliated with or
> endorsed by BuchhaltungsButler GmbH. Use at your own risk; you are responsible
> for what you post to your books.

## Why

The BHB web UI is fine for ad-hoc work, but repetitive or scripted bookkeeping
(recurring journal entries, bulk receipt uploads, reconciliation queries) wants
a CLI. `butler` is a single statically-linkable Zig binary with **no runtime
dependencies** — no Python, no Node, no `curl` — that wraps the REST API behind
a consistent, scriptable interface with `--output json` for piping into `jq`.

## Features

- `resource verb` command grammar modelled on `gh` / `az`.
- Resources: **transactions**, **receipts**, **postings** (alias `bookings`), **accounts**.
- Read: `list` (with filters), `--filter` substring search, `show <id>`.
- Write: `create` (single or multi-line split via JSON), `delete`, `upload`, `unconfirm`.
- `--output table` (aligned) or `--output json` (raw, pipe to `jq`).
- AWS-style profiles and credential precedence (env → file).
- **Write safety:** `--dry-run` prints the exact request payload (api_key
  redacted) and sends nothing; postings are created **confirmed** but unfixed,
  so they stay reviewable/editable in the web UI before you lock them.

## Install

`butler` compiles to a single self-contained binary. The **only** build
requirement is the **Zig 0.16.x** compiler — there are no other dependencies.

**Supported platforms:** Linux and macOS. Windows is not supported.

### From source (no Nix required)

1. **Install Zig 0.16.x.**
   - Download the prebuilt toolchain for your OS from
     <https://ziglang.org/download/> (pick a `0.16.x` release), unpack it, and
     put the `zig` binary on your `PATH`; or
   - use a package manager — `brew install zig` (macOS), `sudo pacman -S zig`
     (Arch), etc.
   - Verify: `zig version` should print `0.16.x`.
2. **Build:**
   ```console
   $ zig build                 # produces ./zig-out/bin/butler
   $ ./zig-out/bin/butler --help
   ```
3. **Put it on your `PATH`:**
   ```console
   $ install -Dm755 zig-out/bin/butler ~/.local/bin/butler
   # or system-wide:  sudo cp zig-out/bin/butler /usr/local/bin/
   ```
   (Make sure the target directory is on your `PATH`.)

During development: `zig build run -- <args>` and `zig build test`.

### With Nix (optional)

If you use Nix, the flake builds and runs butler without installing Zig:

```console
$ nix build .#butler         # binary at ./result/bin/butler
$ nix run   .#butler -- --help
```

## Authentication

`butler` needs three values from your BHB account
(Einstellungen → API): an **API client id**, an **API client secret** (sent as
HTTP Basic auth), and an **API key** (sent in each request body).

Store them once:

```console
$ butler login
Configuring profile 'default'.
API Client: my_company
API Secret: ********
API Key:    ********
saved to ~/.config/butler/credentials (0600)
```

This writes `~/.config/butler/credentials` (mode `0600`) in an INI format:

```ini
[default]
api_client = my_company
api_secret = ...
api_key    = ...
```

### Credential precedence

Highest to lowest:

1. environment — `BUTLER_API_CLIENT`, `BUTLER_API_SECRET`, `BUTLER_API_KEY`
2. the `[profile]` section of `~/.config/butler/credentials`

`XDG_CONFIG_HOME` is honoured. Select a non-default profile with
`--profile <name>`.

## Usage

```
butler <resource> <verb> [flags]
```

A required identifier is a positional argument (`show <id>`, `upload <file>`,
`receipts list <inbound|outbound>`); everything else is a flag. The data
resources are `transactions`, `receipts`, `postings` (alias `bookings`) and
`accounts`; plus `status`, `login` and `logout`.

**Full command reference** — every resource, verb, flag and value — lives in
**[docs/commands.md](docs/commands.md)**, or run `man butler`, `butler --help`
and `butler <resource> <verb> --help`. The examples below cover the common
cases.

### Reading

```console
# all postings in May touching the payroll clearing account
$ butler postings list --date-from 2026-05-01 --date-to 2026-05-31 --postingaccount 3790

# substring search over the listed columns
$ butler transactions list --filter ACME --date-from 2026-05-01 --date-to 2026-05-31

# one entry by id
$ butler transactions show 417

# inbound receipts, as JSON for jq
$ butler receipts list inbound --date-from 2026-05-01 --date-to 2026-05-31 --output json | jq '.data[].counterparty'

# the chart of accounts
$ butler accounts list --filter Verrechnung
```

### Writing

A single free posting:

```console
$ butler postings create \
    --date 2026-05-31 --debit 6020 --credit 3790 \
    --amount 5000.00 --vat 0_none --text "Gehalt 05/2026" \
    --dry-run
```

A multi-line split booking from a JSON file (amounts are **strings**, always
positive — direction comes from the debit/credit pair):

```json
[
  {"date":"2026-05-31","postingtext":"Gehalt 05/2026","amount":"5000.00","debit":6020,"credit":3790,"vat":"0_none"},
  {"date":"2026-05-31","postingtext":"Auszahlung",     "amount":"5000.00","debit":3790,"credit":3720,"vat":"0_none"}
]
```

```console
# preview the exact payloads and verify the clearing account balances to zero
$ butler postings create --from-json booking.json --clearing 3790 --dry-run

# send it (created confirmed; review/lock in the web UI)
$ butler postings create --from-json booking.json --clearing 3790
```

`--clearing <account>` asserts the named account nets to zero across the lines
before anything is sent. Postings are created **confirmed** (visible to the API
and the UI, still unfixed so they remain editable/deletable in the UI). To stage
one for UI-only review instead, unconfirm it afterwards with
`butler postings unconfirm <id>` — but note that an **unconfirmed posting is
invisible to the API** (BHB ticket 443636), so you can no longer list it.

Upload a receipt:

```console
$ butler receipts upload invoice.pdf --type "invoice inbound" \
    --counterparty "ACME GmbH" --invoice-number INV-123 --date 2026-05-31 --amount -42.00
```

## Output & exit codes

- `--output table` renders aligned columns; `--output json` emits the raw API
  body for piping into `jq` (for `show`, just the matched record). `--filter`
  is a table-mode feature — combining it with `--output json` is a usage
  error (filter JSON with `jq` instead).
- Exit `0` on success, `1` on an API/HTTP error, `2` on a usage error.

## Known limitations

The BHB API has a number of non-obvious quirks (symbolic VAT codes, exclusive id
ranges, get-by-id routes that 404, no posting-delete endpoint, …). They are
documented in **[docs/bhb-api-quirks.md](docs/bhb-api-quirks.md)**, alongside a
pointer to the official OpenAPI spec
(<https://app.buchhaltungsbutler.de/docs/api/v1.de.json>).

## Development

```console
$ zig build              # build (and install the man page under zig-out)
$ zig build test         # run unit tests
$ zig build run -- ...   # build & run
$ zig build gen-docs     # regenerate man/butler.1 + docs/commands.md from the spec
```

The whole command surface — every resource, verb, flag and its help text — is
defined once in [`src/spec.zig`](src/spec.zig). The argv parser, the `--help`
text, the man page and [`docs/commands.md`](docs/commands.md) are all rendered
from that single source, so adding or changing a flag is one edit. Source is
grouped into `src/` (CLI, dispatch, rendering), `src/resources/` (one module
per resource) and `src/util/` (domain-agnostic helpers: HTTP, JSON, money,
ANSI). Individual files carry a header comment describing their role.

The build is intentionally **dependency-free and offline**: only the Zig
standard library is used (`std.http.Client` for HTTPS, `std.json`,
`std.crypto`), so a build never touches the network — no package manager or
lockfile to fetch.

## Contributing

The command surface is **data**. To add or change a resource, verb or flag,
edit [`src/spec.zig`](src/spec.zig) — that one table drives the parser, `--help`,
the man page and `docs/commands.md`. Then regenerate the docs and run the
quality gates before pushing:

```console
$ zig build gen-docs                          # regenerate man page + reference
$ zig fmt --check src/ tools/ build.zig
$ zig build test
```

With [Task](https://taskfile.dev) installed, `task docs` and `task check` wrap
the same commands (see `Taskfile.yml`; the lint task additionally runs zlint).
CI runs all of these plus cross-compile checks on Linux and macOS.

### Releasing

1. Bump `version` in `build.zig.zon` (authoritative) and `package.nix`, and
   `doc_date` in `tools/gendoc.zig`.
2. `zig build gen-docs` and commit the regenerated `man/butler.1` and
   `docs/commands.md`.
3. Update [CHANGELOG.md](CHANGELOG.md) and tag `v<version>`.

## License

MIT — see [LICENSE](LICENSE).
