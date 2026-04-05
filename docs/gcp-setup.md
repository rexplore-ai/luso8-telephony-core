# GCP Deployment Guide — Luso8 Telephony Core

Complete reference for the Luso8 Asterisk PBX deployment on GCP, including CI/CD, monitoring, and call recording.

---

## Provisioned Infrastructure (already live)

| Resource | Value |
|---|---|
| **GCE VM** | `luso8-asterisk-pbx` — `africa-south1-a` — `e2-standard-2` |
| **Static IP** | `34.35.43.82` |
| **DNS** | `pbx.luso8.rexplore.ai` → `34.35.43.82` (Cloudflare A, proxy OFF) |
| **Artifact Registry** | `africa-south1-docker.pkg.dev/luso8-cloud/luso8-telephony/asterisk-pbx` |
| **GCS Bucket** | `gs://luso8-call-recordings-1073192452778` |
| **VM SA** | `luso8-asterisk-vm@luso8-cloud.iam.gserviceaccount.com` |
| **GitHub Actions SA** | `luso8-github-actions@luso8-cloud.iam.gserviceaccount.com` |
| **WIF Pool** | `luso8-github-pool` (OIDC provider: `github`, scoped to `rexplore-ai` org) |

---

## Architecture Overview

```
GitHub (master branch push)
        │
        ▼ GitHub Actions (luso8-deploy.yml)
        │   1. Build Docker image (apt-based, ~3 min)
        │   2. Push to Artifact Registry (africa-south1)
        │   3. SSH into GCE VM via GCE_SSH_KEY
        │   4. Pull secrets from Secret Manager → .env
        │   5. Pull new image + restart container
        │   6. Health check (ARI HTTP + SIP)
        │   7. Auto-rollback on failure
        │
        ▼ GCE VM — africa-south1-a
        │   luso8-asterisk-pbx (e2-standard-2)
        │   34.35.43.82 → pbx.luso8.rexplore.ai (Cloudflare A, proxy OFF)
        │   Docker: --network host (required for SIP/RTP NAT)
        │
        ├─ Port 5060 UDP/TCP  → SIP Trunk (local carrier)
        ├─ Port 10000-10100 UDP → RTP media audio
        └─ Port 8088 TCP (internal only) → ARI → Voxtra

GCS Bucket: gs://luso8-call-recordings-1073192452778
        │   Recordings synced every 5 min via cron
        │   90-day auto-delete lifecycle
        └─ Accessible via signed URLs from api.luso8.rexplore.ai
```

---

## GitHub Environment Secrets

All secrets are stored in the **`production` environment** (not repository-level).

Go to: `https://github.com/rexplore-ai/luso8-telephony-core/settings/environments/production/edit`

| Secret Name | Value | Notes |
|---|---|---|
| `GCE_SSH_KEY` | ed25519 private key | SSH into `github-deploy@34.35.43.82` |
| `WIF_PROVIDER` | `projects/1073192452778/locations/global/workloadIdentityPools/luso8-github-pool/providers/github` | Workload Identity Federation — no SA key needed |
| `WIF_SA` | `luso8-github-actions@luso8-cloud.iam.gserviceaccount.com` | Impersonated via WIF |

> **Why no `GCP_SA_KEY`?** The org has `iam.disableServiceAccountKeyCreation` policy. WIF is used instead — GitHub Actions exchanges a short-lived OIDC token for GCP credentials at runtime. More secure, nothing to rotate.

All other configuration (ARI password, SIP trunk credentials, etc.) lives in GCP Secret Manager and is pulled to the VM at deploy time.

---

## GCP Secret Manager Secrets

All prefixed with `luso8-pbx-`. Managed via Luso8 Cloud admin dashboard or `gcloud secrets` CLI.

| Secret Name | Set During | Who Sets It |
|---|---|---|
| `luso8-pbx-ari-username` | `gcp-setup.sh` | Auto (value: `asterisk`) |
| `luso8-pbx-ari-password` | `gcp-setup.sh` | Auto (random 32-char) |
| `luso8-pbx-sip-domain` | `gcp-setup.sh` | Auto (`pbx.luso8.rexplore.ai`) |
| `luso8-pbx-external-ip` | `gcp-setup.sh` | Auto (GCE static IP) |
| `luso8-pbx-sip-trunk-host` | Admin dashboard | Super admin sets carrier |
| `luso8-pbx-sip-trunk-user` | Admin dashboard | Super admin sets carrier |
| `luso8-pbx-sip-trunk-pass` | Admin dashboard | Super admin sets carrier |
| `luso8-pbx-outbound-caller-id` | Admin dashboard | Super admin sets DID |
| `luso8-pbx-recordings-bucket` | `gcp-setup.sh` | Auto (bucket name) |

