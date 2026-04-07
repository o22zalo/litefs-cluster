#!/bin/bash
# bootstrap.sh — Khởi động Consul dựa trên trạng thái cluster hiện tại
# Logic: nếu có peer đang chạy Consul → join; nếu không → tự bootstrap làm leader
set -euo pipefail

TS_TAG="${TS_TAG:-tag:litefs-node}"
CONSUL_HTTP="http://127.0.0.1:8500"
LOG_P="[BOOTSTRAP]"

log()  { echo "$LOG_P [$(date '+%H:%M:%S')] $*"; }
info() { echo "$LOG_P [INFO]  $*" >&2; }
err()  { echo "$LOG_P [ERROR] $*" >&2; }

# ── 1. Chờ Tailscale có IP ────────────────────────────────────────────────────
wait_tailscale() {
    log "Waiting for Tailscale IP..."
    local tries=0
    while [ $tries -lt 60 ]; do
        MY_IP=$(tailscale ip -4 2>/dev/null || true)
        if [[ "$MY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            log "✓ Tailscale IP: $MY_IP"
            export MY_IP
            return 0
        fi
        sleep 2
        tries=$((tries + 1))
    done
    err "Tailscale did not get IP after 120s"
    exit 1
}

# ── 2. Lấy danh sách peers online cùng tag ────────────────────────────────────
# Pitfall: .Peer là object (map), không phải array → dùng to_entries
# Pitfall: Tags có thể null → dùng (.Tags // [])
get_peers() {
    tailscale status --json 2>/dev/null | jq -r '
        (.Peer // {}) | to_entries[] | .value
        | select((.Tags // []) | arrays | any(. == "'"$TS_TAG"'"))
        | select(.Online == true)
        | (.TailscaleIPs // [])[0]
    ' 2>/dev/null | grep -Ev '^(null|)$' || true
}

# ── 3. Kiểm tra Consul có đang chạy trên 1 IP không ──────────────────────────
# Pitfall: Leader trả về "" (empty string) khi chưa elect xong
# → Cần check response là quoted IP, không phải empty/null
consul_alive_on() {
    local ip="$1"
    local resp
    resp=$(curl -sf --connect-timeout 3 --max-time 5 \
        "http://$ip:8500/v1/status/leader" 2>/dev/null || true)
    # Response hợp lệ: "100.x.x.x:8300" (có dấu ngoặc kép, có chấm, có colon)
    [[ "$resp" =~ ^\"[0-9]+\.[0-9]+ ]]
}

# ── 4. Tìm peer có Consul đang chạy ──────────────────────────────────────────
# Chờ có ít nhất 1 peer online trước khi start Consul
wait_for_peers() {
    log "Waiting for at least 1 peer online..."
    local i=0
    while [ $i -lt 60 ]; do
        local peers
        peers=$(get_peers)
        if [ -n "$peers" ]; then
            log "✓ Found peers: $(echo $peers | tr '\n' ' ')"
            echo "$peers"
            return 0
        fi
        sleep 5
        i=$((i + 1))
    done
    log "No peers found after 300s — will bootstrap alone with expect=2"
    return 1
}

# ── 5. Start Consul ───────────────────────────────────────────────────────────
start_consul_old() {
    local my_ip="$1"
    local mode="$2"      # "leader" | "follower"
    local peer="${3:-}"  # required nếu follower

    local flags=()

    if [ "$mode" = "leader" ]; then
        log "★  Starting as LEADER (bootstrap)"
        # -bootstrap: self-elect ngay, không cần peer vote
        # Pitfall: KHÔNG dùng -bootstrap-expect cùng lúc với -bootstrap
        # Thay vì:
        # flags+=("-bootstrap")

        # Dùng:
        flags+=(
            "-bootstrap-expect=3"
            "-retry-join=$(get_peers | head -1 || echo '127.0.0.1')"
            "-retry-interval=10s"
            "-retry-max=30"
        )
    else
        log "→  Starting as FOLLOWER, joining: $peer"
        # retry-join tự động thử lại nếu peer chưa sẵn sàng
        flags+=(
            "-retry-join=$peer"
            "-retry-interval=5s"
            "-retry-max=20"
        )
    fi

    # Pitfall: node name phải unique trong cluster
    # Dùng hostname (Docker container ID prefix, đã unique)
    local node_name="litefs-$(hostname | cut -c1-12)"

    consul agent \
        -server \
        -ui \
        -node="$node_name" \
        -bind="$my_ip" \
        -advertise="$my_ip" \
        -client="0.0.0.0" \
        -data-dir="/var/lib/consul" \
        -config-dir="/etc/consul.d" \
        -log-level="WARN" \
        "${flags[@]}" \
        >> /var/log/consul.log 2>&1 &

    local consul_pid=$!
    log "Consul started (PID: $consul_pid)"

    # Chờ Consul ready
    log "Waiting for Consul to become ready..."
    local i=0
    while [ $i -lt 40 ]; do
        if consul_alive_on "127.0.0.1"; then
            log "✓ Consul is ready"
            return 0
        fi
        # Log progress mỗi 15s để dễ debug
        if (( i % 5 == 4 )); then
            log "  Still waiting... (${i}s / 120s)"
            tail -3 /var/log/consul.log 2>/dev/null | sed 's/^/    /' || true
        fi
        sleep 3
        i=$((i + 1))
    done

    err "Consul NOT ready after 120s. Last logs:"
    tail -20 /var/log/consul.log >&2
    exit 1
}
start_consul() {
    local my_ip="$1"
    local peers="$2"

    local retry_flags=()
    for p in $peers; do
        retry_flags+=("-retry-join=$p")
    done

    consul agent \
        -server \
        -bootstrap-expect=2 \
        -bind="$my_ip" \
        -advertise="$my_ip" \
        -client="0.0.0.0" \
        -data-dir="/var/lib/consul" \
        -config-dir="/etc/consul.d" \
        -log-level="WARN" \
        -retry-interval=10s \
        -retry-max=60 \
        "${retry_flags[@]}" \
        >> /var/log/consul.log 2>&1 &
}
# ── MAIN ──────────────────────────────────────────────────────────────────────
main() {
    log "══════════════════════════════════════════"
    log "  LiteFS Node Bootstrap"
    log "══════════════════════════════════════════"

    wait_tailscale

    # Anti-race backoff
    local backoff=$(( (RANDOM % 12) + 3 ))
    log "Anti-race backoff: ${backoff}s..."
    sleep "$backoff"

    # Refresh IP sau backoff
    MY_IP=$(tailscale ip -4 2>/dev/null) || { err "Lost Tailscale IP"; exit 1; }

    # Tìm peers qua Tailscale tag
    log "Searching for peers with tag: $TS_TAG..."
    local peers=""
    local attempt
    for attempt in 1 2 3; do
        peers=$(get_peers || true)
        if [ -n "$peers" ]; then
            log "✓ Found peers (attempt $attempt): $(echo $peers | tr '\n' ' ')"
            break
        fi
        log "Peer check attempt $attempt failed. Retry in 10s..."
        sleep 10
    done

    if [ -z "$peers" ]; then
        log "No peers found — will bootstrap alone (waiting for others via retry-join)"
    fi

    # Build retry-join flags từ peers tìm được
    local retry_flags=()
    for p in $peers; do
        retry_flags+=("-retry-join=$p")
    done

    # Node bootstrap alone vẫn cần 1 retry-join (chính nó) để Consul không complain
    # bootstrap-expect=2 sẽ block elect cho đến khi có peer join
    if [ ${#retry_flags[@]} -eq 0 ]; then
        log "No retry-join targets — Consul will wait for peers to connect"
    fi

    # Start Consul — tất cả nodes đều dùng bootstrap-expect=2
    local node_name="litefs-$(hostname | cut -c1-12)"
    log "Starting Consul (node: $node_name, expect=2)..."

    consul agent \
        -server \
        -ui \
        -node="$node_name" \
        -bind="$MY_IP" \
        -advertise="$MY_IP" \
        -client="0.0.0.0" \
        -data-dir="/var/lib/consul" \
        -config-dir="/etc/consul.d" \
        -log-level="WARN" \
        -bootstrap-expect=2 \
        -retry-interval=10s \
        -retry-max=60 \
        "${retry_flags[@]}" \
        >> /var/log/consul.log 2>&1 &

    local consul_pid=$!
    log "Consul started (PID: $consul_pid)"

    # Chờ Consul ready
    log "Waiting for Consul to become ready (may take up to 120s while waiting for quorum)..."
    local i=0
    while [ $i -lt 40 ]; do
        if consul_alive_on "127.0.0.1"; then
            log "✓ Consul is ready"
            break
        fi
        if (( i % 5 == 4 )); then
            log "  Still waiting... (${i}s / 120s)"
            tail -3 /var/log/consul.log 2>/dev/null | sed 's/^/    /' || true
        fi
        sleep 3
        i=$((i + 1))
    done

    if ! consul_alive_on "127.0.0.1"; then
        err "Consul NOT ready after 120s. Last logs:"
        tail -20 /var/log/consul.log >&2
        exit 1
    fi

    # Summary
    log "══════════════════════════════════════════"
    log "  Bootstrap Complete"
    log "  Node IP   : $MY_IP"
    log "  Peers     : $([ -n "$peers" ] && echo "$peers" | tr '\n' ' ' || echo "none (bootstrapping alone)")"
    log "  Leader    : $(curl -s http://127.0.0.1:8500/v1/status/leader 2>/dev/null || echo '?')"
    log "══════════════════════════════════════════"
    consul members 2>/dev/null | sed 's/^/  /' || true
}

main "$@"
