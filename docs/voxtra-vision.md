# Voxtra — Library Vision & Design Specification

**Repository**: https://github.com/rexplore-ai/voxtra

---

## What Voxtra Is NOT

Before defining what voxtra should be, let's be clear about what it should **not** try to be:

- ❌ Not a full AI agent framework (LangChain, LangGraph, Haystack already do this)
- ❌ Not an STT/TTS/LLM SDK (Deepgram, OpenAI, ElevenLabs SDKs already exist)
- ❌ Not a voice assistant platform (that's Luso8 Cloud's job)
- ❌ Not a replacement for Asterisk internals

The current voxtra boilerplate includes STT/TTS/LLM provider implementations. These are fine as **examples and optional extras**, but the core of the library must be useful without them.

---

## What Voxtra IS

> **Voxtra is the infrastructure glue layer between Asterisk and any application that needs to talk to phone calls.**

It does exactly three things extremely well:

1. **Manages the connection to Asterisk ARI** — authentication, WebSocket event streaming, reconnection, multi-app isolation
2. **Gives developers a clean per-call handle** — answer, hangup, play audio, receive audio, transfer, DTMF
3. **Handles SaaS provisioning** — generates Asterisk configs for tenants, isolates them, manages their SIP trunks

That's it. What the developer does inside a call (AI, IVR, recording, human handoff) is entirely up to them. Voxtra provides the rails, not the train.

---

## The Developer Experience Voxtra Must Deliver

### Level 1 — Minimal (10 lines to handle a phone call)

A developer who just got SIP trunk credentials and an Asterisk server should be able to handle real phone calls in 10 minutes:

```python
from voxtra import VoxtraApp

app = VoxtraApp(
    ari_url="http://pbx.example.com:8088",
    ari_user="asterisk",
    ari_password="secret"
)

@app.on_call
async def handle(call):
    await call.answer()
    await call.play_audio("hello-world")    # plays Asterisk sound file
    await call.hangup()

app.run()
```

No YAML. No config classes. No provider setup. Just handle the call.

### Level 2 — With Audio Streaming (bring your own AI)

```python
from voxtra import VoxtraApp

app = VoxtraApp(ari_url="...", ari_user="...", ari_password="...")

@app.on_call
async def handle(call):
    await call.answer()

    # stream raw audio OUT from the call to your own pipeline
    async for audio_chunk in call.audio_stream():
        transcript = await my_deepgram_client.transcribe(audio_chunk)
        if transcript:
            response_audio = await my_elevenlabs_client.synthesize(
                await my_openai_client.complete(transcript)
            )
            await call.send_audio(response_audio)

    await call.hangup()

app.run()
```

Voxtra provides `call.audio_stream()` and `call.send_audio()` — that's the entire media contract.

### Level 3 — Human-in-the-Loop Handoff

```python
@app.on_call
async def handle(call):
    await call.answer()

    # AI handles the call until it decides to escalate
    result = await run_ai_agent(call)

    if result.needs_human:
        # Transfer to human agent queue with full conversation context
        await call.transfer_to_queue(
            queue="support",
            metadata={
                "summary": result.conversation_summary,
                "intent": result.detected_intent,
                "caller_name": result.extracted_name,
            }
        )
    else:
        await call.hangup()
```

### Level 4 — Outbound AI Dialing

```python
# Trigger an outbound AI call (e.g., appointment reminder)
await app.originate(
    to="+265123456789",
    caller_id="+265987654321",
    handler=appointment_reminder_handler
)
```

### Level 5 — SaaS Provisioning (the big one)

A Luso8 Cloud customer fills in the "Configure Telephony Provider" form. Voxtra auto-generates and deploys their Asterisk config:

```python
from voxtra.provisioning import TenantProvisioner

provisioner = TenantProvisioner(asterisk_ssh="root@pbx.luso8.com")

await provisioner.create_tenant(
    tenant_id="org_acme",
    sip_trunk=SIPTrunk(
        host="sip.carrier.mw",
        username="acme_did",
        password="secret",
        did="+265999001122"
    ),
    ari_app="voxtra_org_acme",         # isolated Stasis app per tenant
    inbound_handler_url="https://acme.voxtra.app/calls",  # webhook
)
# → generates pjsip.conf fragment
# → generates extensions.conf fragment
# → generates ari.conf user
# → reloads Asterisk modules
# → tests ARI connectivity
# → returns connection credentials to Luso8 UI
```

---

## Core API Surface — What Voxtra Must Expose

### `VoxtraApp`

