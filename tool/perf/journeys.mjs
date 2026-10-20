// Evenda signed-in load and concurrency tests.
//
// Needs two onboarded TEST vendor accounts (never real businesses):
//   A: a rental vendor with one published listing that tracks stock
//   B: any other onboarded vendor
// Env:
//   SUPABASE_URL, SUPABASE_KEY (publishable)
//   A_EMAIL, A_PASSWORD, A_LISTING (listing id with stock), B_EMAIL, B_PASSWORD
// Run:   node tool/perf/journeys.mjs race|quote|load|all
//
// What it creates, and how it cleans up:
//   race   manual reservations on A_LISTING for a date ~200 days ahead,
//          cancelled again at the end (move_reservation 'cancel').
//   quote  one quote request B -> A, one quotation, one booking, which is then
//          cancelled. Rows stay (bookings are never deleted) and are labelled
//          "QA concurrency test".
//   load   reads only.
const URL = process.env.SUPABASE_URL ?? 'https://plihgjgaabxwlbugqbni.supabase.co';
const KEY = process.env.SUPABASE_KEY ?? 'sb_publishable_h-G5GdACswONm25AOMO0WA_EedeK-xm';
const need = (k) => process.env[k] ?? (() => { throw new Error(`missing env ${k}`); })();

async function signIn(email, password) {
  const r = await fetch(`${URL}/auth/v1/token?grant_type=password`, {
    method: 'POST', headers: { apikey: KEY, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password }),
  });
  const j = await r.json();
  if (!r.ok) throw new Error(`sign-in ${email}: ${j.msg ?? j.error_description ?? r.status}`);
  return j.access_token;
}

