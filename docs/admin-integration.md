# Admin Integration Guide — Luso8 + Voxtra + Telephony Core

Full-stack reference for how the Luso8 Cloud admin dashboard configures, connects to, and controls the Asterisk PBX — from UI form through to live call routing via Voxtra.

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  LUSO8 CLOUD ADMIN DASHBOARD (React/Chatwoot)               │
│  Settings → Voice Providers → Asterisk                      │
│  Settings → Telephony → SIP Trunks                          │
└────────────────────┬────────────────────────────────────────┘
                     │ HTTPS POST /api/v1/telephony/config
                     ▼
┌─────────────────────────────────────────────────────────────┐
│  LUSO8 BACKEND (api.luso8.rexplore.ai)                      │
│  1. Validate + save to GCP Secret Manager                   │
│  2. SSH → sudo reload-config.sh (live reload, 0 downtime)   │
│  3. Return new ARI credentials to frontend                  │
└────────────────────┬────────────────────────────────────────┘
                     │
          ┌──────────┴──────────┐
          ▼                     ▼
┌──────────────────┐  ┌────────────────────────────────────┐
│ GCP SECRET MGR   │  │  GCE VM — pbx.luso8.rexplore.ai    │
│ luso8-pbx-*      │  │  sudo reload-config.sh             │
│                  │  │    → pull-secrets.sh               │
│ ari-username     │  │    → envsubst templates            │
│ ari-password     │  │    → asterisk module reload        │
│ sip-trunk-host   │  └──────────────┬─────────────────────┘
│ sip-trunk-user   │                 │
│ sip-trunk-pass   │                 ▼
│ sip-domain       │  ┌────────────────────────────────────┐
│ external-ip      │  │  ASTERISK CONTAINER                │
│ outbound-cid     │  │  Reads /opt/luso8/.env             │
└──────────────────┘  │  ARI HTTP :8088                    │
                       │  SIP UDP/TCP :5060                 │
                       │  RTP :10000–10100                  │
                       └──────────────┬─────────────────────┘
                                      │ ARI WebSocket
                                      ▼
                       ┌────────────────────────────────────┐
                       │  VOXTRA (Python — Cloud Run)       │
                       │  VoxtraApp → ARI WebSocket         │
                       │  Stasis events → VoicePipeline     │
                       │  STT (Deepgram) → LLM (OpenAI)    │
                       │  → TTS (ElevenLabs) → Asterisk     │
                       └────────────────────────────────────┘
```

---

## Part 1 — Luso8 Admin Dashboard

### 1.1 Voice Provider Setup (ARI Connection)

Go to: **Settings → Voice Providers → Add Provider → Asterisk PBX**

| UI Field | Value | Notes |
|---|---|---|
| **ARI URL** | `http://34.35.43.82:8088` | Use IP until DNS is set; then `http://pbx.luso8.rexplore.ai:8088` |
| **ARI Username** | `asterisk` | Set by `gcp-setup.sh`, stored in Secret Manager as `luso8-pbx-ari-username` |
| **ARI Password** | (fetch from Secret Manager) | `gcloud secrets versions access latest --secret=luso8-pbx-ari-password --project=luso8-cloud` |
| **SIP Domain** | `pbx.luso8.rexplore.ai` | Must match what Asterisk uses for From headers |
| **Default Context** | `from-carrier` | The inbound dialplan context in `extensions.conf` |
| **Outbound Caller ID** | `+265XXXXXXXXX` | Your DID number from the carrier |

### 1.2 SIP Trunk / Carrier Setup

Go to: **Settings → Telephony → SIP Trunks → Add Trunk**

| UI Field | Secret Manager Key | Description |
|---|---|---|
| **Trunk Host** | `luso8-pbx-sip-trunk-host` | Carrier SIP server (e.g. `sip.africastalking.com`) |
| **Trunk Username** | `luso8-pbx-sip-trunk-user` | SIP account username |
| **Trunk Password** | `luso8-pbx-sip-trunk-pass` | SIP account password |
| **Outbound Caller ID** | `luso8-pbx-outbound-caller-id` | E.164 format DID: `+265XXXXXXXXX` |

### 1.3 Manually Setting Secrets (CLI — before UI is wired up)

