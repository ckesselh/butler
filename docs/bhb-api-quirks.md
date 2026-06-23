# BuchhaltungsButler API — Known Quirks & Limitations

Field notes on the BuchhaltungsButler (BHB) REST API gathered while building
`butler`. They are the non-obvious things that cost time or break naive
assumptions. Where a point was confirmed against the live API it is marked
**[confirmed]**; otherwise it comes from the OpenAPI spec **[spec]**.

- **Spec:** Swagger 2.0, version `1.9.1`
- **Spec URL:** `https://app.buchhaltungsbutler.de/docs/api/v1.de.json`
- **Base URL:** `https://webapp.buchhaltungsbutler.de/api/v1`
- All endpoints are **POST** with a JSON body; responses are JSON.

## Authentication

- **Auth is two-layered:** HTTP Basic auth (`api_client` : `api_secret`) **plus**
  an account-level `api_key` sent **in the JSON body** of every request. **[confirmed]**
- **The Basic-auth layer is undocumented in the spec** — there is no
  `securityDefinitions`, no `security` block, and no header parameters. Don't go
  looking for it in the schema; it simply has to be sent. **[confirmed]**

## Response envelope

- Every response looks like `{ "success": bool, "message": string, "rows": int, "data": [...] }`. **[confirmed]**
- **`rows` is a COUNT, not the array.** The actual records are under **`data`**.
  Reading `.rows` expecting a list is a common first mistake. **[confirmed]**
- **All numeric values come back as strings:** `"amount": "1234.56"`,
  `"vat": "19.00"`, account numbers `"3790"`. Parse accordingly. **[confirmed]**

## Postings (`/postings/*`)

- **GET vs POST field names differ.** `/postings/get` returns
  `debit_postingaccount_number` / `credit_postingaccount_number`, but
  `/postings/add/free` expects `postingaccount_debit` / `postingaccount_credit`. **[confirmed]**
- **`vat` is a symbolic token, not a number.** Valid values include
  `0_none`, `19_vat`, `7_vat`, `19_pre`, `7_pre`, `19_both_1`, `19_both_2`,
  `7_both`, `19_both_1_no_pre`, `19_both_2_no_pre`, `7_both_no_pre`,
  `19_pre_app`, `7_pre_app`, `19_both_app_1`, `19_both_app_2`, `7_both_app`.
  Sending `"0"` or `"19.00"` returns `error_code 19 "Invalid vat specified"`. **[confirmed]**
- **`amount` type is inconsistent between endpoints.** `/postings/add/free`
  documents `amount` as a **string**; the batch endpoint's `PostingsFree`
  schema documents it as a **number** (and its `required` list has a typo,
  `"amounts"` plural). `butler` posts via repeated `/postings/add/free` with a
  string `amount` to stay on the well-defined path. **[spec]**
- **Negative amounts are rejected** (`error 22 "there are no negative amounts
  allowed"`). Direction is expressed purely by the debit/credit account pair,
  never by the sign. A "split" booking balances via its clearing account, not
  via signed sums. **[spec]**
- **A line's debit and credit account must differ** (`error 26`). **[spec]**
- **`postingtext` max length is 128 characters** (`error 9`). **[spec]**
- **Create endpoints return NO id.** `/postings/add/free` and
  `/postings/add-batch/free` return only `{success, message}` (the batch returns
  a per-line array of the same). To act on a just-created posting (e.g. to
  unconfirm it) you must **re-query `/postings/get` and match by
  date + postingtext (+ amount)** to recover `id_by_customer`. **[confirmed]**
- **`/postings/get` does NOT return unconfirmed extended (free) bookings.** **[confirmed by BHB support]**
  Free postings created via `/postings/add/free` that appear in the web UI under
  "Erweitertes Buchen" as *unbestätigt* are **not returned** by `/postings/get` —
  not with `posting_status: "all"`, not `"unfixed"`, not `account: "free booking"`.
  Reported to BHB support as **ticket 443636** (Apr 2026); BHB **reproduced and
  escalated it internally** (2026-04-07). No resolution received as of this
  writing — treat it as a standing API limitation/bug.
  - **Consequence for tooling:** an *unconfirmed* posting is invisible to the
    API — you cannot list/verify it. So `butler bookings add` deliberately
    leaves new postings *confirmed* (see lifecycle below).