```
VoxtraApp(ari_url, ari_user, ari_password, app_name="voxtra")

.on_call(handler)              → decorator for inbound call handler
.on_event(type, handler)       → decorator for raw ARI events
.originate(to, caller_id, handler)  → make an outbound call
.run()                         → start event loop + ARI WebSocket
.run_async()                   → async version (for embedding in FastAPI, etc.)
.stop()                        → graceful shutdown
```

### `CallSession` (the call handle passed to handlers)

```
call.id                        → unique call ID (= Asterisk channel ID)
call.caller_id                 → calling number
call.called_number             → dialed extension or DID
call.direction                 → "inbound" | "outbound"
call.state                     → "ringing" | "answered" | "ended"
call.metadata                  → dict — store anything you want per call
call.duration                  → seconds since answer

call.answer()                  → answer the call
call.hangup(reason=None)       → hang up
call.hold()                    → put on hold (MOH)
call.unhold()                  → take off hold

call.play_file(filename)       → play Asterisk sound file (e.g. "hello-world")
call.play_url(url)             → play audio from HTTP URL
call.stop_playback()           → stop current playback

call.audio_stream()            → AsyncIterator[AudioChunk] — raw audio in
call.send_audio(chunk)         → send raw audio out
call.open_audio_socket()       → returns (reader, writer) TCP socket (AudioSocket)

call.listen_dtmf(timeout)      → wait for DTMF input, returns digit string
call.send_dtmf(digits)         → send DTMF tones

call.transfer_to(extension)    → blind transfer to dialplan extension
call.transfer_to_queue(queue, metadata=None) → transfer to agent queue
call.bridge_with(other_call)   → bridge two calls together

call.record_start(filename)    → start recording to file
call.record_stop()             → stop recording

call.on_dtmf(handler)          → register DTMF event handler
call.on_hangup(handler)        → register hangup handler
call.on_answered(handler)      → register answered handler
```

### `TenantProvisioner` (SaaS)

```
TenantProvisioner(asterisk_host, ssh_key=None, api_url=None)

.create_tenant(tenant_id, sip_trunk, ...)    → provision new tenant
.update_tenant(tenant_id, ...)               → update tenant config
.delete_tenant(tenant_id)                    → remove tenant from Asterisk
.test_connection(tenant_id)                  → verify ARI + SIP trunk work
.list_tenants()                              → list all provisioned tenants
.get_credentials(tenant_id)                  → return ARI URL/user/pass for UI
```

### `SIPTrunk` config model

```python
SIPTrunk(
    host: str,
    port: int = 5060,
    username: str,
    password: str,
    realm: str = "",           # defaults to host
    did: str = "",             # outbound caller ID
    transport: str = "udp",    # udp | tcp | tls
    codecs: list = ["ulaw"]
)
```

---

## What Voxtra Should NOT Bundle (But Can Offer as Optional Extras)

These belong in separate packages or as thin optional wrappers:

| What | Why Separate |
|---|---|
| Deepgram STT client | Developer might use Whisper, AssemblyAI, Google STT |
| OpenAI LLM client | Developer might use LangGraph, Anthropic, Llama |
| ElevenLabs TTS client | Developer might use Google TTS, Azure, PlayHT |
| Voice pipeline (STT→LLM→TTS) | This is Luso8 Cloud's business logic, not infrastructure |
| VAD (Voice Activity Detection) | Opinionated — developer may want silero, webrtcvad |

These can live in `voxtra[deepgram]`, `voxtra[openai]`, `voxtra[elevenlabs]` as pip extras — **available but not required**.

The core `pip install voxtra` should have zero AI dependencies. Just `httpx`, `websockets`, and `pydantic`.

---

## Audio Transport: AudioSocket over ExternalMedia

The current boilerplate uses Asterisk's `externalMedia` (RTP/UDP). This is overly complex — it requires UDP port management, NAT traversal for media, and codec negotiation.

**Voxtra should use AudioSocket instead.**

`res_audiosocket.so` is already compiled in `luso8-telephony-core`. AudioSocket is a raw TCP socket that carries audio — much simpler:

**Asterisk side** (extensions.conf):
```ini
[from-carrier]
exten = _X.,1,Stasis(${ARI_APP_NAME})
 same = n,Hangup()
```

Voxtra creates the AudioSocket server internally when `call.audio_stream()` or `call.open_audio_socket()` is called, and uses ARI to instruct Asterisk to connect to it. This keeps all audio on a single TCP connection with no NAT issues.

---

## Package Structure Target

