// send-push: delivers pending push notifications through Firebase Cloud Messaging (HTTP v1).
//
// Invoked every minute by pg_cron (see migrations/..._schedules.sql). Each run claims a batch of
// due deliveries with FOR UPDATE SKIP LOCKED, so overlapping runs never send the same row twice.
// Failures are retried with exponential backoff by complete_push_delivery().
//
// Required secrets (supabase secrets set ...):
//   FCM_SERVICE_ACCOUNT_JSON  Firebase service-account JSON (project with Cloud Messaging enabled)
//   PUSH_CRON_SECRET          must match the Vault secret push_cron_secret
// Provided automatically: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY

import { createClient } from "jsr:@supabase/supabase-js@2";

type Claimed = {
  delivery_id: string;
  user_id: string;
  title: string;
  body: string;
  data: Record<string, unknown>;
  tokens: string[];
};

type ServiceAccount = { client_email: string; private_key: string; project_id: string };

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);

let cachedToken: { value: string; expiresAt: number } | null = null;

function base64url(input: ArrayBuffer | string): string {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : new Uint8Array(input);
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function accessToken(sa: ServiceAccount): Promise<string> {
  if (cachedToken && cachedToken.expiresAt > Date.now() + 60_000) return cachedToken.value;
  const now = Math.floor(Date.now() / 1000);
  const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = base64url(JSON.stringify({
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  }));
  const pem = sa.private_key.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    "pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"],
  );
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${header}.${claims}`));
  const jwt = `${header}.${claims}.${base64url(signature)}`;

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: jwt }),
  });
  if (!res.ok) throw new Error(`oauth_failed ${res.status}`);
  const json = await res.json();
  cachedToken = { value: json.access_token, expiresAt: Date.now() + json.expires_in * 1000 };
  return cachedToken.value;
}

// FCM data values must be strings.
function stringify(data: Record<string, unknown>): Record<string, string> {
  return Object.fromEntries(
    Object.entries(data).filter(([, v]) => v !== null && v !== undefined).map(([k, v]) => [k, String(v)]),
  );
}

function urgent(item: Claimed): boolean {
  return item.data.category === "now" || item.data.urgent === true || item.data.urgent === "true";
}

// A new Evenda Now request for a supplier (route /now/respond/<id>).
function nowRequest(item: Claimed): boolean {
  return typeof item.data.route === "string" && item.data.route.startsWith("/now/respond/");
}

// Android: data-only and high priority, so the app's EvendaMessagingService
// wakes even when Evenda is closed and rings like a call (full-screen,
// repeating). iOS still gets a normal time-sensitive alert.
function nowRequestMessage(token: string, item: Claimed) {
  return {
    token,
    data: stringify({ ...item.data, kind: "now_request", title: item.title, body: item.body }),
    android: { priority: "HIGH", ttl: "900s" },
    apns: {
      headers: { "apns-priority": "10" },
      payload: { aps: { alert: { title: item.title, body: item.body }, sound: "default", "interruption-level": "time-sensitive" } },
    },
  };
}

async function sendOne(sa: ServiceAccount, token: string, item: Claimed): Promise<{ ok: boolean; stale: boolean; error?: string }> {
  const res = await fetch(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`, {
    method: "POST",
    headers: { "Authorization": `Bearer ${await accessToken(sa)}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      message: nowRequest(item) ? nowRequestMessage(token, item) : {
        token,
        notification: { title: item.title, body: item.body },
        data: stringify(item.data),
        // Channels are created by the app (MainActivity). Urgent = Evenda Now and
        // critical reminders: high priority on the pop-up-and-sound channel.
        android: urgent(item)
          ? { priority: "HIGH", notification: { channel_id: "evenda_urgent_v2", sound: "evenda_urgent", tag: String(item.data.notification_id ?? "") } }
          : { priority: "NORMAL", notification: { channel_id: "evenda_default_v2", sound: "evenda_chime", tag: String(item.data.notification_id ?? "") } },
        apns: { payload: { aps: { sound: "default", ...(urgent(item) ? { "interruption-level": "time-sensitive" } : {}) } } },
      },
    }),
  });
  if (res.ok) return { ok: true, stale: false };
  const text = await res.text();
  // UNREGISTERED / INVALID_ARGUMENT tokens are removed so they are not retried forever.
  const stale = res.status === 404 || text.includes("UNREGISTERED");
  return { ok: false, stale, error: `${res.status} ${text.slice(0, 300)}` };
}

Deno.serve(async (req) => {
  if (req.headers.get("x-cron-secret") !== Deno.env.get("PUSH_CRON_SECRET")) {
    return new Response("forbidden", { status: 403 });
  }
  const raw = Deno.env.get("FCM_SERVICE_ACCOUNT_JSON");
  if (!raw) {
    // Not configured: leave deliveries pending rather than pretending they were sent.
    return Response.json({ skipped: "FCM_SERVICE_ACCOUNT_JSON not set" }, { status: 503 });
  }
  const sa = JSON.parse(raw) as ServiceAccount;

  const { data, error } = await supabase.rpc("claim_push_deliveries", { p_limit: 200 });
  if (error) return Response.json({ error: error.message }, { status: 500 });

  let sent = 0, failed = 0;
  for (const item of (data ?? []) as Claimed[]) {
    if (item.tokens.length === 0) {
      await supabase.rpc("complete_push_delivery", { p_delivery: item.delivery_id, p_ok: true, p_error: "no_devices" });
      continue;
    }
    let anyOk = false;
    let lastError: string | undefined;
    for (const token of item.tokens) {
      const r = await sendOne(sa, token, item);
      if (r.ok) anyOk = true;
      else lastError = r.error;
      if (r.stale) await supabase.from("device_tokens").delete().eq("token", token);
    }
    await supabase.rpc("complete_push_delivery", { p_delivery: item.delivery_id, p_ok: anyOk, p_error: anyOk ? null : lastError });
    anyOk ? sent++ : failed++;
  }
  return Response.json({ claimed: data?.length ?? 0, sent, failed });
});
