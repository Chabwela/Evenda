# Evenda — proposed Google Play Data safety answers

Derived from the source code on 20 Oct 2026 (Flutter app + Supabase
migrations). **Compare with the Play Console form before submitting; the
console form was not available for inspection.**

## Overview answers
| Question | Proposed answer | Evidence |
|---|---|---|
| Does the app collect or share user data? | Yes, collects | Supabase auth/profile/business tables |
| Is all data encrypted in transit? | Yes | All traffic to Supabase, FCM and tile servers is HTTPS (`AppConfig.supabaseUrl`, no cleartext in the merged manifest) |
| Can users request deletion? | Yes, in the app and on the web | `delete_account_screen.dart`, migration `20261020000300_account_deletion.sql`, `docs/play/delete-account.html` |
| Shared with third parties? | No | Supabase, FCM, the email sender and the tile provider are **service providers** acting for Evenda (Play's definition excludes them from "sharing"). Profiles and listings shown to other vendors are user-initiated. |

## Data types
| Play category → type | Collected | Required? | Purpose(s) | Evidence |
|---|---|---|---|---|
| Personal info → Name | Yes | Required | Account management, App functionality | `profiles.full_name`, sign-up form |
| Personal info → Email address | Yes | Required | Account management | Supabase Auth email sign-up |
| Personal info → Phone number | Yes | Required for onboarding | App functionality (other vendors call/WhatsApp you) | `businesses.phone/whatsapp`, onboarding step 2 |
| Personal info → Address | Yes | Optional | App functionality | `businesses.address_line` |
| Personal info → User IDs | Yes | Required | Account management | Supabase user UUID |
| Location → Precise location | Yes | Required for onboarding (pin) | App functionality | `businesses.location` (exact pin, from GPS on request or placed by hand); Evenda Now request location |
| Location → Approximate location | Yes | Required | App functionality | `businesses.public_location` (~500 m) |
| Financial info → Other financial info | Yes | Optional | App functionality (payment records between vendors) | `payment_records` (amount, method, reference). No card/bank/mobile-money credentials are collected. |
| Messages → Other in-app messages | Yes | Optional | App functionality | `quote_messages` |
| Photos and videos → Photos | Yes | Optional | App functionality | Listing photos, logo (`listing-photos`, `business-logos` buckets) |
| Files and docs → Files and docs | Yes | Optional | App functionality, Fraud prevention/security (verification) | `verification` bucket (PACRA, TPIN, NRC) |
| App activity → Other user-generated content | Yes | Optional | App functionality | Listings, quote requests, bookings, events, tasks |
| Device or other IDs → Device or other IDs | Yes | Optional (only if notifications allowed) | App functionality (push) | `device_tokens` (FCM registration token) |

**Not collected** (no code or SDK found): health, contacts, calendar, audio,
web history, installed apps, search history outside the app, crash logs,
diagnostics, advertising ID. No analytics, advertising or crash-reporting SDK
is in `pubspec.yaml`.

## Unknowns to confirm
- **Firebase Messaging SDK:** Google states FCM may collect a Firebase
  installation ID and device information to deliver messages. Check
  Firebase's current "Data disclosure for Google Play" page and add any
  types it lists.
- **Map tiles:** the default tile server is OpenStreetMap's. Tile requests
  reveal IP address and the map area viewed to that provider. Switch to a
  contracted tile provider before production (OSM's tile policy does not allow
  production apps), then name that provider in the privacy policy.
- **Email sender:** confirm which SMTP provider sends the codes (Gmail or
  Resend) and name it in the privacy policy.
