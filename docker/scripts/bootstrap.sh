#!/bin/bash
# bootstrap.sh — Khởi động Consul theo cơ chế seed động, hỗ trợ 1..N node.
# - Nếu chỉ có 1 node online: node đó tự bootstrap leader.
# - Nếu nhiều node: chọn seed xác định (IP nhỏ nhất) để bootstrap, node khác join follower.
set -euo pipefail

TS_TAG="${TS_TAG:-tag:litefs-node}"
LOG_P="[BOOTSTRAP]"

log()  { echo "$LOG_P [$(date '+%H:%M:%S')] $*"; }
err()  { echo "$LOG_P [ERROR] $*" >&2; }

wait_tailscale() {
    log "Waiting for Tailscale IP..."
    local tries=0
    while [ "$tries" -lt 60 ]; do
        MY_IP=$(tailscale ip -4 2>/dev/null || true)
        if [[ "$MY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            export MY_IP
            log "✓ Tailscale IP: $MY_IP"
            return 0
        fi
        sleep 2
        tries=$((tries + 1))
    done
    err "Tailscale did not get IP after 120s"
    exit 1
}

get_online_peers() {
    tailscale status --json 2>/dev/null | jq -r '
        (.Peer // {}) | to_entries[] | .value
        | select((.Tags // []) | arrays | any(. == "'"$TS_TAG"'"))
        | select(.Online == true)
        | (.TailscaleIPs // [])[0]
    ' 2>/dev/null | grep -Ev '^(null|)$' || true
}

all_known_nodes() {
    {
        echo "$MY_IP"
        get_online_peers
    } | awk 'NF' | sort -u
}

consul_alive_local() {
    local resp
    resp=$(curl -sf --connect-timeout 2 --max-time 4 \
        "http://127.0.0.1:8500/v1/status/leader" 2>/dev/null || true)
    [[ "$resp" =~ ^\"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+\"$ ]]
}

wait_seed_stable() {
    # Startup gate chống race/split-brain:
    # Chọn seed là IP nhỏ nhất trong tập node online (self + peers).
    # Chỉ chốt seed khi giá trị ổn định N vòng liên tiếp.
    local rounds="${BOOTSTRAP_DISCOVERY_ROUNDS:-20}"
    local stable_need="${BOOTSTRAP_STABLE_ROUNDS:-3}"
    local sleep_s="${BOOTSTRAP_DISCOVERY_INTERVAL:-3}"

    local prev=""
    local stable=0
    local i=1

    while [ "$i" -le "$rounds" ]; do
        local nodes seed
        nodes=$(all_known_nodes)
        seed=$(echo "$nodes" | sort -V | head -n1)

        if [ -z "$seed" ]; then
            seed="$MY_IP"
        fi

        if [ "$seed" = "$prev" ]; then
            stable=$((stable + 1))
        else
            stable=1
            prev="$seed"
        fi

        log "Discovery round $i/$rounds | seed=$seed | stable=$stable/$stable_need | nodes=$(echo "$nodes" | tr '\n' ' ')"

        if [ "$stable" -ge "$stable_need" ]; then
            echo "$seed"
            return 0
        fi

        sleep "$sleep_s"
        i=$((i + 1))
    done

    # Timeout thì vẫn trả seed cuối để hệ thống tiến lên (ưu tiên availability).
    echo "$prev"
}

start_consul() {
    local seed_ip="$1"
    local mode="$2" # leader | follower

    local node_name="${NODE_NAME:-litefs-$(hostname | cut -c1-12)}"
    local retry_flags=()

    # Luôn retry-join tất cả peers đang thấy để tăng khả năng hội tụ.
    local peers
    peers=$(get_online_peers || true)
    for p in $peers; do
        [ "$p" = "$MY_IP" ] && continue
        retry_flags+=("-retry-join=$p")
    done

    # Follower luôn có seed_ip trong retry-join để bám seed chắc chắn.
    if [ "$mode" = "follower" ] && [ -n "$seed_ip" ]; then
        retry_flags+=("-retry-join=$seed_ip")
    fi

    local mode_flags=()
    if [ "$mode" = "leader" ]; then
        # Node seed tự bootstrap ngay cả khi hiện tại chỉ có 1 node.
        mode_flags+=("-bootstrap-expect=1")
        log "Mode: LEADER (seed bootstrap) | seed=$seed_ip"
    else
        log "Mode: FOLLOWER (join seed) | seed=$seed_ip"
    fi

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
        -retry-interval="${CONSUL_RETRY_INTERVAL:-5s}" \
        -retry-max="${CONSUL_RETRY_MAX:-0}" \
        "${mode_flags[@]}" \
        "${retry_flags[@]}" \
        >> /var/log/consul.log 2>&1 &

    local consul_pid=$!
    log "Consul started (PID: $consul_pid)"

    log "Waiting for local Consul API ready..."
    local i=0
    while [ "$i" -lt 60 ]; do
        if consul_alive_local; then
            log "✓ Consul is ready"
            return 0
        fi
        if (( i % 10 == 9 )); then
            log "  Still waiting... (${i}s / 180s)"
            tail -3 /var/log/consul.log 2>/dev/null | sed 's/^/    /' || true
        fi
        sleep 3
        i=$((i + 1))
    done

    err "Consul NOT ready after timeout. Last logs:"
    tail -30 /var/log/consul.log >&2 || true
    exit 1
}

main() {
    log "══════════════════════════════════════════"
    log "  LiteFS Node Bootstrap"
    log "══════════════════════════════════════════"

    wait_tailscale

    # Backoff nhẹ để giảm burst đồng thời từ CI/orchestrator.
    local backoff=$(( (RANDOM % 4) + 1 ))
    log "Anti-race initial backoff: ${backoff}s"
    sleep "$backoff"

    local seed
    seed=$(wait_seed_stable)
    [ -z "$seed" ] && seed="$MY_IP"

    if [ "$seed" = "$MY_IP" ]; then
        start_consul "$seed" "leader"
    else
        start_consul "$seed" "follower"
    fi

    log "Consul bootstrap flow completed"
}

main "$@"
