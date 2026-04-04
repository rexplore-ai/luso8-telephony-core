# Configuration Reference

All Asterisk configuration lives in `/etc/asterisk/`. This document covers every file you need to touch for a working Luso8 deployment, with every variable explained.

---

## Environment Variables

When running via Docker (recommended for SaaS), all secrets are injected as environment variables. The `entrypoint.sh` script substitutes them into config templates using `envsubst`.

### Required Variables

| Variable | Example | Description |
|---|---|---|
| `ARI_USERNAME` | `asterisk` | ARI user — must match `[section]` name in `ari.conf` |
| `ARI_PASSWORD` | `Str0ngP@ssw0rd` | ARI password. Use 20+ char random string in production |
| `SIP_DOMAIN` | `pbx.luso8.com` | Your Asterisk server FQDN or public IP |
| `EXTERNAL_IP` | `203.0.113.10` | Public IP of your server (for NAT traversal) |
| `DEFAULT_CONTEXT` | `from-carrier` | Dialplan context inbound calls land in |
| `OUTBOUND_CALLER_ID` | `+265123456789` | Default caller ID for outbound calls |

### SIP Trunk Variables (one set per trunk)

| Variable | Example | Description |
|---|---|---|
| `SIP_TRUNK_HOST` | `sip.carrier.mw` | Your carrier's SIP server hostname |
| `SIP_TRUNK_PORT` | `5060` | SIP port (default 5060) |
| `SIP_TRUNK_USER` | `myaccount` | SIP registration username |
| `SIP_TRUNK_PASS` | `trunksecret` | SIP registration password |
| `SIP_TRUNK_REALM` | `sip.carrier.mw` | SIP auth realm (usually same as host) |

### Optional Variables

| Variable | Default | Description |
|---|---|---|
| `ARI_BIND_ADDR` | `0.0.0.0` | IP to bind the ARI HTTP server to |
| `ARI_PORT` | `8088` | ARI HTTP port |
| `ARI_APP_NAME` | `voxtra` | Stasis application name — must match voxtra config |
| `RTP_PORT_START` | `10000` | First RTP media port |
| `RTP_PORT_END` | `20000` | Last RTP media port (allows N/2 concurrent calls) |
| `LOG_LEVEL` | `notice` | Asterisk log level: `debug`, `verbose`, `notice`, `warning`, `error` |
| `MAX_CHANNELS` | `200` | Max simultaneous calls |
| `LOCAL_NET` | `10.0.0.0/8` | Internal network range (for NAT bypass) |

---

## Config File Reference

### `http.conf` — ARI HTTP Server

The ARI REST API and WebSocket run on Asterisk's built-in HTTP server.

```ini
; /etc/asterisk/http.conf

[general]
enabled = yes
bindaddr = ${ARI_BIND_ADDR}   ; Use 0.0.0.0 to accept from all IPs
                               ; RESTRICT to internal IP in production
bindport = ${ARI_PORT}         ; Default 8088
;prefix = asterisk             ; Optional URL prefix

; TLS (strongly recommended in production)
;tlsenable = yes
;tlsbindaddr = 0.0.0.0:8089
;tlscertfile = /etc/asterisk/keys/asterisk.pem
;tlsprivatekey = /etc/asterisk/keys/asterisk.key
```

**Security**: In production, bind ARI to an internal/private IP only. Voxtra should connect over a VPC or VPN, not over the public internet without TLS.

---

### `ari.conf` — Asterisk REST Interface

Defines which users can authenticate to the ARI.

```ini
; /etc/asterisk/ari.conf

[general]
enabled = yes
pretty = no                   ; Set to yes for human-readable JSON (dev only)
allowed_origins = *           ; CORS — restrict to your domain in production
; allowed_origins = https://luso8.com,https://app.luso8.com

; Display channel variables in every event (performance cost — use sparingly)
;channelvars = CALLERID(num),CALLERID(name)

; ---- ARI User ----
; Section name = ARI username (used in Luso8 UI "ARI Username" field)
[${ARI_USERNAME}]
type = user
password = ${ARI_PASSWORD}
password_format = plain

; Read-only user for monitoring/dashboards
;[monitor]
;type = user
;read_only = yes
;password = monitorpass
;password_format = plain
```

---

### `pjsip.conf` — SIP Stack

The most important file. Defines transports, SIP trunk registrations, and endpoints.

