#!/bin/bash
# =============================================================================
# SysGuard - Backup Automation
# Incremental backups via rsync with rotation, verification, and email alerts
# Compatible with Ubuntu and CentOS/RHEL
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/sysguard.conf"

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "[ERROR] Config file not found: $CONFIG_FILE" >&2
    exit 1
fi

LOG_FILE="${BACKUP_LOG:-/var/log/sysguard/backup.log}"
BACKUP_DEST="${BACKUP_DEST:-/var/backups/sysguard}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
ALERT_EMAIL="${ALERT_EMAIL:-root@localhost}"
HOSTNAME=$(hostname -f)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
DATE_TAG=$(date '+%Y-%m-%d_%H%M%S')
BACKUP_STATUS="SUCCESS"
ERRORS=()

mkdir -p "$(dirname "$LOG_FILE")" "$BACKUP_DEST"

log() {
    local level="$1"
    local message="$2"
    echo "[$TIMESTAMP] [$level] $message" | tee -a "$LOG_FILE"
}

send_alert() {
    local subject="$1"
    local body="$2"
    if command -v mail &>/dev/null; then
        echo -e "$body" | mail -s "[SysGuard BACKUP] $subject - $HOSTNAME" "$ALERT_EMAIL"
        log "INFO" "Alert sent: $subject"
    elif command -v sendmail &>/dev/null; then
        echo -e "Subject: [SysGuard BACKUP] $subject - $HOSTNAME\n\n$body" | sendmail "$ALERT_EMAIL"
    else
        log "WARN" "No mail agent found. Could not send alert: $subject"
    fi
}

# --- Check prerequisites ---
check_prerequisites() {
    local missing=()
    command -v rsync &>/dev/null || missing+=("rsync")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log "ERROR" "Missing required tools: ${missing[*]}"
        # Try to install on Ubuntu
        if command -v apt-get &>/dev/null; then
            log "INFO" "Attempting to install missing tools via apt-get..."
            apt-get install -y "${missing[@]}" &>/dev/null
        # Try to install on CentOS/RHEL
        elif command -v yum &>/dev/null; then
            log "INFO" "Attempting to install missing tools via yum..."
            yum install -y "${missing[@]}" &>/dev/null
        fi
    fi
}

# --- Perform incremental backup for a single source ---
backup_source() {
    local source="$1"
    local label="${2:-$(basename "$source")}"
    local dest_base="${BACKUP_DEST}/${label}"
    local dest_current="${dest_base}/current"
    local dest_snapshot="${dest_base}/snapshots/${DATE_TAG}"
    local rsync_log="${dest_base}/rsync_${DATE_TAG}.log"
    local rsync_opts=(
        -a                        # archive mode (recursive, preserve permissions, timestamps, etc.)
        --delete                  # remove files deleted from source
        --delete-excluded         # remove excluded files from dest
        --link-dest="$dest_current"  # hard-link unchanged files from last backup
        --stats                   # output file transfer statistics
        --timeout=120             # network/IO timeout
        --partial                 # keep partially transferred files
        --log-file="$rsync_log"  # per-run rsync log
    )

    # Add SSH options if remote source
    if [[ "$source" == *":"* ]]; then
        rsync_opts+=(-e "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30")
    fi

    # Append any user-defined excludes
    if [[ -n "${BACKUP_EXCLUDES[*]}" ]]; then
        for excl in "${BACKUP_EXCLUDES[@]}"; do
            rsync_opts+=("--exclude=$excl")
        done
    fi

    mkdir -p "$dest_snapshot" "$(dirname "$rsync_log")"

    log "INFO" "Starting backup: $source -> $dest_snapshot"
    local start_time
    start_time=$(date +%s)

    rsync "${rsync_opts[@]}" "$source/" "$dest_snapshot/" 2>&1
    local rsync_exit=$?

    local end_time duration
    end_time=$(date +%s)
    duration=$(( end_time - start_time ))

    if [[ $rsync_exit -eq 0 ]] || [[ $rsync_exit -eq 24 ]]; then
        # Exit 24 = some files vanished (not critical)
        # Update the "current" symlink to point to this snapshot
        rm -f "$dest_current"
        ln -sf "$dest_snapshot" "$dest_current"

        local size
        size=$(du -sh "$dest_snapshot" 2>/dev/null | awk '{print $1}')
        log "INFO" "Backup completed: $label | Size: $size | Duration: ${duration}s | Exit: $rsync_exit"
    else
        BACKUP_STATUS="FAILED"
        ERRORS+=("$label: rsync exit code $rsync_exit")
        log "ERROR" "Backup FAILED: $label | rsync exit code: $rsync_exit | Duration: ${duration}s"
        log "ERROR" "Check rsync log: $rsync_log"
    fi
}

