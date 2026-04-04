#!/bin/bash
# Luso8 Telephony Core — Docker Entrypoint
# Generates Asterisk config files from environment variables, then starts Asterisk.
set -e

echo "[luso8] Starting Asterisk configuration..."

# ---- Defaults for optional variables ----
export ARI_BIND_ADDR="${ARI_BIND_ADDR:-0.0.0.0}"
export ARI_PORT="${ARI_PORT:-8088}"
export ARI_USERNAME="${ARI_USERNAME:-asterisk}"
export ARI_APP_NAME="${ARI_APP_NAME:-voxtra}"
export RTP_PORT_START="${RTP_PORT_START:-10000}"
export RTP_PORT_END="${RTP_PORT_END:-10100}"
export LOG_LEVEL="${LOG_LEVEL:-notice}"
export LOCAL_NET="${LOCAL_NET:-10.0.0.0/8}"
export SIP_TRUNK_PORT="${SIP_TRUNK_PORT:-5060}"
export DEFAULT_CONTEXT="${DEFAULT_CONTEXT:-from-carrier}"
export OUTBOUND_CALLER_ID="${OUTBOUND_CALLER_ID:-}"

# ---- Validate required variables ----
required_vars=(
    ARI_USERNAME
    ARI_PASSWORD
    SIP_DOMAIN
    EXTERNAL_IP
    SIP_TRUNK_HOST
    SIP_TRUNK_USER
    SIP_TRUNK_PASS
)

missing=()
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        missing+=("$var")
    fi
done

if [ ${#missing[@]} -gt 0 ]; then
    echo "[luso8] ERROR: Missing required environment variables:"
    for var in "${missing[@]}"; do
        echo "  - $var"
    done
    echo ""
    echo "See docs/configuration.md for a full list of required variables."
    exit 1
fi

# Default SIP_TRUNK_REALM to SIP_TRUNK_HOST if not set
export SIP_TRUNK_REALM="${SIP_TRUNK_REALM:-$SIP_TRUNK_HOST}"

echo "[luso8] Substituting config templates..."

# ---- Generate config files from templates ----
envsubst < /etc/asterisk/http.conf.tmpl        > /etc/asterisk/http.conf
envsubst < /etc/asterisk/ari.conf.tmpl         > /etc/asterisk/ari.conf
envsubst < /etc/asterisk/pjsip.conf.tmpl       > /etc/asterisk/pjsip.conf
envsubst < /etc/asterisk/extensions.conf.tmpl  > /etc/asterisk/extensions.conf
envsubst < /etc/asterisk/rtp.conf.tmpl         > /etc/asterisk/rtp.conf
envsubst < /etc/asterisk/logger.conf.tmpl      > /etc/asterisk/logger.conf

# ---- Ensure per-tenant fragment directories exist ----
mkdir -p /etc/asterisk/pjsip.d
mkdir -p /etc/asterisk/extensions.d
mkdir -p /etc/asterisk/ari.d

echo "[luso8] Configuration generated successfully."
echo "[luso8]   ARI endpoint : http://${ARI_BIND_ADDR}:${ARI_PORT}/ari"
echo "[luso8]   ARI username : ${ARI_USERNAME}"
echo "[luso8]   SIP domain   : ${SIP_DOMAIN}"
echo "[luso8]   External IP  : ${EXTERNAL_IP}"
echo "[luso8]   SIP trunk    : ${SIP_TRUNK_USER}@${SIP_TRUNK_HOST}"
echo "[luso8]   Stasis app   : ${ARI_APP_NAME}"
echo "[luso8]   RTP ports    : ${RTP_PORT_START}–${RTP_PORT_END}"

# ---- Start Asterisk in foreground (required for Docker) ----
echo "[luso8] Starting Asterisk..."
exec /usr/sbin/asterisk -f -U asterisk -G asterisk -vvv
