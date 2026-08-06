# BuchhaltungsButler API: Known Quirks & Limitations

Field notes on the BuchhaltungsButler (BHB) REST API, gathered while building
the `butler` CLI. This document serves two audiences: developers working
against the API, and BHB support/engineering, who can treat every classified
item below as a candidate ticket.

Each item carries a **classification** (what kind of issue it is) and an
**evidence marker** (how it was established):

| Tag | Meaning |
|---|---|
| `[BUG]` | The live API misbehaves; needs a server-side fix. |
| `[DOCS]` | The live API works, but the published spec is wrong or incomplete. |
| `[INCONSISTENT]` | Works, but names/shapes/requirements differ between endpoints for no apparent reason. |
| `[GAP]` | A capability the API does not offer at all (feature request rather than bug). |
| `[FYI]` | Apparently by design; non-obvious, but no ticket needed. |

Evidence markers: **[confirmed]** = exercised against the live API;
**[verified YYYY-MM-DD]** = confirmed live on that date; **[spec]** = read
from the OpenAPI spec, not yet exercised. Italic *butler:* notes describe how
the CLI copes and can be skipped by BHB readers.

- **Spec:** Swagger 2.0, version `1.9.1`
- **Spec URL:** `https://app.buchhaltungsbutler.de/docs/api/v1.de.json`
- **Base URL:** `https://webapp.buchhaltungsbutler.de/api/v1`
- All endpoints are **POST** with a JSON body; responses are JSON.

## Suggested ticket list

The classified items in one view, most impactful first. Details in the linked
sections.

