# Evenda — Google Play production readiness audit

Date: 20 Oct 2026. Package `com.dantechsolutionsgroup.evenda`, version 0.1.0 (1).
Flutter 3.44.8. Inspected: repository, merged release manifest, a release AAB
built on 20 Oct 2026 (before the signing fix), official Google pages listed at
the end. Not available: Play Console, the upload key, the hosted policy URLs.

## 1. Verdict: **NO-GO**
Confirmed blockers remain that need you (upload key, hosted privacy and
deletion pages, live database migration, Play Console tasks). The code-side
blockers found in this audit are fixed.

## 2. Compliance checklist
| Requirement | Status | Evidence | Finding | Action |
|---|---|---|---|---|
| Target API ≥ 36 (new apps, from 31 Aug 2026) | PASS | Merged manifest `targetSdkVersion="36"` | Flutter default 36 | — |
| minSdk / compileSdk | PASS | minSdk 24, compileSdk 36 | Android 7.0+ | — |
| Release signed with an upload key | FAIL | AAB certificate "CN=Android Debug" | Play rejects debug-signed bundles | **Fixed in code**: release builds now require `android/key.properties` and refuse otherwise. You must create the key (§4) |
| App bundle builds | PASS (unsigned for Play) | `app-release.aab` 72.4 MB built 20 Oct | Built with the debug key | Rebuild after creating the key |
| Versioning | PASS | `version: 0.1.0+1` | Fine for a first upload | Increase `+N` on every upload |
| Debug settings in release | PASS | No `debuggable`, no cleartext flag in merged manifest | — | — |
| Secrets in the app | PASS | Only the Supabase publishable key and Firebase client config (both public by design); no service-role key | — | — |
| Backup of session tokens | PASS (fixed) | `allowBackup` was the default (true), so Android could back up the saved sign-in session | Set `allowBackup="false"` | — |
| Permissions justified | PASS | INTERNET, ACCESS_NETWORK_STATE, FINE/COARSE_LOCATION, POST_NOTIFICATIONS, WAKE_LOCK, C2DM RECEIVE | All used (see §5) | — |
| Privacy policy | FAIL | None existed | Draft at `docs/play/privacy-policy.html`, built from the code | Confirm the [CONFIRM] items, host it publicly, enter the URL in Play Console, build with `--dart-define=PRIVACY_POLICY_URL=…` |
| In-app account deletion | FAIL → fixed in code | None existed | Business → Account & privacy → Delete account; backend `delete_my_account()` | Run migration `20261020000300`; test with a throwaway account |
| Web account-deletion page | FAIL | None existed | Draft at `docs/play/delete-account.html` | Confirm, host, enter URL in Data safety |
| Data safety form | NOT TESTED | No console access | Proposed answers in `DATA_SAFETY.md` | Fill in and compare with the console |
| Store listing assets | FAIL | None existed | 512 px icon and feature graphic created; listing text drafted | Add ≥ 2 real phone screenshots, support email, category, content rating |
| Reviewer access | NOT TESTED | App is fully behind sign-in | — | Provide a test vendor account in App access |
| Testing track / production access | BLOCKED | Account type and creation date unknown | Personal accounts created after 13 Nov 2023 need a closed test with 12+ testers for 14 continuous days | Tell me the account type |
| Map tiles in production | FAIL (policy risk, not a Play rule) | `AppConfig.mapTileUrl` defaults to tile.openstreetmap.org | OSM tile policy forbids production apps | Choose a tile provider (e.g. MapTiler, Stadia) |
| Static analysis / tests | PASS | `flutter analyze`: no issues; `flutter test`: 27/27 | — | — |

## 3. Release blockers (confirmed)
1. **No upload key**: bundles are debug-signed (`android/app/build.gradle.kts`).
2. **No public privacy policy URL** (Play User Data policy).
3. **Account deletion not live**: the code is done, but migration
   `20261020000300_account_deletion.sql` is not applied, and the web deletion
   page is not hosted.