### Updating a secret from CLI

```bash
# Example: Set SIP trunk host after getting carrier credentials
echo -n "sip.carrier.mw" | gcloud secrets versions add luso8-pbx-sip-trunk-host \
    --data-file=- --project=luso8-cloud

# Then trigger a config reload on the VM (no restart needed):
gcloud compute ssh luso8-asterisk-pbx --zone=africa-south1-a \
    --command="sudo /opt/luso8/scripts/reload-config.sh"
```

---

## Step 1 — Prerequisites

```bash
# Verify gcloud is authenticated
gcloud auth list
gcloud config set project luso8-cloud

# Verify you have the right permissions
gcloud projects get-iam-policy luso8-cloud \
    --flatten="bindings[].members" \
    --filter="bindings.members:patrick@rexplore.ai" \
    --format="table(bindings.role)"
```

You need at minimum: `roles/owner` or `roles/editor` + `roles/iam.securityAdmin`.

---

## Step 2 — Run One-Time GCP Setup

> ✅ Already completed for `luso8-cloud`. Skip to Step 3 for a fresh project.

```bash
cd /path/to/luso8-telephony-core
chmod +x scripts/*.sh
./scripts/gcp-setup.sh
```

The script will output:
1. The GCE static IP → use for Cloudflare DNS A record
2. An SSH private key → save as GitHub Environment Secret `GCE_SSH_KEY`
3. ARI credentials (username/password) → save for Luso8 UI config

The script does **not** generate a `GCP_SA_KEY` — GCP auth uses Workload Identity Federation.
See `scripts/gcp-setup.sh` for the WIF pool setup (already provisioned at `luso8-github-pool`).

---

## Step 3 — Configure Cloudflare DNS

In **Cloudflare dashboard → rexplore.ai → DNS**:

| Type | Name | IPv4 | Proxy Status |
|---|---|---|---|
| A | `pbx.luso8` | `34.35.43.82` | **DNS only (grey cloud)** |

> ⚠️ **Proxy must be OFF** — Cloudflare proxying breaks SIP signaling and RTP audio. SIP requires direct IP connectivity.

Verify after propagation:
```bash
dig pbx.luso8.rexplore.ai +short
# Expected: 34.35.43.82
```

---

## Step 4 — Add GitHub Environment Secrets

Go to: `https://github.com/rexplore-ai/luso8-telephony-core/settings/environments/production/edit`

Add three **environment** secrets (not repository secrets):

| Secret | Value |
|---|---|
| `GCE_SSH_KEY` | ed25519 private key printed by `gcp-setup.sh` |
| `WIF_PROVIDER` | `projects/1073192452778/locations/global/workloadIdentityPools/luso8-github-pool/providers/github` |
| `WIF_SA` | `luso8-github-actions@luso8-cloud.iam.gserviceaccount.com` |

---

## Step 5 — Wait for VM Startup Script

The GCE VM runs `scripts/vm-startup.sh` automatically on first boot. This takes ~3-5 minutes and:
- Installs Docker
- Installs Cloud Ops Agent (logging + monitoring)
- Creates the `github-deploy` user
- Creates `/opt/luso8/` directory structure

Verify it's done:
```bash
# Check startup log on VM
gcloud compute ssh luso8-asterisk-pbx --zone=africa-south1-a \
    --command="cat /var/log/luso8-startup.log | tail -30"
```

---

## Step 6 — Set Up Scripts on VM

The VM needs the operational scripts at `/opt/luso8/scripts/`. Copy them via SSH:

```bash
# Set VM IP variable
VM_IP=$(gcloud compute instances describe luso8-asterisk-pbx \
    --zone=africa-south1-a --format='value(networkInterfaces[0].accessConfigs[0].natIP)')

# Copy scripts to VM
scp -i /tmp/luso8-deploy-key scripts/*.sh github-deploy@${VM_IP}:/tmp/
gcloud compute ssh luso8-asterisk-pbx --zone=africa-south1-a \
    --command="sudo mkdir -p /opt/luso8/scripts && sudo mv /tmp/*.sh /opt/luso8/scripts/ && sudo chmod +x /opt/luso8/scripts/*.sh"
```

---

## Step 7 — Trigger First Deployment

Push to `master` or trigger manually:

```bash
git push origin master
# OR
# GitHub → Actions → "Luso8 — Build & Deploy Asterisk" → "Run workflow"
```

