FROM ubuntu:22.04

LABEL maintainer="Rexplore Research Labs <hello@rexplore.ai>"
LABEL description="Luso8 Telephony Core — Asterisk PBX for AI Call Centers"

ENV DEBIAN_FRONTEND=noninteractive
ENV ASTERISK_USER=asterisk

# ---- System dependencies ----
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libssl-dev \
    libncurses5-dev \
    libnewt-dev \
    libxml2-dev \
    libsqlite3-dev \
    uuid-dev \
    libjansson-dev \
    libxslt1-dev \
    libcurl4-openssl-dev \
    libedit-dev \
    libsrtp2-dev \
    gettext-base \
    wget \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*

# ---- Create asterisk user ----
RUN useradd -r -d /var/lib/asterisk -s /sbin/nologin asterisk

# ---- Copy source and build ----
WORKDIR /usr/src/asterisk
COPY . .

RUN ./configure --with-jansson-bundled --with-ssl=ssl \
    && make -j$(nproc) \
    && make install \
    && make samples \
    && ldconfig

# ---- Create runtime directories ----
RUN mkdir -p \
    /etc/asterisk/pjsip.d \
    /etc/asterisk/extensions.d \
    /etc/asterisk/ari.d \
    /var/log/asterisk \
    /var/run/asterisk \
    /var/spool/asterisk/tmp \
    /var/spool/asterisk/outgoing \
    /var/spool/asterisk/recording \
    /var/lib/asterisk

# ---- Copy Luso8 config templates ----
COPY configs/luso8/asterisk.conf    /etc/asterisk/asterisk.conf
COPY configs/luso8/http.conf        /etc/asterisk/http.conf.tmpl
COPY configs/luso8/ari.conf         /etc/asterisk/ari.conf.tmpl
COPY configs/luso8/pjsip.conf       /etc/asterisk/pjsip.conf.tmpl
COPY configs/luso8/extensions.conf  /etc/asterisk/extensions.conf.tmpl
COPY configs/luso8/queues.conf      /etc/asterisk/queues.conf
COPY configs/luso8/rtp.conf         /etc/asterisk/rtp.conf.tmpl
COPY configs/luso8/logger.conf      /etc/asterisk/logger.conf.tmpl
COPY configs/luso8/modules.conf     /etc/asterisk/modules.conf

# ---- Set ownership ----
RUN chown -R asterisk:asterisk \
    /etc/asterisk \
    /var/lib/asterisk \
    /var/log/asterisk \
    /var/run/asterisk \
    /var/spool/asterisk

# ---- Operational scripts ----
RUN mkdir -p /opt/luso8/scripts
COPY scripts/pull-secrets.sh   /opt/luso8/scripts/pull-secrets.sh
COPY scripts/health-check.sh   /opt/luso8/scripts/health-check.sh
COPY scripts/reload-config.sh  /opt/luso8/scripts/reload-config.sh
COPY scripts/rollback.sh       /opt/luso8/scripts/rollback.sh
COPY scripts/sync-recordings.sh /opt/luso8/scripts/sync-recordings.sh
RUN chmod +x /opt/luso8/scripts/*.sh

# ---- Entrypoint ----
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# ---- Ports ----
# SIP signaling
EXPOSE 5060/udp
EXPOSE 5060/tcp
EXPOSE 5061/tcp

# ARI HTTP + WebSocket
EXPOSE 8088/tcp
EXPOSE 8089/tcp

# RTP media — NOTE: Docker -p 10000-10100:10000-10100/udp when running
# Use --network=host for production to avoid Docker NAT on RTP
EXPOSE 10000-10100/udp

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD curl -sf -u "${ARI_USERNAME}:${ARI_PASSWORD}" \
        http://localhost:${ARI_PORT}/ari/asterisk/info > /dev/null || exit 1

ENTRYPOINT ["/entrypoint.sh"]
