#!/bin/bash
# =============================================================================
# SysGuard - User Provisioning & SSH Key Deployment
# Automates user creation, SSH key setup, and permission hardening
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/sysguard.conf"

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "[ERROR] Config file not found: $CONFIG_FILE" >&2
    exit 1
fi

LOG_FILE="${USER_MGMT_LOG:-/var/log/sysguard/user_mgmt.log}"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
HOSTNAME=$(hostname -f)
DEFAULT_SHELL="${DEFAULT_SHELL:-/bin/bash}"
DEFAULT_UMASK="${DEFAULT_UMASK:-027}"
SSH_KEY_DIR="${SSH_KEY_DIR:-/etc/sysguard/ssh_keys}"

mkdir -p "$(dirname "$LOG_FILE")"

# --- Root check ---
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] This script must be run as root." >&2
    exit 1
fi

log() {
    local level="$1"
    local message="$2"
    echo "[$TIMESTAMP] [$level] [$HOSTNAME] $message" | tee -a "$LOG_FILE"
}

# --- Create a new user ---
create_user() {
    local username="$1"
    local groups="${2:-}"           # comma-separated additional groups
    local comment="${3:-SysGuard Provisioned}"
    local shell="${4:-$DEFAULT_SHELL}"
    local home_dir="/home/$username"

    if id "$username" &>/dev/null; then
        log "WARN" "User already exists: $username"
        return 1
    fi

    log "INFO" "Creating user: $username (groups=$groups, shell=$shell)"

    useradd \
        --create-home \
        --home-dir "$home_dir" \
        --shell "$shell" \
        --comment "$comment" \
        "$username"

    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to create user: $username"
        return 1
    fi

    # Set secure home directory permissions
    chmod 750 "$home_dir"
    chown "${username}:${username}" "$home_dir"
    log "INFO" "Home directory created: $home_dir (permissions: 750)"

    # Add to supplementary groups
    if [[ -n "$groups" ]]; then
        IFS=',' read -ra GROUP_LIST <<< "$groups"
        for group in "${GROUP_LIST[@]}"; do
            group=$(echo "$group" | xargs)  # trim whitespace
            if getent group "$group" &>/dev/null; then
                usermod -aG "$group" "$username"
                log "INFO" "Added $username to group: $group"
            else
                log "WARN" "Group does not exist: $group"
            fi
        done
    fi

    # Apply umask in user profile
    echo "umask $DEFAULT_UMASK" >> "$home_dir/.bashrc"
    echo "umask $DEFAULT_UMASK" >> "$home_dir/.profile"
    log "INFO" "Applied umask $DEFAULT_UMASK to $username profile"

    log "INFO" "User created successfully: $username"
    return 0
}

# --- Deploy SSH public key for a user ---
deploy_ssh_key() {
    local username="$1"
    local pubkey="$2"   # path to .pub file OR raw key string
    local home_dir="/home/$username"
    local ssh_dir="$home_dir/.ssh"
    local auth_keys="$ssh_dir/authorized_keys"

    if ! id "$username" &>/dev/null; then
        log "ERROR" "User does not exist: $username"
        return 1
    fi

    # Resolve key content
    local key_content
    if [[ -f "$pubkey" ]]; then
        key_content=$(cat "$pubkey")
        log "INFO" "Reading SSH key from file: $pubkey"
    else
        key_content="$pubkey"
        log "INFO" "Using provided SSH key string for: $username"
    fi

    # Validate key format
    if ! echo "$key_content" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|sk-ssh-ed25519)'; then
        log "ERROR" "Invalid SSH public key format for user: $username"
        return 1
    fi

    # Set up .ssh directory
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    chown "${username}:${username}" "$ssh_dir"

    # Prevent duplicate key entries
    if [[ -f "$auth_keys" ]] && grep -qF "$key_content" "$auth_keys"; then
        log "WARN" "SSH key already exists for user: $username"
        return 0
    fi

    echo "$key_content" >> "$auth_keys"
    chmod 600 "$auth_keys"
    chown "${username}:${username}" "$auth_keys"

    log "INFO" "SSH key deployed for user: $username"
    return 0
}

# --- Harden SSH config for a user ---
harden_ssh_config() {
    local username="$1"
    local home_dir="/home/$username"
    local ssh_dir="$home_dir/.ssh"

    if [[ -d "$ssh_dir" ]]; then
        find "$ssh_dir" -type f -exec chmod 600 {} \;
        find "$ssh_dir" -type d -exec chmod 700 {} \;
        chown -R "${username}:${username}" "$ssh_dir"
        log "INFO" "SSH directory permissions hardened for: $username"
    fi
}

# --- Manage sudoers entry ---
manage_sudo() {
    local username="$1"
    local action="${2:-grant}"   # grant | revoke
    local sudoers_file="/etc/sudoers.d/sysguard_${username}"

    case "$action" in
        grant)
            echo "${username} ALL=(ALL) NOPASSWD: ALL" > "$sudoers_file"
            chmod 440 "$sudoers_file"
            if visudo -cf "$sudoers_file" &>/dev/null; then
                log "INFO" "Sudo access granted to: $username"
            else
                rm -f "$sudoers_file"
                log "ERROR" "Invalid sudoers syntax; file removed for: $username"
                return 1
            fi
            ;;
        grant-passwd)
            echo "${username} ALL=(ALL) ALL" > "$sudoers_file"
            chmod 440 "$sudoers_file"
            visudo -cf "$sudoers_file" &>/dev/null && \
                log "INFO" "Password-required sudo granted to: $username"
            ;;
        revoke)
            if [[ -f "$sudoers_file" ]]; then
                rm -f "$sudoers_file"
                log "INFO" "Sudo access revoked for: $username"
            else
                log "WARN" "No sudoers entry found for: $username"
            fi
            ;;
        *)
            log "ERROR" "Unknown sudo action: $action (use: grant|grant-passwd|revoke)"
            return 1
            ;;
    esac
}