The workflow will:
1. Build the Docker image (~10 min first time, ~3 min with cache)
2. Push to Artifact Registry
3. SSH into `pbx.luso8.rexplore.ai`
4. Pull secrets from Secret Manager
5. Start the Asterisk container
6. Run health check

---

## Step 8 — Verify End-to-End

```bash
# 1. Check ARI from your machine (requires ARI_PASSWORD from Secret Manager)
ARI_PASS=$(gcloud secrets versions access latest --secret=luso8-pbx-ari-password --project=luso8-cloud)
curl -u asterisk:$ARI_PASS http://pbx.luso8.rexplore.ai:8088/ari/asterisk/info | python3 -m json.tool

# 2. Check container on VM
gcloud compute ssh luso8-asterisk-pbx --zone=africa-south1-a \
    --command="docker ps && sudo /opt/luso8/scripts/health-check.sh"

# 3. Check Cloud Logging for Asterisk logs
gcloud logging read 'labels.service="asterisk-pbx"' \
    --project=luso8-cloud \
    --limit=20 \
    --format="table(timestamp,textPayload)"
```

---

## Setting Carrier Credentials (After Deployment)

Once you have SIP trunk credentials from your local carrier (e.g., Malawi carrier):

```bash
# Set each secret
echo -n "sip.carrier.mw"     | gcloud secrets versions add luso8-pbx-sip-trunk-host --data-file=- --project=luso8-cloud
echo -n "265XXXXXXXXX"       | gcloud secrets versions add luso8-pbx-sip-trunk-user  --data-file=- --project=luso8-cloud
echo -n "carrier_password"   | gcloud secrets versions add luso8-pbx-sip-trunk-pass  --data-file=- --project=luso8-cloud
echo -n "+265XXXXXXXXX"      | gcloud secrets versions add luso8-pbx-outbound-caller-id --data-file=- --project=luso8-cloud

# Apply without restarting Asterisk (live reload — active calls not dropped)
gcloud compute ssh luso8-asterisk-pbx --zone=africa-south1-a \
    --command="sudo /opt/luso8/scripts/reload-config.sh"

# Verify SIP registration
gcloud compute ssh luso8-asterisk-pbx --zone=africa-south1-a \
    --command="docker exec luso8-asterisk asterisk -rx 'pjsip show registrations'"
```

---

## Monitoring & Logs

### Cloud Logging

View real-time Asterisk logs:

```bash
# All Asterisk logs
gcloud logging read 'labels.service="asterisk-pbx"' \
    --project=luso8-cloud --limit=50 --freshness=1h

# Errors only
gcloud logging read 'labels.service="asterisk-pbx" severity>=ERROR' \
    --project=luso8-cloud --limit=20

# Inbound calls (StasisStart events)
gcloud logging read 'labels.service="asterisk-pbx" textPayload:"StasisStart"' \
    --project=luso8-cloud --limit=20
```

**Cloud Console URL**:
```
https://console.cloud.google.com/logs/query;query=labels.service%3D"asterisk-pbx"?project=luso8-cloud
```

### Cloud Monitoring Dashboard

The GCE VM sends system metrics (CPU, memory, disk) automatically via Cloud Ops Agent.

**Create a custom dashboard**:
```
https://console.cloud.google.com/monitoring/dashboards?project=luso8-cloud
```

Add these widgets:
- **GCE CPU** — `compute.googleapis.com/instance/cpu/utilization`
- **GCE Memory** — `agent.googleapis.com/memory/percent_used`
- **GCE Disk** — `agent.googleapis.com/disk/percent_used`

### Uptime Alert

```bash
# Create an email alert policy for ARI downtime
gcloud alpha monitoring policies create \
    --policy-from-file=- << 'EOF'
{
  "displayName": "Luso8 Asterisk ARI Down",
  "conditions": [{
    "displayName": "ARI uptime check failing",
    "conditionThreshold": {
      "filter": "resource.type=\"uptime_url\" AND metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\"",
      "comparison": "COMPARISON_LT",
      "thresholdValue": 1,
      "duration": "300s"
    }
  }],
  "notificationChannels": [],
  "alertStrategy": {"autoClose": "604800s"}
}
EOF
```

---

## Call Recordings

Recordings are stored in GCS and accessible via signed URLs from the Luso8 backend.

### Enable Recording in Dialplan

Add `MixMonitor` to `configs/luso8/extensions.conf` to record all calls:

