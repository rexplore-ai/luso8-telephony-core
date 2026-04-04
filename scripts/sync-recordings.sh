#!/bin/bash
# =============================================================================
# Luso8 — Sync Call Recordings to GCS
# =============================================================================
# Run via cron every 5 minutes (set in vm-startup.sh):
#   */5 * * * * root /opt/luso8/scripts/sync-recordings.sh
#
# Recording directory structure in GCS:
#   gs://{BUCKET}/recordings/{YYYY-MM-DD}/{tenant_id}/{call_id}.wav
#
# Asterisk writes recordings to:
#   /var/spool/asterisk/recording/{filename}.wav
#
# Filenames use this pattern (set in extensions.conf MixMonitor):
#   {TENANT_ID}_{UNIQUEID}_{CALLERID}_{STRFTIME(%Y%m%d-%H%M%S)}.wav
# =============================================================================
set -uo pipefail

ENV_FILE="/opt/luso8/.env"
LOCAL_DIR="/var/spool/asterisk/recording"
ARCHIVE_DIR="/var/spool/asterisk/recording/.archived"
MIN_AGE_SECONDS=30  # Only sync recordings older than 30s (ensure write is complete)

# Load env
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    set -o allexport; source "$ENV_FILE"; set +o allexport
fi

BUCKET="${RECORDINGS_BUCKET:-luso8-call-recordings}"
DATE=$(date -u '+%Y-%m-%d')

if [ ! -d "$LOCAL_DIR" ]; then
    echo "[recordings] Directory $LOCAL_DIR does not exist, skipping."
    exit 0
fi

mkdir -p "$ARCHIVE_DIR"

# Find completed recordings (older than MIN_AGE_SECONDS, not archived)
SYNCED=0
ERRORS=0

while IFS= read -r -d $'\0' FILE; do
    FILENAME=$(basename "$FILE")
    EXTENSION="${FILENAME##*.}"

    # Parse tenant ID from filename prefix (format: TENANTID_UNIQUEID_...)
    TENANT_ID=$(echo "$FILENAME" | cut -d'_' -f1)
    [ -z "$TENANT_ID" ] && TENANT_ID="default"

    # Upload to GCS with organized path
    GCS_PATH="gs://${BUCKET}/recordings/${DATE}/${TENANT_ID}/${FILENAME}"

    if gcloud storage cp "$FILE" "$GCS_PATH" --quiet 2>/dev/null; then
        # Move to archived (keeps local copy for 24h before cleanup)
        mv "$FILE" "$ARCHIVE_DIR/$FILENAME"
        SYNCED=$((SYNCED + 1))
        echo "[recordings] Synced: $FILENAME → $GCS_PATH"
    else
        ERRORS=$((ERRORS + 1))
        echo "[recordings] ERROR: Failed to sync $FILENAME"
    fi
done < <(find "$LOCAL_DIR" -maxdepth 1 -name "*.wav" -o -name "*.mp3" -o -name "*.ogg" \
    | xargs -I{} find {} -mmin +1 -print0 2>/dev/null)

# Clean up archived files older than 24 hours
find "$ARCHIVE_DIR" -mmin +1440 -delete 2>/dev/null || true

if [ $SYNCED -gt 0 ] || [ $ERRORS -gt 0 ]; then
    echo "[recordings] Sync complete: $SYNCED uploaded, $ERRORS errors"
fi

exit $( [ $ERRORS -eq 0 ] && echo 0 || echo 1 )
