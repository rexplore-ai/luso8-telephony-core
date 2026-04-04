#!/bin/bash
# =============================================================================
# Luso8 — Zero-Downtime Config Reload
# =============================================================================
# Called when Luso8 Cloud admin dashboard updates carrier settings.
# Pulls new secrets from Secret Manager and does a live Asterisk reload
# WITHOUT dropping active calls.
#
# Usage (from Luso8 backend API via SSH):
#   sudo /opt/luso8/scripts/reload-config.sh
#
# Asterisk module reload is live — active calls continue uninterrupted.
# Only new calls pick up the updated configuration.
# =============================================================================
set -euo pipefail

echo "[reload] Starting config reload — $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ── 1. Pull latest secrets from Secret Manager ────────────────────────────────
echo "[reload] Fetching latest config from Secret Manager..."
/opt/luso8/scripts/pull-secrets.sh

# ── 2. Reload Asterisk modules (live, no call interruption) ──────────────────
echo "[reload] Reloading Asterisk configuration..."

reload_module() {
    local MOD="$1"
    docker exec luso8-asterisk \
        /usr/sbin/asterisk -rx "module reload $MOD" 2>/dev/null \
        && echo "[reload]   $MOD reloaded" \
        || echo "[reload]   WARNING: $MOD reload returned non-zero"
}

# Reload PJSIP (picks up new SIP trunk credentials)
reload_module "res_pjsip.so"
reload_module "res_pjsip_session.so"
reload_module "res_pjsip_outbound_registration.so"

# Reload dialplan (picks up new extension/context changes)
docker exec luso8-asterisk \
    /usr/sbin/asterisk -rx "dialplan reload" 2>/dev/null \
    && echo "[reload]   Dialplan reloaded" || true

# Reload ARI (picks up new user credentials if changed)
reload_module "res_ari.so"

# ── 3. Regenerate Asterisk config files inside container ──────────────────────
# The container uses envsubst on startup — for a live reload, we need to
# regenerate configs inside the running container from the updated .env
echo "[reload] Regenerating config files inside container..."
docker exec luso8-asterisk bash -c '
    source /proc/1/environ 2>/dev/null || true
    for TMPL in /etc/asterisk/*.conf.tmpl; do
        DEST="${TMPL%.tmpl}"
        envsubst < "$TMPL" > "$DEST"
    done
' 2>/dev/null || true

# Reload again after config regeneration
reload_module "res_pjsip.so"
docker exec luso8-asterisk /usr/sbin/asterisk -rx "dialplan reload" 2>/dev/null || true

# ── 4. Verify after reload ────────────────────────────────────────────────────
sleep 3
echo "[reload] Running health check..."
/opt/luso8/scripts/health-check.sh

echo "[reload] Config reload complete."
