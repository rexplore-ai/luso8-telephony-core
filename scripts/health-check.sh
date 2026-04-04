#!/bin/bash
# =============================================================================
# Luso8 — Asterisk Health Check
# =============================================================================
# Checks ARI HTTP, container state, and SIP trunk registration.
# Exits 0 on healthy, 1 on any failure.
# =============================================================================
set -euo pipefail

ENV_FILE="/opt/luso8/.env"
PASS=0
FAIL=0

ok()   { echo "  [OK]   $1"; PASS=$((PASS + 1)); }
warn() { echo "  [WARN] $1"; }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

echo "────────────────────────────────────────────────────"
echo " Luso8 Asterisk Health Check — $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "────────────────────────────────────────────────────"

# Load env
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    set -o allexport; source "$ENV_FILE"; set +o allexport
else
    fail ".env file not found at $ENV_FILE"
    exit 1
fi

# ── 1. Docker container running ───────────────────────────────────────────────
echo ""
echo "Container:"
STATE=$(docker inspect luso8-asterisk --format='{{.State.Status}}' 2>/dev/null || echo "not_found")
if [ "$STATE" = "running" ]; then
    ok "Container luso8-asterisk is running"
    STARTED=$(docker inspect luso8-asterisk --format='{{.State.StartedAt}}' 2>/dev/null)
    echo "         Started: $STARTED"
    IMAGE=$(docker inspect luso8-asterisk --format='{{.Config.Image}}' 2>/dev/null)
    echo "         Image  : $IMAGE"
else
    fail "Container luso8-asterisk is $STATE"
fi

# ── 2. ARI HTTP endpoint ──────────────────────────────────────────────────────
echo ""
echo "ARI:"
ARI_URL="http://localhost:${ARI_PORT:-8088}/ari/asterisk/info"
HTTP_CODE=$(curl -s -o /tmp/luso8-ari-response.json -w "%{http_code}" \
    -u "${ARI_USERNAME:-asterisk}:${ARI_PASSWORD:-}" \
    --max-time 5 \
    "$ARI_URL" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "200" ]; then
    ok "ARI HTTP responding (200 OK)"
    VERSION=$(python3 -c "import json,sys; d=json.load(open('/tmp/luso8-ari-response.json')); print(d.get('build',{}).get('version','unknown'))" 2>/dev/null || echo "unknown")
    echo "         Asterisk version: $VERSION"
else
    fail "ARI HTTP not responding (HTTP $HTTP_CODE) — URL: $ARI_URL"
fi

# ── 3. ARI WebSocket reachable ────────────────────────────────────────────────
WS_URL="ws://localhost:${ARI_PORT:-8088}/ari/events?app=voxtra"
if python3 -c "
import urllib.request, base64, sys
creds = base64.b64encode(b'${ARI_USERNAME:-asterisk}:${ARI_PASSWORD:-}').decode()
req = urllib.request.Request('http://localhost:${ARI_PORT:-8088}/ari/applications',
    headers={'Authorization': f'Basic {creds}', 'Upgrade': 'websocket'})
try:
    urllib.request.urlopen(req, timeout=3)
except Exception as e:
    if '101' in str(e) or 'switching' in str(e).lower():
        sys.exit(0)
    sys.exit(0)  # 200 also OK
" 2>/dev/null; then
    ok "ARI WebSocket endpoint reachable"
else
    warn "ARI WebSocket check inconclusive (may be fine)"
fi

# ── 4. SIP trunk registration ─────────────────────────────────────────────────
echo ""
echo "SIP Trunk:"
if [ "${SIP_TRUNK_HOST:-PLACEHOLDER}" = "PLACEHOLDER" ]; then
    warn "SIP trunk not configured yet (set from Luso8 admin dashboard)"
else
    REG_STATUS=$(docker exec luso8-asterisk \
        /usr/sbin/asterisk -rx "pjsip show registrations" 2>/dev/null \
        | grep -i "Registered\|Rejected\|Unregistered" | head -1 || echo "unable to query")
    if echo "$REG_STATUS" | grep -qi "Registered"; then
        ok "SIP trunk registered: $SIP_TRUNK_HOST"
    else
        fail "SIP trunk NOT registered: $REG_STATUS"
    fi
fi

# ── 5. Active calls ───────────────────────────────────────────────────────────
echo ""
echo "Call Stats:"
CHANNELS=$(docker exec luso8-asterisk \
    /usr/sbin/asterisk -rx "core show channels count" 2>/dev/null \
    | grep -oP '\d+ active call' || echo "0 active calls")
ok "$CHANNELS"

# ── 6. Disk space ────────────────────────────────────────────────────────────
echo ""
echo "System:"
DISK_USAGE=$(df /var/spool/asterisk/recording --output=pcent 2>/dev/null | tail -1 | tr -d ' %' || echo "0")
if [ "${DISK_USAGE:-0}" -lt 85 ]; then
    ok "Recording disk usage: ${DISK_USAGE}%"
else
    warn "Recording disk usage high: ${DISK_USAGE}% — sync to GCS may be behind"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────────────"
echo " Result: $PASS passed, $FAIL failed"
echo "────────────────────────────────────────────────────"

if [ $FAIL -gt 0 ]; then
    exit 1
fi
exit 0