```ini
; /etc/asterisk/pjsip.conf

;=============================================================================
; TRANSPORTS
;=============================================================================

[transport-udp]
type = transport
protocol = udp
bind = 0.0.0.0:5060

; NAT traversal — required when Asterisk is behind a NAT (VPS, GCE, etc.)
local_net = ${LOCAL_NET}
external_media_address = ${EXTERNAL_IP}
external_signaling_address = ${EXTERNAL_IP}

; TLS transport (recommended for production)
;[transport-tls]
;type = transport
;protocol = tls
;bind = 0.0.0.0:5061
;cert_file = /etc/asterisk/keys/asterisk.pem
;priv_key_file = /etc/asterisk/keys/asterisk.key
;method = tlsv1_2

;=============================================================================
; SIP TRUNK — YOUR CARRIER (e.g., local Malawi carrier)
;=============================================================================

; Outbound registration to carrier
[trunk-registration]
type = registration
outbound_auth = trunk-auth
server_uri = sip:${SIP_TRUNK_HOST}:${SIP_TRUNK_PORT}
client_uri = sip:${SIP_TRUNK_USER}@${SIP_TRUNK_HOST}
retry_interval = 60
expiration = 3600
line = yes
endpoint = trunk-endpoint

; Trunk authentication
[trunk-auth]
type = auth
auth_type = userpass
username = ${SIP_TRUNK_USER}
password = ${SIP_TRUNK_PASS}
realm = ${SIP_TRUNK_REALM}

; Trunk endpoint — handles both inbound and outbound calls
[trunk-endpoint]
type = endpoint
context = ${DEFAULT_CONTEXT}     ; Inbound calls land here
allow = !all,ulaw,alaw,g722      ; Allowed codecs (ulaw = standard in Africa/US)
outbound_auth = trunk-auth
aors = trunk-aor
direct_media = no                ; Always proxy media through Asterisk
from_domain = ${SIP_TRUNK_HOST}
from_user = ${SIP_TRUNK_USER}
trust_id_inbound = yes           ; Trust caller ID from carrier

; Trunk address of record
[trunk-aor]
type = aor
contact = sip:${SIP_TRUNK_HOST}:${SIP_TRUNK_PORT}
qualify_frequency = 30           ; Send OPTIONS ping every 30s to check trunk health

; Identify inbound calls from this carrier by IP
[trunk-identify]
type = identify
endpoint = trunk-endpoint
match = ${SIP_TRUNK_HOST}

;=============================================================================
; AI VOICE AGENT ENDPOINT
; This is a virtual SIP endpoint that Voxtra uses for outbound AI calls
;=============================================================================

[ai-agent-template](!)
type = endpoint
context = from-ai-agent
allow = !all,ulaw
direct_media = no
rtp_symmetric = yes
force_rport = yes
rewrite_contact = yes

; The Voxtra application registers as a SIP UA for outbound calls
[voxtra-ua](ai-agent-template)
auth = voxtra-ua-auth
aors = voxtra-ua-aor
callerid = AI Agent <${OUTBOUND_CALLER_ID}>

[voxtra-ua-auth]
type = auth
auth_type = userpass
username = voxtra
password = ${ARI_PASSWORD}    ; Reuse ARI password or set a separate one

[voxtra-ua-aor]
type = aor
max_contacts = 10             ; Allow multiple concurrent Voxtra instances

;=============================================================================
; INTERNAL HUMAN AGENTS (softphones / desk phones)
; Add one block per agent. In SaaS, these are auto-generated per tenant.
;=============================================================================

;[agent-1001]
;type = endpoint
;context = from-internal
;allow = !all,ulaw,g722
;auth = agent-1001-auth
;aors = agent-1001-aor
;callerid = Agent Name <1001>
;direct_media = no

;[agent-1001-auth]
;type = auth
;auth_type = userpass
;username = 1001
;password = agentpassword

;[agent-1001-aor]
;type = aor
;max_contacts = 1
;mailboxes = 1001@default
```

---

### `extensions.conf` — Dialplan

Controls what happens to calls at each stage. For Luso8, the core rule is simple: route everything into Voxtra via `Stasis()`.