- **Create / confirm / delete lifecycle** **[verified 2026-06-04]**
  - **A posting created via `/postings/add/free` lands `confirmed` (and
    `fixed:"0"`), and IS returned by `/postings/get`.** Verified with a live
    test (single free posting): created → visible.
  - **`/postings/unconfirm/free` (body `posting_id_by_customer`) sets it back to
    unconfirmed.** After that it **vanishes from `/postings/get`** (any
    `posting_status`) but **remains visible in the web UI** as *unbestätigt*.
    It is NOT deleted.
  - **You cannot truly delete a posting via the API** — deletion is **web-UI only**.
  - **No "confirm"/lock (Festschreibung) endpoint exists** — final
    confirming/locking is web-UI only. **[spec]**
  - **Design choice in `butler`:** `bookings add` leaves new postings
    **confirmed** (visible to API + UI; still unfixed, so editable/deletable in
    the UI). To stage one for UI-only review, unconfirm it with a separate
    `butler bookings unconfirm <id>`. (Postings confirmed in a live account are
    likewise `fixed:"0"`/visible — so this matches how existing data looks.)
  - The same behaviour was observed for a real multi-line extended booking
    (split); the live test above used a single free posting. A multi-line split
    is the same `/postings/add/free` per line.
- **`tax_key` on `/postings/get` rows is an UNDOCUMENTED numeric code.** The spec
  lists it only with the example value `"1"` — no enum, no meaning. It is the
  tax-treatment key behind the symbolic `vat` codes above (which ARE documented,
  each with a German label, in the `/postings/add/free` `vat` parameter
  description). The numeric key is independent of the chart of accounts (the same
  across SKR03/SKR04 — account *numbers* differ, the tax key does not). `butler`
  decodes the observed keys to that documented label — e.g. `9 → "19% Vst."`
  (domestic input VAT), `19 → "i.g.E. 19% USt./VSt."` (intra-community
  acquisition), `94 → "§13b 19% USt./VSt."` (reverse charge), `0 → "keine Ust."` —
  see `src/spec.zig` `tax_keys`. The numeric→symbolic bridge is empirically
  derived, so the raw key is always shown next to the label and an unknown key
  renders as unmapped. **[empirical — best-effort, not from the spec]**
- **Three posting classes; the UI "Erweitertes Buchen" shows only one.** A
  posting is created by one of three endpoints: `/postings/add/free` (free /
  extended booking), `/postings/add/receipt` (booked from a receipt), or
  `/postings/add/transaction` (booked directly on a bank transaction, no
  receipt). `/postings/get` returns all three; its `account` filter selects the
  class — `free booking` = free/extended only, `all financial accounts` =
  transaction/bank-side bookings, `all` (the default) = everything. The UI's
  "Erweitertes Buchen" corresponds to `free booking`, so a posting made directly
  on a payment (transaction class) does NOT appear there — it lives under
  `all financial accounts`. **[confirmed — observed via the account filter]**

## Get-by-id routes are broken

- **`/transactions/get/id_by_customer` and `/receipts/get/id_by_customer`
  return HTTP 404 (an HTML page, not a JSON error)** in practice, even though
  they are listed in the spec. Do not rely on them. **[confirmed]**
- Workaround: fetch from the corresponding list endpoint and filter. `butler`'s
  `transactions show <id>` uses the list endpoint's id range (see next point).

## `id_by_customer_from` / `id_by_customer_to` are BOTH exclusive

- On `/transactions/get`, the id range bounds are **both exclusive**: **[confirmed]**
  - `[416, 418]` → returns only id `417`
  - `[417, 419]` → returns only id `418`
  - `[417, 417]` → returns **nothing**
