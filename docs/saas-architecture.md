# SaaS Architecture — Multi-Tenant AI Call Center

This document describes how Luso8 Cloud deploys and manages Asterisk + Voxtra for multiple organizations simultaneously.

---

## The Core Problem: One Asterisk, Many Tenants

When running a SaaS call center platform, you have two options:

| Model | Pros | Cons |
|---|---|---|
| **One Asterisk per tenant** | Perfect isolation, easy teardown | Expensive, slow to provision |
| **Shared Asterisk, isolated by app name** | Cost-efficient, fast provisioning | More complex config management |

**Luso8 recommendation**: Use shared Asterisk for small/medium tenants, dedicated Asterisk for enterprise. Voxtra's `TenantProvisioner` handles both.

---

## Isolation Model: ARI App Namespacing

Asterisk's Stasis framework is the key to multi-tenancy. Each tenant gets their own Stasis application name, and Asterisk only sends events for a channel to the app that channel belongs to.

```
┌──────────────────────────────────────────────────────┐
│                  Asterisk PBX                         │
│                                                        │
│  Tenant A calls → Stasis(voxtra_org_acme)             │
│  Tenant B calls → Stasis(voxtra_org_beta)             │
│  Tenant C calls → Stasis(voxtra_org_gamma)            │
│                                                        │
│  ARI WebSocket streams:                                │
│    /ari/events?app=voxtra_org_acme  → Voxtra A        │
│    /ari/events?app=voxtra_org_beta  → Voxtra B        │
│    /ari/events?app=voxtra_org_gamma → Voxtra C        │
└──────────────────────────────────────────────────────┘
```

Each tenant's calls are completely isolated — Tenant A never sees Tenant B's events.

---

## Deployment Architecture

### Development / Small Teams (1 server)

```
┌─────────────────────────────────────────┐
│           Single GCE VM (e2-standard-4) │
│                                          │
│  [Asterisk] ← all tenants on one PBX    │
│  [Voxtra]   ← Python process per tenant │
│  [Redis]    ← session state              │
│  [Nginx]    ← reverse proxy for ARI TLS │
└─────────────────────────────────────────┘
```

### Production / Scale (recommended)

```
┌──────────────────────────────────────────────────────────────┐
│                      Google Cloud                             │
│                                                               │
│  ┌───────────────────────────────────────────────────────┐  │
│  │   GCE VM Pool (Asterisk PBX nodes)                     │  │
│  │   asterisk-01.luso8.com   ← handles tenants A, B, C   │  │
│  │   asterisk-02.luso8.com   ← handles tenants D, E, F   │  │
│  │   asterisk-03.luso8.com   ← enterprise tenants        │  │
│  └──────────────────────┬────────────────────────────────┘  │
│                          │ ARI WebSocket (VPC internal)       │
│  ┌───────────────────────┴────────────────────────────────┐  │
│  │   Cloud Run — Voxtra Services                           │  │
│  │   voxtra-org-acme  (min 1 instance, websocket to ARI)  │  │
│  │   voxtra-org-beta  (min 1 instance)                     │  │
│  │   voxtra-org-gamma (scales 1-10)                        │  │
│  └──────────────────────┬────────────────────────────────┘  │
│                          │ HTTPS API calls                    │
│  ┌───────────────────────┴────────────────────────────────┐  │
│  │   Luso8 Cloud Backend (Rails / Node)                    │  │
│  │   - Provisioning API                                    │  │
│  │   - Agent console                                       │  │
│  │   - Analytics                                           │  │
│  └────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

---

## Tenant Provisioning Flow

When a new customer signs up to Luso8 Cloud and connects their Asterisk:

```
Step 1: Customer fills Luso8 UI form
────────────────────────────────────────────────────────────
  ARI URL:            http://pbx.example.com:8088
  ARI Username:       asterisk
  ARI Password:       ****
  SIP Domain:         pbx.example.com
  Default Context:    from-carrier
  Outbound Caller ID: +265999001122

Step 2: Luso8 Backend calls Voxtra Provisioner API
────────────────────────────────────────────────────────────
POST /api/v1/provisioning/tenants
{
  "tenant_id": "org_acme_123",
  "asterisk_host": "pbx.example.com",
  "ari_url": "http://pbx.example.com:8088",
  "ari_username": "asterisk",
  "ari_password": "****",
  "sip_domain": "pbx.example.com",
  "default_context": "from-carrier",
  "outbound_caller_id": "+265999001122"
}