| # | Class | Issue | Section |
|---|---|---|---|
| 1 | BUG | `/postings/get` never returns unconfirmed free postings (BHB ticket 443636, reproduced and escalated by BHB) | Postings |
| 2 | DOCS | By-id routes: `id_by_customer` in route names is a path placeholder; neither marked as a template nor documented as a parameter | By-id routes |
| 3 | DOCS | Basic-auth layer completely absent from the spec | Authentication |
| 4 | BUG | `/transactions/get` id-range bounds are both exclusive; `[X, X]` returns nothing | Listing & filtering |
| 5 | DOCS | `tax_key` on `/postings/get` rows is undocumented (example value only) | Postings |
| 6 | DOCS | `PostingsFree` batch schema: `amount` typed number vs. string on `/postings/add/free`; `required` list has a typo (`"amounts"`) | Postings |
| 7 | INCONSISTENT | Field names differ between read and write: `debit_postingaccount_number` vs. `postingaccount_debit` | Postings |
| 8 | INCONSISTENT | `invoice_number` (upload/add) vs. `invoicenumber` (get filter) | Receipts |
| 9 | INCONSISTENT | `order` parameter is a string on `/postings/get` but an object on `/receipts/get` | Listing & filtering |
| 10 | INCONSISTENT | `oi_receipts_ids_by_customer` required on `/postings/add/transaction` even with open-item postings disabled | Transaction-linked postings |
| 11 | INCONSISTENT | `/receipts/add` requires `currency`, `/receipts/upload` does not | Receipts |
| 12 | DOCS | `/receipts/get` requires `list_direction` but the spec gives no enum of valid values | Listing & filtering |
| 13 | GAP | No way to delete a posting via the API (web UI only) | Postings |
| 14 | GAP | No confirm/lock (Festschreibung) endpoint | Postings |
| 15 | GAP | Create endpoints return no id (postings, creditors, debtors); callers must re-query and match | Postings, Accounts & subledgers |
| 16 | GAP | No update endpoint for receipts; metadata immutable via API | Receipts |
| 17 | GAP | No get-by-id for postings (`/postings/get/<id>` does not exist) | By-id routes |
| 18 | GAP | `/settings` resources: no search/filter, no get-one, no delete | Accounts & subledgers |
| 19 | INCONSISTENT | By-id miss behaviour differs: receipts answer 200 with an empty array (and switch `data`'s shape), transactions answer HTTP 400 | By-id routes |
| 20 | GAP | Comments are write-only: no get/update/delete, and readable only as a field on `/postings/get` rows | Comments |

## Authentication

- `[FYI]` **Auth is two-layered:** HTTP Basic auth (`api_client` : `api_secret`)
  **plus** an account-level `api_key` sent **in the JSON body** of every
  request. **[confirmed]**
- `[DOCS]` **The Basic-auth layer is undocumented in the spec.** There is no
  `securityDefinitions`, no `security` block, and no header parameters. Don't
  go looking for it in the schema; it simply has to be sent. **[confirmed]**

## Response envelope

- `[FYI]` Every response looks like
  `{ "success": bool, "message": string, "rows": int, "data": [...] }`. **[confirmed]**
- `[FYI]` **`rows` is a COUNT, not the array.** The actual records are under
  **`data`**. Reading `.rows` expecting a list is a common first mistake. **[confirmed]**
- `[FYI]` **All numeric values come back as strings:** `"amount": "1234.56"`,
  `"vat": "19.00"`, account numbers `"3790"`. Parse accordingly. **[confirmed]**

## By-id routes (`*/get/<id>`, `*/delete/<id>`)

- `[DOCS]` **`id_by_customer` in a route name is a path placeholder, not a
  literal segment.** The spec lists routes like
  `/receipts/get/id_by_customer` without marking the last segment as a
  template (`{id_by_customer}`) and without documenting any id parameter; only
  `api_key` (plus `get_file` on the receipts route) appears as a body
  parameter. The working call is `POST /receipts/get/<id>` (e.g.
  `/receipts/get/289`) with only `api_key` in the JSON body.
  **[verified 2026-07-22]**
  - Working routes, all verified live:
    - `POST /receipts/get/<id>` → HTTP 200, the full receipt record. With
      `get_file: true` it also returns `file_content` (see "Receipt file
      download").
    - `POST /receipts/delete/<id>` → HTTP 200,
      `{"success":true,"id_by_customer":"<id>"}`. Deleting a **booked**
      receipt works and cascades: the receipt posting is removed with it.
    - `POST /transactions/get/<id>` → HTTP 200, the full transaction record.
  - `[FYI]` **`data` is an OBJECT on these routes, not a list.** Tooling that
    feeds responses through a list-shaped emitter must special-case them.
  - The failure modes when POSTing to the literal placeholder path are
    misleading enough to record (they cost real debugging time):
    - `/receipts/get/id_by_customer` and `/receipts/delete/id_by_customer` DO
      match the route pattern, so the server parses the literal segment
      `"id_by_customer"` as the id and rejects it: HTTP 400
      `{"success":false,"error_code":5,"message":"invalid … id_by_customer specified"}`
      for every body variant (id as string or int; named `id_by_customer`,
      `receipt_id_by_customer`, or `id`). The error text names the
      placeholder, which reads as if a body field were wrong; it is the path.
    - `/transactions/get/id_by_customer` does NOT match any route: HTTP 404
      with an HTML login page (~6 KB `text/html`), not a JSON error.
- `[GAP]` **`/postings/get/<id>` does not exist** (HTML 404). There is no
  get-by-id for postings; see "Create endpoints return NO id" below for why
  that hurts.
- `[INCONSISTENT]` **A miss (no such id) behaves differently per resource.**
  `/receipts/get/<missing-id>` answers HTTP 200 with an **empty `data`
  ARRAY** (so `data`'s shape flips between object and array depending on the
  hit); `/transactions/get/<missing-id>` answers HTTP 400
  `{"success":false,"error_code":6,"message":"transaction not found"}`.
  **[verified 2026-07-23]**
- `[FYI]` **Soft-deleted receipts are still returned by `/receipts/get/<id>`**
  (with `deleted: "1"`); the route does not filter them.
  **[verified 2026-07-23]**
- `[spec, untested]` `*/restore/id_by_customer` presumably follows the same
  path-segment pattern (`POST /receipts/restore/<id>`).
- *butler: `receipts show`, `receipts download`, `transactions show` and the
  receipt lookup behind `receipts pay`/`transactions settle` use the direct
  routes; the settle lookup rejects a soft-deleted receipt explicitly.*

## Postings (`/postings/*`)

- `[BUG]` **`/postings/get` does NOT return unconfirmed extended (free)
  bookings.** **[confirmed by BHB support]** Free postings created via
  `/postings/add/free` that appear in the web UI under "Erweitertes Buchen" as
  *unbestätigt* are **not returned** by `/postings/get`: not with
  `posting_status: "all"`, not `"unfixed"`, not `account: "free booking"`.
  Reported to BHB support as **ticket 443636** (Apr 2026); BHB **reproduced
  and escalated it internally** (2026-04-07). No resolution received as of
  this writing.
  - Consequence for tooling: an *unconfirmed* posting is invisible to the
    API; you cannot list or verify it. *butler: `bookings add` deliberately
    leaves new postings confirmed (see lifecycle below).*
- `[GAP]` **You cannot delete a posting via the API.** Deletion is web-UI
  only. **[verified 2026-06-04]**
- `[GAP]` **No confirm/lock (Festschreibung) endpoint exists.** Final
  confirming/locking is web-UI only. **[spec]**
- `[GAP]` **Create endpoints return NO id.** `/postings/add/free` and
  `/postings/add-batch/free` return only `{success, message}` (the batch
  returns a per-line array of the same). To act on a just-created posting
  (e.g. to unconfirm it) you must re-query `/postings/get` and match by
  date + postingtext (+ amount) to recover `id_by_customer`. **[confirmed]**
- `[FYI]` **Create / confirm / delete lifecycle.** **[verified 2026-06-04]**
  - A posting created via `/postings/add/free` lands `confirmed` (and
    `fixed:"0"`), and IS returned by `/postings/get`. Verified with a live
    test (single free posting): created → visible.
  - `/postings/unconfirm/free` (body `posting_id_by_customer`) sets it back
    to unconfirmed. After that it **vanishes from `/postings/get`** (any
    `posting_status`) but remains visible in the web UI as *unbestätigt*. It
    is NOT deleted. (This is ticket 443636 above from the other side.)
  - The same behaviour was observed for a real multi-line extended booking
    (split); a multi-line split is the same `/postings/add/free` per line.
  - *butler: `bookings add` leaves new postings confirmed (visible to API and
    UI; still unfixed, so editable/deletable in the UI). To stage one for
    UI-only review, unconfirm it with a separate `butler bookings
    unconfirm <id>`. Postings confirmed in a live account are likewise
    `fixed:"0"`/visible, so this matches how existing data looks.*
- `[INCONSISTENT]` **Read and write field names differ.** `/postings/get`
  returns `debit_postingaccount_number` / `credit_postingaccount_number`, but
  `/postings/add/free` expects `postingaccount_debit` /
  `postingaccount_credit`. **[confirmed]**
- `[DOCS]` **`tax_key` on `/postings/get` rows is an undocumented numeric
  code.** The spec lists it only with the example value `"1"`: no enum, no
  meaning. It is the tax-treatment key behind the symbolic `vat` codes (which
  ARE documented, each with a German label, in the `/postings/add/free` `vat`
  parameter description). The numeric key is independent of the chart of
  accounts (the same across SKR03/SKR04; account *numbers* differ, the tax
  key does not). *butler: decodes observed keys to the documented label, e.g.
  `9 → "19% Vst."` (domestic input VAT), `19 → "i.g.E. 19% USt./VSt."`
  (intra-community acquisition), `94 → "§13b 19% USt./VSt."` (reverse
  charge), `0 → "keine Ust."`; see `src/spec.zig` `tax_keys`. The
  numeric→symbolic bridge is empirically derived, so the raw key is always
  shown next to the label and an unknown key renders as unmapped.*
- `[DOCS]` **`amount` type is inconsistent between endpoints.**
  `/postings/add/free` documents `amount` as a **string**; the batch
  endpoint's `PostingsFree` schema documents it as a **number** (and its
  `required` list has a typo, `"amounts"` plural). **[spec]** *butler: posts
  via repeated `/postings/add/free` with a string `amount` to stay on the
  well-defined path.*
- `[FYI]` **`vat` is a symbolic token, not a number.** Valid values include
  `0_none`, `19_vat`, `7_vat`, `19_pre`, `7_pre`, `19_both_1`, `19_both_2`,
  `7_both`, `19_both_1_no_pre`, `19_both_2_no_pre`, `7_both_no_pre`,
  `19_pre_app`, `7_pre_app`, `19_both_app_1`, `19_both_app_2`, `7_both_app`.
  Sending `"0"` or `"19.00"` returns `error_code 19 "Invalid vat specified"`. **[confirmed]**
- `[FYI]` **Negative amounts are rejected** (`error 22 "there are no negative
  amounts allowed"`). Direction is expressed purely by the debit/credit
  account pair, never by the sign. A "split" booking balances via its
  clearing account, not via signed sums. **[spec]**
- `[FYI]` **A line's debit and credit account must differ** (`error 26`). **[spec]**
- `[FYI]` **`postingtext` max length is 128 characters** (`error 9`). **[spec]**
- `[FYI]` **Three posting classes; the UI "Erweitertes Buchen" shows only
  one.** A posting is created by one of three endpoints: `/postings/add/free`
  (free / extended booking), `/postings/add/receipt` (booked from a receipt),
  or `/postings/add/transaction` (booked directly on a bank transaction, no
  receipt). `/postings/get` returns all three; its `account` filter selects
  the class: `free booking` = free/extended only, `all financial accounts` =
  transaction/bank-side bookings, `all` (the default) = everything. The UI's
  "Erweitertes Buchen" corresponds to `free booking`, so a posting made
  directly on a payment (transaction class) does NOT appear there; it lives
  under `all financial accounts`. **[confirmed, observed via the account filter]**

## Receipt file (PDF) download

- `[FYI]` **Download works via the by-id route:** `POST /receipts/get/<id>`
  with body `{api_key, get_file: true}` returns the stored file as base64 in
  `file_content` (`e_invoice_type` 0 = PDF, 1 = ZUGFeRD, 2 = xRechnung).
  Verified live against a 1.5 MB PDF: 2,009,312 base64 chars decoding to
  `%PDF-` magic bytes. **[verified 2026-07-22]** (Earlier revisions of this
  document called the download unreachable; that was the path-placeholder
  confusion above.) *butler: `receipts download <id>` saves the file; a
  round-trip through upload and download is byte-identical.*
- `[FYI]` **The list route carries no file and no link.** `/receipts/get`
  ignores `get_file`; its rows hold only metadata (`filename`, `amount`,
  `date`, `counterparty`, `account`, …): no `file_content`, no URL. **[confirmed]**
- `[FYI]` **The file URLs in posting rows are webapp-session-only.**
  `/postings/get` rows carry `receipts_links` / `receipts_assigned_links`,
  e.g. `https://webapp.buchhaltungsbutler.de/receipts/view-pdf/<filename>.pdf`.
  Under API Basic auth this 301-redirects to
  `https://app.buchhaltungsbutler.de/login/` (HTTP 200 login page); it needs
  a logged-in browser session cookie, not the API credentials. **[confirmed]**

## Listing & filtering

- `[BUG]` **`/transactions/get` id-range bounds are BOTH exclusive.** **[confirmed]**
  - `[416, 418]` → returns only id `417`
  - `[417, 419]` → returns only id `418`
  - `[417, 417]` → returns **nothing**
  - To fetch exactly id `X`, query `[X-1, X+1]`. At minimum this behaviour is
    undocumented; an inclusive range (or any documented convention) would be
    expected. *butler: no longer affected for single lookups (`transactions
    show` fetches directly by id); the exclusivity still matters for any
    ranged list query.*
- `[FYI]` **`/postings/get` requires both `date_from` and `date_to`.** **[confirmed]**
- `[DOCS]` **`/receipts/get` requires `list_direction`**, exactly `inbound` or
  `outbound`; the spec gives no enum of valid values. **[confirmed]**
- `[INCONSISTENT]` **`order` parameter shape differs:** for `/postings/get` it
  is a **string** (`"date ASC"`); for `/receipts/get` it is an **object**
  (`{"date":"ASC"}`). **[spec]**
- `[FYI]` List endpoints cap at high limits (postings `limit` max 1000;
  transactions / receipts max 500). **[spec]**

## Receipts (`/receipts/*`)

- `[GAP]` **No update endpoint; receipt metadata is immutable via the API.**
  The only receipt verbs are `add`/`addBatch`/`upload`, `get`, `delete` and
  `restore`; there is no `/receipts/update` (the API's only update routes are
  `/settings/update/{postingaccount,creditor,debtor}` and
  `/cost-locations/update`). A receipt captured with wrong metadata, e.g. a
  credit note stored as a regular invoice with a positive amount, cannot be
  corrected in place: fix it in the web UI, or `delete` and re-upload it
  (deletes are soft; a restore route exists, see "By-id routes"). **[spec]**
- `[FYI]` **Upload field names:** the file goes in `file` as **base64**, and
  `file_name` is **required** alongside it (because `file` is base64). It is
  *not* `filename`, `file_content`, or `base64`. **[spec]**
- `[INCONSISTENT]` **Invoice-number field name differs:** `/receipts/upload`
  and `/receipts/add` expect `invoice_number` (underscore), but the
  `/receipts/get` **filter** uses `invoicenumber` (no underscore). **[spec]**
- `[INCONSISTENT]` **`/receipts/add` requires `currency`** (unlike
  `/receipts/upload`). **[spec]**

## Receipt-linked postings (`/postings/add/receipt`)

- `[FYI]` Takes parallel arrays `postingaccounts`, `postingtexts`, `vats`,
  `amounts` (plus optional `cost_locations`, `cost_locations_two`) and scalars
  `receipt_id_by_customer`, `creditor`, `debtor`. **[spec]**
- `[FYI]` **`creditor` and `debtor` are both REQUIRED** (integer Sammelkonto
  numbers; use `0` for the side that does not apply). **[spec]**

## Transaction-linked postings (`/postings/add/transaction`)

- `[FYI]` Books directly onto a bank transaction (the contra side), so it
  takes only the charged `postingaccounts` (parallel
  `postingtexts`/`vats`/`amounts`) and the scalar
  `transaction_id_by_customer`; no debit/credit pair. **[spec]**
- `[INCONSISTENT]` **`oi_receipts_ids_by_customer` is REQUIRED even with
  open-item postings off.** Send one `null` per line (an array sized to the
  lines). **[spec]** *butler: does this automatically.*

## Accounts & subledgers (`/settings/*`)

- `[FYI]` The chart of accounts and the Personenkonten are three parallel
  `/settings` ledgers: `postingaccounts` (Sachkonten), `creditors`
  (Kreditoren) and `debtors` (Debitoren). Each has `get`, `add` and `update`
  (`/settings/{get,add,update}/{postingaccount,creditor,debtor}`), plus an
  `add-batch` for creditors/debtors. **[spec]**
- `[GAP]` **Three capabilities these `/settings` resources do not offer:**
  1. **No search/filter on `get`.** None of the `get` endpoints take a name,
     number, VAT-id or IBAN filter; only `limit`/`offset` (and, for
     `postingaccounts`, the `exclude_*` *type* toggles). *butler: fetches the
     list and applies `--filter` client-side.*
  2. **No get-by-id / get-one.** There is no route to fetch a single account
     by its number. *butler: `show` fetches the list and matches
     `postingaccount_number` client-side.*
  3. **No delete.** The API exposes no `/settings/delete/*` (nor any delete
     route) for postingaccounts, creditors or debtors; once created, they can
     only be edited via `update`, never removed through the API. Cleanup
     (deletion or deactivation) must be done in the BHB web UI. *butler:
     offers `add`/`update` for these resources but no `delete`.* **[spec]**
- `[FYI]` **`get/postingaccounts` is the unified chart view:** it returns
  EVERY numbered account as a ledger row (Sachkonten, the base cash/bank
  accounts AND the creditor/debtor Personenkonten plus their collective
  accounts) with only `postingaccount_number`, `name`, `type` and `parent`.
  The per-party master data (address, IBAN, `sales_tax_id`, ...) is NOT here;
  it lives on `get/creditors` / `get/debtors`. Narrow by category with the
  `exclude_postingaccounts` / `exclude_accounts` / `exclude_creditors` /
  `exclude_debtors` booleans (an `exclude_*` drops a type and its
  collective). **It defaults to 1000 rows** (a silent truncation if the chart
  is larger). *butler: pages it to exhaustion via `limit`/`offset` like the
  subledger endpoints.* **[spec]**
- `[FYI]` **All three `get` endpoints paginate** (postingaccounts default
  1000/page, creditors/debtors 25/page). *butler: sweeps every page to
  completion, advancing the offset by the rows actually returned, unless
  `--limit` bounds it to a single page.*
- `[GAP]` **`add` returns no id** (the same envelope-only behaviour as
  `/postings/add/*`); on creditor/debtor `add` you may omit
  `postingaccount_number` to have BHB assign the next free one; re-query the
  list to learn it. `add/postingaccount` requires the number plus a
  `parent_postingaccount_number`. **[spec]**

## Comments (`/comments/add`)

- `[GAP]` **Comments are write-only.** `/comments/add` is the only comments
  endpoint: there is no `/comments/get`, `/comments/update` or
  `/comments/delete`. A comment can be created and then never corrected or
  removed through the API — only in the web UI. **[confirmed]**
- `[GAP]` **A comment can only be read back through `/postings/get`,** which
  returns it in the row's `comment` field. Since `/postings/get` offers no
  receipt or transaction id filter (only a mandatory date span, accounts,
  status and cost location), fetching "the comment on receipt N" means sweeping
  a date window and matching client-side. **[confirmed]** A comment on a
  receipt or transaction with no posting is therefore unreadable via the API.
  *butler: `bookings list --comments` adds the column; there is deliberately no
  `comments list` verb, since it could only guess at the window.*
- `[FYI]` **`comment_text` is 2..210 characters**, and the limit counts
  characters rather than bytes — 210 `§` (420 bytes) is accepted. Violations
  come back as `error_code` 12 (invalid) or 13 (absent). **[confirmed]**
  *butler: checked locally before the request, so an over-long comment is a
  usage error rather than a round trip.*
- `[FYI]` **Exactly one of `receipt_id_by_customer` /
  `transaction_id_by_customer`** must be sent; the rejected id yields
  `error_code` 6 or 5 respectively. **[spec]**

---

*This document reflects the API as observed in 2026 against spec `1.9.1`.
Behaviour may change; treat `[spec]` points as unverified until exercised.*