```ini
; /etc/asterisk/extensions.conf

;=============================================================================
; INBOUND FROM CARRIER
; All calls from the SIP trunk land here first.
;=============================================================================
[from-carrier]
exten = _X.,1,NoOp(Inbound call: ${CALLERID(num)} → ${EXTEN})
 same = n,Set(CALL_DIRECTION=inbound)
 same = n,Set(TENANT_ID=${CUT(EXTEN,@,2)})  ; extract tenant from SIP URI if multi-tenant
 same = n,Stasis(${ARI_APP_NAME})            ; hand off to Voxtra
 same = n,Hangup()

; Handle calls that Voxtra rejects or errors out
exten = failed,1,NoOp(Voxtra rejected call)
 same = n,Playback(sorry-cant-take-call)
 same = n,Hangup()

;=============================================================================
; OUTBOUND AI CALLS (Voxtra originates these)
; Voxtra uses ARI originate to create outbound calls.
;=============================================================================
[from-ai-agent]
exten = _X.,1,Set(CALL_DIRECTION=outbound)
 same = n,Dial(PJSIP/${EXTEN}@trunk-endpoint,,rU(${OUTBOUND_CALLER_ID}))
 same = n,Hangup()

;=============================================================================
; HUMAN AGENT QUEUE (AI hands off to human when needed)
; Voxtra calls session.transfer_to_queue("support") → lands here
;=============================================================================
[agent-queues]
exten = support,1,NoOp(Transferring to support queue)
 same = n,Queue(support,,,,300)    ; 300s queue timeout
 same = n,Playback(all-agents-busy)
 same = n,Hangup()

exten = sales,1,NoOp(Transferring to sales queue)
 same = n,Queue(sales,,,,300)
 same = n,Hangup()

;=============================================================================
; INTERNAL CALLS (human agent to human agent)
;=============================================================================
[from-internal]
exten = _1XXX,1,Dial(PJSIP/${EXTEN},,rU(${CALLERID(num)}))
 same = n,Hangup()

; Dial into a queue directly from internal
exten = 2000,1,Queue(support)
 same = n,Hangup()

;=============================================================================
; HOLD / PARK CONTEXT
;=============================================================================
[parked-calls]
exten = _700X,1,ParkedCall(${EXTEN})
```

---

### `queues.conf` — Call Queues

Defines the human agent queues that AI hands off to.

```ini
; /etc/asterisk/queues.conf

[general]
persistmembers = yes          ; Remember queue members across restarts
monitor-type = MixMonitor     ; Call recording type
log-membername = yes

;=============================================================================
; SUPPORT QUEUE
;=============================================================================
[support]
strategy = ringall            ; Ring all available agents simultaneously
; strategy = leastrecent      ; Ring agent who answered least recently (recommended)
timeout = 30                  ; Ring each agent for 30s before moving to next
retry = 5                     ; Wait 5s between retries
maxlen = 50                   ; Max callers waiting
announce-frequency = 60       ; Tell caller their position every 60s
announce-holdtime = yes
announce-position = yes
music = default               ; Hold music class
joinempty = yes               ; Allow callers to join even with no agents
leavewhenempty = no           ; Don't kick callers if agents log out
reportholdtime = yes
memberdelay = 0
weight = 0

;=============================================================================
; SALES QUEUE
;=============================================================================
[sales]
strategy = leastrecent
timeout = 30
retry = 5
maxlen = 50
music = default
joinempty = yes
```

---

### `rtp.conf` — RTP Media Ports

```ini
; /etc/asterisk/rtp.conf

[general]
rtpstart = ${RTP_PORT_START}  ; Default 10000
rtpend = ${RTP_PORT_END}      ; Default 20000
; Each call uses 2 ports (1 RTP + 1 RTCP)
; Port range of 10000 = max 5000 concurrent calls

; DTLS-SRTP for WebRTC endpoints
;dtlsenable = yes
;dtlsverify = no
;dtlscertfile = /etc/asterisk/keys/asterisk.pem
;dtlsprivatekey = /etc/asterisk/keys/asterisk.key
;dtlssetup = actpass
```

---

### `logger.conf` — Logging

```ini
; /etc/asterisk/logger.conf

[general]
; Rotate logs daily
rotatestrategy = rotate
; Keep 30 days of logs
exec_after_rotate = gzip -9 ${filename}.2

[logfiles]
; Console output
console = ${LOG_LEVEL},notice,warning,error

; Main log file
messages = notice,warning,error,verbose(3)

; Security events (authentication failures, etc.)
security = security

; Full verbose for debugging (disable in production — large files)
;debug = debug,verbose,notice,warning,error,dtmf
```

---

### `modules.conf` — Module Loading

Only load what you need for performance. For the Luso8 AI call center setup:

