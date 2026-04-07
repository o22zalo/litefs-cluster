FROM ubuntu:22.04

ARG CONSUL_VERSION=1.17.1
ARG LITEFS_VERSION=0.5.11

ENV DEBIAN_FRONTEND=noninteractive

# ── Base packages ─────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y \
    curl wget jq sqlite3 fuse3 ca-certificates awscli \
    iproute2 iptables net-tools unzip gnupg \
    && rm -rf /var/lib/apt/lists/*

# ── Tailscale ─────────────────────────────────────────────────────────────────
# Dùng repo chính thức, tránh dùng install.sh (có thể thay đổi)
RUN curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.noarmor.gpg \
      | tee /usr/share/keyrings/tailscale-archive-keyring.gpg > /dev/null \
    && curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.tailscale-keyring.list \
      | tee /etc/apt/sources.list.d/tailscale.list \
    && apt-get update && apt-get install -y tailscale \
    && rm -rf /var/lib/apt/lists/* \
    && tailscale version

# ── Consul ────────────────────────────────────────────────────────────────────
RUN wget -qO /tmp/consul.zip \
      "https://releases.hashicorp.com/consul/${CONSUL_VERSION}/consul_${CONSUL_VERSION}_linux_amd64.zip" \
    && unzip /tmp/consul.zip -d /usr/local/bin/ \
    && rm /tmp/consul.zip \
    && chmod +x /usr/local/bin/consul \
    && consul version

# ── LiteFS ────────────────────────────────────────────────────────────────────
RUN wget -qO /tmp/litefs.tar.gz \
      "https://github.com/superfly/litefs/releases/download/v${LITEFS_VERSION}/litefs-v${LITEFS_VERSION}-linux-amd64.tar.gz" \
    && tar xzf /tmp/litefs.tar.gz -C /usr/local/bin/ litefs \
    && rm /tmp/litefs.tar.gz \
    && chmod +x /usr/local/bin/litefs \
    && litefs version

# ── Directories ───────────────────────────────────────────────────────────────
RUN mkdir -p \
    /data/litefs \
    /mnt/litefs \
    /var/lib/consul \
    /var/lib/tailscale \
    /etc/consul.d \
    /var/log

# ── FUSE: cho phép user khác đọc mount ───────────────────────────────────────
# Cần thiết cho litefs allow-other: true
RUN echo "user_allow_other" >> /etc/fuse.conf

# ── Configs ───────────────────────────────────────────────────────────────────
COPY docker/config/consul.hcl  /etc/consul.d/consul.hcl
COPY docker/config/litefs.yml  /etc/litefs.yml

# ── Scripts ───────────────────────────────────────────────────────────────────
COPY docker/scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/scripts/bootstrap.sh  /usr/local/bin/bootstrap.sh
COPY docker/scripts/run-app.sh    /usr/local/bin/run-app.sh
COPY docker/scripts/verify.sh     /usr/local/bin/verify.sh
COPY docker/scripts/backup.sh     /usr/local/bin/backup.sh

RUN chmod +x \
    /usr/local/bin/entrypoint.sh \
    /usr/local/bin/bootstrap.sh \
    /usr/local/bin/run-app.sh \
    /usr/local/bin/verify.sh \
    /usr/local/bin/backup.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
