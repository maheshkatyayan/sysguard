#!/bin/bash
# =============================================================================
# SysGuard - Service Health Monitor
# Checks systemd service status; auto-restarts failed services; sends alerts
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/sysguard.conf"

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "[ERROR] Config file not found: $CONFIG_FILE" >&2
    exit 1
fi

LOG_FILE="${SERVICE_LOG_FILE:-/var/log/sysguard/services.log}"
ALERT_EMAIL="${ALERT_EMAIL:-root@localhost}"
HOSTNAME=$(hostname -f)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
AUTO_RESTART="${AUTO_RESTART:-true}"
MAX_RESTARTS="${MAX_RESTARTS:-3}"
RESTART_TRACK_FILE="/tmp/sysguard_restart_count"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
    local level="$1"
    local message="$2"
    echo "[$TIMESTAMP] [$level] $message" | tee -a "$LOG_FILE"
}

send_alert() {
    local subject="$1"
    local body="$2"
    if command -v mail &>/dev/null; then
        echo -e "$body" | mail -s "[SysGuard ALERT] $subject" "$ALERT_EMAIL"
    fi
}

# --- Check if systemd is available ---
check_systemd() {
    if ! command -v systemctl &>/dev/null; then
        log "ERROR" "systemctl not found. Is this a systemd-based system?"
        exit 1
    fi
}

# --- Get restart count for a service ---
get_restart_count() {
    local service="$1"
    local key="restart_${service//[^a-zA-Z0-9]/_}"
    grep -c "^${key}$" "$RESTART_TRACK_FILE" 2>/dev/null || echo 0
}

# --- Increment restart count ---
increment_restart_count() {
    local service="$1"
    local key="restart_${service//[^a-zA-Z0-9]/_}"
    echo "$key" >> "$RESTART_TRACK_FILE"
}

# --- Reset restart count (run at start of day via cron) ---
reset_restart_counts() {
    > "$RESTART_TRACK_FILE"
    log "INFO" "Restart counts reset."
}

# --- Check single service ---
check_service() {
    local service="$1"

    # Check if service exists
    if ! systemctl list-unit-files "${service}.service" &>/dev/null; then
        log "WARN" "Service not found: $service"
        return
    fi

    local status
    status=$(systemctl is-active "$service" 2>/dev/null)
    local enabled
    enabled=$(systemctl is-enabled "$service" 2>/dev/null)

    log "INFO" "Service: $service | Active: $status | Enabled: $enabled"

    if [[ "$status" != "active" ]]; then
        log "WARN" "SERVICE DOWN: $service (status=$status)"

        local restart_count
        restart_count=$(get_restart_count "$service")

        if [[ "$AUTO_RESTART" == "true" ]] && (( restart_count < MAX_RESTARTS )); then
            log "INFO" "Attempting to restart $service (attempt $((restart_count + 1))/$MAX_RESTARTS)..."
            if systemctl restart "$service" 2>/dev/null; then
                sleep 3
                local new_status
                new_status=$(systemctl is-active "$service" 2>/dev/null)
                if [[ "$new_status" == "active" ]]; then
                    log "INFO" "Successfully restarted $service"
                    increment_restart_count "$service"
                    send_alert "Service Restarted: $service" \
"Host        : $HOSTNAME
Time        : $TIMESTAMP
Service     : $service
Old Status  : $status
New Status  : active
Restart No. : $((restart_count + 1))/$MAX_RESTARTS

Service was automatically restarted by SysGuard."
                else
                    log "ERROR" "Failed to restart $service (still $new_status)"
                    send_alert "Service Restart FAILED: $service" \
"Host    : $HOSTNAME
Time    : $TIMESTAMP
Service : $service
Status  : $new_status

SysGuard attempted to restart this service but it remains down.
Please investigate immediately.

Last Journal Entries:
$(journalctl -u "$service" -n 20 --no-pager 2>/dev/null)"
                fi
            fi
        elif (( restart_count >= MAX_RESTARTS )); then
            log "ERROR" "Max restarts ($MAX_RESTARTS) reached for $service. Manual intervention required."
            send_alert "Service CRITICAL - Max Restarts Reached: $service" \
"Host    : $HOSTNAME
Time    : $TIMESTAMP
Service : $service
Status  : $status

WARNING: SysGuard has attempted to restart this service $MAX_RESTARTS times.
Automatic restarts have been suspended. MANUAL INTERVENTION REQUIRED.

Last Journal Entries:
$(journalctl -u "$service" -n 30 --no-pager 2>/dev/null)"
        else
            send_alert "Service Down: $service" \
"Host    : $HOSTNAME
Time    : $TIMESTAMP
Service : $service
Status  : $status

Service is down and auto-restart is disabled.

Last Journal Entries:
$(journalctl -u "$service" -n 20 --no-pager 2>/dev/null)"
        fi
    fi
}

# --- Check all configured services ---
check_all_services() {
    if [[ -z "${MONITORED_SERVICES[*]}" ]]; then
        log "WARN" "No services defined in MONITORED_SERVICES config array."
        return
    fi

    log "INFO" "=== Service Health Check Started ==="
    for service in "${MONITORED_SERVICES[@]}"; do
        check_service "$service"
    done
    log "INFO" "=== Service Health Check Completed ==="
}

# --- Generate service status report ---
service_report() {
    echo "============================================"
    echo "  SysGuard Service Status Report"
    echo "  Host: $HOSTNAME | Time: $TIMESTAMP"
    echo "============================================"
    printf "%-30s %-10s %-10s\n" "SERVICE" "ACTIVE" "ENABLED"
    echo "--------------------------------------------"
    for service in "${MONITORED_SERVICES[@]}"; do
        local active enabled
        active=$(systemctl is-active "$service" 2>/dev/null || echo "unknown")
        enabled=$(systemctl is-enabled "$service" 2>/dev/null || echo "unknown")
        printf "%-30s %-10s %-10s\n" "$service" "$active" "$enabled"
    done
    echo "============================================"
}

# --- Entry point ---
case "${1:-check}" in
    check)    check_systemd; check_all_services ;;
    report)   check_systemd; service_report ;;
    reset)    reset_restart_counts ;;
    *)        echo "Usage: $0 {check|report|reset}"; exit 1 ;;
esac