```bash
# Set each secret (first time creates it; repeat to update)
echo -n "sip.africastalking.com" \
  | gcloud secrets versions add luso8-pbx-sip-trunk-host --data-file=- --project=luso8-cloud

echo -n "your_sip_username" \
  | gcloud secrets versions add luso8-pbx-sip-trunk-user --data-file=- --project=luso8-cloud

echo -n "your_sip_password" \
  | gcloud secrets versions add luso8-pbx-sip-trunk-pass --data-file=- --project=luso8-cloud

echo -n "+265XXXXXXXXX" \
  | gcloud secrets versions add luso8-pbx-outbound-caller-id --data-file=- --project=luso8-cloud

# Then trigger a live reload (no restart, no dropped calls):
gcloud compute ssh luso8-asterisk-pbx --zone=africa-south1-a --project=luso8-cloud \
  --command="sudo /opt/luso8/scripts/reload-config.sh"
```

---

## Part 2 — Luso8 Backend Implementation

### 2.1 API Endpoint

```
POST /api/v1/telephony/config
Authorization: Bearer <admin_token>
Content-Type: application/json
```

**Request body:**
```json
{
  "provider": "asterisk",
  "ari_url": "http://34.35.43.82:8088",
  "ari_username": "asterisk",
  "ari_password": "...",
  "sip_domain": "pbx.luso8.rexplore.ai",
  "default_context": "from-carrier",
  "outbound_caller_id": "+265XXXXXXXXX",
  "trunk": {
    "host": "sip.africastalking.com",
    "username": "myaccount",
    "password": "mypassword"
  }
}
```

**Response:**
```json
{
  "status": "ok",
  "reload": "triggered",
  "ari_url": "http://34.35.43.82:8088",
  "message": "Config updated and applied. Trunk registration in progress."
}
```

### 2.2 Backend Logic (Node.js / Python pseudocode)

```python
# POST /api/v1/telephony/config
async def update_telephony_config(body, admin):
    secrets = {
        "luso8-pbx-sip-trunk-host":      body.trunk.host,
        "luso8-pbx-sip-trunk-user":      body.trunk.username,
        "luso8-pbx-sip-trunk-pass":      body.trunk.password,
        "luso8-pbx-outbound-caller-id":  body.outbound_caller_id,
        "luso8-pbx-sip-domain":          body.sip_domain,
    }

    # 1. Write each value to GCP Secret Manager
    sm_client = secretmanager.SecretManagerServiceClient()
    for secret_id, value in secrets.items():
        sm_client.add_secret_version(
            parent=f"projects/luso8-cloud/secrets/{secret_id}",
            payload={"data": value.encode("utf-8")}
        )

    # 2. Trigger live reload on the VM via SSH
    #    (Use paramiko, subprocess gcloud, or a webhook)
    run_on_vm("sudo /opt/luso8/scripts/reload-config.sh")

    # 3. Persist the ARI connection details for Voxtra
    await db.telephony_providers.upsert({
        "type": "asterisk",
        "ari_url": body.ari_url,
        "ari_username": body.ari_username,
        "ari_password": encrypt(body.ari_password),  # store encrypted
        "sip_domain": body.sip_domain,
        "default_context": body.default_context,
    })

    return {"status": "ok", "reload": "triggered"}
```

### 2.3 SSH Reload from Backend

The backend triggers config reload by SSH-ing into the VM. Use the `github-deploy` key (or a separate `backend-deploy` key) with strict sudoers:

**Option A — `gcloud compute ssh` (simplest, uses WIF service account):**
```python
import subprocess

def run_on_vm(command: str):
    result = subprocess.run([
        "gcloud", "compute", "ssh", "luso8-asterisk-pbx",
        "--zone=africa-south1-a",
        "--project=luso8-cloud",
        "--quiet",
        f"--command={command}"
    ], capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        raise RuntimeError(f"VM command failed: {result.stderr}")
    return result.stdout
```

**Option B — Direct SSH with paramiko (lower latency, no gcloud dependency):**
```python
import paramiko

def run_on_vm(command: str):
    key = paramiko.Ed25519Key.from_private_key_file("/run/secrets/luso8_deploy_key")
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect("34.35.43.82", username="github-deploy", pkey=key)
    _, stdout, stderr = client.exec_command(command)
    exit_code = stdout.channel.recv_exit_status()
    if exit_code != 0:
        raise RuntimeError(stderr.read().decode())
    return stdout.read().decode()
```

**Option C — Cloud Run job / Pub/Sub trigger (recommended for production):**
```
Admin saves config
  → Backend writes to Secret Manager
  → Backend publishes to Pub/Sub topic: luso8-pbx-reload
  → Cloud Run job subscribes, SSHes into VM, runs reload-config.sh
  → Job reports status back via Firestore/webhook
```

### 2.4 VM Firewall — Backend Access

The VM's SSH port (22) is currently restricted. To allow backend SSH access, add the backend Cloud Run service's outbound IP to the firewall rule:

