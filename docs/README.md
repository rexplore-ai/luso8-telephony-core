# Luso8 Telephony Core — Documentation

**Asterisk PBX backend for the Luso8 Cloud AI Call Center platform.**

This repository is the Asterisk open-source PBX source code, customized and maintained by Rexplore Research Labs as the telephony backbone for the Luso8 Cloud platform. It handles SIP signaling, call routing, media bridging, and exposes ARI (Asterisk REST Interface) so that [Voxtra](https://github.com/rexplore-ai/voxtra) and Luso8 Cloud can connect AI agents to real phone calls.

---

## What This Is

| Layer | Technology | Role |
|---|---|---|
| **SIP/PSTN** | Local carrier SIP trunk | Connects real phone numbers (local DIDs) |
| **PBX / Call Routing** | **Asterisk** (this repo) | Routes calls, manages extensions, exposes ARI |
| **AI Bridge** | [Voxtra](https://github.com/rexplore-ai/voxtra) | Connects Asterisk to STT/LLM/TTS |
| **Platform UI** | Luso8 Cloud | Multi-tenant dashboard, agent management |

---

## Documentation Index

| Document | Description |
|---|---|
| [Deployment Guide](./deployment.md) | Deploy on a VPS or Google Cloud |
| [Configuration Reference](./configuration.md) | All config files and environment variables |
| [Voxtra Library Vision](./voxtra-vision.md) | What voxtra should focus on — design spec |
| [SaaS Architecture](./saas-architecture.md) | Multi-tenant architecture for Luso8 Cloud |

---

## Quick Start (5 minutes)

### Prerequisites

- Ubuntu 20.04+ or Debian 11+ server (2 CPU / 4GB RAM minimum)
- Public IP address (or port-forwarded SIP/RTP ports)
- SIP trunk credentials from your local carrier

### 1 — Build and Install Asterisk

```bash
# Install build dependencies
sudo apt-get update
sudo apt-get install -y build-essential libssl-dev libncurses5-dev \
    libnewt-dev libxml2-dev libsqlite3-dev uuid-dev libjansson-dev \
    libxslt1-dev

# From this repository root:
./configure
make menuselect        # optional: select/deselect modules
make -j$(nproc)
sudo make install
sudo make samples      # writes default configs to /etc/asterisk/
sudo ldconfig
```

### 2 — Apply Minimum Configuration

Copy the ready-to-use configs from this repo:

```bash
sudo cp configs/luso8/*.conf /etc/asterisk/
```

> See [Configuration Reference](./configuration.md) for every option.

### 3 — Start Asterisk

```bash
# Foreground (debugging)
sudo asterisk -vvvc

# As a daemon
sudo systemctl start asterisk
sudo systemctl enable asterisk
```

### 4 — Verify ARI is Working

```bash
curl -u asterisk:YOUR_ARI_PASSWORD http://localhost:8088/ari/asterisk/info
```

You should get a JSON response with Asterisk version info.

### 5 — Connect Voxtra

```bash
pip install voxtra[asterisk,deepgram,openai,elevenlabs]
```

```python
# app.py
from voxtra import VoxtraApp

app = VoxtraApp.from_yaml("voxtra.yaml")

@app.route(extension="1000")
async def handle(session):
    await session.answer()
    await session.say("Hello, welcome to support!")
    text = await session.listen()
    reply = await session.agent.respond(text)
    await session.say(reply.text)
    await session.hangup()

app.run()
```

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                        Luso8 Cloud SaaS                          │
│  ┌──────────────┐   ┌─────────────────┐   ┌──────────────────┐  │
│  │  Web Dashboard│   │  Agent Console  │   │  Analytics API   │  │
│  └──────┬───────┘   └────────┬────────┘   └──────────────────┘  │
└─────────┼────────────────────┼────────────────────────────────────┘
          │ REST/WebSocket      │ SIP (human agent softphone)
          ▼                    ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Asterisk PBX (this repo)                      │
│                                                                   │
│  pjsip.conf  ←  SIP Trunk  ←  Local Carrier (Malawi, etc.)     │
│  extensions.conf  →  Stasis(voxtra)  →  ARI WebSocket :8088    │
│  queues.conf  →  Human agent queue fallback                      │
└─────────────────────────────┬───────────────────────────────────┘
                              │ ARI (HTTP + WebSocket)
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                         Voxtra Library                           │
│                                                                   │
│  AsteriskARIAdapter  →  CallSession  →  VoicePipeline           │
│                              │                                    │
│              ┌───────────────┼───────────────────┐              │
│              ▼               ▼                   ▼              │
│           Deepgram        OpenAI /          ElevenLabs          │
│            (STT)         LangGraph            (TTS)             │
│                            (LLM)                                 │
└─────────────────────────────────────────────────────────────────┘
```
