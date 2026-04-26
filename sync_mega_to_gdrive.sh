#!/usr/bin/env zsh
set -euo pipefail

REMOTE_MEGA="mega:/Cloud/PMVDL/"
REMOTE_GDRIVE="gdrive:/PMVDL/"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "Existing files on Google Drive:"
rclone ls "$REMOTE_GDRIVE" 2>/dev/null || true

log ""
log "Files on MEGA:"
rclone ls "$REMOTE_MEGA"

log ""
log "Starting rclone copy (mega → gdrive)..."
rclone copy "$REMOTE_MEGA" "$REMOTE_GDRIVE" \
  --progress \
  --fast-list \
  --tpslimit=10 \
  --transfers=2 \
  --verbose \
  --no-traverse

log ""
log "Done. Final listing on Google Drive:"
rclone ls "$REMOTE_GDRIVE" 2>/dev/null || true
log "Complete."