```bash
# Get Cloud Run outbound IP range and add to allow list
gcloud compute firewall-rules update luso8-asterisk-ssh \
    --source-ranges="35.XXX.XXX.XXX/32,YOUR_BACKEND_IP/32" \
    --project=luso8-cloud
```

Or use **Cloud IAP** (Identity-Aware Proxy) for zero-trust VM access without exposing port 22 publicly.

---

## Part 3 — Voxtra Integration

### 3.1 How Voxtra Connects to Asterisk

Voxtra is a Python library (`pip install voxtra[asterisk,deepgram,openai,elevenlabs]`) that bridges Asterisk ARI to AI voice agents.

**Connection flow:**
1. Voxtra establishes an ARI WebSocket to `ws://pbx.luso8.rexplore.ai:8088/ari/events?app=voxtra`
2. When a call arrives, Asterisk dialplan executes `Stasis(voxtra)` — handing control to Voxtra
3. Voxtra receives `StasisStart` event → creates a `CallSession`
4. `CallSession` starts the `VoicePipeline` (STT → LLM → TTS loop)
5. On hangup, `StasisEnd` → `CallSession` teardown

### 3.2 Voxtra Configuration

```yaml
# voxtra.config.yaml (deployed with Voxtra on Cloud Run)
asterisk:
  ari_url: "http://pbx.luso8.rexplore.ai:8088"
  ari_username: "asterisk"
  ari_password: "${ARI_PASSWORD}"         # from Secret Manager at runtime
  app_name: "voxtra"
  reconnect_interval: 5                  # seconds before reconnect on disconnect
  max_reconnect_attempts: 10

stt:
  provider: deepgram
  model: nova-2-phonecall
  language: en
  endpointing_ms: 400

llm:
  provider: openai
  model: gpt-4o-mini
  system_prompt: "You are a helpful AI call agent for Luso8 Cloud..."

tts:
  provider: elevenlabs
  voice_id: "${ELEVENLABS_VOICE_ID}"
  model: eleven_turbo_v2
  latency_optimization: 4
```

### 3.3 Voxtra Python App Bootstrap

```python
# main.py — Voxtra Cloud Run service entry point
from voxtra import VoxtraApp, Config

config = Config.from_yaml("voxtra.config.yaml")

app = VoxtraApp(
    ari_url=config.asterisk.ari_url,
    ari_username=config.asterisk.ari_username,
    ari_password=config.asterisk.ari_password,
    app_name=config.asterisk.app_name,
)

@app.on_call
async def handle_call(session):
    """Called for every inbound/outbound call entering Stasis(voxtra)."""
    await session.answer()
    await session.run_pipeline(config)

if __name__ == "__main__":
    app.run()
```

### 3.4 Voxtra Secrets (Cloud Run environment)

```bash
# Set Voxtra secrets in Secret Manager
echo -n "your_deepgram_key" \
  | gcloud secrets versions add luso8-voxtra-deepgram-key --data-file=- --project=luso8-cloud

echo -n "your_openai_key" \
  | gcloud secrets versions add luso8-voxtra-openai-key --data-file=- --project=luso8-cloud

echo -n "your_elevenlabs_key" \
  | gcloud secrets versions add luso8-voxtra-elevenlabs-key --data-file=- --project=luso8-cloud

# Deploy Voxtra to Cloud Run with secrets mounted
gcloud run deploy luso8-voxtra \
  --image=africa-south1-docker.pkg.dev/luso8-cloud/luso8-telephony/voxtra:latest \
  --region=africa-south1 \
  --project=luso8-cloud \
  --set-secrets="ARI_PASSWORD=luso8-pbx-ari-password:latest,DEEPGRAM_API_KEY=luso8-voxtra-deepgram-key:latest,OPENAI_API_KEY=luso8-voxtra-openai-key:latest,ELEVENLABS_API_KEY=luso8-voxtra-elevenlabs-key:latest"
```

### 3.5 ARI Port Firewall — Voxtra Access

The ARI HTTP port (8088) is currently not exposed publicly (by design). Voxtra must reach it over internal GCP VPC (recommended) or you can open it to Cloud Run's IP range only:

```bash
# Internal VPC access (recommended — same VPC as GCE VM)
# Add Voxtra Cloud Run with VPC connector to the same VPC as the GCE VM

# OR: Allow Cloud Run's static outbound IP (less secure)
gcloud compute firewall-rules create luso8-ari-voxtra \
    --network=default \
    --action=allow \
    --direction=ingress \
    --rules=tcp:8088 \
    --source-ranges="CLOUD_RUN_OUTBOUND_IP/32" \
    --target-tags=luso8-asterisk \
    --project=luso8-cloud
```