Step 3: Voxtra Provisioner executes
────────────────────────────────────────────────────────────
  a) Test ARI connectivity (GET /ari/asterisk/info)
  b) Generate isolated config fragments:
     → /etc/asterisk/pjsip.d/org_acme_123.conf
     → /etc/asterisk/extensions.d/org_acme_123.conf  
     → /etc/asterisk/ari.d/org_acme_123.conf
  c) Reload Asterisk modules:
     → asterisk -rx "module reload res_pjsip.so"
     → asterisk -rx "module reload pbx_config.so"
  d) Register Stasis app: voxtra_org_acme_123
  e) Test inbound/outbound routing

Step 4: Start Voxtra listener for this tenant
────────────────────────────────────────────────────────────
  → Deploy Cloud Run service: voxtra-org-acme-123
  → Configure ARI app_name = voxtra_org_acme_123
  → Connect to ARI WebSocket
  → Ready to receive calls

Step 5: Return credentials to Luso8 UI
────────────────────────────────────────────────────────────
{
  "status": "active",
  "ari_app": "voxtra_org_acme_123",
  "test_call_number": "+265999001122",
  "websocket_url": "ws://pbx.example.com:8088/ari/events?app=voxtra_org_acme_123"
}
```

---

## Config Fragment Pattern

Instead of one monolithic `pjsip.conf` that gets regenerated for every tenant, use Asterisk's `#include` directive to load per-tenant fragments from separate files.

### Master Config Files (set once, never change)

**`/etc/asterisk/pjsip.conf`**:
```ini
; Global transport (set once)
[transport-udp]
type = transport
protocol = udp
bind = 0.0.0.0:5060
local_net = 10.0.0.0/8
external_media_address = SERVER_PUBLIC_IP
external_signaling_address = SERVER_PUBLIC_IP

; Load all tenant-specific trunk configs
#include pjsip.d/*.conf
```

**`/etc/asterisk/extensions.conf`**:
```ini
; Load all tenant dialplan fragments
#include extensions.d/*.conf
```

**`/etc/asterisk/ari.conf`**:
```ini
[general]
enabled = yes
allowed_origins = *

; Load all tenant ARI users
#include ari.d/*.conf
```

### Per-Tenant Fragment (generated by Voxtra Provisioner)

**`/etc/asterisk/pjsip.d/org_acme_123.conf`**:
```ini
; Tenant: ACME Corp (org_acme_123)
; Generated by Voxtra Provisioner — do not edit manually

[trunk-org-acme-123-reg]
type = registration
outbound_auth = trunk-org-acme-123-auth
server_uri = sip:sip.carrier.mw
client_uri = sip:265999001122@sip.carrier.mw
retry_interval = 60

[trunk-org-acme-123-auth]
type = auth
auth_type = userpass
username = 265999001122
password = carrier_password_here

[trunk-org-acme-123-endpoint]
type = endpoint
context = tenant-org-acme-123
allow = !all,ulaw
outbound_auth = trunk-org-acme-123-auth
aors = trunk-org-acme-123-aor
direct_media = no
from_domain = sip.carrier.mw

[trunk-org-acme-123-aor]
type = aor
contact = sip:sip.carrier.mw

[trunk-org-acme-123-identify]
type = identify
endpoint = trunk-org-acme-123-endpoint
match = sip.carrier.mw
```

**`/etc/asterisk/extensions.d/org_acme_123.conf`**:
```ini
; Tenant: ACME Corp — dialplan fragment

[tenant-org-acme-123]
exten = _X.,1,NoOp(ACME Corp inbound: ${CALLERID(num)} → ${EXTEN})
 same = n,Set(TENANT_ID=org_acme_123)
 same = n,Stasis(voxtra_org_acme_123)
 same = n,Hangup()
```

**`/etc/asterisk/ari.d/org_acme_123.conf`**:
```ini
; Tenant: ACME Corp — ARI user
[voxtra_org_acme_123]
type = user
password = generated_ari_password_per_tenant
password_format = plain
```

---

## Voxtra SaaS Runner: One Process Per Tenant

In the Luso8 Cloud backend, each active tenant has a long-running Voxtra process connected to Asterisk via ARI WebSocket. These can run as:

### Option A: Cloud Run Services (recommended)

```python
# voxtra_runner.py — deployed as Cloud Run service per tenant
import asyncio
import os
from voxtra import VoxtraApp

tenant_id = os.environ["TENANT_ID"]
agent_handler_url = os.environ["AGENT_HANDLER_URL"]  # Luso8 Cloud webhook

app = VoxtraApp(
    ari_url=os.environ["ARI_URL"],
    ari_user=os.environ["ARI_USER"],
    ari_password=os.environ["ARI_PASSWORD"],
    app_name=f"voxtra_{tenant_id}"
)

@app.on_call
async def handle(call):
    # Delegate to Luso8 Cloud AI agent via webhook
    await call.answer()
    await delegate_to_luso8_agent(call, agent_handler_url)

asyncio.run(app.run_async())
```