function client(token) {
  const h = { apikey: KEY, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
  return {
    rpc: async (fn, body) => {
      const r = await fetch(`${URL}/rest/v1/rpc/${fn}`, { method: 'POST', headers: h, body: JSON.stringify(body ?? {}) });
      const t = await r.text();
      const j = t ? JSON.parse(t) : null;
      return { ok: r.ok, status: r.status, data: j, error: r.ok ? null : (j?.message ?? String(r.status)) };
    },
    get: async (path) => {
      const r = await fetch(`${URL}/rest/v1/${path}`, { headers: h });
      return { ok: r.ok, status: r.status, data: await r.json().catch(() => null) };
    },
  };
}

const iso = (d) => d.toISOString().slice(0, 10);
const pct = (xs, p) => xs[Math.min(xs.length - 1, Math.floor((p / 100) * xs.length))];
let failures = 0;
const check = (cond, msg) => { console.log(`${cond ? 'PASS' : 'FAIL'}  ${msg}`); if (!cond) failures++; };

// --- 1. Last units: N+k simultaneous reservations for the same day ----------
async function race(A) {
  const listing = need('A_LISTING');
  const day = new Date(Date.now() + 200 * 864e5);
  const from = iso(day);
  const avail = (await A.rpc('available_quantity', { p_listing: listing, p_from: from, p_to: from })).data;
  if (!(avail > 0)) throw new Error(`listing has no free stock on ${from} (got ${avail})`);
  const target = Math.min(avail, 5);
  // Leave exactly `target` units free by holding the rest, then race for them.
  const hold = avail - target;
  const created = [];
  if (hold > 0) {
    const h = await A.rpc('record_manual_reservation', { p_listing: listing, p_quantity: hold, p_from: from, p_to: from, p_client_label: 'QA hold' });
    if (h.ok) created.push(h.data);
  }
  const attempts = target + 7;
  const t0 = performance.now();
  const results = await Promise.all(Array.from({ length: attempts }, (_, i) =>
    A.rpc('record_manual_reservation', { p_listing: listing, p_quantity: 1, p_from: from, p_to: from, p_client_label: `QA race ${i}` })));
  const ms = performance.now() - t0;
  const won = results.filter((r) => r.ok);
  const lost = results.filter((r) => !r.ok);
  created.push(...won.map((r) => r.data));
  const after = (await A.rpc('available_quantity', { p_listing: listing, p_from: from, p_to: from })).data;
  console.log(`race: ${attempts} simultaneous requests for ${target} free units on ${from} in ${ms.toFixed(0)} ms`);
  check(won.length === target, `exactly ${target} reservations succeeded (got ${won.length})`);
  check(lost.every((r) => r.error === 'insufficient_availability'), `every loser got insufficient_availability (${[...new Set(lost.map((r) => r.error))].join(', ')})`);
  check(after === 0, `no stock left and none oversold (available now ${after})`);
  for (const id of created) await A.rpc('move_reservation', { p_reservation: id, p_action: 'cancel' });
  const restored = (await A.rpc('available_quantity', { p_listing: listing, p_from: from, p_to: from })).data;
  check(restored === avail, `cleanup restored availability to ${avail} (now ${restored})`);
}

// --- 2. Same quotation accepted many times at once ---------------------------
async function quote(A, B, bizA, bizB) {
  const listing = need('A_LISTING');
  const day = iso(new Date(Date.now() + 210 * 864e5));
  const req = await B.rpc('create_quote_request', { p: {
    requester_business_id: bizB, supplier_business_id: bizA, needed_from: day, needed_to: day,
    message: 'QA concurrency test - please ignore', idempotency_key: crypto.randomUUID(),
    items: [{ listing_id: listing, description: 'QA concurrency test', quantity: 1 }],
  } });
  if (!req.ok) throw new Error(`create_quote_request: ${req.error}`);
  const qt = await A.rpc('send_quotation', { p: {
    request_id: req.data, valid_until: day, payment_terms: 'QA', conditions: 'QA concurrency test',
    items: [{ listing_id: listing, description: 'QA concurrency test', quantity: 1, unit_price: 1, days: 1 }],
  } });
  if (!qt.ok) throw new Error(`send_quotation: ${qt.error}`);
  const sameKey = crypto.randomUUID();
  const calls = [
    ...Array.from({ length: 3 }, () => B.rpc('accept_quotation', { p_quotation: qt.data, p_idempotency_key: sameKey })),
    ...Array.from({ length: 3 }, () => B.rpc('accept_quotation', { p_quotation: qt.data, p_idempotency_key: crypto.randomUUID() })),
  ];
  const res = await Promise.all(calls);
  const ids = new Set(res.filter((r) => r.ok).map((r) => r.data));
  const bookings = (await B.get(`bookings?quotation_id=eq.${qt.data}&select=id`)).data ?? [];
  console.log(`quote: 6 simultaneous accepts -> ${res.filter((r) => r.ok).length} ok, errors: ${[...new Set(res.filter((r) => !r.ok).map((r) => r.error))].join(', ') || 'none'}`);
  check(bookings.length === 1, `exactly one booking exists for the quotation (found ${bookings.length})`);
  check(ids.size <= 1, `every successful accept returned the same booking (${ids.size} distinct)`);
  check(res.filter((r) => !r.ok).every((r) => r.error === 'quotation_not_open'), 'rejected accepts said quotation_not_open');
  if (bookings[0]) await A.rpc('update_booking_status', { p_booking: bookings[0].id, p_to: 'cancelled', p_note: 'QA concurrency test cleanup' });
}

// --- 3. Signed-in browsing at increasing concurrency -------------------------
async function load(A) {
  const steps = [
    () => A.get('listings?select=*,listing_photos(storage_path,sort),businesses(id,name,logo_path,neighbourhood,verification_status,whatsapp,phone)&status=eq.published&moderation_status=eq.ok&limit=60'),
    () => A.get('categories?select=id,name,kind,icon,sort,active&order=sort.asc'),
    () => A.get('notifications?select=*&order=created_at.desc&limit=50'),
    () => A.get('bookings?select=id,reference,status,total&order=starts_on.asc&limit=200'),
  ];
  console.log('load  users  journeys  p50   p95   p99  errors');
  for (const users of [2, 5, 10, 25]) {
    const times = []; let errors = 0;
    await Promise.all(Array.from({ length: users }, async () => {
      for (let j = 0; j < 5; j++) for (const s of steps) {
        const t = performance.now();
        const r = await s();
        times.push(performance.now() - t);
        if (!r.ok) errors++;
      }
    }));
    times.sort((a, b) => a - b);
    console.log(`      ${String(users).padStart(5)}  ${String(users * 5).padStart(8)}  ${pct(times, 50).toFixed(0).padStart(4)}  ${pct(times, 95).toFixed(0).padStart(4)}  ${pct(times, 99).toFixed(0).padStart(4)}  ${errors}`);
  }
}

const mode = process.argv[2] ?? 'all';
const A = client(await signIn(need('A_EMAIL'), need('A_PASSWORD')));
const B = ['quote', 'all'].includes(mode) ? client(await signIn(need('B_EMAIL'), need('B_PASSWORD'))) : null;
const myBiz = async (c) => (await c.rpc('my_business_ids')).data?.[0] ?? (await c.get('business_members?select=business_id&status=eq.active&limit=1')).data?.[0]?.business_id;
console.log(`target ${URL}  mode ${mode}  ${new Date().toISOString()}`);
if (mode === 'race' || mode === 'all') await race(A);
if (mode === 'quote' || mode === 'all') await quote(A, B, await myBiz(A), await myBiz(B));
if (mode === 'load' || mode === 'all') await load(A);
console.log(failures ? `\n${failures} CHECK(S) FAILED` : '\nALL CHECKS PASSED');
process.exit(failures ? 1 : 0);
