#!/bin/bash
# entrypoint.sh — Điểm vào chính của container
# Thứ tự: tailscaled → tailscale up → bootstrap.sh (consul) → litefs mount
set -euo pipefail

LOG_P="[ENTRY]"
log() { echo "$LOG_P [$(date '+%H:%M:%S')] $*"; }

CLEANING=false
cleanup() {
    $CLEANING && return
    CLEANING=true
    log "═══ GRACEFUL SHUTDOWN ═══"

    if consul members &>/dev/null 2>&1; then
        log "Leaving Consul cluster..."
        consul leave 2>/dev/null || true
        sleep 2
    fi

    local pids
    pids=$(jobs -p 2>/dev/null || true)
    [ -n "$pids" ] && echo "$pids" | xargs -r kill 2>/dev/null || true

    log "═══ SHUTDOWN DONE ═══"
}
trap cleanup SIGTERM SIGINT EXIT

log "Setting up TUN device..."
mkdir -p /dev/net
if [ ! -c /dev/net/tun ]; then
    mknod /dev/net/tun c 10 200
    chmod 0666 /dev/net/tun
    log "  Created /dev/net/tun"
else
    log "  /dev/net/tun already exists"
fi

log "Starting tailscaled..."
mkdir -p /var/lib/tailscale

tailscaled \
    --state=/var/lib/tailscale/tailscaled.state \
    --socket=/var/run/tailscale/tailscaled.sock \
    >> /var/log/tailscaled.log 2>&1 &

TAILSCALED_PID=$!
log "tailscaled PID: $TAILSCALED_PID"

mkdir -p /var/run/tailscale
sock_wait=0
while [ $sock_wait -lt 15 ] && [ ! -S /var/run/tailscale/tailscaled.sock ]; do
    sleep 1
    sock_wait=$((sock_wait + 1))
done

log "Authenticating Tailscale (hostname: ${NODE_NAME:-litefs-$(hostname | cut -c1-8)})..."
tailscale up \
    --authkey="${TS_AUTHKEY}" \
    --advertise-tags="${TS_TAGS:-tag:litefs-node}" \
    --hostname="${NODE_NAME:-litefs-$(hostname | cut -c1-8)}" \
    --accept-routes \
    --accept-dns=false \
    2>&1 | tee -a /var/log/tailscaled.log

log "✓ Tailscale authenticated"
tailscale status 2>/dev/null | head -5 || true

/usr/local/bin/bootstrap.sh

MY_IP=$(tailscale ip -4 2>/dev/null) || { log "ERROR: No Tailscale IP"; exit 1; }
export LITEFS_ADVERTISE_URL="$MY_IP"
log "LiteFS will advertise at: http://$MY_IP:20202"

# Backup loop (optional): chỉ hoạt động khi BACKUP_ENABLED=true.
if [ "${BACKUP_ENABLED:-false}" = "true" ]; then
    log "Starting backup loop in background..."
    /usr/local/bin/backup.sh >> /var/log/backup.log 2>&1 &
fi

log "Starting LiteFS (this will block until run-app.sh exits)..."
log "═══════════════════════════════════════════"

sed "s|\${LITEFS_ADVERTISE_URL}|${LITEFS_ADVERTISE_URL}|g" \
    /etc/litefs.yml > /tmp/litefs-rendered.yml
exec litefs mount -config /tmp/litefs-rendered.yml
