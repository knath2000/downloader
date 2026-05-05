#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: scripts/release.sh <short-version> <build-number> <release notes>" >&2
    echo "Example: scripts/release.sh 2.1.0 3 \"Fixes pmvhaven throttling; improves update checks\"" >&2
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
PRODUCT_URL="${PRODUCT_URL:-https://viddl.com}"
APPCAST_URL="${VIDDL_APPCAST_URL:-https://updates.viddl.com/appcast.xml}"
BLOB_BASE_URL="${VIDDL_BLOB_BASE_URL:-${APPCAST_URL%/appcast.xml}}"
BLOB_READ_WRITE_TOKEN="${BLOB_READ_WRITE_TOKEN:-}"

if [[ -z "$BLOB_READ_WRITE_TOKEN" ]]; then
    echo "ERROR: Set BLOB_READ_WRITE_TOKEN before releasing." >&2
    exit 1
fi

if [[ "$BLOB_BASE_URL" == "$APPCAST_URL" ]]; then
    echo "ERROR: Set VIDDL_BLOB_BASE_URL to the public base URL for release assets." >&2
    exit 1
fi

PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$INFO_PLIST" 2>/dev/null || true)"
if [[ -z "$PUBLIC_KEY" || "$PUBLIC_KEY" == "REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY" ]]; then
    echo "ERROR: SUPublicEDKey is not configured. Run Sparkle's generate_keys and update Info.plist first." >&2
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
/usr/libexec/PlistBuddy -c "Set :SUFeedURL ${APPCAST_URL}" "$INFO_PLIST"

echo "==> Building signed DMG and Sparkle ZIP..."
VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" bash scripts/build-dmg.sh

ZIP_NAME="${APP_NAME}-${VERSION}.zip"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
ZIP_PATH="$ROOT/$ZIP_NAME"
DMG_PATH="$ROOT/$DMG_NAME"
SIG_PATH="${ZIP_PATH}.sig.txt"

if [[ ! -f "$ZIP_PATH" || ! -f "$SIG_PATH" ]]; then
    echo "ERROR: Missing Sparkle ZIP or signature output." >&2
    exit 1
fi

WORK_DIR="$(mktemp -d "/tmp/viddl-release-${VERSION}.XXXXXX")"
EXISTING_APPCAST="$WORK_DIR/existing-appcast.xml"
NEW_APPCAST="$WORK_DIR/appcast.xml"
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

ZIP_PATHNAME="releases/${ZIP_NAME}"
NOTES_PATHNAME="notes/${VERSION}.html"
ZIP_URL="${BLOB_BASE_URL}/${ZIP_PATHNAME}"
NOTES_URL="${BLOB_BASE_URL}/${NOTES_PATHNAME}"

echo "==> Uploading ZIP and release notes to Vercel Blob..."
vercel_blob_put "$ZIP_PATH" "$ZIP_PATHNAME" "application/octet-stream" 31536000 false
vercel_blob_put "$NOTES_HTML" "$NOTES_PATHNAME" "text/html; charset=utf-8" 3600 true

echo "==> Fetching existing appcast..."
if ! curl -fsSL "$APPCAST_URL" -o "$EXISTING_APPCAST"; then
    : > "$EXISTING_APPCAST"
fi

echo "==> Generating appcast item..."
export APPCAST_URL
export BLOB_BASE_URL
export PRODUCT_URL
export ZIP_URL
export NOTES_URL
export ZIP_SIG_PATH="$SIG_PATH"
export EXISTING_APPCAST
export NEW_APPCAST
export RELEASE_BUILD_NUMBER="$BUILD_NUMBER"
/usr/bin/python3 <<'PY'
import email.utils
import os
import re
import xml.etree.ElementTree as ET

sparkle_ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"
sparkle = f"{{{sparkle_ns}}}"
ET.register_namespace("sparkle", sparkle_ns)

version = os.environ["RELEASE_VERSION"]
build_number = os.environ["RELEASE_BUILD_NUMBER"]
appcast_url = os.environ["APPCAST_URL"]
product_url = os.environ["PRODUCT_URL"]
zip_url = os.environ["ZIP_URL"]
notes_url = os.environ["NOTES_URL"]
sig_path = os.environ["ZIP_SIG_PATH"]
existing_appcast = os.environ["EXISTING_APPCAST"]
new_appcast = os.environ["NEW_APPCAST"]

with open(sig_path, "r", encoding="utf-8") as handle:
    sig_line = handle.read().strip()

signature_match = re.search(r'sparkle:edSignature="([^"]+)"', sig_line)
length_match = re.search(r'length="([^"]+)"', sig_line)
if not signature_match or not length_match:
    raise SystemExit(f"Could not parse Sparkle signature line: {sig_line}")

try:
    tree = ET.parse(existing_appcast)
    root = tree.getroot()
    channel = root.find("channel")
    if channel is None:
        raise ET.ParseError("missing channel")
except ET.ParseError:
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "VidDL Updates"
    ET.SubElement(channel, "link").text = appcast_url
    tree = ET.ElementTree(root)

title = channel.find("title")
if title is None:
    title = ET.Element("title")
    title.text = "VidDL Updates"
    channel.insert(0, title)

link = channel.find("link")
if link is None:
    link = ET.Element("link")
    link.text = appcast_url
    channel.insert(1, link)
else:
    link.text = appcast_url

for item in list(channel.findall("item")):
    item_version = item.find(f"{sparkle}version")
    short_version = item.find(f"{sparkle}shortVersionString")
    if (item_version is not None and item_version.text == build_number) or (
        short_version is not None and short_version.text == version
    ):
        channel.remove(item)

item = ET.Element("item")
ET.SubElement(item, "title").text = f"Version {version}"
ET.SubElement(item, "link").text = product_url
ET.SubElement(item, f"{sparkle}version").text = build_number
ET.SubElement(item, f"{sparkle}shortVersionString").text = version
ET.SubElement(item, f"{sparkle}minimumSystemVersion").text = "14.0"
ET.SubElement(item, f"{sparkle}releaseNotesLink").text = notes_url
ET.SubElement(item, "pubDate").text = email.utils.formatdate(localtime=True)
ET.SubElement(
    item,
    "enclosure",
    {
        "url": zip_url,
        f"{sparkle}edSignature": signature_match.group(1),
        "length": length_match.group(1),
        "type": "application/octet-stream",
    },
)

children = list(channel)
insert_index = next((idx for idx, child in enumerate(children) if child.tag == "item"), len(children))
channel.insert(insert_index, item)

if hasattr(ET, "indent"):
    ET.indent(tree, space="  ")
tree.write(new_appcast, encoding="utf-8", xml_declaration=True)
PY

echo "==> Uploading appcast..."
vercel_blob_put "$NEW_APPCAST" "appcast.xml" "application/xml" 60 true

echo ""
echo "Release ready:"
echo "  Appcast: ${APPCAST_URL}"
echo "  Sparkle ZIP: ${ZIP_URL}"
echo "  Release notes: ${NOTES_URL}"
echo "  Website DMG: ${DMG_PATH}"
