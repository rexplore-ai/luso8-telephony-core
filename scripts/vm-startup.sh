#!/bin/bash
# =============================================================================
# Luso8 Telephony Core — GCE VM Startup Script
# =============================================================================
# Runs automatically when the GCE VM first boots (set via instance metadata).
# Also re-runs on every VM restart.
#
# This script:
#   1. Installs Docker + Cloud Logging agent
#   2. Installs gcloud SDK (for Artifact Registry auth + Secret Manager)
#   3. Creates the deploy user for GitHub Actions SSH
#   4. Pulls secrets from Secret Manager → /opt/luso8/.env
#   5. Creates tenant config directories
#   6. Sets up recording sync cron job
#   7. Pulls and starts the Asterisk container
# =============================================================================
set -euo pipefail

LOG="/var/log/luso8-startup.log"
exec > >(tee -a "$LOG") 2>&1

echo "============================================================"
echo " Luso8 VM Startup — $(date)"
echo "============================================================"

# ── Read metadata ─────────────────────────────────────────────────────────────
METADATA_URL="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
H="Metadata-Flavor: Google"

get_meta() {
    curl -sf -H "$H" "${METADATA_URL}/$1" 2>/dev/null || echo ""
}

PROJECT_ID=$(curl -sf -H "$H" "http://metadata.google.internal/computeMetadata/v1/project/project-id")
REGION=$(get_meta "region")
ARTIFACT_REPO=$(get_meta "artifact-repo")
IMAGE_NAME=$(get_meta "image-name")
RECORDINGS_BUCKET=$(get_meta "recordings-bucket")

IMAGE_FULL="${REGION}-docker.pkg.dev/${PROJECT_ID}/${ARTIFACT_REPO}/${IMAGE_NAME}:latest"

echo "Project : $PROJECT_ID"
echo "Image   : $IMAGE_FULL"

# ── 1. Install Docker ────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    echo "[startup] Installing Docker..."
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg lsb-release gettext-base

    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io
    systemctl enable docker
    systemctl start docker
    echo "[startup] Docker installed."
else
    echo "[startup] Docker already installed."
fi

# ── 2. Install Cloud Logging + Monitoring agent ───────────────────────────────
if ! systemctl is-active --quiet google-cloud-ops-agent 2>/dev/null; then
    echo "[startup] Installing Cloud Ops Agent (logging + monitoring)..."
    curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
    bash add-google-cloud-ops-agent-repo.sh --also-install --version=latest --quiet
    rm add-google-cloud-ops-agent-repo.sh

    # Configure agent to tail Asterisk log files
    cat > /etc/google-cloud-ops-agent/config.yaml << 'EOF'
logging:
  receivers:
    asterisk_messages:
      type: files
      include_paths:
        - /var/log/asterisk/messages
      record_log_file_path: true
    asterisk_security:
      type: files
      include_paths:
        - /var/log/asterisk/security
      record_log_file_path: true
  processors:
    luso8_labels:
      type: modify_fields
      fields:
        labels."service":
          static_value: asterisk-pbx
        labels."environment":
          static_value: production
  service:
    pipelines:
      asterisk_pipeline:
        receivers: [asterisk_messages, asterisk_security]
        processors: [luso8_labels]

metrics:
  receivers:
    hostmetrics:
      type: hostmetrics
      collection_interval: 60s
  service:
    pipelines:
      system_pipeline:
        receivers: [hostmetrics]
EOF

    systemctl restart google-cloud-ops-agent
    echo "[startup] Cloud Ops Agent installed and configured."
else
    echo "[startup] Cloud Ops Agent already running."
fi

# ── 3. Set up deploy user for GitHub Actions ─────────────────────────────────
echo "[startup] Setting up github-deploy user..."
if ! id -u github-deploy &>/dev/null; then
    useradd -m -s /bin/bash github-deploy
    usermod -aG docker github-deploy
fi

mkdir -p /home/github-deploy/.ssh
chmod 700 /home/github-deploy/.ssh
chown github-deploy:github-deploy /home/github-deploy/.ssh

# Allow github-deploy to run specific scripts as root (no full sudo)
cat > /etc/sudoers.d/github-deploy-luso8 << 'EOF'
github-deploy ALL=(root) NOPASSWD: /opt/luso8/scripts/pull-secrets.sh
github-deploy ALL=(root) NOPASSWD: /opt/luso8/scripts/reload-config.sh
github-deploy ALL=(root) NOPASSWD: /opt/luso8/scripts/rollback.sh
github-deploy ALL=(root) NOPASSWD: /opt/luso8/scripts/health-check.sh
EOF
chmod 440 /etc/sudoers.d/github-deploy-luso8

