#!/bin/bash
# =============================================================================
# Luso8 — Automatic Rollback to Previous Image
# =============================================================================
# Called automatically by the deploy workflow on health check failure.
# Reverts to the last known-good Docker image.
# =============================================================================
set -euo pipefail

PREV_IMAGE_FILE="/opt/luso8/.previous-image"
ENV_FILE="/opt/luso8/.env"

echo "[rollback] Initiating rollback — $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

if [ ! -f "$PREV_IMAGE_FILE" ]; then
    echo "[rollback] ERROR: No previous image recorded at $PREV_IMAGE_FILE"
    exit 1
fi

PREV_IMAGE=$(cat "$PREV_IMAGE_FILE")

if [ -z "$PREV_IMAGE" ] || [ "$PREV_IMAGE" = "none" ]; then
    echo "[rollback] ERROR: No valid previous image to roll back to"
    exit 1
fi

echo "[rollback] Rolling back to: $PREV_IMAGE"

docker stop luso8-asterisk 2>/dev/null || true
docker rm   luso8-asterisk 2>/dev/null || true

docker run -d \
    --name luso8-asterisk \
    --network host \
    --restart unless-stopped \
    --env-file "$ENV_FILE" \
    -v /var/log/asterisk:/var/log/asterisk \
    -v /var/spool/asterisk/recording:/var/spool/asterisk/recording \
    -v /var/lib/asterisk:/var/lib/asterisk \
    -v /opt/luso8/tenant-configs/pjsip:/etc/asterisk/pjsip.d:ro \
    -v /opt/luso8/tenant-configs/extensions:/etc/asterisk/extensions.d:ro \
    -v /opt/luso8/tenant-configs/ari:/etc/asterisk/ari.d:ro \
    --log-driver gcplogs \
    --log-opt gcp-project=luso8-cloud \
    --label service=asterisk-pbx \
    --label environment=production \
    --label rollback=true \
    "$PREV_IMAGE"

sleep 15

echo "[rollback] Verifying rolled-back container..."
/opt/luso8/scripts/health-check.sh && echo "[rollback] Rollback successful." || {
    echo "[rollback] CRITICAL: Rollback also failed. Manual intervention required."
    exit 1
}
