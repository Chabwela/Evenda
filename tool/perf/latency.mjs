// Evenda backend latency probe. Measures round-trip time from this machine to
// Supabase at increasing concurrency. Anonymous only: it touches no user data.
// Usage: node tool/perf/latency.mjs [requestsPerLevel=40]
// Env: SUPABASE_URL, SUPABASE_KEY (publishable). For signed-in journeys use
// tool/perf/journeys.mjs with test accounts (see README.md).
const URL = process.env.SUPABASE_URL ?? 'https://plihgjgaabxwlbugqbni.supabase.co';
const KEY = process.env.SUPABASE_KEY ?? 'sb_publishable_h-G5GdACswONm25AOMO0WA_EedeK-xm';
const PER_LEVEL = Number(process.argv[2] ?? 40);
const LEVELS = [1, 2, 5, 10, 25];
const H = { apikey: KEY, 'Content-Type': 'application/json' };

const probes = {
  // Gateway + Auth service, no database work.
  auth_health: () => fetch(`${URL}/auth/v1/health`, { headers: H }),
  // PostgREST read: a real SQL query through RLS (anon sees no rows).
  rest_read: () => fetch(`${URL}/rest/v1/categories?select=id,name&order=sort.asc`, { headers: H }),
  // RPC call: reaches Postgres, which refuses anon (permission check in DB).
  rpc_call: () => fetch(`${URL}/rest/v1/rpc/available_quantity`, {
    method: 'POST', headers: H,
    body: JSON.stringify({ p_listing: '00000000-0000-0000-0000-000000000000', p_from: '2026-11-01', p_to: '2026-11-01' }),
  }),
};

const pct = (xs, p) => xs[Math.min(xs.length - 1, Math.floor((p / 100) * xs.length))];

async function level(name, fn, conc) {
  const times = []; let errors = 0, next = 0;
  async function worker() {
    while (next < PER_LEVEL) {
      next++;
      const t = performance.now();
      try { const r = await fn(); await r.arrayBuffer(); if (r.status >= 500) errors++; }
      catch { errors++; }
      times.push(performance.now() - t);
    }
  }
  const t0 = performance.now();
  await Promise.all(Array.from({ length: conc }, worker));
  const wall = (performance.now() - t0) / 1000;
  times.sort((a, b) => a - b);
  return { probe: name, conc, n: times.length, p50: pct(times, 50), p95: pct(times, 95), p99: pct(times, 99), max: times.at(-1), rps: times.length / wall, errors };
}

console.log(`target ${URL}  requests/level ${PER_LEVEL}  started ${new Date().toISOString()}`);
console.log('probe        conc    n    p50     p95     p99     max   req/s  5xx/err');
for (const [name, fn] of Object.entries(probes)) {
  await fn().then((r) => r.arrayBuffer()).catch(() => {}); // warm the connection
  for (const c of LEVELS) {
    const r = await level(name, fn, c);
    console.log(`${r.probe.padEnd(12)} ${String(r.conc).padStart(4)} ${String(r.n).padStart(4)} ${r.p50.toFixed(0).padStart(6)}  ${r.p95.toFixed(0).padStart(6)}  ${r.p99.toFixed(0).padStart(6)}  ${r.max.toFixed(0).padStart(6)}  ${r.rps.toFixed(1).padStart(5)}  ${r.errors}`);
  }
}