```ini
; /etc/asterisk/modules.conf

[modules]
autoload = yes

; Modules explicitly required for Luso8 + Voxtra
load = res_ari.so             ; ARI core
load = res_ari_channels.so    ; ARI channel operations
load = res_ari_bridges.so     ; ARI bridge operations
load = res_ari_applications.so
load = res_ari_events.so
load = res_ari_recordings.so
load = res_ari_playbacks.so
load = res_stasis.so          ; Stasis (ARI app framework)
load = res_stasis_answer.so
load = res_stasis_playback.so
load = res_stasis_recording.so
load = res_stasis_snoop.so
load = res_pjsip.so           ; PJSIP SIP stack
load = res_pjsip_session.so
load = res_pjsip_outbound_registration.so
load = res_pjsip_authenticator_digest.so
load = res_pjsip_endpoint_identifier_user.so
load = res_pjsip_endpoint_identifier_ip.so
load = res_http_websocket.so  ; WebSocket support for ARI
load = res_audiosocket.so     ; AudioSocket for direct audio I/O (used by Voxtra)
load = app_queue.so           ; Call queues (human agent handoff)
load = app_dial.so            ; Dial application
load = app_playback.so        ; Audio playback
load = app_record.so          ; Call recording
load = app_stasis.so          ; Stasis dialplan app
load = res_rtp_asterisk.so    ; RTP media
load = res_srtp.so            ; SRTP encryption
load = res_musiconhold.so     ; Hold music
load = codec_ulaw.so          ; ulaw/PCMU codec
load = codec_alaw.so          ; alaw/PCMA codec
load = codec_g722.so          ; G.722 wideband

; Disable modules not needed (reduces attack surface + memory)
noload = chan_iax2.so
noload = chan_mgcp.so
noload = chan_skinny.so
noload = chan_unistim.so
noload = res_xmpp.so
noload = res_fax.so
```

---

## Complete Environment Variable Template

Copy this to a `.env` file (never commit to Git):

```bash
# .env — Asterisk configuration
# Copy to server, never commit to version control

#------------------------------------------------------------
# ARI (Asterisk REST Interface)
#------------------------------------------------------------
ARI_USERNAME=asterisk
ARI_PASSWORD=CHANGE_ME_USE_STRONG_RANDOM_PASSWORD_32_CHARS
ARI_PORT=8088
ARI_BIND_ADDR=0.0.0.0
ARI_APP_NAME=voxtra

#------------------------------------------------------------
# Network / NAT
#------------------------------------------------------------
SIP_DOMAIN=pbx.yourdomain.com
EXTERNAL_IP=YOUR_SERVER_PUBLIC_IP
LOCAL_NET=10.0.0.0/8

#------------------------------------------------------------
# SIP Trunk (from your local carrier)
#------------------------------------------------------------
SIP_TRUNK_HOST=sip.carrier.com
SIP_TRUNK_PORT=5060
SIP_TRUNK_USER=your_account_id
SIP_TRUNK_PASS=your_trunk_password
SIP_TRUNK_REALM=sip.carrier.com

#------------------------------------------------------------
# Call Routing
#------------------------------------------------------------
DEFAULT_CONTEXT=from-carrier
OUTBOUND_CALLER_ID=+265XXXXXXXXX

#------------------------------------------------------------
# Media
#------------------------------------------------------------
RTP_PORT_START=10000
RTP_PORT_END=20000

#------------------------------------------------------------
# Logging
#------------------------------------------------------------
LOG_LEVEL=notice
```

---

## What Needs to Be Done Before Go-Live

| # | Task | Who | Status |
|---|---|---|---|
| 1 | Create `configs/luso8/` directory with template `.conf` files using `${VAR}` placeholders | Dev | TODO |
| 2 | Create `docker/entrypoint.sh` with `envsubst` config generation | Dev | TODO |
| 3 | Create `Dockerfile` in `docker/` directory | Dev | TODO |
| 4 | Get SIP trunk credentials from local carrier (e.g., Malawi carrier) | Business | TODO |
| 5 | Reserve static IP on GCE or VPS | DevOps | TODO |
| 6 | Configure UFW/GCE firewall rules (SIP:5060 UDP, RTP:10000-20000 UDP, ARI:8088 TCP) | DevOps | TODO |
| 7 | Set `external_media_address` + `external_signaling_address` to server public IP | Dev | TODO |
| 8 | Test ARI connectivity: `curl -u asterisk:PASS http://SERVER:8088/ari/asterisk/info` | Dev | TODO |
| 9 | Register Asterisk in Luso8 UI (Screenshot 2 form fields) | Product | TODO |
| 10 | Point Voxtra at ARI URL and test end-to-end call | Dev | TODO |
