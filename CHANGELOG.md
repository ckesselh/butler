# Changelog

All notable changes to butler are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `bookings list` no longer shows the VAT column as `?unmapped` for bookings you
  made through butler. They now read with the same label the web app shows
  (e.g. "19% Vst."), so a booked receipt looks the same in the terminal as in
  the browser.

### Changed

- `bookings add --help` now says up front that an entry tied to an invoice or a
  payment belongs on `receipts book` / `transactions book`, and that the free
  booking is only for a standalone entry with neither.

## [0.3.0] - 2026-06-23

The aim of this release was to let you work with the accounts, suppliers and
customers that your bookings refer to, not just the bookings themselves. butler
can now list and search them, look any one up by its number, and create or edit
them straight from the command line, so the master data no longer means a trip
to the web app. The one thing it cannot do is delete them, because the
accounting service offers no way to.

### Added

- `creditors` and `debtors` commands for your suppliers and customers (Kreditoren
  and Debitoren): `list` (with a `--filter` search over number, name, city, VAT
  id and IBAN), `show <account>` to look one up by its number, and `add` /
  `update` to create or change them (name, address, VAT id, IBAN, payment terms).
  These are where you find the account number for `receipts book --creditor` /
  `--debtor`.
- `accounts` now covers the whole chart of accounts, not only the Sachkonten:
  `accounts list --type postingaccount|account|creditor|debtor` narrows it
  (default: all), and `accounts show <number>` looks up any account by its number.
- `accounts add` and `accounts update` to create and rename ledger accounts.
- `--dry-run` on every new write command prints the request without sending it.
  None of these can be deleted, because the API has no delete endpoint.

## [0.2.0] - 2026-06-14

Turns butler from a read-only client into one you can keep the books with:
booking entries, settling receipts against payments, and the open-item filters
the web UI offers. The command vocabulary now follows the BHB web UI rather than
the raw API, so workflows transfer from the browser to the terminal.

### Added

- Book entries from the terminal: a free or split entry (`bookings add`), a bank
  payment directly (`transactions book`), or a receipt (`receipts book`).
- Settle receipts against payments — `receipts pay <id> --with <tx>`, or
  `transactions settle <tx> --receipts <ids>` for one payment covering several
  invoices. The account and amount are taken from the receipt's own booking, so
  the common case is just the two ids. Credit notes are handled, including
  `receipts upload --credit-note`.
- Open-item filters mirroring the web UI: `receipts list --unbooked` / `--unpaid`
  and `transactions list --unbooked` / `--missing-receipt`.
- Link a receipt to a payment without booking it (`transactions link` /
  `unlink`) or to an existing booking (`bookings assign`); list the receipts on a
  transaction (`transactions receipts`).
- `bookings list` is easier to read: the VAT key is decoded to its German label,
  account numbers resolve to names, and `fixed` / `receipt` / `tx` columns are
  added. `--output json` keeps every raw field and adds the decoded label/name
  fields alongside.

### Changed

- The `postings` resource is now `bookings` (the web UI's "Buchungen");
  `postings` still works as an alias.
- Command names now follow the BHB web UI: `bookings create` → `bookings add`;
  `transactions match` / `unmatch` → `link` / `unlink` (a pointer, not a
  settlement — settle with `transactions settle` / `receipts pay`); and
  `receipts list --unmatched` → `--unbooked`.

## [0.1.0] - 2026-06-12

First public release: a read-only client for the core BHB resources. Enough to
list and inspect transactions, receipts and postings from the terminal, with
table or JSON output and stored credential profiles.

### Added

- A `resource verb` CLI for the BuchhaltungsButler API, covering transactions,
  receipts, postings and accounts, plus `status` / `login` / `logout`.
- `--output table|json`, a client-side `--filter`, `--dry-run` on writes, and a
  `--clearing` net-zero check for split bookings.
- Credential profiles (`$XDG_CONFIG_HOME/butler/credentials`, mode 0600;
  `BUTLER_*` env vars take precedence; `login` hides typed secrets).
- A generated man page and `docs/commands.md`, and a Nix flake.
