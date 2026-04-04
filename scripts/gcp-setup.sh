#!/bin/bash
# =============================================================================
# Luso8 Telephony Core — One-time GCP Infrastructure Setup
# =============================================================================
# Run this ONCE from your local machine after: gcloud auth login
#
# What this script creates:
#   - Artifact Registry repository for Docker images
#   - GCE VM (luso8-asterisk-pbx) in africa-south1-a
#   - Static public IP → map to pbx.luso8.rexplore.ai in Cloudflare
#   - Firewall rules (SIP, RTP, ARI-internal)
#   - GCS bucket for call recordings
#   - Secret Manager secrets (with placeholder values)
#   - Service account for the VM + GitHub Actions
#   - Cloud Monitoring uptime check
#
# Usage:
#   chmod +x scripts/gcp-setup.sh
#   ./scripts/gcp-setup.sh
# =============================================================================
set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────────
PROJECT_ID="luso8-cloud"
REGION="africa-south1"
ZONE="africa-south1-a"
INSTANCE_NAME="luso8-asterisk-pbx"
MACHINE_TYPE="e2-standard-2"
ARTIFACT_REPO="luso8-telephony"
IMAGE_NAME="asterisk-pbx"
BUCKET_NAME="luso8-call-recordings-$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')"
SA_VM_NAME="luso8-asterisk-vm"
SA_GH_NAME="luso8-github-actions"
SECRET_PREFIX="luso8-pbx"
STATIC_IP_NAME="luso8-asterisk-ip"
NETWORK_TAG="luso8-asterisk"
DISK_SIZE="50"

echo "============================================================"
echo " Luso8 Telephony Core — GCP Infrastructure Setup"
echo " Project : $PROJECT_ID"
echo " Region  : $REGION / $ZONE"
echo " Instance: $INSTANCE_NAME"
echo "============================================================"
echo ""

# ── 1. Enable required APIs ──────────────────────────────────────────────────
echo "[1/11] Enabling GCP APIs..."
gcloud services enable \
    compute.googleapis.com \
    artifactregistry.googleapis.com \
    secretmanager.googleapis.com \
    storage.googleapis.com \
    logging.googleapis.com \
    monitoring.googleapis.com \
    cloudresourcemanager.googleapis.com \
    --project="$PROJECT_ID" --quiet

echo "  APIs enabled."

# ── 2. Create Artifact Registry repository ───────────────────────────────────
echo "[2/11] Creating Artifact Registry repository..."
gcloud artifacts repositories create "$ARTIFACT_REPO" \
    --repository-format=docker \
    --location="$REGION" \
    --description="Luso8 Asterisk PBX Docker images" \
    --project="$PROJECT_ID" 2>/dev/null || echo "  Already exists."

echo "  Registry: ${REGION}-docker.pkg.dev/${PROJECT_ID}/${ARTIFACT_REPO}/${IMAGE_NAME}"

# ── 3. Create Service Account for GCE VM ────────────────────────────────────
echo "[3/11] Creating VM service account..."
gcloud iam service-accounts create "$SA_VM_NAME" \
    --display-name="Luso8 Asterisk VM" \
    --project="$PROJECT_ID" 2>/dev/null || echo "  Already exists."

SA_VM_EMAIL="${SA_VM_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# Grant VM SA the permissions it needs
for ROLE in \
    "roles/secretmanager.secretAccessor" \
    "roles/storage.objectAdmin" \
    "roles/logging.logWriter" \
    "roles/monitoring.metricWriter" \
    "roles/artifactregistry.reader"; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:${SA_VM_EMAIL}" \
        --role="$ROLE" --quiet 2>/dev/null
    echo "  Granted: $ROLE"
done

# ── 4. Create Service Account for GitHub Actions ─────────────────────────────
echo "[4/11] Creating GitHub Actions service account..."
gcloud iam service-accounts create "$SA_GH_NAME" \
    --display-name="Luso8 GitHub Actions" \
    --project="$PROJECT_ID" 2>/dev/null || echo "  Already exists."

SA_GH_EMAIL="${SA_GH_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

for ROLE in \
    "roles/artifactregistry.writer" \
    "roles/compute.instanceAdmin.v1" \
    "roles/iam.serviceAccountUser"; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:${SA_GH_EMAIL}" \
        --role="$ROLE" --quiet 2>/dev/null
    echo "  Granted: $ROLE to GitHub Actions SA"
done

echo ""
echo "  Generating GitHub Actions SA key..."
gcloud iam service-accounts keys create /tmp/luso8-github-sa-key.json \
    --iam-account="$SA_GH_EMAIL" --project="$PROJECT_ID"

echo "  ⚠️  KEY GENERATED: /tmp/luso8-github-sa-key.json"
echo "  → Add the contents of this file to GitHub Secret: GCP_SA_KEY"
echo "  → Then DELETE the file: rm /tmp/luso8-github-sa-key.json"
echo ""