- To fetch exactly id `X`, query `[X-1, X+1]`. (This is how `transactions show`
  is implemented.)

## Listing requirements

- **`/postings/get` requires both `date_from` and `date_to`.** **[confirmed]**
- **`/receipts/get` requires `list_direction`**, exactly `inbound` or
  `outbound` (the spec gives no enum array, but those are the only valid
  values). **[confirmed]**
- **`order` parameter shape is inconsistent:** for `/postings/get` it is a
  **string** (`"date ASC"`); for `/receipts/get` it is an **object**
  (`{"date":"ASC"}`). **[spec]**
- List endpoints cap at high limits (postings `limit` max 1000; transactions /
  receipts max 500). **[spec]**

## Receipts (`/receipts/*`)

- **Upload field names:** the file goes in `file` as **base64**, and
  `file_name` is **required** alongside it (because `file` is base64). It is
  *not* `filename`, `file_content`, or `base64`. **[spec]**
- **Invoice-number field name is inconsistent:** `/receipts/upload` and
  `/receipts/add` expect `invoice_number` (underscore), but the `/receipts/get`
  **filter** uses `invoicenumber` (no underscore). **[spec]**
- **`/receipts/add` requires `currency`** (unlike `/receipts/upload`). **[spec]**

## Receipt-linked postings (`/postings/add/receipt`)

- Takes parallel arrays `postingaccounts`, `postingtexts`, `vats`, `amounts`
  (plus optional `cost_locations`, `cost_locations_two`) and scalars
  `receipt_id_by_customer`, `creditor`, `debtor`. **[spec]**
- **`creditor` and `debtor` are both REQUIRED** (integer Sammelkonto numbers;
  use `0` for the side that does not apply). **[spec]**

## Transaction-linked postings (`/postings/add/transaction`)

- Books directly onto a bank transaction (the contra side), so it takes only the
  charged `postingaccounts` (parallel `postingtexts`/`vats`/`amounts`) and the
  scalar `transaction_id_by_customer` — no debit/credit pair. **[spec]**
- **`oi_receipts_ids_by_customer` is REQUIRED even with open-item postings off.**
  Send one `null` per line (an array sized to the lines); `butler` does this
  automatically. **[spec]**

## Accounts & subledgers (`/settings/*`)

- The chart of accounts and the Personenkonten are three parallel `/settings`
  ledgers: `postingaccounts` (Sachkonten), `creditors` (Kreditoren) and
  `debtors` (Debitoren). Each has `get`, `add` and `update`
  (`/settings/{get,add,update}/{postingaccount,creditor,debtor}`), plus an
  `add-batch` for creditors/debtors. **[spec]**
- **There is NO delete endpoint for any of them.** The API exposes no
  `/settings/delete/*` (nor any delete route) for postingaccounts, creditors or
  debtors — once created, an account/creditor/debtor can only be edited via
  `update`, never removed through the API. Cleanup (deletion or deactivation)
  must be done in the BHB web UI. `butler` therefore offers `add`/`update` for
  these resources but no `delete`. **[spec]**
- **`get` for creditors/debtors paginates (default 25 rows/page);** `butler`
  sweeps every page (advancing the offset by the rows actually returned) unless
  `--limit` bounds it. `get/postingaccounts` returns the chart in one response.
- **`get/creditors` and `get/debtors` have no get-by-id route** (like the other
  resources, see above), so a single-record lookup fetches the list and matches
  `postingaccount_number` client-side. **[spec]**
- **`add` returns no id** (the same envelope-only quirk as `/postings/add/*`); on
  creditor/debtor `add` you may omit `postingaccount_number` to have BHB assign
  the next free one — re-query the list to learn it. `add/postingaccount`
  requires the number plus a `parent_postingaccount_number`. **[spec]**

---

*This document reflects the API as observed in 2026 against spec `1.9.1`.
Behaviour may change; treat `[spec]` points as unverified until exercised.*
