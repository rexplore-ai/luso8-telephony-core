# Luso8 Telephony Core

**AI-powered call center backbone — built by Rexplore Research Labs.**

This is the Asterisk PBX source code that powers the telephony layer of the Luso8 Cloud platform. It handles SIP signaling, call routing, and real-time media — and exposes the ARI (Asterisk REST Interface) that [Voxtra](https://github.com/rexplore-ai/voxtra) uses to connect AI agents to real phone calls.

---

## Documentation

| Document | Description |
|---|---|
| **[docs/README.md](docs/README.md)** | Project overview and 5-minute quick start |
| **[docs/gcp-setup.md](docs/gcp-setup.md)** | **Start here** — full GCP CI/CD deployment with Secret Manager |
| **[docs/deployment.md](docs/deployment.md)** | How to deploy: VPS, Google Cloud Compute Engine, Docker |
| **[docs/configuration.md](docs/configuration.md)** | All config files, environment variables, and what needs to be done |
| **[docs/voxtra-vision.md](docs/voxtra-vision.md)** | What the Voxtra library should focus on — design spec |
| **[docs/saas-architecture.md](docs/saas-architecture.md)** | Multi-tenant SaaS architecture for Luso8 Cloud |

---

## Configuration Templates

Production-ready Asterisk config templates live in [`configs/luso8/`](configs/luso8/). All values use `${VARIABLE}` placeholders substituted by `docker/entrypoint.sh` at container startup.

| File | Purpose |
|---|---|
| `configs/luso8/asterisk.conf` | Core Asterisk settings (directories, limits) |
| `configs/luso8/http.conf` | ARI HTTP server — port, bind address, TLS |
| `configs/luso8/ari.conf` | ARI authentication — users, origins |
| `configs/luso8/pjsip.conf` | SIP stack — transport, trunk, endpoints |
| `configs/luso8/extensions.conf` | Dialplan — routes calls into Voxtra via `Stasis()` |
| `configs/luso8/queues.conf` | Human agent queues for AI-to-human handoff |
| `configs/luso8/rtp.conf` | RTP media port range |
| `configs/luso8/logger.conf` | Log levels and rotation |
| `configs/luso8/modules.conf` | Module loading — only what's needed for AI call center |
| `configs/luso8/musiconhold.conf` | Hold music for queuing callers |

---

## CI/CD Deployment (GCP)

```bash
# 1. Run one-time infrastructure setup (creates VM, secrets, firewall, bucket)
chmod +x scripts/*.sh
./scripts/gcp-setup.sh

# 2. Add 2 GitHub Secrets from the setup output:
#    GCP_SA_KEY  → /tmp/luso8-github-sa-key.json
#    GCE_SSH_KEY → printed SSH private key

# 3. Add Cloudflare DNS A record: pbx.luso8.rexplore.ai → GCE static IP (proxy OFF)

# 4. Push to main → GitHub Actions builds, pushes, and deploys automatically
git push origin main
```

See [docs/gcp-setup.md](docs/gcp-setup.md) for the full guide.

## Local Development

```bash
cp .env.example .env
nano .env          # fill in your real values
docker-compose -f docker/docker-compose.yml up --build
curl -u asterisk:YOUR_ARI_PASSWORD http://localhost:8088/ari/asterisk/info
```

See [`docker/docker-compose.yml`](docker/docker-compose.yml) and [`docker/Dockerfile`](docker/Dockerfile).

---

## Minimum Environment Variables

| Variable | Required | Example | Where Used |
|---|---|---|---|
| `ARI_USERNAME` | ✅ | `asterisk` | Luso8 UI "ARI Username" field |
| `ARI_PASSWORD` | ✅ | `Str0ngRand0m32chars` | Luso8 UI "ARI Password" field |
| `EXTERNAL_IP` | ✅ | `34.102.X.X` | NAT traversal for SIP/RTP |
| `SIP_DOMAIN` | ✅ | `pbx.luso8.com` | Luso8 UI "SIP Domain" field |
| `SIP_TRUNK_HOST` | ✅ | `sip.carrier.mw` | Your local SIP carrier |
| `SIP_TRUNK_USER` | ✅ | `265XXXXXXXXX` | Your carrier account ID |
| `SIP_TRUNK_PASS` | ✅ | `carrierpass` | Your carrier password |
| `OUTBOUND_CALLER_ID` | ✅ | `+265XXXXXXXXX` | Luso8 UI "Outbound Caller ID" |
| `DEFAULT_CONTEXT` | ✅ | `from-carrier` | Luso8 UI "Default Context" |

Full list: [docs/configuration.md](docs/configuration.md)

---

## How It Connects to Voxtra

Asterisk exposes an ARI WebSocket. Voxtra connects to it and receives a `StasisStart` event for every inbound call. The dialplan entry point is a single line:

```ini
; /etc/asterisk/extensions.conf
[from-carrier]
exten = _X.,1,Stasis(voxtra)
 same = n,Hangup()
```

Voxtra then owns the call entirely — answering, streaming audio, talking to AI, and hanging up.

```python
# voxtra quickstart
from voxtra import VoxtraApp

app = VoxtraApp(
    ari_url="http://YOUR_SERVER:8088",
    ari_user="asterisk",
    ari_password="YOUR_ARI_PASSWORD"
)

@app.on_call
async def handle(call):
    await call.answer()
    # your AI logic here
    await call.hangup()

app.run()
```

---

## What Needs to Be Done Before Production

- [ ] Run `./scripts/gcp-setup.sh` to provision all GCP infrastructure
- [ ] Add `GCP_SA_KEY` and `GCE_SSH_KEY` to GitHub repository secrets
- [ ] Add Cloudflare DNS A record: `pbx.luso8.rexplore.ai` → GCE static IP (proxy **OFF**)
- [ ] Push to `main` branch — CI/CD handles build, push, and deploy
- [ ] Get SIP trunk credentials from local carrier (Malawi)
- [ ] Set carrier credentials via: `gcloud secrets versions add luso8-pbx-sip-trunk-host ...`
- [ ] Trigger live reload: `gcloud compute ssh luso8-asterisk-pbx --command="sudo /opt/luso8/scripts/reload-config.sh"`
- [ ] Register Asterisk in Luso8 Cloud UI ("Configure Telephony Provider" form)
- [ ] Deploy Voxtra pointing at `http://pbx.luso8.rexplore.ai:8088`
- [ ] Make a test call through the full stack

See [docs/gcp-setup.md](docs/gcp-setup.md) for the complete guide.
