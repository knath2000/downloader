#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: scripts/release.sh <short-version> <build-number> <release notes>" >&2
    echo "Example: scripts/release.sh 2.1.0 3 \"Improves extraction reliability; refreshes docs\"" >&2
}

if [[ $# -lt 3 ]]; then
    usage
    exit 1
fi

VERSION="$1"
BUILD_NUMBER="$2"
shift 2
RELEASE_NOTES="$*"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

INFO_PLIST="PMVDL/PMVDL/Info.plist"
APP_NAME="VidDL"
BLOB_BASE_URL="${VIDDL_BLOB_BASE_URL:-}"
BLOB_READ_WRITE_TOKEN="${BLOB_READ_WRITE_TOKEN:-}"

if [[ -z "$BLOB_READ_WRITE_TOKEN" ]]; then
    echo "ERROR: Set BLOB_READ_WRITE_TOKEN before releasing." >&2
    exit 1
fi

if [[ -z "$BLOB_BASE_URL" ]]; then
    echo "ERROR: Set VIDDL_BLOB_BASE_URL to the public base URL for release assets." >&2
    exit 1
fi

vercel_blob_put() {
    local file="$1"
    local pathname="$2"
    local content_type="$3"
    local cache_max_age="$4"
    local allow_overwrite="$5"

    local cmd=(
        npx --yes vercel@latest blob put "$file"
        --pathname "$pathname"
        --content-type "$content_type"
        --cache-control-max-age "$cache_max_age"
        --rw-token "$BLOB_READ_WRITE_TOKEN"
    )

    if [[ "$allow_overwrite" == "true" ]]; then
        cmd+=(--allow-overwrite)
    fi

    "${cmd[@]}"
}

echo "==> Bumping ${APP_NAME} to ${VERSION} (${BUILD_NUMBER})..."
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "$INFO_PLIST"

echo "==> Building signed DMG..."
VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" bash scripts/build-dmg.sh

DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="$ROOT/$DMG_NAME"

if [[ ! -f "$DMG_PATH" ]]; then
    echo "ERROR: Missing DMG output." >&2
    exit 1
fi

WORK_DIR="$(mktemp -d "/tmp/viddl-release-${VERSION}.XXXXXX")"
NOTES_HTML="$WORK_DIR/${VERSION}.html"

echo "==> Generating release notes..."
export RELEASE_VERSION="$VERSION"
export RELEASE_NOTES
export NOTES_HTML
/usr/bin/python3 <<'PY'
import html
import os
import re

version = os.environ["RELEASE_VERSION"]
notes = os.environ["RELEASE_NOTES"]
output = os.environ["NOTES_HTML"]
parts = [part.strip() for part in re.split(r";\s*|\n+", notes) if part.strip()]

if len(parts) > 1:
    body = "<ul>" + "".join(f"<li>{html.escape(part)}</li>" for part in parts) + "</ul>"
else:
    body = f"<p>{html.escape(notes)}</p>"

document = f"""<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <style>
    body {{ font: -apple-system-body; color: #1f2328; margin: 20px; }}
    h1 {{ font: -apple-system-headline; margin-bottom: 12px; }}
    ul {{ padding-left: 20px; }}
    li {{ margin: 6px 0; }}
  </style>
</head>
<body>
  <h1>VidDL {html.escape(version)}</h1>
  {body}
</body>
</html>
"""

with open(output, "w", encoding="utf-8") as handle:
    handle.write(document)
PY

DMG_PATHNAME="releases/${DMG_NAME}"
NOTES_PATHNAME="notes/${VERSION}.html"
DMG_URL="${BLOB_BASE_URL}/${DMG_PATHNAME}"
NOTES_URL="${BLOB_BASE_URL}/${NOTES_PATHNAME}"

echo "==> Uploading DMG and release notes to Vercel Blob..."
vercel_blob_put "$DMG_PATH" "$DMG_PATHNAME" "application/x-apple-diskimage" 31536000 false
vercel_blob_put "$NOTES_HTML" "$NOTES_PATHNAME" "text/html; charset=utf-8" 3600 true

echo ""
echo "Release ready:"
echo "  DMG: ${DMG_URL}"
echo "  Release notes: ${NOTES_URL}"