# --- Verify backup integrity ---
verify_backup() {
    local label="$1"
    local dest_current="${BACKUP_DEST}/${label}/current"

    if [[ ! -d "$dest_current" ]]; then
        log "WARN" "Cannot verify: no current backup found for $label"
        return 1
    fi

    local file_count
    file_count=$(find "$dest_current" -type f | wc -l)
    local total_size
    total_size=$(du -sh "$dest_current" | awk '{print $1}')

    log "INFO" "Verification OK: $label | Files: $file_count | Size: $total_size"
    echo "  Label: $label | Files: $file_count | Size: $total_size"
}

# --- Prune old snapshots ---
prune_snapshots() {
    local label="${1:-}"
    local retention="${2:-$BACKUP_RETENTION_DAYS}"

    local dirs=()
    if [[ -n "$label" ]]; then
        dirs=("${BACKUP_DEST}/${label}/snapshots")
    else
        while IFS= read -r -d '' d; do
            dirs+=("$d")
        done < <(find "$BACKUP_DEST" -maxdepth 2 -type d -name "snapshots" -print0)
    fi

    for snap_dir in "${dirs[@]}"; do
        [[ -d "$snap_dir" ]] || continue
        log "INFO" "Pruning snapshots older than ${retention} days in: $snap_dir"
        local count=0
        while IFS= read -r -d '' snap; do
            rm -rf "$snap"
            log "INFO" "Deleted old snapshot: $snap"
            (( count++ ))
        done < <(find "$snap_dir" -maxdepth 1 -mindepth 1 -type d -mtime +"$retention" -print0)
        log "INFO" "Pruned $count snapshot(s) from $snap_dir"
    done
}

# --- Generate backup report ---
backup_report() {
    local report="============================================
  SysGuard Backup Report
  Host: $HOSTNAME
  Time: $TIMESTAMP
  Status: $BACKUP_STATUS
============================================
Backup Destination : $BACKUP_DEST
Retention Period   : ${BACKUP_RETENTION_DAYS} days

Backup Sizes:
$(du -sh "${BACKUP_DEST}"/*/ 2>/dev/null || echo "  No backups found")

Disk Usage:
$(df -h "$BACKUP_DEST")
============================================"

    if [[ ${#ERRORS[@]} -gt 0 ]]; then
        report+="\n\nERRORS:\n"
        for err in "${ERRORS[@]}"; do
            report+="  - $err\n"
        done
    fi

    echo -e "$report"
    echo -e "$report" >> "$LOG_FILE"
}

# --- Run all configured backups ---
run_all_backups() {
    check_prerequisites

    if [[ -z "${BACKUP_SOURCES[*]}" ]]; then
        log "ERROR" "No BACKUP_SOURCES defined in config."
        exit 1
    fi

    log "INFO" "====== Backup Run Started ======"

    for entry in "${BACKUP_SOURCES[@]}"; do
        local source label
        source="${entry%%:*}"
        label="${entry##*:}"
        [[ "$label" == "$source" ]] && label=$(basename "$source")
        backup_source "$source" "$label"
    done

    prune_snapshots

    log "INFO" "====== Backup Run Completed (Status: $BACKUP_STATUS) ======"

    # Send success or failure report
    if [[ "$BACKUP_STATUS" == "FAILED" ]]; then
        send_alert "BACKUP FAILED" "$(backup_report)

ERRORS:
$(printf '%s\n' "${ERRORS[@]}")"
    else
        if [[ "${SEND_SUCCESS_REPORT:-false}" == "true" ]]; then
            send_alert "Backup Successful" "$(backup_report)"
        fi
    fi
}

# --- Entry point ---
case "${1:-run}" in
    run)     run_all_backups ;;
    verify)  verify_backup "${2:-}" ;;
    prune)   prune_snapshots "${2:-}" "${3:-$BACKUP_RETENTION_DAYS}" ;;
    report)  backup_report ;;
    *)       echo "Usage: $0 {run|verify [label]|prune [label] [days]|report}"; exit 1 ;;
esac
