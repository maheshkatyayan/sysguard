#!/bin/bash
# =============================================================================
# SysGuard - System Resource Monitor
# Monitors CPU, Memory, and Disk usage; sends alerts when thresholds exceeded
# =============================================================================

# --- Load config ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/sysguard.conf"

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "[ERROR] Config file not found: $CONFIG_FILE" >&2
    exit 1
fi

# --- Defaults (overridden by config) ---
CPU_THRESHOLD="${CPU_THRESHOLD:-85}"
MEM_THRESHOLD="${MEM_THRESHOLD:-80}"
DISK_THRESHOLD="${DISK_THRESHOLD:-90}"
ALERT_EMAIL="${ALERT_EMAIL:-root@localhost}"
LOG_FILE="${LOG_FILE:-/var/log/sysguard/monitor.log}"
HOSTNAME=$(hostname -f)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# --- Ensure log directory exists ---
mkdir -p "$(dirname "$LOG_FILE")"

# --- Logging function ---
log() {
    local level="$1"
    local message="$2"
    echo "[$TIMESTAMP] [$level] $message" | tee -a "$LOG_FILE"
}

# --- Send alert email ---
send_alert() {
    local subject="$1"
    local body="$2"
    if command -v mail &>/dev/null; then
        echo -e "$body" | mail -s "[SysGuard ALERT] $subject - $HOSTNAME" "$ALERT_EMAIL"
        log "INFO" "Alert email sent to $ALERT_EMAIL: $subject"
    else
        log "WARN" "mail command not found; alert not sent: $subject"
    fi
}

# --- Check CPU Usage ---
check_cpu() {
    local cpu_idle
    cpu_idle=$(top -bn1 | grep "Cpu(s)" | awk '{print $8}' | tr -d '%us,')
    # Fallback for different top formats
    if [[ -z "$cpu_idle" ]]; then
        cpu_idle=$(top -bn1 | grep "Cpu(s)" | sed 's/.*, *\([0-9.]*\)%* id.*/\1/')
    fi
    local cpu_usage
    cpu_usage=$(echo "100 - $cpu_idle" | bc 2>/dev/null || echo "0")
    cpu_usage=${cpu_usage%.*}  # strip decimals

    log "INFO" "CPU Usage: ${cpu_usage}% (threshold: ${CPU_THRESHOLD}%)"

    if (( cpu_usage > CPU_THRESHOLD )); then
        log "WARN" "CPU ALERT: Usage at ${cpu_usage}% exceeds threshold of ${CPU_THRESHOLD}%"
        local top_procs
        top_procs=$(ps aux --sort=-%cpu | head -6 | awk '{printf "%-20s %-6s %-6s\n", $11, $3, $4}')
        send_alert "High CPU Usage: ${cpu_usage}%" \
"Host     : $HOSTNAME
Time     : $TIMESTAMP
CPU Usage: ${cpu_usage}% (Threshold: ${CPU_THRESHOLD}%)

Top Processes by CPU:
$(ps aux --sort=-%cpu | head -6)"
    fi
}

# --- Check Memory Usage ---
check_memory() {
    local mem_info
    mem_info=$(free -m | awk '/^Mem:/')
    local mem_total mem_used mem_usage
    mem_total=$(echo "$mem_info" | awk '{print $2}')
    mem_used=$(echo "$mem_info" | awk '{print $3}')
    mem_usage=$(( mem_used * 100 / mem_total ))

    log "INFO" "Memory Usage: ${mem_usage}% (${mem_used}MB / ${mem_total}MB) (threshold: ${MEM_THRESHOLD}%)"

    if (( mem_usage > MEM_THRESHOLD )); then
        log "WARN" "MEMORY ALERT: Usage at ${mem_usage}% exceeds threshold of ${MEM_THRESHOLD}%"
        send_alert "High Memory Usage: ${mem_usage}%" \
"Host        : $HOSTNAME
Time        : $TIMESTAMP
Memory Usage: ${mem_usage}% (${mem_used}MB / ${mem_total}MB)
Threshold   : ${MEM_THRESHOLD}%

Top Processes by Memory:
$(ps aux --sort=-%mem | head -6)"
    fi
}

# --- Check Disk Usage ---
check_disk() {
    local alert_triggered=false
    while IFS= read -r line; do
        local usage mount
        usage=$(echo "$line" | awk '{print $5}' | tr -d '%')
        mount=$(echo "$line" | awk '{print $6}')

        log "INFO" "Disk $mount: ${usage}% used (threshold: ${DISK_THRESHOLD}%)"

        if (( usage > DISK_THRESHOLD )); then
            alert_triggered=true
            log "WARN" "DISK ALERT: $mount at ${usage}% exceeds threshold of ${DISK_THRESHOLD}%"
            send_alert "High Disk Usage on $mount: ${usage}%" \
"Host       : $HOSTNAME
Time       : $TIMESTAMP
Mount Point: $mount
Disk Usage : ${usage}% (Threshold: ${DISK_THRESHOLD}%)

Disk Details:
$(df -h "$mount")"
        fi
    done < <(df -H | grep -vE '^Filesystem|tmpfs|cdrom|udev' | tail -n +2)
}

# --- Check Swap Usage ---
check_swap() {
    local swap_total swap_used swap_usage
    swap_total=$(free -m | awk '/^Swap:/{print $2}')
    swap_used=$(free -m  | awk '/^Swap:/{print $3}')

    if (( swap_total > 0 )); then
        swap_usage=$(( swap_used * 100 / swap_total ))
        log "INFO" "Swap Usage: ${swap_usage}% (${swap_used}MB / ${swap_total}MB)"
        if (( swap_usage > 70 )); then
            log "WARN" "SWAP ALERT: Swap usage at ${swap_usage}%"
            send_alert "High Swap Usage: ${swap_usage}%" \
"Host      : $HOSTNAME
Time      : $TIMESTAMP
Swap Usage: ${swap_usage}% (${swap_used}MB / ${swap_total}MB)"
        fi
    fi
}

# --- Main ---
log "INFO" "=== SysGuard Monitor Run Started ==="
check_cpu
check_memory
check_disk
check_swap
log "INFO" "=== SysGuard Monitor Run Completed ==="
