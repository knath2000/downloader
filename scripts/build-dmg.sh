#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SCHEME="PMVDL"
PROJECT="PMVDL/PMVDL.xcodeproj"
CONFIGURATION="Debug"
APP_NAME="LustreStudio"
INFO_PLIST="PMVDL/PMVDL/Info.plist"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Volumes/WD/Applications/Xcode.app/Contents/Developer}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/lustrestudio-local-dmg-debug}"
STAGING_DIR="${STAGING_DIR:-/tmp/lustrestudio-dmg-staging}"

VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")}"
OUTPUT_DMG="${OUTPUT_DMG:-${APP_NAME}-${VERSION}-build${BUILD_NUMBER}-unsigned.dmg}"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"

echo "==> Building unsigned ${APP_NAME} ${VERSION} (${BUILD_NUMBER})..."
DEVELOPER_DIR="$DEVELOPER_DIR" xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY='' \
    build

EXECUTABLE_PATH="${APP_PATH}/Contents/MacOS/${APP_NAME}"
if [[ ! -x "$EXECUTABLE_PATH" ]]; then
    echo "ERROR: Missing app executable at ${EXECUTABLE_PATH}" >&2
    exit 1
fi

"$ROOT/scripts/embed-lustre-agent-runtime.sh" "$APP_PATH"

echo "==> Verifying unsigned app bundle..."
if codesign -dv "$APP_PATH" >/tmp/lustrestudio-codesign-check.log 2>&1; then
    echo "WARNING: ${APP_NAME}.app is signed; this script is intended for unsigned local DMGs." >&2
    cat /tmp/lustrestudio-codesign-check.log >&2
else
    echo "Expected: ${APP_NAME}.app is unsigned."
fi

echo "==> Creating local unsigned DMG..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$OUTPUT_DMG"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    -o "$OUTPUT_DMG"

echo ""
echo "Done:"
echo "  DMG: ${ROOT}/${OUTPUT_DMG}"
echo "  Note: this DMG is unsigned and unnotarized for personal local use."
