#!/bin/bash
# backup.sh — Snapshot SQLite và upload S3 theo chu kỳ (chỉ chạy trên PRIMARY)
set -euo pipefail

LOG_P="[BACKUP]"
DB="${APP_DB_PATH:-/mnt/litefs/cluster.db}"
ENABLED="${BACKUP_ENABLED:-false}"
INTERVAL="${BACKUP_INTERVAL_SECONDS:-300}"
S3_BUCKET="${BACKUP_S3_BUCKET:-}"
S3_PREFIX="${BACKUP_S3_PREFIX:-litefs}"
AWS_REGION="${AWS_REGION:-us-east-1}"

log() { echo "$LOG_P [$(date '+%H:%M:%S')] $*"; }

is_primary() {
    local my_ip
    my_ip=$(tailscale ip -4 2>/dev/null || echo "")
    [ -z "$my_ip" ] && return 1
    consul kv get litefs/primary 2>/dev/null | grep -q "$my_ip"
}

wait_requirements() {
    local i=0
    while [ "$i" -lt 180 ]; do
        if [ -f "$DB" ] && sqlite3 "$DB" "SELECT 1;" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        i=$((i + 1))
    done
    return 1
}

snapshot_once() {
    local ts host tmpfile key
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    host=${NODE_NAME:-$(hostname | cut -c1-12)}
    tmpfile="/tmp/cluster-${host}-${ts}.db"
    key="${S3_PREFIX%/}/${host}/cluster-${ts}.db"

    sqlite3 "$DB" ".timeout 5000" ".backup '$tmpfile'"

    AWS_DEFAULT_REGION="$AWS_REGION" aws s3 cp "$tmpfile" "s3://${S3_BUCKET}/${key}" --only-show-errors
    rm -f "$tmpfile"
    log "✓ Uploaded snapshot to s3://${S3_BUCKET}/${key}"
}

main() {
    if [ "$ENABLED" != "true" ]; then
        log "Backup disabled (BACKUP_ENABLED=$ENABLED)."
        exit 0
    fi

    if [ -z "$S3_BUCKET" ]; then
        log "Backup enabled but BACKUP_S3_BUCKET is empty. Exit."
        exit 1
    fi

    log "Backup loop started | interval=${INTERVAL}s | bucket=${S3_BUCKET} | prefix=${S3_PREFIX} | region=${AWS_REGION}"

    while true; do
        if wait_requirements; then
            if is_primary; then
                if snapshot_once; then
                    :
                else
                    log "⚠ Snapshot/upload failed"
                fi
            else
                log "Skip backup: current node is replica"
            fi
        else
            log "⚠ DB not ready after waiting window"
        fi
        sleep "$INTERVAL"
    done
}

main "$@"