---

## Part 4 — Telephony Core: Config Reload Flow

### 4.1 What Happens When Admin Saves Settings

```
Admin saves trunk credentials in UI
  │
  ▼
Backend: write secrets to Secret Manager
  │
  ▼
Backend: SSH → sudo /opt/luso8/scripts/reload-config.sh
  │
  ├─ pull-secrets.sh
  │    └─ gcloud secrets versions access → /opt/luso8/.env
  │
  ├─ docker exec → envsubst templates (pjsip.conf, ari.conf, etc.)
  │
  ├─ asterisk -rx "module reload res_pjsip.so"
  │    └─ picks up new SIP trunk credentials LIVE (no call drop)
  │
  ├─ asterisk -rx "module reload res_pjsip_outbound_registration.so"
  │    └─ re-registers with new carrier immediately
  │
  └─ health-check.sh
       └─ verifies ARI HTTP 200 + SIP trunk registered
```

**Zero downtime**: Asterisk module reload re-reads config without interrupting active calls. Only new calls use the updated trunk.

### 4.2 Config Template Variable Map

Every variable in `/opt/luso8/.env` maps directly to a template placeholder:

| `.env` variable | `pjsip.conf.tmpl` | `ari.conf.tmpl` | `extensions.conf.tmpl` |
|---|---|---|---|
| `ARI_USERNAME` | — | `[${ARI_USERNAME}]` user section | — |
| `ARI_PASSWORD` | `password = ${ARI_PASSWORD}` (voxtra-auth) | `password = ${ARI_PASSWORD}` | — |
| `SIP_DOMAIN` | `from_domain = ${SIP_DOMAIN}` | — | context names |
| `EXTERNAL_IP` | `external_media_address = ${EXTERNAL_IP}` | — | — |
| `SIP_TRUNK_HOST` | `server_uri = sip:${SIP_TRUNK_HOST}` | — | — |
| `SIP_TRUNK_USER` | `username = ${SIP_TRUNK_USER}` | — | — |
| `SIP_TRUNK_PASS` | `password = ${SIP_TRUNK_PASS}` | — | — |
| `OUTBOUND_CALLER_ID` | `callerid = Luso8 AI <${OUTBOUND_CALLER_ID}>` | — | `Set(CALLERID(num)=...)` |
| `DEFAULT_CONTEXT` | `context = ${DEFAULT_CONTEXT}` | — | `[${DEFAULT_CONTEXT}]` |

### 4.3 Per-Tenant Config Fragments (Multi-tenant SaaS)

For multi-tenant deployments, the Voxtra `TenantProvisioner` writes per-tenant SIP endpoint and ARI user fragments:

```
/opt/luso8/tenant-configs/
  pjsip/
    <tenant_id>.conf     ← per-tenant SIP endpoint + auth + AOR
  ari/
    <tenant_id>.conf     ← per-tenant ARI user
  extensions/
    <tenant_id>.conf     ← per-tenant dialplan context
```

These are volume-mounted into the container at:
- `/etc/asterisk/pjsip.d/<tenant_id>.conf`
- `/etc/asterisk/ari.d/<tenant_id>.conf`
- `/etc/asterisk/extensions.d/<tenant_id>.conf`

**Fragment format (pjsip):**
```ini
; Tenant: acme-corp
[acme-corp-endpoint]
type = endpoint
context = from-carrier-acme-corp
allow = !all,ulaw,alaw
aors = acme-corp-aor

[acme-corp-aor]
type = aor
max_contacts = 10

[acme-corp-auth]
type = auth
auth_type = userpass
username = acme-corp
password = <generated_per_tenant>
```

**Adding a tenant (via Luso8 backend):**
```python
def provision_tenant(tenant_id: str, sip_password: str):
    # Write pjsip fragment to VM
    fragment = render_pjsip_template(tenant_id, sip_password)
    write_to_vm(f"/opt/luso8/tenant-configs/pjsip/{tenant_id}.conf", fragment)

    # Live reload (no restart)
    run_on_vm("sudo /opt/luso8/scripts/reload-config.sh")
```

---

## Part 5 — End-to-End Call Flow

