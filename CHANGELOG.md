# Changelog

All notable changes to butler are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Settlement verbs mirroring the UI's "Beleg einer Zahlung zuordnen":
  `receipts pay <id> --with <tx>` (receipt-first) and `transactions settle <tx>
  --receipts <id,id,...>` (payment-first, for one payment covering several
  invoices). The settlement line — creditor account, open amount, text — is
  resolved from the receipt's own booking, so the happy path is just ids; it
  posts the creditor->bank line carrying the receipt as an open item, marking it
  paid. Credit notes work too: the creditor is taken from the correct side of the
  (reversed) booking by the receipt's sign.
- `receipts upload --credit-note` negates `--amount` so a Gutschrift uploads with
  the negative amount BHB needs to reverse its booking; `receipts book` defaults
  the counterparty account to the standard Kreditoren-Sammelkonto (70000).
- Booking verbs for all three BHB posting classes:
  - `transactions book <tx>` — book a bank payment directly onto account(s), no
    receipt (`/postings/add/transaction`); single line or `--from-json` split.
  - `receipts book <id>` — book a receipt onto account(s), with the counterparty
    Sammelkonto in `--creditor` / `--debtor` (`/postings/add/receipt`).
  - `bookings assign <receipt-id> <posting-id>` — link a receipt to an existing
    free booking (`/postings/assign/receipt-to-free-posting`).
- Receipt↔transaction linking: `transactions link` / `unlink <tx> <receipt>` (a
  soft pointer, no booking) and `transactions receipts <tx>` (the receipts
  assigned to a transaction).
- Open-item discovery: `transactions list --unbooked` / `receipts list
  --unbooked` (no posting of any class references the item), `transactions list
  --missing-receipt` (booked but no receipt) and `receipts list --unpaid` — a
  `/postings/get` anti-join keyed on posting linkage, so a receipt-less but
  booked payment (salary, tax) is correctly excluded from `--unbooked`.
- `bookings list` decodes each booking's numeric `tax_key` into its documented
  German VAT label (e.g. `i.g.E. 19% USt./VSt. [19]`, `§13b 19% USt./VSt. [94]`,
  `19% Vst. [9]`), keeping the raw key in brackets so a wrong/unknown mapping can
  never hide ground truth. The numeric key is undocumented in the BHB API; the
  label is sourced from the spec's symbolic `vat` codes via an empirically
  derived, source-commented bridge table.
- `bookings list` gained `fixed` (festgeschrieben vs editable), `receipt`
  (assigned invoice number) and `tx` (linked bank transaction) columns, and
  resolves the debit/credit accounts to `NNNN Name` (one extra API call).
- `bookings list --output json` is now enriched: each row keeps its raw fields
  and gains sibling `tax_label`, `debit_postingaccount_name` and
  `credit_postingaccount_name` (the enriched body is a strict superset of the
  API's).
- `output.emitListDecorated` / `output.Decorator`: a per-row hook for computed
  fields, shaped per output mode (table cells vs JSON sibling fields).

### Changed

- The `postings` resource is now **`bookings`** (matching BHB's "Buchungen");
  `postings` stays an alias, so existing invocations keep working.
- Command vocabulary now mirrors the BHB web UI rather than the API:
  - `bookings create` → **`bookings add`** (the UI "Erweitertes Buchen" /
    "Hinzufügen").
  - `transactions match` / `unmatch` → **`link`** / **`unlink`** — they only set
    the payment date (a soft pointer), so the names no longer read as "settle";
    settling is `transactions settle` / `receipts pay`.
  - `receipts list --unmatched` → **`--unbooked`** (the UI "Ungebucht"), matching
    `transactions list --unbooked`. A separate **`--unpaid`** (UI "Unbezahlt",
    the receipt's payment status) keeps the two distinct as the UI does.
  - New **`transactions list --missing-receipt`** (UI "Fehlender Beleg"): a
    payment that is booked but carries no receipt (e.g. salary, taxes).

## [0.1.0] - 2026-06-12

First public release.

### Added

- `resource verb` CLI for the BuchhaltungsButler API: **transactions**
  (list, show), **receipts** (list, show, upload, delete), **postings**
  (list, create, unconfirm; alias `bookings`), **accounts** (list), plus
  `status`, `login`, `logout`.
- `--output table|json`, client-side `--filter` (table mode),
  `--dry-run` for writes, `--clearing` net-zero assertion for split bookings.
- AWS-style profiles in `$XDG_CONFIG_HOME/butler/credentials` (mode 0600,
  written atomically), `BUTLER_*` environment variables taking precedence;
  `butler login` disables terminal echo while secrets are typed.
- Man page (`man butler`) and `docs/commands.md`, both generated from the
  single command spec in `src/spec.zig`.
- Nix flake (package, devShell, overlay).
