# Evenda performance & concurrency — beta baseline (20 Oct 2026)

Everything below was measured, unless marked **not yet run**. Measurements
were taken from a laptop in Lusaka against the production Supabase project,
and on a TECNO CC7 (Android 9, low-to-mid range).

## Architecture (what runs where)

| Layer | What it does |
|---|---|
| Flutter 3.44.8 app | Riverpod state, go_router; all reads through Supabase REST with RLS; every business rule is a Postgres RPC |
| Postgres (Supabase) | Availability, reservations (row lock on the listing), quotes → bookings, Evenda Now matching, notifications, audit |
| pg_cron | Reminders (1 min), push sender (1 min), expiry of Now requests and quotations, digests |
| Edge Function `send-push` | Claims due deliveries (`FOR UPDATE SKIP LOCKED`) and sends via FCM |
| Realtime | One channel per signed-in business; events only trigger a refetch |
| Storage | Listing photos and logos (public), verification documents (private, 10-minute signed URLs) |

## Baseline measurements

### Backend round trips (`node tool/perf/latency.mjs 40`)
40 requests per level, anonymous, 20 Oct 2026 03:20 UTC.

| Probe | Users at once | p50 | p95 | p99 | Errors |
|---|---|---|---|---|---|
| Auth health (network only) | 1 | 270 ms | 405 ms | 986 ms | 0 |
| | 25 | 492 ms | 835 ms | 839 ms | 0 |
| REST read through RLS | 1 | 387 ms | 513 ms | 534 ms | 0 |
| | 10 | 475 ms | 963 ms | 996 ms | 0 |
| | 25 | 838 ms | 1467 ms | 1705 ms | 0 |
| RPC (database function) | 1 | 377 ms | 475 ms | 506 ms | 0 |
| | 10 | 389 ms | 2322 ms | 2327 ms | 0 |
| | 25 | 687 ms | 865 ms | 870 ms | 0 |

Reading: ~270 ms of every request is the network path to Supabase. The
database adds ~100 ms. No errors up to 25 concurrent callers. Tail latency
(p95) grows to 1–2 s from 5+ concurrent callers; with 40 samples per level the
p95/p99 figures are noisy. **The cost that matters is the number of
sequential round trips per screen, not database speed.**

Limits: anonymous probes only (RLS returns no rows), so they measure the
request path, not heavy queries. Signed-in journeys are in `journeys.mjs`
(not yet run, needs test accounts).

### App start-up (profile build, TECNO CC7)
| Metric | Result |
|---|---|
| Engine start → first frame (`--trace-startup`) | 1.08 s |
| Android cold start to first frame (`am start -W`, 5 runs) | 2.54–2.63 s (median 2.56 s) |
| Tap → real content (admin overview with data) | ≈ 4 s (screenshots at 1 s intervals) |

The gap between first frame and content is three sequential round trips
(session restore → admin role / business). Not changed in this pass.

## Problems found and fixed

| # | Problem | Evidence | Fix |
|---|---|---|---|
| P1 | Date search checked stock with **one round trip per listing**, sequentially (up to 60) | Code; at the measured ~370 ms per RPC that is up to ~22 s | `available_quantities()` RPC: one call for all results. Own-business lookup now runs alongside the search |
| P2 | Listing editor applied stock edits as **absolute** values: a concurrent stock change by a teammate was silently reverted | Code: delta computed against the server's current total | Delta is now relative to what the editor opened; save refused (`stale_write`) if the listing changed meanwhile |
| P3 | Business profile saves **overwrote** concurrent edits (last write wins) | Code; `updated_at` only changed on name/description/location edits | `updated_at` trigger on every update; saves check the version and are refused with a clear message if someone saved in between |
| P4 | Thumbnails decoded full-size photos (up to 1600 px) | Code (`CachedNetworkImage` without cache size) | Decode at display size × pixel ratio |
| P5 | Foreign-key columns used by embedded selects and RLS had no indexes (21) | Schema review (Postgres does not index referencing columns) | Indexes in `20261020000200_performance.sql` |
| P6 | Nine list queries silently sorted newest-first (postgrest-dart default) | Fixed earlier (commit 39853d6) | Explicit sort direction everywhere |
| T1 | Full test suite hung | A layout test awaited DemoBackend's real timers under the fake clock | Run on the real clock |
| T2 | Layout tests measured text in the Ahem test font (~2× wider) | "Awaiting quote" measured 232 px | Tests load Figtree/Fraunces; then found a real 15 px overflow at 1.3× text in booking rows, fixed |

Verified already correct (code review, not load-tested): stock reservation
locks the listing row (`reserve_stock ... for update`); quotation acceptance
and Now offer selection are idempotent and backed by unique constraints
(`bookings.quotation_id`, `bookings.now_offer_id`); push delivery claims rows
with `SKIP LOCKED` and notifications are de-duplicated by key; stale search
responses are discarded (sequence number).

## Concurrency & load tests — **not yet run**

`tool/perf/journeys.mjs` (needs two TEST vendor accounts):

- `race`: 12 simultaneous reservations for the last 5 units → expects exactly
  5 successes, the rest `insufficient_availability`, availability 0, cleanup
  restores it.
- `quote`: the same quotation accepted 6× at once (3 with one idempotency
  key, 3 with different keys) → expects exactly one booking.
- `load`: browse journeys at 2, 5, 10, 25 signed-in users, p50/p95/p99.

```
export A_EMAIL=... A_PASSWORD=... A_LISTING=<listing uuid> B_EMAIL=... B_PASSWORD=...
node tool/perf/journeys.mjs all
```

Run it against a staging project if possible. On production it creates
labelled test reservations (cancelled afterwards) and one cancelled test booking.

## Provisional beta targets (to validate, not guarantees)
- Reads p95 < 800 ms and writes p95 < 1.2 s at 10 concurrent users from Lusaka.
  The 500/800 ms targets in the brief are not reachable while ~270 ms of every
  request is network distance; revisit if the project region changes.
- No screen needing more than 2 sequential round trips before showing content.
- Zero oversold stock and zero duplicate bookings in the concurrency tests.

## Not done / next
- Run `journeys.mjs` (blocked on test accounts).
- `EXPLAIN ANALYZE` of discovery and RLS-heavy queries (no SQL access from here;
  run in the SQL Editor with real data volumes).
- Start-up: fetch admin role and business in one call.
- Soak test (memory over 30+ minutes of use) with DevTools on the phone.
- Cost: none of this needs a paid tier or extra services. No cache layer, Redis
  or queue is justified by these measurements.
