#!/bin/bash
# run-app.sh — Chạy bởi LiteFS sau khi FUSE mount xong
#   - Primary: ghi heartbeat vào SQLite
#   - Replica: chỉ đọc và verify replication
set -u

LOG_P="[APP]"
DB="${APP_DB_PATH:-/mnt/litefs/cluster.db}"
ROLE_LOG_LEVEL="${ROLE_LOG_LEVEL:-info}" # info|debug
PRIMARY_STABLE_ROUNDS="${PRIMARY_STABLE_ROUNDS:-3}"
PRIMARY_STABLE_INTERVAL="${PRIMARY_STABLE_INTERVAL:-2}"

log()   { echo "$LOG_P [$(date '+%H:%M:%S')] $*"; }
debug() { [ "$ROLE_LOG_LEVEL" = "debug" ] && echo "$LOG_P [DEBUG] $*" || true; }

MY_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
MY_NODE=${NODE_NAME:-$(hostname | cut -c1-12)}

log "═══════════════════════════════════════════"
log "  App started"
log "  Node : $MY_NODE"
log "  IP   : $MY_IP"
log "  DB   : $DB"
log "═══════════════════════════════════════════"

primary_advertise_url() {
    consul kv get litefs/primary 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('advertise-url',''))" 2>/dev/null \
      || true
}

is_primary() {
    local kv
    kv=$(consul kv get litefs/primary 2>/dev/null || true)
    echo "$kv" | grep -q "$MY_IP"
}

wait_db() {
    log "Waiting for database to be accessible..."
    local i=0
    while [ "$i" -lt 60 ]; do
        if sqlite3 "$DB" "SELECT 1;" &>/dev/null 2>&1; then
            log "✓ DB accessible"
            return 0
        fi
        sleep 2
        i=$((i + 1))
    done
    log "⚠ DB not accessible after 120s (sync pending or first bootstrap)"
    return 1
}

wait_primary_stable() {
    log "Waiting for primary leader to stabilize (${PRIMARY_STABLE_ROUNDS} rounds)..."
    local prev=""
    local stable=0
    local i=0

    while [ "$i" -lt 90 ]; do
        local cur
        cur=$(primary_advertise_url)

        if [ -n "$cur" ] && [ "$cur" = "$prev" ]; then
            stable=$((stable + 1))
        elif [ -n "$cur" ]; then
            prev="$cur"
            stable=1
        else
            stable=0
        fi

        if [ "$stable" -ge "$PRIMARY_STABLE_ROUNDS" ]; then
            log "✓ Primary stabilized at: $cur"
            return 0
        fi

        sleep "$PRIMARY_STABLE_INTERVAL"
        i=$((i + 1))
    done

    log "⚠ Primary not stabilized in time; continue with best effort"
    return 1
}

init_db() {
    log "Initializing DB schema (PRIMARY)..."
    sqlite3 "$DB" <<'SQL'
CREATE TABLE IF NOT EXISTS cluster_nodes (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    node_ip   TEXT    NOT NULL UNIQUE,
    node_name TEXT    NOT NULL,
    role      TEXT    NOT NULL DEFAULT 'member',
    joined_at TEXT    DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS heartbeats (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    node_ip   TEXT    NOT NULL,
    node_name TEXT    NOT NULL,
    message   TEXT    NOT NULL,
    ts        TEXT    DEFAULT (datetime('now'))
);
SQL
    log "✓ Schema ready"
}

register_node() {
    local role="$1"
    sqlite3 "$DB" \
        "INSERT OR REPLACE INTO cluster_nodes(node_ip, node_name, role, joined_at)
         VALUES('$MY_IP', '$MY_NODE', '$role', datetime('now'));" \
        >/dev/null 2>&1
    log "✓ Registered as $role"
}

main() {
    sleep 5
    wait_db || true
    wait_primary_stable || true

    if is_primary; then
        log "★ I am LiteFS PRIMARY"
        init_db
        register_node "primary"
    else
        log "→ I am LiteFS REPLICA"
        debug "Replica mode: skip register_node to avoid noisy write errors"
    fi

    local tick=0
    while true; do
        tick=$((tick + 1))
        sleep 30

        if is_primary; then
            if sqlite3 "$DB" \
                "INSERT INTO heartbeats(node_ip, node_name, message)
                 VALUES('$MY_IP', '$MY_NODE', 'tick-$tick @ $(date -u +%T)');" \
                >/dev/null 2>&1; then
                log "♥ [PRIMARY] wrote tick #$tick"
            else
                log "⚠ [PRIMARY] write failed tick #$tick (possibly leader transition)"
            fi
        else
            local cnt
            cnt=$(sqlite3 "$DB" "SELECT COUNT(*) FROM heartbeats;" 2>/dev/null || echo "?")
            local p
            p=$(primary_advertise_url)
            log "♥ [REPLICA] tick #$tick | DB heartbeats: $cnt | Primary: ${p:-?}"
        fi
    done
}

main "$@"
