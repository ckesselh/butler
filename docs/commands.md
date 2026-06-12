# butler command reference

Generated from `src/spec.zig` by `zig build gen-docs` — do not edit by hand.
This is the same source the `--help` text and the `man butler` page render
from. butler 0.1.0.

```
butler <resource> <verb> [flags]
```

## Contents

- [Global flags](#global-flags)
- [**transactions**](#transactions)
  - [`list`](#list)
  - [`show`](#show)
- [**receipts**](#receipts)
  - [`list`](#list-1)
  - [`show`](#show-1)
  - [`upload`](#upload)
  - [`delete`](#delete)
- [**postings**](#postings)
  - [`list`](#list-2)
  - [`create`](#create)
  - [`unconfirm`](#unconfirm)
  - [`delete`](#delete-1)
- [**accounts**](#accounts)
  - [`list`](#list-3)
- [**status**](#status)
- [**login**](#login)
- [**logout**](#logout)

---

## Global flags

- `--profile <name>` — credentials profile (default: default)
- `--output <table|json>` — output format (default: table). Values: `table`, `json`
- `--api-base <url>` — override API base URL (https unless --insecure)
- `--debug` — print the request line to stderr
- `--insecure` — allow sending credentials over a non-HTTPS api-base
- `--help` — show help; per command: `<resource> <verb> --help`
- `--version` — print the butler version

---

## transactions

bank transactions (list, show)

### `list`

list transactions (with filters)

```
butler transactions list [flags]
```

**Flags:**

- `--date-from <YYYY-MM-DD>` — earliest booking date
- `--date-to <YYYY-MM-DD>` — latest booking date
- `--account <n>` — bank account number
- `--to-from <text>` — counterparty filter (server-side)
- `--id-from <n>` — lowest id (exclusive)
- `--id-to <n>` — highest id (exclusive)
- `--filter <text>` — case-insensitive substring over the shown columns
- `--limit <n>` — max rows
- `--offset <n>` — skip the first n rows

### `show`

a single transaction

```
butler transactions show <id>
```

**Arguments:**

- `id` — transaction id_by_customer

Show a single transaction by its id_by_customer.

---

## receipts

receipts / documents (list, show, upload, delete)

### `list`

list receipts (with filters)

```
butler receipts list <inbound|outbound> [flags]
```

**Arguments:**

- `inbound|outbound` — receipt direction (required)

**Flags:**

- `--counterparty <text>` — counterparty filter
- `--date-from <YYYY-MM-DD>` — earliest date
- `--date-to <YYYY-MM-DD>` — latest date
- `--payment-status <s>` — e.g. paid | unpaid
- `--invoice-number <s>` — invoice number filter
- `--due-date <YYYY-MM-DD>` — due-date filter
- `--include-offers` — include offers
- `--deleted` — include deleted receipts
- `--filter <text>` — case-insensitive substring over the shown columns
- `--limit <n>` — max rows
- `--offset <n>` — skip the first n rows

### `show`

a single receipt

```
butler receipts show <id> [--direction inbound|outbound]
```

**Arguments:**

- `id` — receipt id_by_customer

**Flags:**

- `--direction <inbound|outbound>` — narrow the lookup. Values: `inbound`, `outbound`

Show a single receipt by its id_by_customer.

BHB's get-by-id route returns HTTP 404 (server-side bug), so butler looks
the id up via the list endpoint; at most 500 receipts per direction are
searched. Pass --direction to narrow the lookup.

### `upload`

upload a receipt file

```
butler receipts upload <file> --type <type> [flags]
```

**Arguments:**

- `file` — path to the receipt file

**Flags:**

- `--type <type>` — receipt type, e.g. "invoice inbound" *(required)*
- `--counterparty <text>` — counterparty
- `--invoice-number <s>` — invoice number
- `--date <YYYY-MM-DD>` — document date
- `--amount <n>` — gross amount
- `--vat-rate <n>` — vat rate
- `--dry-run` — print what would be sent, send nothing

### `delete`

delete a receipt

```
butler receipts delete <id>
```

**Arguments:**

- `id` — receipt id_by_customer

Delete a receipt by its id_by_customer.

---

## postings

extended bookings (list, create, unconfirm), alias: bookings

Aliases: `bookings`

### `list`

list postings (with filters)

```
butler postings list --date-from D --date-to D [flags]
```

**Flags:**

- `--date-from <YYYY-MM-DD>` — earliest date *(required)*
- `--date-to <YYYY-MM-DD>` — latest date *(required)*
- `--account <csv>` — accounts filter (e.g. "free booking")
- `--postingaccount <csv>` — posting-account filter (e.g. 3790)
- `--status <s>` — all | fixed | unfixed
- `--order <s>` — e.g. "date ASC"
- `--cost-location <s>` — cost location filter
- `--filter <text>` — case-insensitive substring over the shown columns
- `--limit <n>` — max rows
- `--offset <n>` — skip the first n rows

### `create`

create a posting / split booking

```
butler postings create (--from-json <file> | <line flags>) [flags]
```

**Flags:**

- `--from-json <file>` — JSON array of split lines (see FORMAT)
- `--date <YYYY-MM-DD>` — single line: date
- `--debit <acct>` — single line: debit account
- `--credit <acct>` — single line: credit account
- `--amount <n>` — single line: positive amount, e.g. 5000.00
- `--vat <code>` — single line: vat code. Values: `0_none`, `19_vat`, `7_vat`, `19_pre`, `7_pre`, `19_both_1`, `19_both_2`, `7_both`, `19_both_1_no_pre`, `19_both_2_no_pre`, `7_both_no_pre`, `19_pre_app`, `7_pre_app`, `19_both_app_1`, `19_both_app_2`, `7_both_app`
- `--text <s>` — single line: posting text
- `--cost-location <s>` — optional cost location
- `--clearing <acct>` — assert this account nets to zero before sending
- `--dry-run` — print the redacted payload, send nothing

New postings are created CONFIRMED (visible to the API and the web UI,
still unfixed so they stay editable/deletable in the UI). To stage one
for UI-only review, unconfirm it afterwards: butler postings unconfirm <id>.

--from-json FORMAT
  [ {"date":"2026-05-31","postingtext":"...","amount":"5000.00",
     "debit":6020,"credit":3790,"vat":"0_none"} , ... ]

### `unconfirm`

set a posting back to unconfirmed

```
butler postings unconfirm <id>
```

**Arguments:**

- `id` — posting id

Set a free posting back to unconfirmed by its posting id.

### `delete`

not supported by the BHB API (explains the web-UI path)

```
butler postings delete [id]
```

**Arguments:**

- `id` — posting id (unused — deletion is web-UI only)

The BHB API has no posting-delete endpoint; this command only explains
that deletion must happen in the web UI, and exits with a usage error.

---

## accounts

chart of accounts (list)

### `list`

list the chart of accounts (postingaccounts)

```
butler accounts list [flags]
```

**Flags:**

- `--filter <text>` — case-insensitive substring over the shown columns
- `--limit <n>` — max rows
- `--offset <n>` — skip the first n rows

---

## status

test API connectivity and show client info

Probe the BHB API (authenticated) and print the api base, profile, and butler/API
versions. Exits non-zero if the call fails.

---

## login

store credentials for a profile

Prompt for api_client / api_secret / api_key and store them in
$XDG_CONFIG_HOME/butler/credentials (default ~/.config/butler/credentials),
mode 0600.

---

## logout

explain how to remove a profile's credentials

Explains how to remove a profile's [section] from the credentials file
($XDG_CONFIG_HOME/butler/credentials, default ~/.config/butler/credentials).
