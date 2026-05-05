#!/usr/bin/env bash
# Build, sign, notarize, and package VidDL as a distributable DMG and Sparkle ZIP.
#
# Prerequisites (one-time setup):
#   1. Apple Developer Program membership (developer.apple.com)
#   2. "Developer ID Application" certificate in your keychain
#      (Xcode → Settings → Accounts → Manage Certificates)
#   3. App-specific password from appleid.apple.com
#   4. Store notarization credentials:
#        xcrun notarytool store-credentials "pmvdl-notary" \
#          --apple-id "knath2000@icloud.com" \
#          --team-id "<YOUR_TEAM_ID>" \
#          --password "<APP_SPECIFIC_PASSWORD>"
#   5. Replace FILL_IN_TEAM_ID below (and in exportOptions.plist) with your
#      10-character Apple Team ID (visible in developer.apple.com/account).
#
# Usage (from repo root):
#   bash scripts/build-dmg.sh
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
SCHEME="PMVDL"
PROJECT="PMVDL/PMVDL.xcodeproj"
CONFIGURATION="Release"
ARCHIVE_PATH="/tmp/VidDL.xcarchive"
EXPORT_PATH="/tmp/VidDL-export"
EXPORT_OPTIONS="exportOptions.plist"
APP_NAME="VidDL"
INFO_PLIST="PMVDL/PMVDL/Info.plist"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")}"
DMG_NAME="${APP_NAME}-${VERSION}"
TEAM_ID="FILL_IN_TEAM_ID"          # ← Replace before running
NOTARY_PROFILE="pmvdl-notary"      # keychain profile from prerequisites

if [[ "$TEAM_ID" == "FILL_IN_TEAM_ID" ]]; then
    echo "ERROR: Set TEAM_ID in this script before running." >&2
    exit 1
fi

find_sparkle_sign_update() {
    if [[ -n "${SPARKLE_SIGN_UPDATE:-}" && -x "${SPARKLE_SIGN_UPDATE:-}" ]]; then
        printf '%s\n' "$SPARKLE_SIGN_UPDATE"
        return 0
    fi

    if command -v sign_update >/dev/null 2>&1; then
        command -v sign_update
        return 0
    fi

    find ~/Library/Developer/Xcode/DerivedData \
        \( -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" \
        -o -path "*/SourcePackages/checkouts/Sparkle/bin/sign_update" \) \
        -type f -perm -111 2>/dev/null | head -1
}

# ── 1. Archive ────────────────────────────────────────────────────────────────
echo "==> Archiving ${APP_NAME} ${VERSION} (${BUILD_NUMBER})..."
ARCHIVE_CMD=(
    xcodebuild archive
    -project "$PROJECT"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -archivePath "$ARCHIVE_PATH"
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="Developer ID Application"
    DEVELOPMENT_TEAM="$TEAM_ID"
    CODE_SIGN_ENTITLEMENTS="PMVDL/PMVDL/PMVDL.entitlements"
)
if command -v xcpretty >/dev/null 2>&1; then
    "${ARCHIVE_CMD[@]}" | xcpretty
else
    "${ARCHIVE_CMD[@]}"
fi

# ── 2. Export .app ─────────────────────────────────────────────────────────────
echo "==> Exporting signed .app..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS"

APP="$EXPORT_PATH/$APP_NAME.app"

# ── 3. Notarize the .app ───────────────────────────────────────────────────────
echo "==> Notarizing .app (submitting to Apple — may take a few minutes)..."
ditto -c -k --keepParent "$APP" "/tmp/${APP_NAME}.zip"
xcrun notarytool submit "/tmp/${APP_NAME}.zip" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

# ── 4. Staple notarization ticket to .app ─────────────────────────────────────
echo "==> Stapling .app..."
xcrun stapler staple "$APP"

# ── 5. Create Sparkle ZIP ─────────────────────────────────────────────────────
echo "==> Creating Sparkle ZIP..."
ZIP_NAME="${APP_NAME}-${VERSION}.zip"
ZIP_PATH="$(pwd)/${ZIP_NAME}"
rm -f "$ZIP_PATH" "${ZIP_PATH}.sig.txt"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP_PATH"

# ── 6. EdDSA sign Sparkle ZIP ─────────────────────────────────────────────────
echo "==> Signing Sparkle ZIP..."
SPARKLE_BIN="$(find_sparkle_sign_update)"
if [[ -z "$SPARKLE_BIN" ]]; then
    echo "ERROR: Could not find Sparkle sign_update. Build once with Sparkle resolved, or set SPARKLE_SIGN_UPDATE." >&2
    exit 1
fi
SIG_LINE="$("$SPARKLE_BIN" "$ZIP_PATH")"
echo "$SIG_LINE" > "${ZIP_PATH}.sig.txt"

# ── 7. Create DMG ─────────────────────────────────────────────────────────────
echo "==> Creating DMG..."
DMG_STAGING="/tmp/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

OUTPUT_DMG="${DMG_NAME}.dmg"
hdiutil create \
    -volname "VidDL" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    -o "$OUTPUT_DMG"

# ── 8. Notarize the DMG ────────────────────────────────────────────────────────
echo "==> Notarizing DMG..."
xcrun notarytool submit "$OUTPUT_DMG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

xcrun stapler staple "$OUTPUT_DMG"

# ── 9. Verify ─────────────────────────────────────────────────────────────────
echo "==> Verifying..."
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --display --entitlements - "$APP"
xcrun stapler validate "$OUTPUT_DMG"
spctl --assess --type open --context context:primary-signature "$APP" && \
    echo "Gatekeeper: ACCEPTED" || echo "Gatekeeper: REJECTED (check signing)"

echo ""
echo "==> Done:"
echo "    DMG: $(pwd)/${OUTPUT_DMG}"
echo "    ZIP: ${ZIP_PATH}"
echo "    Signature: ${ZIP_PATH}.sig.txt"
