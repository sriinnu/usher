#!/bin/bash
# Builds, signs, notarizes and packages a release of Usher.
#
#   ./Scripts/release.sh
#
# Needs, once, on this Mac:
#   - a "Developer ID Application" certificate in the login keychain
#   - notarization credentials stored under a keychain profile:
#       xcrun notarytool store-credentials usher-notary \
#         --key <path to AuthKey_XXXX.p8> --key-id <key id> --issuer <issuer id>
#     (override the profile name with NOTARY_PROFILE=...)
#
# The API key file is never read here: notarytool reads the stored profile.
# Nothing is uploaded anywhere but Apple's notary service; publishing the zip
# is a separate, deliberate step.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
PROFILE="${NOTARY_PROFILE:-usher-notary}"

TAG="$(git describe --tags --exact-match 2>/dev/null || true)"
if [ -z "$TAG" ]; then
    echo "error: HEAD is not tagged. Tag the release first (git tag -s vX.Y.Z)." >&2
    exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
    echo "error: the working tree has changes. A release is built from a clean, tagged commit." >&2
    exit 1
fi

echo "== tests"
swift test 2>&1 | tail -1

echo "== build"
UNIVERSAL=1 ./Scripts/bundle.sh
APP="$ROOT/build/Usher.app"
# Captured first: `codesign | grep -q` under pipefail fails when grep exits
# early and codesign takes a SIGPIPE — which stopped the first release here.
SIGNATURE="$(codesign -dv "$APP" 2>&1 || true)"
if ! printf '%s\n' "$SIGNATURE" | grep -q "flags=.*runtime"; then
    echo "error: not signed with the hardened runtime — no Developer ID certificate?" >&2
    exit 1
fi

VERSION="${TAG#v}"
OUT="$ROOT/build/release"
mkdir -p "$OUT"
ZIP="$OUT/Usher-$VERSION.zip"

echo "== notarize ($PROFILE)"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

# Zip again with the ticket stapled in, so it opens offline too.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
( cd "$OUT" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256" )

echo
echo "release: $ZIP"
cat "$ZIP.sha256"