4. **Play Console declarations not done**: Data safety, App access, content
   rating, target audience, store listing screenshots.
5. **Production access** may require a 14-day closed test (account type unknown).

Risks, not blockers: OSM tiles; Firebase SDK data disclosures to confirm;
unapplied earlier migrations (`…000200` admin review through
`…20261020000200` performance). Without the performance migration, supplier
search with dates fails.

## 4. Developer actions, in order
1. Apply pending migrations in the SQL Editor, in filename order:
   `20261019000200`, `…0300`, `…0400`, `20261020000100`, `…0200`, `…0300`.
2. Create the upload key (keep it and the passwords somewhere safe; losing it
   blocks updates unless Google resets it):
   `keytool -genkeypair -v -keystore ~/evenda-upload.jks -keyalg RSA -keysize 2048 -validity 10000 -alias evenda-upload`
   then create `android/key.properties` (template in `build.gradle.kts`).
3. Fill in the [CONFIRM] items in `privacy-policy.html` and `delete-account.html`
   and host both publicly (your website, Google Sites or GitHub Pages).
4. Pick a map tile provider; set `MAP_TILE_URL`/`MAP_ATTRIBUTION`.
5. Build: `flutter build appbundle --release --dart-define=PRIVACY_POLICY_URL=… --dart-define=ACCOUNT_DELETION_URL=… --dart-define=MAP_TILE_URL=…`
6. Test account deletion end to end with a throwaway account (never a real vendor).
7. **Play Console (manual):** create the app; enrol in Play App Signing; App
   content (privacy URL, Data safety from `DATA_SAFETY.md`, data deletion URL,
   App access with a test account, content rating, target audience 18+, ads: none);
   store listing (text from `STORE_LISTING.md`, icon, feature graphic, screenshots).
8. Upload to Internal testing, then Closed testing; if required, keep 12+
   testers opted in for 14 days; then apply for production access.

## 5. Evidence
- **Target API / config:** `build/app/intermediates/merged_manifests/release/…/AndroidManifest.xml`: min 24, target 36.
- **Release AAB:** `build/app/outputs/bundle/release/app-release.aab` (72.4 MB, 20 Oct 2026), signed "CN=Android Debug", so not uploadable. NOT PROVIDED: an upload-signed AAB.
- **Privacy policy:** draft in repo; hosted URL NOT PROVIDED.
- **Account deletion:** `lib/features/business/delete_account_screen.dart`, `AuthApi.deleteAccount` (removes storage files, then `delete_my_account()`), migration `20261020000300`; widget test `test/widgets/delete_account_test.dart` passes. Server function NOT YET APPLIED or run.
- **Data safety:** proposal `DATA_SAFETY.md`; console state NOT PROVIDED.
- **Permissions:**
  - Location: business pin and Evenda Now; asked only when "Use my location" is tapped or on first open of the pin step, with an explanation; denying falls back to placing the pin by hand.
  - Notifications: asked after sign-in.
  - Network state: offline banner.
  - WAKE_LOCK / C2DM: added by Firebase Messaging.
  - No camera or storage permission: photos use the system picker.
- **Store listing:** icon and feature graphic in `docs/play/assets/`; screenshots NOT PROVIDED.
- **Testing track / production access:** NOT PROVIDED.

## 6. Can the current release be submitted to production now?
**No.** The code-level blockers are fixed. Submission still needs an
upload-signed bundle, a hosted privacy policy and deletion page, the account
deletion migration applied, and the Play Console declarations. Even then,
Google reviews every submission, and a newer personal account must first
complete the closed-test requirement. Passing this audit does not mean Google
will approve.

## Sources (checked 20 Oct 2026)
- Target API requirements: https://developer.android.com/google/play/requirements/target-sdk
- Testing requirements for new personal accounts: https://support.google.com/googleplay/android-developer/answer/14151465
- Account deletion requirements: https://support.google.com/googleplay/android-developer/answer/13327111