# ── 5. Reserve Static IP ─────────────────────────────────────────────────────
echo "[5/11] Reserving static external IP..."
gcloud compute addresses create "$STATIC_IP_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID" 2>/dev/null || echo "  Already exists."

STATIC_IP=$(gcloud compute addresses describe "$STATIC_IP_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --format="value(address)")

echo "  Static IP: $STATIC_IP"
echo "  → Add Cloudflare DNS A record: pbx.luso8.rexplore.ai → $STATIC_IP (Proxy: OFF)"

# ── 6. Create Firewall Rules ──────────────────────────────────────────────────
echo "[6/11] Creating firewall rules..."

# SIP signaling — open to any (carrier IPs are dynamic in most cases)
# In production, restrict to your carrier's IP ranges
gcloud compute firewall-rules create luso8-allow-sip \
    --network=default \
    --direction=INGRESS \
    --priority=1000 \
    --action=ALLOW \
    --rules=udp:5060,tcp:5060,tcp:5061 \
    --target-tags="$NETWORK_TAG" \
    --description="SIP signaling for Luso8 PBX" \
    --project="$PROJECT_ID" 2>/dev/null || echo "  SIP rule already exists."

# RTP media ports
gcloud compute firewall-rules create luso8-allow-rtp \
    --network=default \
    --direction=INGRESS \
    --priority=1000 \
    --action=ALLOW \
    --rules=udp:10000-10100 \
    --target-tags="$NETWORK_TAG" \
    --description="RTP media ports for Luso8 PBX" \
    --project="$PROJECT_ID" 2>/dev/null || echo "  RTP rule already exists."

# ARI — restricted to GCP internal + specific IPs
# This allows Voxtra (Cloud Run) and Luso8 backend to reach ARI
# Cloud Run uses NAT IPs — add them if you know them, or use VPC connector
gcloud compute firewall-rules create luso8-allow-ari-internal \
    --network=default \
    --direction=INGRESS \
    --priority=1000 \
    --action=ALLOW \
    --rules=tcp:8088,tcp:8089 \
    --target-tags="$NETWORK_TAG" \
    --source-ranges="10.0.0.0/8,35.191.0.0/16,130.211.0.0/22" \
    --description="ARI interface — internal GCP + Load Balancer health checks only" \
    --project="$PROJECT_ID" 2>/dev/null || echo "  ARI rule already exists."

# SSH for GitHub Actions deploy
gcloud compute firewall-rules create luso8-allow-ssh-deploy \
    --network=default \
    --direction=INGRESS \
    --priority=1000 \
    --action=ALLOW \
    --rules=tcp:22 \
    --target-tags="$NETWORK_TAG" \
    --description="SSH for GitHub Actions deployment" \
    --project="$PROJECT_ID" 2>/dev/null || echo "  SSH rule already exists."

echo "  Firewall rules created."

# ── 7. Create GCE VM ──────────────────────────────────────────────────────────
echo "[7/11] Creating GCE VM..."
gcloud compute instances create "$INSTANCE_NAME" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --image-family=ubuntu-2204-lts \
    --image-project=ubuntu-os-cloud \
    --boot-disk-size="${DISK_SIZE}GB" \
    --boot-disk-type=pd-balanced \
    --network-interface="address=${STATIC_IP_NAME},network-tier=PREMIUM" \
    --tags="$NETWORK_TAG" \
    --service-account="$SA_VM_EMAIL" \
    --scopes="https://www.googleapis.com/auth/cloud-platform" \
    --metadata-from-file=startup-script=scripts/vm-startup.sh \
    --metadata="project-id=${PROJECT_ID},region=${REGION},artifact-repo=${ARTIFACT_REPO},image-name=${IMAGE_NAME},recordings-bucket=${BUCKET_NAME}" \
    --project="$PROJECT_ID" 2>/dev/null || echo "  VM already exists."

echo "  VM created: $INSTANCE_NAME ($ZONE)"

# ── 8. Create GCS Bucket for Call Recordings ─────────────────────────────────
echo "[8/11] Creating GCS recordings bucket..."
gcloud storage buckets create "gs://$BUCKET_NAME" \
    --location="$REGION" \
    --uniform-bucket-level-access \
    --project="$PROJECT_ID" 2>/dev/null || echo "  Already exists."

# Set 90-day lifecycle rule
cat > /tmp/lifecycle.json << 'EOF'
{
  "rule": [
    {
      "action": {"type": "Delete"},
      "condition": {"age": 90}
    }
  ]
}
EOF
gcloud storage buckets update "gs://$BUCKET_NAME" --lifecycle-file=/tmp/lifecycle.json 2>/dev/null || true
rm /tmp/lifecycle.json

# Grant VM SA write access to the recordings bucket
gcloud storage buckets add-iam-policy-binding "gs://$BUCKET_NAME" \
    --member="serviceAccount:${SA_VM_EMAIL}" \
    --role="roles/storage.objectAdmin" 2>/dev/null || true

echo "  Recordings bucket: gs://$BUCKET_NAME"
echo "  → Add to Secret Manager as: ${SECRET_PREFIX}-recordings-bucket"

# ── 9. Create Secret Manager Secrets ─────────────────────────────────────────
echo "[9/11] Creating Secret Manager secrets (with placeholder values)..."

create_secret() {
    local NAME="$1"
    local VALUE="$2"
    local FULL_NAME="${SECRET_PREFIX}-${NAME}"

    if gcloud secrets describe "$FULL_NAME" --project="$PROJECT_ID" &>/dev/null; then
        echo "  EXISTS: $FULL_NAME"
    else
        echo -n "$VALUE" | gcloud secrets create "$FULL_NAME" \
            --data-file=- \
            --replication-policy=automatic \
            --project="$PROJECT_ID" --quiet
        echo "  CREATED: $FULL_NAME"
    fi
}

# Core ARI secrets — set real values now
ARI_PASS=$(openssl rand -base64 32 | tr -d '/+=\n' | cut -c1-32)
create_secret "ari-username"  "asterisk"
create_secret "ari-password"  "$ARI_PASS"
create_secret "sip-domain"    "pbx.luso8.rexplore.ai"
create_secret "external-ip"   "$STATIC_IP"

# Carrier secrets — placeholder, set from Luso8 Cloud admin dashboard
create_secret "sip-trunk-host"     "PLACEHOLDER_SET_FROM_ADMIN_DASHBOARD"
create_secret "sip-trunk-user"     "PLACEHOLDER_SET_FROM_ADMIN_DASHBOARD"
create_secret "sip-trunk-pass"     "PLACEHOLDER_SET_FROM_ADMIN_DASHBOARD"
create_secret "outbound-caller-id" "PLACEHOLDER_SET_FROM_ADMIN_DASHBOARD"

# Infrastructure secrets
create_secret "recordings-bucket"  "$BUCKET_NAME"

echo ""
echo "  ⚠️  SAVE THESE VALUES — YOU WILL NEED THEM FOR THE LUSO8 UI:"
echo "  ARI Username  : asterisk"
echo "  ARI Password  : $ARI_PASS"
echo "  ARI URL       : http://${STATIC_IP}:8088"
echo "  SIP Domain    : pbx.luso8.rexplore.ai"

# ── 10. Generate Deploy SSH Key ───────────────────────────────────────────────
echo "[10/11] Generating deploy SSH key pair..."
ssh-keygen -t ed25519 -C "github-deploy@luso8-asterisk" -f /tmp/luso8-deploy-key -N "" -q

# Add the public key to the VM's metadata
gcloud compute instances add-metadata "$INSTANCE_NAME" \
    --zone="$ZONE" \
    --project="$PROJECT_ID" \
    --metadata="ssh-keys=github-deploy:$(cat /tmp/luso8-deploy-key.pub)"

echo ""
echo "  ⚠️  Add the following SSH private key to GitHub Secret: GCE_SSH_KEY"
echo "  ────────────────────────────────────────────────────────────────────"
cat /tmp/luso8-deploy-key
echo "  ────────────────────────────────────────────────────────────────────"

rm /tmp/luso8-deploy-key /tmp/luso8-deploy-key.pub
echo ""

# ── 11. Create Cloud Monitoring Uptime Check ──────────────────────────────────
echo "[11/11] Setting up Cloud Monitoring..."
gcloud monitoring uptime create luso8-asterisk-ari \
    --display-name="Luso8 Asterisk ARI" \
    --resource-type=uptime-url \
    --hostname="${STATIC_IP}" \
    --http-check-path="/ari/asterisk/info" \
    --port=8088 \
    --project="$PROJECT_ID" 2>/dev/null || echo "  Uptime check already exists."

echo ""
echo "============================================================"
echo " SETUP COMPLETE"
echo "============================================================"
echo ""
echo "NEXT STEPS:"
echo ""
echo "1. Add Cloudflare DNS A record:"
echo "   Name: pbx.luso8.rexplore.ai"
echo "   IPv4: $STATIC_IP"
echo "   Proxy: OFF (DNS only — required for SIP/RTP)"
echo ""
echo "2. Add GitHub Repository Secrets:"
echo "   GCP_SA_KEY  → contents of /tmp/luso8-github-sa-key.json"
echo "   GCE_SSH_KEY → the SSH private key printed above"
echo ""
echo "3. Wait ~3 mins for VM startup script to run, then verify:"
echo "   ssh github-deploy@$STATIC_IP 'docker ps'"
echo ""
echo "4. Set carrier credentials from Luso8 Cloud admin dashboard"
echo "   (or manually via: gcloud secrets versions add luso8-pbx-sip-trunk-host ...)"
echo ""
echo "5. Push to main branch to trigger first deployment."
echo ""
