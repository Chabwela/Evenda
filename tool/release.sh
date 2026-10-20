#!/usr/bin/env bash
# Builds the Google Play bundle with the production settings in env/prod.json,
# and refuses to build while anything Play requires is missing.
#
#   tool/release.sh            # checks, tests, then build/app/outputs/bundle/release/app-release.aab
#
# env/prod.json needs: SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, MAP_TILE_URL,
# MAP_ATTRIBUTION, PRIVACY_POLICY_URL, ACCOUNT_DELETION_URL, SUPPORT_EMAIL.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "✗ $1" >&2; exit 1; }
need() { node -e "const e=require('./env/prod.json'); const v=e['$1']; if(!v||/CONFIRM|YOUR_/.test(v)) process.exit(1)" || fail "env/prod.json: $1 is missing"; }

[ -f android/key.properties ] || fail "android/key.properties is missing (upload key)"
for k in SUPABASE_URL SUPABASE_PUBLISHABLE_KEY MAP_TILE_URL MAP_ATTRIBUTION PRIVACY_POLICY_URL ACCOUNT_DELETION_URL SUPPORT_EMAIL; do need "$k"; done
node -e "process.exit(require('./env/prod.json').MAP_TILE_URL.includes('tile.openstreetmap.org') ? 1 : 0)" || fail "MAP_TILE_URL still points at OpenStreetMap's servers"
grep -q "CONFIRM" site/privacy-policy.html site/delete-account.html && fail "site/: policy pages still have [CONFIRM] items"

flutter analyze --no-pub
flutter test --no-pub
flutter build appbundle --release --dart-define-from-file=env/prod.json

aab=build/app/outputs/bundle/release/app-release.aab
jarsigner -verify "$aab" | grep -q "jar verified" || fail "bundle signature did not verify"
keytool -printcert -jarfile "$aab" | grep -q "CN=Android Debug" && fail "bundle is debug-signed"
echo "✓ $aab is signed with the upload key and ready for Play Console"