```ini
[from-carrier]
exten = _X.,1,NoOp(Luso8 inbound: ${CALLERID(num)} to ${EXTEN})
 same = n,Set(CALL_DIRECTION=inbound)
 same = n,Set(REC_FILE=${STRFTIME(%Y%m%d-%H%M%S,,%Y%m%d-%H%M%S)})
 same = n,MixMonitor(default_${UNIQUEID}_${CALLERID(num)}_${REC_FILE}.wav,b)
 same = n,Stasis(${ARI_APP_NAME})
 same = n,Hangup()
```

### Access Recordings from Luso8 Backend

```python
# In api.luso8.rexplore.ai backend — generate signed URL for playback
from google.cloud import storage
from datetime import timedelta

def get_recording_url(filename: str, tenant_id: str) -> str:
    client = storage.Client(project="luso8-cloud")
    bucket = client.bucket("luso8-call-recordings-1073192452778")
    blob = bucket.blob(f"recordings/{tenant_id}/{filename}")
    url = blob.generate_signed_url(
        version="v4",
        expiration=timedelta(hours=1),
        method="GET"
    )
    return url
```

---

## Deploying a Config-Only Change

If you only changed Asterisk config files (not C source), you don't need a full rebuild. Use the `reload-config.sh` script:

```bash
gcloud compute ssh luso8-asterisk-pbx --zone=africa-south1-a \
    --command="sudo /opt/luso8/scripts/reload-config.sh"
```

Or trigger a deploy with **"Skip build"** option in the GitHub Actions workflow dispatch.

---

## Scaling

### Vertical Scaling (more concurrent calls)

```bash
# Resize the VM (requires brief stop)
gcloud compute instances stop luso8-asterisk-pbx --zone=africa-south1-a
gcloud compute instances set-machine-type luso8-asterisk-pbx \
    --zone=africa-south1-a \
    --machine-type=e2-standard-4   # 4 vCPU, 16GB RAM
gcloud compute instances start luso8-asterisk-pbx --zone=africa-south1-a
```

### Horizontal Scaling (multiple PBX nodes)

For multi-node deployments (e.g., dedicated node per enterprise tenant):

```bash
# Copy the VM as a template
gcloud compute instances create luso8-asterisk-pbx-02 \
    --zone=africa-south1-a \
    --machine-type=e2-standard-2 \
    --source-instance=luso8-asterisk-pbx \
    --source-instance-zone=africa-south1-a
```

Each node gets its own static IP, its own DNS subdomain (e.g., `pbx2.luso8.rexplore.ai`), and its own set of Secret Manager secrets with a different prefix (e.g., `luso8-pbx2-*`).

---

## Troubleshooting

### Container not starting

```bash
gcloud compute ssh luso8-asterisk-pbx --zone=africa-south1-a \
    --command="docker logs luso8-asterisk --tail=50"
```

### ARI not responding

```bash
# Check Asterisk is actually running inside container
gcloud compute ssh luso8-asterisk-pbx --zone=africa-south1-a \
    --command="docker exec luso8-asterisk asterisk -rx 'core show version'"

# Check ARI module is loaded
gcloud compute ssh luso8-asterisk-pbx --zone=africa-south1-a \
    --command="docker exec luso8-asterisk asterisk -rx 'module show like res_ari'"
```

### SIP trunk not registering

```bash
gcloud compute ssh luso8-asterisk-pbx --zone=africa-south1-a --command="
docker exec luso8-asterisk asterisk -rx 'pjsip show registrations'
docker exec luso8-asterisk asterisk -rx 'pjsip show contacts'
"
```

Common causes:
- `SIP_TRUNK_HOST` still set to `PLACEHOLDER` → set via admin dashboard
- Firewall blocking UDP 5060 from carrier IP
- Carrier's realm doesn't match `SIP_TRUNK_REALM`

### No audio (one-way or no audio)

```bash
# Verify RTP ports are open
gcloud compute firewall-rules describe luso8-allow-rtp --project=luso8-cloud

# Check external IP is correctly set in pjsip.conf
gcloud compute ssh luso8-asterisk-pbx --zone=africa-south1-a \
    --command="docker exec luso8-asterisk asterisk -rx 'pjsip show transport transport-udp'"
```

Common causes:
- `EXTERNAL_IP` wrong or not matching GCE static IP
- RTP ports `10000-10100/udp` not open in firewall
- Docker not using `--network host` (check container config)

### Deployment failing

```bash
# Check GitHub Actions logs in the Actions tab
# Check last deploy on VM
gcloud compute ssh luso8-asterisk-pbx --zone=africa-south1-a \
    --command="docker events --since 1h --until now --filter 'container=luso8-asterisk'"
```