### Option B: Async Tasks in Luso8 Backend (simpler)

```python
# In your Luso8 Cloud Django/FastAPI backend
from voxtra import VoxtraApp

# Stored in memory / Redis — one app per active tenant
tenant_apps: dict[str, VoxtraApp] = {}

async def start_tenant_listener(tenant: Tenant):
    app = VoxtraApp(
        ari_url=tenant.ari_url,
        ari_user=tenant.ari_username,
        ari_password=tenant.ari_password,
        app_name=f"voxtra_{tenant.id}"
    )

    @app.on_call
    async def handle(call):
        await route_call_to_agent(tenant, call)

    tenant_apps[tenant.id] = app
    asyncio.create_task(app.run_async())  # non-blocking background task
```

---

## Environment Variables for Multi-Tenant Deployment

### Voxtra Runner Service (Cloud Run)

```bash
# Required per tenant instance
TENANT_ID=org_acme_123
ARI_URL=http://asterisk-01.luso8.internal:8088
ARI_USER=voxtra_org_acme_123
ARI_PASSWORD=per_tenant_generated_password
ARI_APP_NAME=voxtra_org_acme_123

# Luso8 Cloud integration
LUSO8_WEBHOOK_URL=https://api.luso8.com/v1/calls/webhook
LUSO8_API_KEY=luso8_internal_service_key

# Optional AI providers (if Voxtra handles AI directly)
DEEPGRAM_API_KEY=dg_...
OPENAI_API_KEY=sk-...
ELEVENLABS_API_KEY=...
```

### Asterisk Node (GCE VM)

```bash
# Set in /etc/environment or Docker env
ASTERISK_PUBLIC_IP=34.X.X.X        # GCE static IP
ASTERISK_LOCAL_NET=10.0.0.0/8      # GCE internal range

# ARI master credentials (for Voxtra Provisioner admin operations)
ARI_ADMIN_USER=admin
ARI_ADMIN_PASSWORD=very_strong_admin_password

# SSH key path (for Voxtra Provisioner config deployment)
SSH_KEY_PATH=/root/.ssh/id_ed25519
```

---

## Scaling Considerations

### How Many Tenants Per Asterisk Node?

Rule of thumb: 1 vCPU handles ~50 simultaneous calls for transcoded audio.

| GCE Machine | Max Concurrent Calls | Tenants (avg 5 concurrent each) |
|---|---|---|
| e2-standard-2 (2 vCPU) | ~100 | ~20 tenants |
| e2-standard-4 (4 vCPU) | ~200 | ~40 tenants |
| e2-standard-8 (8 vCPU) | ~400 | ~80 tenants |
| c2-standard-8 (compute opt) | ~600 | ~120 tenants |

### When to Add a New Asterisk Node

Trigger a new node provisioning when:
- Active calls on a node exceed 70% of its capacity
- A tenant requests a dedicated node (enterprise tier)
- A tenant is in a different region (latency optimization)

### Multi-Region for Africa

For Malawi and neighboring markets, latency matters enormously. Plan:

```
Region 1: Johannesburg (closest GCP region to Central/Southern Africa)
  → asterisk-af-south1.luso8.com
  → Handles: MW, ZM, ZW, MZ, TZ tenants

Region 2: US Central (global fallback)
  → asterisk-us-central1.luso8.com
  → Handles: US, EU tenants, overflow

Region 3: Europe West (EU compliance)
  → asterisk-eu-west1.luso8.com
  → Handles: EU tenants with data residency requirements
```

---

## Security Checklist for Production SaaS

- [ ] ARI is never exposed on the public internet — use VPC internal IPs
- [ ] ARI uses TLS (`https://` and `wss://`) — configure `http.conf` TLS settings
- [ ] Each tenant gets a unique ARI username and password (never share)
- [ ] SIP trunk passwords are stored encrypted in Luso8 Cloud database
- [ ] Firewall: ARI port (8088) blocked from public internet, open only to Voxtra service IPs
- [ ] Firewall: SIP (5060 UDP) open only to carrier IP ranges, not `0.0.0.0/0`
- [ ] RTP ports (10000-20000 UDP) open to carrier IP ranges only
- [ ] Asterisk runs as non-root `asterisk` user
- [ ] `fail2ban` installed and configured for SIP auth failures
- [ ] Call recordings stored encrypted at rest (Google Cloud Storage)
- [ ] Per-tenant call recording bucket isolation (each tenant can only read their own)
- [ ] Tenant ARI passwords rotated on demand via `TenantProvisioner.rotate_credentials()`
