# Changelog

All notable changes to butler are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.0] - 2026-08-06

This release covers the payment that does not match its receipt, and tells apart
the two §13b cases that belong on different lines of the Umsatzsteuervoranmeldung.

### Added

- `transactions book` can settle a receipt and book a second amount in the same
  payment — the web app's split payment with a receipt assigned to one line
  only. For a bank line that does not match its receipt: a card terminal that
  rounded up for a donation, a tip, a bank charge taken with the invoice. Name
  the receipt on the line that clears it (`--receipt`, or `"receipt"` in
  `--from-json`); the other line takes the difference. `receipts pay` still
  covers the ordinary case where payment and receipt are equal.
- The two `§13b` rates that separate an EU supplier from one outside the EU,
  `19_both_506` (§ 13b Abs. 1) and `19_both_511` (§ 13b Abs. 2 Nr. 1) — the
  same choice the web app offers under "§13b 19/16% USt./VSt.". The two go on
  different lines of the Umsatzsteuervoranmeldung, so it matters which one you
  book. Bookings that use them now show their label instead of `?unmapped`.
  `19_both_1` still works and still says neither.

## [0.4.0] - 2026-07-23

This release fixes receipt deletion, adds downloading a receipt's stored
document, and makes lookups by id reliable: show and settle now find every
receipt instead of only recent ones.

### Added

- `receipts download <id>`: saves a receipt's stored document (the file you
  see in the web app's receipt preview) locally. By default the file is named
  like the receipt in BHB; `--file <path>` picks another destination.

### Changed

- `receipts show` can also show deleted receipts. The `--direction` flag is
  gone; it is no longer needed.
- `transactions show` shows additional fields, such as the counterparty's
  bank details.
- Settling a deleted receipt now says "receipt X is deleted" instead of
  "not found".

### Fixed

- `receipts delete` now works. It previously failed with "invalid receipt
  id_by_customer specified" for every id. Deleting a booked receipt also
  removes the receipt's booking.
- `receipts show`, `receipts pay` and `transactions settle` find every
  receipt. Lookups used to stop at the newest 500 receipts per direction and
  treated older ones as not found.

## [0.3.2] - 2026-07-14

A small fix-up release: bookings whose VAT comes from account automation now
show that rate instead of looking tax-free.

### Fixed

- `bookings list` now shows the VAT rate for postings whose VAT sits on the
  account rather than on a tax key, such as the geldwerter Vorteil of a company
  car or a benefit (booked on a "sonstige Sachbezüge 19/16 % USt" account). These
  were shown as "keine Ust." even though the web app shows "19% USt."; the rate
  is now displayed, matching the browser.

## [0.3.1] - 2026-07-01

A small fix-up release: bookings you make through butler now read back in the
terminal exactly as they look in the web app, and the `bookings add` help points
you to the right command up front.

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