```
1. INBOUND CALL
   Cellular/SIP carrier → SIP INVITE to 34.35.43.82:5060
   Asterisk PJSIP (trunk-endpoint) matches via [trunk-identify]
   Dialplan: [from-carrier] exten _X.
     → MixMonitor(recording.wav)       ← starts recording
     → Stasis(voxtra)                   ← hands call to Voxtra

2. VOXTRA HANDLES CALL
   ARI StasisStart event received by Voxtra WebSocket
   VoxtraApp.on_call callback fires
   session.answer() → ARI POST /channels/{id}/answer
   VoicePipeline starts:
     ├─ STT: Deepgram stream receives RTP audio from Asterisk
     ├─ VAD: voice activity detection triggers LLM call
     ├─ LLM: OpenAI generates response text
     └─ TTS: ElevenLabs synthesizes audio
   Audio played back via ARI POST /channels/{id}/play

3. OUTBOUND CALL (AI-originated)
   Voxtra calls ARI POST /channels (originate)
   Asterisk [from-voxtra] dialplan:
     → Dial(PJSIP/+265XXXXXXXX@trunk-endpoint)
   Carrier routes call to destination

4. CALL RECORDING
   MixMonitor writes .wav to /var/spool/asterisk/recording/
   Volume-mounted to host: /var/spool/asterisk/recording/
   Cron job (every 5 min): sync-recordings.sh → gsutil rsync → GCS
   Recordings accessible via signed URLs from api.luso8.rexplore.ai

5. HANGUP
   ARI StasisEnd event
   Voxtra CallSession teardown
   Recording finalized by MixMonitor
   Recording synced to GCS on next cron tick
```

---

## Part 6 — Checklist: Wiring It All Up

### Step 1 — Telephony Core (already done ✅)
- [x] VM running at `34.35.43.82`
- [x] Asterisk container healthy, ARI responding
- [x] `pull-secrets.sh` + `reload-config.sh` on VM
- [ ] DNS: add `pbx.luso8.rexplore.ai` A record → `34.35.43.82` (Cloudflare, proxy OFF)

### Step 2 — Set Carrier Credentials (do this next)
```bash
# Replace with real carrier values
echo -n "YOUR_SIP_TRUNK_HOST" \
  | gcloud secrets versions add luso8-pbx-sip-trunk-host --data-file=- --project=luso8-cloud
echo -n "YOUR_SIP_TRUNK_USER" \
  | gcloud secrets versions add luso8-pbx-sip-trunk-user --data-file=- --project=luso8-cloud
echo -n "YOUR_SIP_TRUNK_PASS" \
  | gcloud secrets versions add luso8-pbx-sip-trunk-pass --data-file=- --project=luso8-cloud
echo -n "+265XXXXXXXXX" \
  | gcloud secrets versions add luso8-pbx-outbound-caller-id --data-file=- --project=luso8-cloud

# Apply immediately
gcloud compute ssh luso8-asterisk-pbx --zone=africa-south1-a --project=luso8-cloud \
  --command="sudo /opt/luso8/scripts/reload-config.sh"
```

### Step 3 — Luso8 UI Configuration
In **Luso8 Cloud dashboard → Voice Providers**:
- ARI URL: `http://34.35.43.82:8088`
- ARI Username: `asterisk`
- ARI Password: `$(gcloud secrets versions access latest --secret=luso8-pbx-ari-password --project=luso8-cloud)`
- SIP Domain: `pbx.luso8.rexplore.ai`
- Default Context: `from-carrier`
- Outbound Caller ID: your DID in E.164

### Step 4 — Deploy Voxtra
```bash
# Build and push Voxtra image
docker build -t africa-south1-docker.pkg.dev/luso8-cloud/luso8-telephony/voxtra:latest .
docker push africa-south1-docker.pkg.dev/luso8-cloud/luso8-telephony/voxtra:latest

# Deploy to Cloud Run (same region as VM for low latency)
gcloud run deploy luso8-voxtra \
  --image=africa-south1-docker.pkg.dev/luso8-cloud/luso8-telephony/voxtra:latest \
  --region=africa-south1 \
  --project=luso8-cloud \
  --vpc-connector=luso8-vpc-connector \
  --set-secrets="ARI_PASSWORD=luso8-pbx-ari-password:latest,..."
```

### Step 5 — Test a Call
```bash
# Verify ARI is accessible from Voxtra's network
curl -u asterisk:$(gcloud secrets versions access latest --secret=luso8-pbx-ari-password --project=luso8-cloud) \
  http://34.35.43.82:8088/ari/asterisk/info

# Check SIP trunk registered (after setting carrier credentials)
gcloud compute ssh luso8-asterisk-pbx --zone=africa-south1-a --project=luso8-cloud \
  --command="sudo docker exec luso8-asterisk asterisk -rx 'pjsip show registrations'"

# Make a test call via ARI originate
curl -X POST -u asterisk:PASSWORD \
  "http://34.35.43.82:8088/ari/channels?endpoint=PJSIP/+265XXXXXXXXX@trunk-endpoint&app=voxtra&callerId=+265XXXXXXXXX"
```