```
voxtra/
├── __init__.py           → exposes VoxtraApp, CallSession
├── app.py                → VoxtraApp main class
├── session.py            → CallSession (call handle)
├── events.py             → ARI event types and translation
├── exceptions.py         → VoxtraError, ConnectionError, CallError
├── types.py              → AudioChunk, CallDirection, CallState
│
├── ari/
│   ├── client.py         → ARIClient (HTTP REST + WebSocket)
│   ├── events.py         → raw ARI event parsing
│   └── models.py         → Channel, Bridge, Playback data models
│
├── audio/
│   ├── socket.py         → AudioSocket TCP server
│   ├── chunk.py          → AudioChunk type
│   └── codec.py          → ulaw/alaw/pcm conversion helpers
│
└── provisioning/         → SaaS provisioning (optional, heavy)
    ├── provisioner.py    → TenantProvisioner
    ├── templates/        → Jinja2 config templates
    │   ├── pjsip_trunk.conf.j2
    │   ├── ari_user.conf.j2
    │   └── extensions_tenant.conf.j2
    └── ssh.py            → SSH config deployment helper
```

**Optional extras** (separate install):

```
voxtra-deepgram/          → pip install voxtra[deepgram]
voxtra-openai/            → pip install voxtra[openai]
voxtra-elevenlabs/        → pip install voxtra[elevenlabs]
voxtra-langgraph/         → pip install voxtra[langgraph]
```

---

## What Needs to Be Built in Voxtra (Priority Order)

### P0 — Must Have

| Feature | Description |
|---|---|
| `call.audio_stream()` | AsyncIterator of raw PCM/ulaw audio chunks from caller |
| `call.send_audio(chunk)` | Send audio to caller (from AI TTS or any source) |
| `call.transfer_to_queue(queue, metadata)` | Human handoff with context forwarding |
| `app.originate(to, caller_id, handler)` | Outbound AI dialing |
| `TenantProvisioner.create_tenant()` | Auto-generate pjsip/ari/extensions config for new tenant |
| `TenantProvisioner.test_connection()` | Verify ARI + SIP trunk health |

### P1 — Important

| Feature | Description |
|---|---|
| Multi-app isolation | Each tenant gets `app_name=voxtra_{tenant_id}` in ARI |
| Config templating | Jinja2 templates for all Asterisk config fragments |
| Webhook mode | POST to developer's HTTP endpoint instead of running a persistent server |
| `call.record_start/stop()` | Call recording to file or S3 |
| Reconnection logic | Auto-reconnect ARI WebSocket on disconnect |

### P2 — Nice to Have

| Feature | Description |
|---|---|
| Outbound WebSocket ARI | Asterisk initiates connection to Voxtra (no open port needed) |
| SDK for Luso8 Cloud UI | Python client for Luso8 provisioning API |
| Metrics / events webhook | Per-call events (start, end, transfer, DTMF) to developer webhook |
| `voxtra CLI` | `voxtra start`, `voxtra provision tenant.yaml`, `voxtra test-connection` |

---

## How Luso8 Cloud Uses Voxtra

Luso8 Cloud is the **SaaS platform**. It uses voxtra as its internal telephony SDK. When a customer fills in the "Configure Telephony Provider" form:

```
Customer fills Luso8 UI form:
  ARI URL     = http://pbx.example.com:8088
  ARI User    = asterisk
  ARI Pass    = secret
  SIP Domain  = pbx.example.com
  Context     = from-carrier
  Caller ID   = +265999001122
        ↓
Luso8 Cloud Backend calls:
  await voxtra_provisioner.create_tenant(
      tenant_id=org.id,
      ari_url=form.ari_url,
      ari_user=form.ari_user,
      ari_pass=form.ari_pass,
      ...
  )
        ↓
Voxtra TenantProvisioner:
  1. Tests ARI connectivity
  2. Creates isolated ARI app name: voxtra_{tenant_id}
  3. Pushes pjsip.conf fragment for their SIP trunk
  4. Pushes extensions.conf fragment routing to Stasis(voxtra_{tenant_id})
  5. Reloads Asterisk: "module reload res_pjsip.so"
  6. Returns: { ari_app: "voxtra_org123", ws_url: "ws://..." }
        ↓
Luso8 Cloud starts a Voxtra listener for this tenant:
  app = VoxtraApp(ari_url=..., app_name="voxtra_org123")
  app.on_call(org.voice_agent_handler)
  await app.run_async()
```

This is the entire SaaS integration model. Each organization is isolated by their `app_name` — Asterisk only sends events for their calls to their Voxtra instance.
