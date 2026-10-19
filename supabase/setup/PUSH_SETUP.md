# Evenda push notifications — one-time setup

In-app notifications and reminders already work. These steps make them reach
phones when Evenda is closed. About 15 minutes.

## 1. Firebase project (Google account)
1. Go to https://console.firebase.google.com → **Add project** → name it `Evenda`
   (Google Analytics: optional, can be off).
2. In the project: **Add app → Android**.
   - Package name: `com.dantechsolutionsgroup.evenda` (must match exactly)
   - App nickname: `Evenda Android`
   - Skip the SHA-1 and the SDK steps (already done in the code).
3. Download **google-services.json** and put it here: `android/app/google-services.json`.
   The build picks it up automatically; nothing else to change.
4. **Project settings → Service accounts → Generate new private key.**
   This downloads a JSON file. It is a secret: never commit it or put it in the app.

## 2. Deploy the send-push function (Supabase dashboard)
1. **Edge Functions → Deploy a new function → Via editor.**
   Name: `send-push`. Replace the code with `supabase/functions/send-push/index.ts` and deploy.
2. Open the function → **Details/Settings** → turn **Enforce JWT verification OFF**.
   (The scheduler calls it with a shared secret instead of a user login.)
3. **Edge Functions → Secrets** → add:
   - `FCM_SERVICE_ACCOUNT_JSON` = the whole content of the service-account JSON from step 1.4
   - `PUSH_CRON_SECRET` = `<your PUSH_CRON_SECRET>`

## 3. Database (SQL Editor) — run each once
1. `supabase/migrations/20261018000200_precise_location.sql` (if not run yet)
2. `supabase/migrations/20261018000300_push_urgency.sql`
3. Tell the scheduler where the function is:

```sql
select vault.create_secret('https://plihgjgaabxwlbugqbni.supabase.co', 'project_url');
select vault.create_secret('<your PUSH_CRON_SECRET>', 'push_cron_secret');
```

The `evenda-push` job (already scheduled every minute) starts sending as soon as
these two secrets exist.

## 4. Check it works
- Rebuild and install the app, sign in, allow notifications.
- SQL Editor: `select platform, updated_at from device_tokens;` → your phone appears.
- Edge Functions → send-push → **Logs**: each minute shows `claimed / sent / failed`.
