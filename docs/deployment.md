# Deployment Guide

Asterisk is a **stateful, real-time media server** — it holds open SIP connections and RTP audio streams. This means it cannot run on fully stateless platforms like Cloud Run, Cloud Functions, or Fargate. It needs a persistent server with a stable IP and open UDP ports.

---

## Recommended Deployment Options

| Option | Best For | Cost |
|---|---|---|
| [VPS / Dedicated Server](#option-1-vps--dedicated-server) | Production, lowest latency | $10–40/mo (DigitalOcean, Hetzner, Contabo) |
| [Google Cloud Compute Engine](#option-2-google-cloud-compute-engine-gce) | GCP-native, easy scale-up | ~$30–60/mo |
| [Docker on GCE](#option-3-docker-on-gce-recommended-for-saas) | Multi-tenant SaaS, reproducible | ~$30–60/mo per instance |
| [Google Cloud Run — Voxtra only](#option-4-google-cloud-run-voxtra-app-only) | Voxtra Python app (NOT Asterisk) | Pay-per-request |

> **Important**: Asterisk itself **cannot run on Cloud Run** — Cloud Run containers are stateless and don't support persistent UDP sockets needed for SIP/RTP. Deploy Asterisk on a real VM. Voxtra (the Python app) CAN run on Cloud Run.

---

## Option 1: VPS / Dedicated Server

The simplest, lowest-latency option. Recommended for a single-tenant or small multi-tenant setup.

### Recommended Providers

| Provider | Region | Monthly Cost | Notes |
|---|---|---|---|
| Hetzner Cloud | Europe/US | $5–20 | Best price/performance |
| DigitalOcean Droplet | Worldwide | $12–24 | Easy, good docs |
| Contabo VPS | Europe/US | $5–10 | Very cheap, good for Africa routing |
| Vultr | Worldwide | $10–20 | Good African edge nodes |
| Google Cloud GCE | Worldwide | $25–60 | Best if rest of stack is on GCP |

### Minimum Server Specs

| Concurrent Calls | CPU | RAM | Bandwidth |
|---|---|---|---|
| Up to 50 | 2 vCPU | 4 GB | 100 Mbps |
| 50–200 | 4 vCPU | 8 GB | 500 Mbps |
| 200–500 | 8 vCPU | 16 GB | 1 Gbps |

### Step 1 — Provision the Server

```bash
# Ubuntu 22.04 LTS recommended
# After SSH into the server:

# Update system
sudo apt-get update && sudo apt-get upgrade -y

# Install build dependencies
sudo apt-get install -y \
    build-essential libssl-dev libncurses5-dev libnewt-dev \
    libxml2-dev libsqlite3-dev uuid-dev libjansson-dev \
    libxslt1-dev libcurl4-openssl-dev libedit-dev \
    subversion git wget unzip

# Install DAHDI (optional, only needed for hardware telephony cards)
# sudo apt-get install -y dahdi dahdi-dkms
```

### Step 2 — Build and Install Asterisk

```bash
# Clone this repository
git clone https://github.com/rexplore-ai/luso8-telephony-core.git
cd luso8-telephony-core

# Run configure
./configure --with-jansson-bundled

# Select modules (optional - use defaults for full install)
# make menuselect

# Build (uses all CPU cores)
make -j$(nproc)

# Install binaries, modules, configs
sudo make install
sudo make samples

# Create asterisk user
sudo useradd -r -d /var/lib/asterisk -s /sbin/nologin asterisk
sudo chown -R asterisk:asterisk /etc/asterisk /var/lib/asterisk \
    /var/log/asterisk /var/run/asterisk /var/spool/asterisk
```

### Step 3 — Configure Firewall

```bash
# SIP signaling (TCP + UDP)
sudo ufw allow 5060/udp
sudo ufw allow 5060/tcp
sudo ufw allow 5061/tcp    # SIP TLS

# RTP media (audio) — MUST be open for calls to have audio
sudo ufw allow 10000:20000/udp

# ARI HTTP interface (restrict to Voxtra server IP in production)
sudo ufw allow 8088/tcp    # ARI HTTP
sudo ufw allow 8089/tcp    # ARI HTTPS

# AMI (optional — restrict tightly)
# sudo ufw allow 5038/tcp

sudo ufw enable
```

### Step 4 — Apply Luso8 Configs

```bash
# Copy the production-ready configs
sudo cp /path/to/luso8-telephony-core/configs/luso8/*.conf /etc/asterisk/

# Edit with your actual values
sudo nano /etc/asterisk/pjsip.conf      # SIP trunk credentials
sudo nano /etc/asterisk/ari.conf        # ARI username/password
sudo nano /etc/asterisk/http.conf       # bind address
sudo nano /etc/asterisk/extensions.conf # dialplan
```

### Step 5 — Create Systemd Service

```bash
sudo tee /etc/systemd/system/asterisk.service > /dev/null <<'EOF'
[Unit]
Description=Asterisk PBX
After=network.target

[Service]
Type=forking
User=asterisk
Group=asterisk
ExecStart=/usr/sbin/asterisk -U asterisk -G asterisk -f
ExecReload=/usr/sbin/asterisk -rx "core reload"
ExecStop=/usr/sbin/asterisk -rx "core stop gracefully"
PIDFile=/var/run/asterisk/asterisk.pid
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable asterisk
sudo systemctl start asterisk
```

### Step 6 — Verify

```bash
# Check Asterisk is running
sudo systemctl status asterisk

# Connect to CLI
sudo asterisk -rvvv

# Test ARI from localhost
curl -u asterisk:YOUR_PASSWORD http://localhost:8088/ari/asterisk/info | python3 -m json.tool
```

---

## Option 2: Google Cloud Compute Engine (GCE)

### Step 1 — Create the VM

```bash
gcloud compute instances create asterisk-pbx \
    --zone=us-central1-a \
    --machine-type=e2-standard-2 \
    --image-family=ubuntu-2204-lts \
    --image-project=ubuntu-os-cloud \
    --boot-disk-size=50GB \
    --tags=asterisk-server
```

### Step 2 — Configure Firewall Rules

```bash
# SIP
gcloud compute firewall-rules create allow-sip \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=udp:5060,tcp:5060,tcp:5061 \
    --target-tags=asterisk-server

# RTP Media
gcloud compute firewall-rules create allow-rtp \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=udp:10000-20000 \
    --target-tags=asterisk-server

# ARI (restrict source to your Voxtra Cloud Run service IP range or VPC)
gcloud compute firewall-rules create allow-ari \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:8088,tcp:8089 \
    --target-tags=asterisk-server \
    --source-ranges=YOUR_VOXTRA_IP/32
```

### Step 3 — Reserve a Static IP

```bash
gcloud compute addresses create asterisk-static-ip --region=us-central1

# Get the IP
gcloud compute addresses describe asterisk-static-ip --region=us-central1 --format="get(address)"

# Assign to the instance
gcloud compute instances delete-access-config asterisk-pbx \
    --access-config-name="External NAT"
gcloud compute instances add-access-config asterisk-pbx \
    --access-config-name="External NAT" \
    --address=YOUR_STATIC_IP
```

### Step 4 — NAT Configuration for Asterisk

When Asterisk is behind a NAT (including GCE), you **must** set external IPs in `pjsip.conf`:

```ini
[transport-udp]
type = transport
protocol = udp
bind = 0.0.0.0:5060
local_net = 10.0.0.0/8          ; GCE internal network range
external_media_address = YOUR_STATIC_IP
external_signaling_address = YOUR_STATIC_IP
```

### Step 5 — Install Asterisk on GCE

SSH into the VM and follow the same [VPS steps](#step-1--provision-the-server) above.

---

## Option 3: Docker on GCE (Recommended for SaaS)

Running Asterisk in Docker gives you reproducibility and easy multi-tenant deployment. Each tenant or customer cluster gets an isolated Asterisk container.

### Dockerfile

Create `docker/Dockerfile` in this repo:

```dockerfile
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    build-essential libssl-dev libncurses5-dev libnewt-dev \
    libxml2-dev libsqlite3-dev uuid-dev libjansson-dev \
    libxslt1-dev libcurl4-openssl-dev libedit-dev \
    wget git && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/asterisk
COPY . .

RUN ./configure --with-jansson-bundled && \
    make -j$(nproc) && \
    make install && \
    make samples && \
    useradd -r -d /var/lib/asterisk -s /sbin/nologin asterisk && \
    chown -R asterisk:asterisk /etc/asterisk /var/lib/asterisk \
        /var/log/asterisk /var/run/asterisk /var/spool/asterisk

# Config files are injected at runtime via environment variables
# or mounted as a ConfigMap/Secret volume
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 5060/udp 5060/tcp 8088/tcp 8089/tcp
# RTP ports - must match rtp.conf rtpstart/rtpend
EXPOSE 10000-10100/udp

USER asterisk
ENTRYPOINT ["/entrypoint.sh"]
```

### `docker/entrypoint.sh`

```bash
#!/bin/bash
set -e

# Generate configs from environment variables
envsubst < /etc/asterisk/pjsip.conf.tmpl > /etc/asterisk/pjsip.conf
envsubst < /etc/asterisk/ari.conf.tmpl > /etc/asterisk/ari.conf
envsubst < /etc/asterisk/extensions.conf.tmpl > /etc/asterisk/extensions.conf

# Start Asterisk in foreground (for Docker)
exec /usr/sbin/asterisk -f -U asterisk -G asterisk
```

### `docker-compose.yml` for Local Development

```yaml
version: "3.9"
services:
  asterisk:
    build:
      context: ..
      dockerfile: docker/Dockerfile
    ports:
      - "5060:5060/udp"
      - "5060:5060/tcp"
      - "8088:8088/tcp"
      - "10000-10100:10000-10100/udp"
    environment:
      - ARI_USERNAME=asterisk
      - ARI_PASSWORD=supersecret
      - SIP_DOMAIN=localhost
      - SIP_TRUNK_HOST=sip.carrier.com
      - SIP_TRUNK_USER=myaccount
      - SIP_TRUNK_PASS=mypassword
      - OUTBOUND_CALLER_ID=+265123456789
      - DEFAULT_CONTEXT=from-carrier
      - EXTERNAL_IP=127.0.0.1
    volumes:
      - asterisk_logs:/var/log/asterisk
    network_mode: host   # Required for SIP/RTP to work correctly

volumes:
  asterisk_logs:
```

### Deploy Docker Container to GCE

```bash
# Build and push image to Google Artifact Registry
docker build -t gcr.io/YOUR_PROJECT/luso8-asterisk:latest .
docker push gcr.io/YOUR_PROJECT/luso8-asterisk:latest

# SSH into GCE VM and run:
docker pull gcr.io/YOUR_PROJECT/luso8-asterisk:latest
docker run -d \
    --name asterisk \
    --network host \
    -e ARI_USERNAME=asterisk \
    -e ARI_PASSWORD=supersecret \
    -e SIP_TRUNK_HOST=sip.carrier.com \
    -e SIP_TRUNK_USER=myaccount \
    -e SIP_TRUNK_PASS=mypassword \
    -e OUTBOUND_CALLER_ID=+265123456789 \
    -e EXTERNAL_IP=$(curl -s ifconfig.me) \
    -v /var/log/asterisk:/var/log/asterisk \
    gcr.io/YOUR_PROJECT/luso8-asterisk:latest
```

---

## Option 4: Google Cloud Run — Voxtra App Only

Cloud Run is **perfect for the Voxtra Python application** (the AI bridge layer). It scales to zero, is billed per request, and handles WebSocket connections.

```bash
# From the Voxtra repo
gcloud run deploy voxtra-agent \
    --image gcr.io/YOUR_PROJECT/voxtra:latest \
    --platform managed \
    --region us-central1 \
    --allow-unauthenticated \
    --set-env-vars="ASTERISK_ARI_URL=http://YOUR_ASTERISK_IP:8088" \
    --set-env-vars="ASTERISK_ARI_USER=asterisk" \
    --set-secrets="ASTERISK_ARI_PASS=asterisk-ari-password:latest" \
    --set-secrets="DEEPGRAM_API_KEY=deepgram-key:latest" \
    --set-secrets="OPENAI_API_KEY=openai-key:latest" \
    --set-secrets="ELEVENLABS_API_KEY=elevenlabs-key:latest" \
    --min-instances=1 \   # Keep warm for low-latency
    --concurrency=100
```

> **Note**: Set `--min-instances=1` so the ARI WebSocket connection to Asterisk stays alive. Cloud Run instances with 0 min instances will lose the persistent WebSocket to Asterisk.

---

## Network Architecture for Production

```
Internet
    │
    │  SIP/UDP:5060  +  RTP/UDP:10000-20000
    ▼
[GCE VM — Static Public IP]
    │   Asterisk PBX
    │   ARI :8088 (internal only)
    │
    │  ARI WebSocket (VPC internal or TLS)
    ▼
[Cloud Run — Voxtra]
    │   STT/LLM/TTS API calls
    │
    ▼
[External AI APIs: Deepgram, OpenAI, ElevenLabs]
```

---

## Health Checks and Monitoring

### Asterisk Health Check Script

```bash
#!/bin/bash
# /usr/local/bin/asterisk-health.sh

# Check process
if ! pgrep -x asterisk > /dev/null; then
    echo "CRITICAL: Asterisk not running"
    exit 2
fi

# Check ARI
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -u asterisk:$ARI_PASSWORD \
    http://localhost:8088/ari/asterisk/info)

if [ "$HTTP_CODE" != "200" ]; then
    echo "CRITICAL: ARI not responding (HTTP $HTTP_CODE)"
    exit 2
fi

echo "OK: Asterisk running, ARI healthy"
exit 0
```

### Key Metrics to Watch

```bash
# Active calls
asterisk -rx "core show channels" | tail -1

# SIP peer status
asterisk -rx "pjsip show contacts"

# ARI registered apps
asterisk -rx "ari show apps"

# Module health
asterisk -rx "module show like res_ari"
```
