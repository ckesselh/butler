# butler command reference

Generated from `src/spec.zig` by `zig build gen-docs` — do not edit by hand.
This is the same source the `--help` text and the `man butler` page render
from. butler 0.2.0.

```
butler <resource> <verb> [flags]
```

## Contents

- [Global flags](#global-flags)
- [**transactions**](#transactions)
  - [`list`](#list)
  - [`show`](#show)
  - [`book`](#book)
  - [`settle`](#settle)
  - [`link`](#link)
  - [`unlink`](#unlink)
  - [`receipts`](#receipts)
- [**receipts**](#receipts-1)
  - [`list`](#list-1)
  - [`show`](#show-1)
  - [`upload`](#upload)
  - [`delete`](#delete)
  - [`book`](#book-1)
  - [`pay`](#pay)
- [**bookings**](#bookings)
  - [`list`](#list-2)
  - [`add`](#add)
  - [`unconfirm`](#unconfirm)
  - [`assign`](#assign)
  - [`delete`](#delete-1)
- [**accounts**](#accounts)
  - [`list`](#list-3)
  - [`show`](#show-2)
  - [`add`](#add-1)
  - [`update`](#update)
- [**creditors**](#creditors)
  - [`list`](#list-4)
  - [`show`](#show-3)
  - [`add`](#add-2)
  - [`update`](#update-1)
- [**debtors**](#debtors)
  - [`list`](#list-5)
  - [`show`](#show-4)
  - [`add`](#add-3)
  - [`update`](#update-2)
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

bank transactions (list, show, book, settle, link, unlink, receipts)

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
- `--unbooked` — only payments with no posting of any class — UI "Ungebucht" (needs the date window)
- `--missing-receipt` — only payments no posting carries a receipt for — UI "Fehlender Beleg" (needs the date window)
- `--filter <text>` — case-insensitive substring over the shown columns
- `--limit <n>` — max rows
- `--offset <n>` — skip the first n rows

The open-items filters mirror the "Zahlungen" screen and anti-join a
second /postings/get sweep over the window:
  --unbooked         no posting of any class references the payment
                     (keys on posting linkage, not receipt assignment, so
                     a receipt-less but booked payment like salary/tax is
                     correctly treated as booked).
  --missing-receipt  no posting carries a receipt for the payment — the
                     "Fehlender Beleg" case. A superset of --unbooked, since
                     an unbooked payment has no receipt either.
Because /postings/get caps at 1000 rows, keep the window bounded or items
past the cap may show as falsely open.

### `show`

a single transaction

```
butler transactions show <id>
```

**Arguments:**

- `id` — transaction id_by_customer

Show a single transaction by its id_by_customer.

### `book`

book a payment directly onto account(s), no receipt

```
butler transactions book <tx> (--account A --amount N --vat V --text T | --from-json <file>)
```

**Arguments:**

- `tx` — transaction id_by_customer

**Flags:**

- `--from-json <file>` — JSON array of {account, postingtext, vat, amount} split lines
- `--account <acct>` — single line: posting account (e.g. 3841)
- `--amount <n>` — single line: positive amount, e.g. 9.70
- `--vat <code>` — single line: vat code. Values: `0_none`, `19_vat`, `7_vat`, `19_pre`, `7_pre`, `19_both_1`, `19_both_2`, `7_both`, `19_both_1_no_pre`, `19_both_2_no_pre`, `7_both_no_pre`, `19_pre_app`, `7_pre_app`, `19_both_app_1`, `19_both_app_2`, `7_both_app`
- `--text <s>` — single line: posting text
- `--dry-run` — print the redacted payload, send nothing

Posts directly onto a bank transaction (/postings/add/transaction) — the
web UI "book on a payment" action, no receipt involved. The transaction
is the contra side, so you give only the account(s) being charged: a
single --account books the whole payment, or --from-json splits it across
accounts. New postings land confirmed (see `bookings add`). The booking
is a transaction-class posting, so it shows under `--account
"all financial accounts"`, not under "Erweitertes Buchen".

### `settle`

settle booked receipt(s) against a payment

```
butler transactions settle <tx> --receipts <id,id,...> [--dry-run]
```

**Arguments:**

- `tx` — transaction id_by_customer

**Flags:**

- `--receipts <csv>` — receipt id_by_customer(s), comma-separated *(required)*
- `--dry-run` — print the derived payload, send nothing

Payment-first settlement: clears the open items of the listed receipts by
posting one creditor->bank line each, in a single /postings/add/transaction
that marks them paid. Use when one payment covers several invoices; the
receipt amounts must sum to the transaction (the API rejects a mismatch).
For a single receipt, `receipts pay <id> --with <tx>` reads more naturally.

### `link`

link a receipt to a transaction (no booking)

```
butler transactions link <tx> <receipt>
```

**Arguments:**

- `tx` — transaction id_by_customer
- `receipt` — receipt id_by_customer

A soft pointer (/transactions/assign/receipt): it sets the payment date but
does NOT settle — no posting, the receipt stays unpaid. To actually settle, use
`transactions settle` / `receipts pay`.

### `unlink`

remove a receipt link from a transaction

```
butler transactions unlink <tx> <receipt>
```

**Arguments:**

- `tx` — transaction id_by_customer
- `receipt` — receipt id_by_customer

Inverse of `link`. The API rejects it (error 10) once a confirmed posting
exists on the link.

### `receipts`

list receipts assigned to a transaction

```
butler transactions receipts <tx> [--confirmed-only]
```

**Arguments:**

- `tx` — transaction id_by_customer

**Flags:**

- `--confirmed-only` — only confirmed assignments
- `--filter <text>` — case-insensitive substring over the shown columns

---

## receipts

receipts / documents (list, show, upload, delete, book, pay)

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
- `--unbooked` — only receipts with no posting referencing them — UI "Ungebucht" (needs the date window)
- `--unpaid` — only unpaid receipts — UI "Unbezahlt" (shorthand for --payment-status unpaid)
- `--filter <text>` — case-insensitive substring over the shown columns
- `--limit <n>` — max rows
- `--offset <n>` — skip the first n rows

Two distinct open-items filters, matching the "Eingangsbelege" screen:
  --unbooked  ("Ungebucht") no posting references the receipt over the
              window — a /postings/get sweep + id anti-join.
  --unpaid    ("Unbezahlt") the receipt's own payment status is unpaid
              (server-side; same as --payment-status unpaid).
They are NOT the same: a receipt can be booked yet unpaid, or paid yet
(rarely) unbooked. --unbooked caps at /postings/get's 1000 rows, so keep
the window bounded.

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
- `--credit-note` — a Gutschrift: send --amount negative (BHB reverses the booking)
- `--dry-run` — print what would be sent, send nothing

### `delete`

delete a receipt

```
butler receipts delete <id>
```

**Arguments:**

- `id` — receipt id_by_customer

Delete a receipt by its id_by_customer.

### `book`

book a receipt onto account(s)

```
butler receipts book <id> (--account A --amount N --vat V --text T | --from-json <file>) [--creditor C | --debtor D]
```

**Arguments:**

- `id` — receipt id_by_customer

**Flags:**

- `--from-json <file>` — JSON array of {account, postingtext, vat, amount} split lines
- `--account <acct>` — single line: posting account (e.g. 6815)
- `--amount <n>` — single line: positive amount, e.g. 36.97
- `--vat <code>` — single line: vat code. Values: `0_none`, `19_vat`, `7_vat`, `19_pre`, `7_pre`, `19_both_1`, `19_both_2`, `7_both`, `19_both_1_no_pre`, `19_both_2_no_pre`, `7_both_no_pre`, `19_pre_app`, `7_pre_app`, `19_both_app_1`, `19_both_app_2`, `7_both_app`
- `--text <s>` — single line: posting text
- `--creditor <acct>` — creditor Sammelkonto (inbound invoice)
- `--debtor <acct>` — debtor Sammelkonto (outbound invoice)
- `--dry-run` — print the redacted payload, send nothing

Books a receipt (/postings/add/receipt): the account line(s) for the
expense/revenue. The counterparty Sammelkonto defaults to the standard
Kreditoren-Sammelkonto (70000); pass --creditor for a dedicated creditor,
or --debtor for an outbound invoice (Debitoren-Sammelkonto 10000). Then
settle it against the payment with `receipts pay <id> --with <tx>`.

### `pay`

settle a booked receipt against a bank payment

```
butler receipts pay <id> --with <tx> [flags]
```

**Arguments:**

- `id` — receipt id_by_customer

**Flags:**

- `--with <tx>` — the bank transaction id_by_customer that pays it *(required)*
- `--amount <n>` — part-payment amount (default: the receipt's open amount)
- `--account <acct>` — override the creditor account (default: from the receipt's booking)
- `--text <s>` — posting text (default: counterparty + invoice number)
- `--dry-run` — print the derived payload, send nothing

Mirrors the UI "Beleg einer Zahlung zuordnen": it settles the receipt's
open item by posting the creditor->bank line carrying the receipt
(/postings/add/transaction with the receipt as an open item), which marks
it paid. The account, amount and text are resolved from the receipt's own
booking, so the happy path is just the two ids. This is NOT
/transactions/assign/receipt, which only links without settling.

---

## bookings

bookings: add (free/extended), list, unconfirm, assign, delete; alias: postings

Aliases: `postings`

### `list`

list bookings (with filters)

```
butler bookings list --date-from D --date-to D [flags]
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

Columns include a decoded `tax`: the posting's numeric tax_key mapped to
BHB's documented vat-code label (e.g. "i.g.E. 19% USt./VSt. [19]"). The
numeric key is undocumented, so the mapping is a best-effort, empirically
derived bridge — the raw key stays in brackets and an unmapped key shows
as "[N] ?unmapped", so a wrong/missing label can never hide it. Also
`fixed` (yes = festgeschrieben/locked, no = still editable), `receipt`
(assigned invoice number, or — if none) and `tx` (linked bank
transaction id, or —). The debit/credit accounts resolve to "NNNN Name"
(table columns; sibling *_name fields under --output json).

### `add`

add a free (extended) booking / split

```
butler bookings add (--from-json <file> | <line flags>) [flags]
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

This is the FREE booking class ("Erweitertes Buchen") — not anchored to a
receipt or transaction; for those see `receipts book` / `transactions book`.
New bookings are created CONFIRMED (visible to the API and the web UI,
still unfixed so they stay editable/deletable in the UI). To stage one
for UI-only review, unconfirm it afterwards: butler bookings unconfirm <id>.

--from-json FORMAT
  [ {"date":"2026-05-31","postingtext":"...","amount":"5000.00",
     "debit":6020,"credit":3790,"vat":"0_none"} , ... ]

### `unconfirm`

set a free booking back to unconfirmed

```
butler bookings unconfirm <id>
```

**Arguments:**

- `id` — posting id

Set a free booking back to unconfirmed by its posting id.

### `assign`

link a receipt to a free booking

```
butler bookings assign <receipt-id> <posting-id>
```

**Arguments:**

- `receipt-id` — receipt id_by_customer
- `posting-id` — posting id_by_customer

Assign a receipt to an existing free booking
(/postings/assign/receipt-to-free-posting) — e.g. a booking made before its
receipt arrived.

### `delete`

not supported by the BHB API (explains the web-UI path)

```
butler bookings delete [id]
```

**Arguments:**

- `id` — posting id (unused — deletion is web-UI only)

The BHB API has no posting-delete endpoint; this command only explains
that deletion must happen in the web UI, and exits with a usage error.

---

## accounts

chart of accounts (list, show, add, update)

### `list`

list the chart of accounts (postingaccounts)

```
butler accounts list [flags]
```

**Flags:**

- `--filter <text>` — case-insensitive substring over the shown columns
- `--limit <n>` — max rows
- `--offset <n>` — skip the first n rows

### `show`

a single account by its number

```
butler accounts show <account>
```

**Arguments:**

- `account` — postingaccount_number

Look up one account by its number among the chart of accounts
(/settings/get/postingaccounts) — the same set `accounts list` returns.
This covers Sachkonten and the cash/bank accounts, NOT creditors or
debtors; use `creditors show` / `debtors show` for those subledgers.
The lookup matches client-side (the API has no get-by-id route).

### `add`

create a postingaccount (Sachkonto)

```
butler accounts add <account> --name <s> --parent <n> [--dry-run]
```

**Arguments:**

- `account` — postingaccount_number to create

**Flags:**

- `--name <s>` — account name *(required)*
- `--parent <n>` — parent postingaccount_number (the chart node it nests under) *(required)*
- `--dry-run` — print the redacted payload, send nothing

Create a Sachkonto via /settings/add/postingaccount. The account number,
--name and --parent (the chart node it nests under) are all required.
No delete endpoint exists (see docs/bhb-api-quirks.md).

### `update`

rename a postingaccount by its number

```
butler accounts update <account> --name <s> [--dry-run]
```

**Arguments:**

- `account` — postingaccount_number

**Flags:**

- `--name <s>` — new account name *(required)*
- `--dry-run` — print the redacted payload, send nothing

Rename a Sachkonto via /settings/update/postingaccount (name is the only
updatable field the API takes here).

---

## creditors

creditors / Kreditoren (list, show, add, update)

### `list`

list creditors (Kreditoren)

```
butler creditors list [flags]
```

**Flags:**

- `--filter <text>` — case-insensitive substring over the shown columns
- `--limit <n>` — max rows
- `--offset <n>` — skip the first n rows

Creditor accounts (Kreditoren) from /settings/get/creditors. The dedicated
creditor account is in `postingaccount_number` — the value you pass to
`receipts book --creditor`.
Without --limit butler pages the endpoint to completion (the API defaults to
25 rows per page); pass --limit for a single bounded page. --offset skips the
first n rows in either mode.

### `show`

a single creditor by its account number

```
butler creditors show <account>
```

**Arguments:**

- `account` — creditor postingaccount_number

Look up one creditor by its account number (postingaccount_number);
the lookup pages the list endpoint, which has no get-by-id route.

### `add`

create a creditor (Kreditor)

```
butler creditors add --name <s> [--account n] [field flags] [--dry-run]
```

**Flags:**

- `--name <s>` — creditor name *(required)*
- `--account <n>` — postingaccount_number to assign (else auto-assigned)
- `--contact <s>` — contact person name
- `--street <s>` — street
- `--address2 <s>` — additional address line
- `--zip <s>` — postal / ZIP code
- `--city <s>` — city
- `--country <s>` — country
- `--vat-id <s>` — EU VAT id (sales_tax_id)
- `--email <s>` — email address
- `--iban <s>` — IBAN
- `--bic <s>` — BIC
- `--due-days <n>` — default payment term in days
- `--dry-run` — print the redacted payload, send nothing

Create a creditor via /settings/add/creditor. Only --name is required; omit
--account to let BHB assign the next free Kreditoren number. The API returns no
id — re-query with `creditors list --filter` / `creditors show`. No delete
endpoint exists (see docs/bhb-api-quirks.md).

### `update`

update a creditor by its account number

```
butler creditors update <account> [field flags] [--dry-run]
```

**Arguments:**

- `account` — creditor postingaccount_number

**Flags:**

- `--name <s>` — new creditor name
- `--contact <s>` — contact person name
- `--street <s>` — street
- `--address2 <s>` — additional address line
- `--zip <s>` — postal / ZIP code
- `--city <s>` — city
- `--country <s>` — country
- `--vat-id <s>` — EU VAT id (sales_tax_id)
- `--email <s>` — email address
- `--iban <s>` — IBAN
- `--bic <s>` — BIC
- `--due-days <n>` — default payment term in days
- `--dry-run` — print the redacted payload, send nothing

Update a creditor via /settings/update/creditor. Pass only the fields you want to change; omitted fields are left untouched.

---

## debtors

debtors / Debitoren (list, show, add, update)

### `list`

list debtors (Debitoren)

```
butler debtors list [flags]
```

**Flags:**

- `--filter <text>` — case-insensitive substring over the shown columns
- `--limit <n>` — max rows
- `--offset <n>` — skip the first n rows

Debtor accounts (Debitoren) from /settings/get/debtors. The dedicated
debtor account is in `postingaccount_number` — the value you pass to
`receipts book --debtor`.
Without --limit butler pages the endpoint to completion (the API defaults to
25 rows per page); pass --limit for a single bounded page. --offset skips the
first n rows in either mode.

### `show`

a single debtor by its account number

```
butler debtors show <account>
```

**Arguments:**

- `account` — debtor postingaccount_number

Look up one debtor by its account number (postingaccount_number);
the lookup pages the list endpoint, which has no get-by-id route.

### `add`

create a debtor (Debitor)

```
butler debtors add --name <s> [--account n] [field flags] [--dry-run]
```

**Flags:**

- `--name <s>` — debtor name *(required)*
- `--account <n>` — postingaccount_number to assign (else auto-assigned)
- `--contact <s>` — contact person name
- `--street <s>` — street
- `--address2 <s>` — additional address line
- `--zip <s>` — postal / ZIP code
- `--city <s>` — city
- `--country <s>` — country
- `--vat-id <s>` — EU VAT id (sales_tax_id)
- `--email <s>` — email address
- `--iban <s>` — IBAN
- `--bic <s>` — BIC
- `--customer-number <s>` — customer number
- `--dry-run` — print the redacted payload, send nothing

Create a debtor via /settings/add/debtor. Only --name is required; omit
--account to let BHB assign the next free Debitoren number. The API returns no
id — re-query with `debtors list --filter` / `debtors show`. No delete endpoint
exists (see docs/bhb-api-quirks.md).

### `update`

update a debtor by its account number

```
butler debtors update <account> [field flags] [--dry-run]
```

**Arguments:**

- `account` — debtor postingaccount_number

**Flags:**

- `--name <s>` — new debtor name
- `--contact <s>` — contact person name
- `--street <s>` — street
- `--address2 <s>` — additional address line
- `--zip <s>` — postal / ZIP code
- `--city <s>` — city
- `--country <s>` — country
- `--vat-id <s>` — EU VAT id (sales_tax_id)
- `--email <s>` — email address
- `--iban <s>` — IBAN
- `--bic <s>` — BIC
- `--customer-number <s>` — customer number
- `--dry-run` — print the redacted payload, send nothing

Update a debtor via /settings/update/debtor. Pass only the fields you want to change; omitted fields are left untouched.

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