# ── 4. Create Luso8 directory structure ──────────────────────────────────────
echo "[startup] Creating /opt/luso8 directory structure..."
mkdir -p /opt/luso8/{scripts,tenant-configs/{pjsip,extensions,ari}}
mkdir -p /var/log/asterisk
mkdir -p /var/spool/asterisk/{recording,tmp,outgoing}
mkdir -p /var/lib/asterisk

# ── 5. Copy scripts from this startup script's source ────────────────────────
# Scripts are baked into the image — copy them to /opt/luso8/scripts
# (In CI deployment, scripts are deployed via the image or SSH)
echo "[startup] Marking scripts directory as ready..."

# ── 6. Pull secrets from Secret Manager ──────────────────────────────────────
echo "[startup] Pulling secrets from Secret Manager..."
/opt/luso8/scripts/pull-secrets.sh || {
    echo "[startup] WARNING: pull-secrets.sh failed — carrier config may not be set yet."
    echo "[startup] This is expected on first boot. Set secrets from Luso8 admin dashboard."

    # Create minimal .env for ARI-only startup (Asterisk will start, trunk won't register)
    cat > /opt/luso8/.env << 'MINENV'
ARI_USERNAME=asterisk
ARI_PASSWORD=STARTUP_DEFAULT_CHANGE_VIA_ADMIN
ARI_PORT=8088
ARI_BIND_ADDR=0.0.0.0
ARI_APP_NAME=voxtra
SIP_DOMAIN=pbx.luso8.rexplore.ai
EXTERNAL_IP=127.0.0.1
LOCAL_NET=10.0.0.0/8
SIP_TRUNK_HOST=PLACEHOLDER
SIP_TRUNK_PORT=5060
SIP_TRUNK_USER=PLACEHOLDER
SIP_TRUNK_PASS=PLACEHOLDER
SIP_TRUNK_REALM=PLACEHOLDER
DEFAULT_CONTEXT=from-carrier
OUTBOUND_CALLER_ID=+000000000000
RTP_PORT_START=10000
RTP_PORT_END=10100
LOG_LEVEL=notice
RECORDINGS_BUCKET=luso8-call-recordings
MINENV
}
chmod 600 /opt/luso8/.env

# ── 7. Configure Docker Artifact Registry authentication ─────────────────────
echo "[startup] Configuring Docker for Artifact Registry..."
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

# ── 8. Pull and start Asterisk container ─────────────────────────────────────
echo "[startup] Pulling Asterisk image..."
docker pull "$IMAGE_FULL" || {
    echo "[startup] Image pull failed — will retry on next deploy. Starting will be skipped."
    exit 0
}

echo "[startup] Starting Asterisk container..."
docker stop luso8-asterisk 2>/dev/null || true
docker rm   luso8-asterisk 2>/dev/null || true

docker run -d \
    --name luso8-asterisk \
    --network host \
    --restart unless-stopped \
    --env-file /opt/luso8/.env \
    -v /var/log/asterisk:/var/log/asterisk \
    -v /var/spool/asterisk/recording:/var/spool/asterisk/recording \
    -v /var/lib/asterisk:/var/lib/asterisk \
    -v /opt/luso8/tenant-configs/pjsip:/etc/asterisk/pjsip.d:ro \
    -v /opt/luso8/tenant-configs/extensions:/etc/asterisk/extensions.d:ro \
    -v /opt/luso8/tenant-configs/ari:/etc/asterisk/ari.d:ro \
    --log-driver gcplogs \
    --log-opt gcp-project="$PROJECT_ID" \
    --log-opt gcp-log-cmd=true \
    --label service=asterisk-pbx \
    --label environment=production \
    "$IMAGE_FULL"

# ── 9. Set up recording sync cron job ─────────────────────────────────────────
echo "[startup] Setting up recording sync cron job..."
cat > /etc/cron.d/luso8-recordings << 'EOF'
# Sync call recordings to GCS every 5 minutes
*/5 * * * * root /opt/luso8/scripts/sync-recordings.sh >> /var/log/luso8-recordings-sync.log 2>&1
EOF

# ── 10. Set up log rotation for Luso8 logs ────────────────────────────────────
cat > /etc/logrotate.d/luso8 << 'EOF'
/var/log/luso8-*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
}
EOF

echo ""
echo "============================================================"
echo " VM Startup Complete — $(date)"
echo " Asterisk container: $(docker inspect --format='{{.State.Status}}' luso8-asterisk 2>/dev/null || echo 'not running')"
echo "============================================================"
