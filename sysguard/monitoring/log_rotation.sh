#!/bin/bash
# =============================================================================
# SysGuard - Log Rotation Manager
# Rotates, compresses, and prunes logs with configurable retention policies
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/sysguard.conf"

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "[ERROR] Config file not found: $CONFIG_FILE" >&2
    exit 1
fi

ROTATION_LOG="${ROTATION_LOG:-/var/log/sysguard/rotation.log}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
MAX_LOG_SIZE_MB="${MAX_LOG_SIZE_MB:-100}"
COMPRESS_LOGS="${COMPRESS_LOGS:-true}"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
DATE_SUFFIX=$(date '+%Y%m%d_%H%M%S')
HOSTNAME=$(hostname -f)

mkdir -p "$(dirname "$ROTATION_LOG")"

log() {
    local level="$1"
    local message="$2"
    echo "[$TIMESTAMP] [$level] $message" | tee -a "$ROTATION_LOG"
}

send_alert() {
    local subject="$1"
    local body="$2"
    if command -v mail &>/dev/null; then
        echo -e "$body" | mail -s "[SysGuard] $subject" "${ALERT_EMAIL:-root@localhost}"
    fi
}

# --- Get file size in MB ---
file_size_mb() {
    local file="$1"
    du -m "$file" 2>/dev/null | awk '{print $1}'
}

# --- Rotate a single log file ---
rotate_log() {
    local logfile="$1"
    local retention="${2:-$RETENTION_DAYS}"

    if [[ ! -f "$logfile" ]]; then
        log "WARN" "Log file not found, skipping: $logfile"
        return
    fi

    local size_mb
    size_mb=$(file_size_mb "$logfile")
    log "INFO" "Checking: $logfile (${size_mb}MB)"

    if (( size_mb >= MAX_LOG_SIZE_MB )); then
        local rotated="${logfile}.${DATE_SUFFIX}"
        cp "$logfile" "$rotated"
        : > "$logfile"   # truncate original (preserves permissions/ownership)
        log "INFO" "Rotated: $logfile -> $rotated (was ${size_mb}MB)"

        if [[ "$COMPRESS_LOGS" == "true" ]]; then
            gzip -f "$rotated"
            log "INFO" "Compressed: ${rotated}.gz"
            rotated="${rotated}.gz"
        fi
    else
        log "INFO" "No rotation needed: $logfile (${size_mb}MB < ${MAX_LOG_SIZE_MB}MB threshold)"
    fi
}

# --- Prune old rotated log files ---
prune_old_logs() {
    local log_dir="$1"
    local retention="${2:-$RETENTION_DAYS}"

    if [[ ! -d "$log_dir" ]]; then
        log "WARN" "Log directory not found: $log_dir"
        return
    fi

    log "INFO" "Pruning logs older than ${retention} days in: $log_dir"
    local count=0
    while IFS= read -r -d '' file; do
        rm -f "$file"
        log "INFO" "Deleted old log: $file"
        (( count++ ))
    done < <(find "$log_dir" -maxdepth 1 -type f \( -name "*.gz" -o -name "*.log.*" \) \
             -mtime +"$retention" -print0)

    log "INFO" "Pruned $count old log file(s) from $log_dir"
}

# --- Rotate all SysGuard logs ---
rotate_sysguard_logs() {
    log "INFO" "=== SysGuard Log Rotation Started ==="
    local sysguard_log_dir
    sysguard_log_dir=$(dirname "${LOG_FILE:-/var/log/sysguard/monitor.log}")

    for logfile in "$sysguard_log_dir"/*.log; do
        [[ -f "$logfile" ]] && rotate_log "$logfile"
    done

    prune_old_logs "$sysguard_log_dir"
    log "INFO" "=== SysGuard Log Rotation Completed ==="
}

# --- Rotate application logs defined in config ---
rotate_app_logs() {
    if [[ -z "${APP_LOG_DIRS[*]}" ]]; then
        log "INFO" "No APP_LOG_DIRS defined in config; skipping app log rotation."
        return
    fi

    log "INFO" "=== Application Log Rotation Started ==="
    for entry in "${APP_LOG_DIRS[@]}"; do
        local dir retention
        dir="${entry%%:*}"
        retention="${entry##*:}"
        [[ "$retention" == "$dir" ]] && retention="$RETENTION_DAYS"

        if [[ -d "$dir" ]]; then
            log "INFO" "Processing app log dir: $dir (retention: ${retention}d)"
            for logfile in "$dir"/*.log "$dir"/*.log.* ; do
                [[ -f "$logfile" ]] && rotate_log "$logfile" "$retention"
            done
            prune_old_logs "$dir" "$retention"
        else
            log "WARN" "App log directory not found: $dir"
        fi
    done
    log "INFO" "=== Application Log Rotation Completed ==="
}

# --- Disk space check after rotation ---
post_rotation_disk_check() {
    local log_dir
    log_dir=$(dirname "${LOG_FILE:-/var/log/sysguard/monitor.log}")
    local usage
    usage=$(df -h "$log_dir" | tail -1)
    log "INFO" "Disk usage after rotation: $usage"
}

# --- Generate rotation summary ---
rotation_summary() {
    local sysguard_log_dir
    sysguard_log_dir=$(dirname "${LOG_FILE:-/var/log/sysguard/monitor.log}")
    echo "============================================"
    echo "  SysGuard Log Rotation Summary"
    echo "  Host: $HOSTNAME | Time: $TIMESTAMP"
    echo "============================================"
    echo "Log Directory : $sysguard_log_dir"
    echo "Retention     : ${RETENTION_DAYS} days"
    echo "Max Log Size  : ${MAX_LOG_SIZE_MB}MB"
    echo "Compression   : ${COMPRESS_LOGS}"
    echo ""
    echo "Current log files:"
    ls -lh "$sysguard_log_dir" 2>/dev/null
    echo ""
    echo "Disk Usage:"
    df -h "$sysguard_log_dir"
    echo "============================================"
}

# --- Entry point ---
case "${1:-all}" in
    all)     rotate_sysguard_logs; rotate_app_logs; post_rotation_disk_check ;;
    sysguard) rotate_sysguard_logs; post_rotation_disk_check ;;
    apps)    rotate_app_logs; post_rotation_disk_check ;;
    summary) rotation_summary ;;
    prune)   prune_old_logs "${2:-/var/log/sysguard}" "${3:-$RETENTION_DAYS}" ;;
    *)       echo "Usage: $0 {all|sysguard|apps|summary|prune [dir] [days]}"; exit 1 ;;
esac
