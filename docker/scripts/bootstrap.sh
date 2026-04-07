#!/bin/bash
# bootstrap.sh — Khởi động Consul cho 1..N node, có cơ chế recovery khi cluster "no leader".
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

leader_of_ip() {
    local ip="$1"
    curl -sf --connect-timeout 2 --max-time 4 "http://${ip}:8500/v1/status/leader" 2>/dev/null || true
}

has_real_leader_value() {
    local leader="$1"
    [[ "$leader" =~ ^\"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+\"$ ]]
}

find_existing_leader() {
    local nodes leader
    nodes=$(all_known_nodes)
    for ip in $nodes; do
        leader=$(leader_of_ip "$ip")
        if has_real_leader_value "$leader"; then
            echo "$leader"
            return 0
        fi
    done
    return 1
}

wait_seed_stable() {
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
        [ -z "$seed" ] && seed="$MY_IP"

        if [ "$seed" = "$prev" ]; then
            stable=$((stable + 1))
        else
            stable=1
            prev="$seed"
        fi

        log "Discovery $i/$rounds | seed=$seed | stable=$stable/$stable_need | nodes=$(echo "$nodes" | tr '\n' ' ')"

        if [ "$stable" -ge "$stable_need" ]; then
            echo "$seed"
            return 0
        fi

        sleep "$sleep_s"
        i=$((i + 1))
    done

    echo "$prev"
}

rank_of_self() {
    local nodes rank=1 ip
    nodes=$(all_known_nodes | sort -V)
    for ip in $nodes; do
        if [ "$ip" = "$MY_IP" ]; then
            echo "$rank"
            return 0
        fi
        rank=$((rank + 1))
    done
    echo "1"
}

start_consul_process() {
    local mode="$1" # leader|follower
    local explicit_join="${2:-}"

    local node_name="${NODE_NAME:-litefs-$(hostname | cut -c1-12)}"
    local retry_flags=()

    local peers
    peers=$(get_online_peers || true)
    for p in $peers; do
        [ "$p" = "$MY_IP" ] && continue
        retry_flags+=("-retry-join=$p")
    done

    if [ -n "$explicit_join" ]; then
        retry_flags+=("-retry-join=$explicit_join")
    fi

    local mode_flags=()
    if [ "$mode" = "leader" ]; then
        mode_flags+=("-bootstrap-expect=1")
        log "Mode: LEADER (self-bootstrap)"
    else
        log "Mode: FOLLOWER (retry-join peers)"
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
}

wait_local_consul_ready() {
    log "Waiting for local Consul API ready..."
    local i=0 resp
    while [ "$i" -lt 60 ]; do
        resp=$(leader_of_ip "127.0.0.1")
        # API có thể ready dù chưa có leader, nên chỉ cần resp là string JSON
        if [[ "$resp" =~ ^\" ]]; then
            log "✓ Local Consul API reachable (leader=$resp)"
            return 0
        fi
        sleep 3
        i=$((i + 1))
    done

    err "Local Consul API not ready after timeout"
    tail -30 /var/log/consul.log >&2 || true
    exit 1
}


wait_cluster_leader() {
    local timeout="${1:-120}"
    local i=0 resp
    while [ "$i" -lt "$timeout" ]; do
        resp=$(leader_of_ip "127.0.0.1")
        if has_real_leader_value "$resp"; then
            echo "$resp"
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    return 1
}

reset_local_consul_state() {
    log "Reset local Consul state (no-leader recovery)..."
    pkill -f "consul agent" 2>/dev/null || true
    sleep 2
    rm -rf /var/lib/consul/*
}

main() {
    log "══════════════════════════════════════════"
    log "  LiteFS Node Bootstrap"
    log "══════════════════════════════════════════"

    wait_tailscale

    local backoff=$(( (RANDOM % 4) + 1 ))
    log "Initial anti-race backoff: ${backoff}s"
    sleep "$backoff"

    local seed existing_leader mode
    seed=$(wait_seed_stable)
    [ -z "$seed" ] && seed="$MY_IP"

    if existing_leader=$(find_existing_leader); then
        log "Detected existing leader in cluster: $existing_leader"
        mode="follower"
        start_consul_process "follower"
    else
        local rank step delay
        rank=$(rank_of_self)
        step="${BOOTSTRAP_RECOVERY_STEP_SECONDS:-10}"
        delay=$(( (rank - 1) * step ))
        log "No leader detected. Recovery gate: rank=$rank, delay=${delay}s"
        sleep "$delay"

        if existing_leader=$(find_existing_leader); then
            log "Leader appeared during recovery wait: $existing_leader"
            mode="follower"
            start_consul_process "follower"
        else
            log "Still no leader after recovery wait → bootstrap self"
            mode="leader"
            start_consul_process "leader"
        fi
    fi

    wait_local_consul_ready

    local final_leader
    if final_leader=$(wait_cluster_leader "${BOOTSTRAP_LEADER_WAIT_SECONDS:-90}"); then
        log "✓ Cluster leader elected: $final_leader"
        log "Consul bootstrap flow completed"
        exit 0
    fi

    log "⚠ Cluster still has no leader after wait window"
    if [ "${CONSUL_AUTO_RECOVER_NO_LEADER:-true}" != "true" ]; then
        err "CONSUL_AUTO_RECOVER_NO_LEADER=false, stop here"
        exit 1
    fi

    # Auto-recovery: reset local raft state và thử lại 1 lần.
    reset_local_consul_state

    if [ "$mode" = "leader" ]; then
        log "Retry as LEADER after local reset"
        start_consul_process "leader"
    else
        log "Retry as FOLLOWER after local reset"
        start_consul_process "follower"
    fi

    wait_local_consul_ready
    if final_leader=$(wait_cluster_leader "${BOOTSTRAP_LEADER_WAIT_SECONDS:-90}"); then
        log "✓ Cluster leader elected after recovery: $final_leader"
        log "Consul bootstrap flow completed"
        exit 0
    fi

    err "Cluster still has no leader after recovery retry"
    tail -40 /var/log/consul.log >&2 || true
    exit 1
}

main "$@"
