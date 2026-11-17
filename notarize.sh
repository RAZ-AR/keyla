#!/bin/bash
# Release build signed with Developer ID, notarized by Apple and stapled — no Gatekeeper warning for users.
#
# One-time setup (needs a paid Apple Developer account):
#   1. Xcode → Settings → Accounts → Manage Certificates → + "Developer ID Application".
#   2. Create an app-specific password at account.apple.com, then store it:
#        xcrun notarytool store-credentials keyla-notary --apple-id <your Apple ID> --team-id <TEAMID>
#
# Usage: KEYLA_TEAM_ID=<TEAMID> ./notarize.sh
set -euo pipefail
cd "$(dirname "$0")"
: "${KEYLA_TEAM_ID:?Set KEYLA_TEAM_ID to your 10-character Team ID}"
export KEYLA_TEAM_ID
export KEYLA_SIGN_ID=$(security find-identity -v -p codesigning | awk -F'"' "/Developer ID Application: .*\\($KEYLA_TEAM_ID\\)/{print \$2; exit}")
[[ -n "$KEYLA_SIGN_ID" ]] || { echo "No 'Developer ID Application' certificate for team $KEYLA_TEAM_ID in the keychain" >&2; exit 1; }
PROFILE="${KEYLA_NOTARY_PROFILE:-keyla-notary}"

./make-dmg.sh
VERSION=$(plutil -extract CFBundleShortVersionString raw "${TMPDIR:-/tmp}/keyla-build/Keyla.app/Contents/Info.plist")
DMG="dist/Keyla-$VERSION.dmg"

xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
shasum -a 256 "$DMG"
echo "Notarized $DMG"