# --- Disable a user account ---
disable_user() {
    local username="$1"

    if ! id "$username" &>/dev/null; then
        log "ERROR" "User does not exist: $username"
        return 1
    fi

    usermod --lock --shell /sbin/nologin "$username" 2>/dev/null
    # Revoke SSH keys
    local auth_keys="/home/${username}/.ssh/authorized_keys"
    if [[ -f "$auth_keys" ]]; then
        mv "$auth_keys" "${auth_keys}.disabled.$(date +%Y%m%d)"
        log "INFO" "SSH authorized_keys disabled for: $username"
    fi
    # Revoke sudo
    manage_sudo "$username" revoke

    log "INFO" "User account disabled: $username"
}

# --- Delete a user account ---
delete_user() {
    local username="$1"
    local keep_home="${2:-false}"

    if ! id "$username" &>/dev/null; then
        log "ERROR" "User does not exist: $username"
        return 1
    fi

    disable_user "$username"

    if [[ "$keep_home" == "true" ]]; then
        userdel "$username"
        log "INFO" "User deleted (home kept): $username"
    else
        userdel --remove "$username"
        log "INFO" "User deleted (home removed): $username"
    fi
}

# --- Bulk provision from CSV file ---
# CSV format: username,groups,ssh_key_path,sudo_access(yes/no),comment
bulk_provision() {
    local csv_file="$1"

    if [[ ! -f "$csv_file" ]]; then
        log "ERROR" "CSV file not found: $csv_file"
        return 1
    fi

    log "INFO" "Starting bulk provisioning from: $csv_file"
    local success=0 failed=0

    while IFS=',' read -r username groups ssh_key_path sudo_access comment; do
        # Skip header and blank lines
        [[ "$username" =~ ^#|^username|^$ ]] && continue
        username=$(echo "$username" | xargs)

        log "INFO" "Provisioning: $username"

        if create_user "$username" "$groups" "${comment:-Bulk Provisioned}"; then
            if [[ -n "$ssh_key_path" && "$ssh_key_path" != "-" ]]; then
                deploy_ssh_key "$username" "$ssh_key_path"
            fi
            if [[ "$sudo_access" == "yes" ]]; then
                manage_sudo "$username" grant
            fi
            harden_ssh_config "$username"
            (( success++ ))
        else
            (( failed++ ))
        fi
    done < "$csv_file"

    log "INFO" "Bulk provisioning complete: $success succeeded, $failed failed"
}

# --- List all SysGuard-provisioned users ---
list_users() {
    echo "============================================"
    echo "  SysGuard Provisioned Users - $HOSTNAME"
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================================"
    grep "SysGuard Provisioned\|Bulk Provisioned" /etc/passwd | \
        awk -F: '{printf "%-20s %-6s %-30s\n", $1, $3, $7}' || \
        echo "No SysGuard-provisioned users found."
    echo "============================================"
}

# --- SSH hardening for sshd_config ---
harden_sshd() {
    local sshd_config="/etc/ssh/sshd_config"
    local backup="${sshd_config}.bak.$(date +%Y%m%d)"

    cp "$sshd_config" "$backup"
    log "INFO" "Backed up sshd_config to: $backup"

    declare -A settings=(
        ["PermitRootLogin"]="no"
        ["PasswordAuthentication"]="no"
        ["X11Forwarding"]="no"
        ["MaxAuthTries"]="3"
        ["LoginGraceTime"]="30"
        ["PermitEmptyPasswords"]="no"
        ["Protocol"]="2"
        ["ClientAliveInterval"]="300"
        ["ClientAliveCountMax"]="2"
    )

    for key in "${!settings[@]}"; do
        local value="${settings[$key]}"
        if grep -qE "^#?${key}\s" "$sshd_config"; then
            sed -i "s/^#\?${key}\s.*/${key} ${value}/" "$sshd_config"
        else
            echo "${key} ${value}" >> "$sshd_config"
        fi
        log "INFO" "sshd_config: set $key = $value"
    done

    if sshd -t 2>/dev/null; then
        systemctl reload sshd 2>/dev/null || service sshd reload 2>/dev/null
        log "INFO" "sshd configuration validated and reloaded"
    else
        cp "$backup" "$sshd_config"
        log "ERROR" "sshd config validation failed; original restored from backup"
        return 1
    fi
}

# --- Entry point ---
usage() {
    cat <<EOF
Usage: $0 <command> [options]

Commands:
  create   <username> [groups] [comment]          Create a new user
  ssh-key  <username> <pubkey-file|key-string>    Deploy SSH public key
  sudo     <username> <grant|grant-passwd|revoke> Manage sudo access
  disable  <username>                             Lock and disable account
  delete   <username> [keep-home]                 Delete user account
  bulk     <csv-file>                             Bulk provision from CSV
  list                                            List provisioned users
  harden-ssh                                      Harden sshd_config
EOF
}

case "${1:-}" in
    create)      create_user "${2:-}" "${3:-}" "${4:-}" ;;
    ssh-key)     deploy_ssh_key "${2:-}" "${3:-}" ;;
    sudo)        manage_sudo "${2:-}" "${3:-grant}" ;;
    disable)     disable_user "${2:-}" ;;
    delete)      delete_user "${2:-}" "${3:-false}" ;;
    bulk)        bulk_provision "${2:-}" ;;
    list)        list_users ;;
    harden-ssh)  harden_sshd ;;
    *)           usage; exit 1 ;;
esac
