# SysGuard – Linux Server Monitoring & Automation Toolkit

![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnubash&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-Ubuntu%20%7C%20CentOS-blue)
![License](https://img.shields.io/badge/License-MIT-yellow)
![Status](https://img.shields.io/badge/Status-Active-brightgreen)

A production-ready Bash scripting toolkit for Linux server monitoring, user management, and backup automation. Built for Ubuntu and CentOS/RHEL environments, SysGuard automates routine sysadmin tasks with alerting, logging, and systemd integration.

---

## Features

| Module | Capability |
|---|---|
| **System Monitor** | CPU, memory, disk, and swap usage alerts via cron |
| **Service Health** | systemd service checks with auto-restart and escalation |
| **Log Rotation** | Configurable retention, size-based rotation, gzip compression |
| **User Provisioning** | Automated user creation, SSH key deployment, sudoers management |
| **Backup Automation** | Incremental rsync backups with snapshot rotation and email alerts |

---

## Project Structure

```
sysguard/
├── config/
│   └── sysguard.conf           # Central configuration file
├── monitoring/
│   ├── system_monitor.sh       # CPU / memory / disk alerts
│   ├── service_health.sh       # systemd service health checks
│   └── log_rotation.sh         # Log rotation with configurable retention
├── user-management/
│   ├── provision_users.sh      # User creation, SSH key deploy, sudo management
│   └── users_sample.csv        # Sample CSV for bulk provisioning
├── backup/
│   └── backup.sh               # rsync incremental backup with email alerts
├── logs/                        # Runtime log output (auto-created)
└── install_crons.sh             # Cron job installer
```

---

## Quick Start

### 1. Clone the repository

```bash
git clone https://github.com/yourusername/sysguard.git
cd sysguard
```

### 2. Configure

Edit `config/sysguard.conf` with your thresholds, email, and paths:

```bash
# Alert thresholds
CPU_THRESHOLD=85
MEM_THRESHOLD=80
DISK_THRESHOLD=90

# Email for all alerts
ALERT_EMAIL="admin@example.com"

# Services to monitor
MONITORED_SERVICES=("nginx" "sshd" "cron" "rsyslog")

# Backup sources
BACKUP_SOURCES=("/etc:etc_config" "/home:home_dirs")
```

### 3. Make scripts executable

```bash
chmod +x monitoring/*.sh user-management/*.sh backup/*.sh install_crons.sh
```

### 4. Install cron jobs (as root)

```bash
sudo ./install_crons.sh
```

---

## Modules

### System Monitor (`monitoring/system_monitor.sh`)

Monitors CPU, memory, disk, and swap usage. Sends email alerts when any metric breaches its configured threshold.

```bash
# Run manually
./monitoring/system_monitor.sh

# Runs automatically every 5 minutes via cron
```

**What it checks:**
- CPU usage via `top`
- Memory and swap via `free`
- Disk usage per mount point via `df`
- Includes top processes in alert emails

---

### Service Health (`monitoring/service_health.sh`)

Monitors systemd services and auto-restarts them if they go down. Tracks restart attempts per day; escalates to a critical alert when the max restart count is reached.

```bash
# Check all monitored services
./monitoring/service_health.sh check

# Print a status table
./monitoring/service_health.sh report

# Reset daily restart counters
./monitoring/service_health.sh reset
```

**Flow:**
1. Service is down → restart attempt
2. Restart succeeds → notify via email
3. Restart fails or max retries reached → critical alert, manual intervention required

---

### Log Rotation (`monitoring/log_rotation.sh`)

Rotates logs when they exceed a size threshold, compresses them with gzip, and deletes files older than the retention period.

```bash
# Rotate all logs (SysGuard + app logs)
./monitoring/log_rotation.sh all

# Rotate only SysGuard's own logs
./monitoring/log_rotation.sh sysguard

# Rotate only application log directories
./monitoring/log_rotation.sh apps

# View rotation summary
./monitoring/log_rotation.sh summary
```

**Configuration in `sysguard.conf`:**
```bash
RETENTION_DAYS=30       # Days to retain rotated files
MAX_LOG_SIZE_MB=100     # Rotate when log exceeds this size
COMPRESS_LOGS=true      # gzip compressed archives
APP_LOG_DIRS=("/var/log/nginx:14" "/var/log/mysql:30")
```

---

### User Provisioning (`user-management/provision_users.sh`)

Automates user lifecycle management: create, configure SSH keys, assign sudo, disable, and delete accounts. Supports bulk operations via CSV.

```bash
# Requires root

# Create a user with groups
sudo ./user-management/provision_users.sh create alice "sudo,developers" "Alice Smith"

# Deploy an SSH public key
sudo ./user-management/provision_users.sh ssh-key alice /path/to/alice.pub

# Grant or revoke sudo access
sudo ./user-management/provision_users.sh sudo alice grant
sudo ./user-management/provision_users.sh sudo alice revoke

# Disable an account (locks password + revokes SSH keys)
sudo ./user-management/provision_users.sh disable alice

# Delete a user
sudo ./user-management/provision_users.sh delete alice

# Bulk provision from CSV
sudo ./user-management/provision_users.sh bulk user-management/users_sample.csv

# List all SysGuard-provisioned users
sudo ./user-management/provision_users.sh list

# Harden sshd_config (disables root login, password auth, etc.)
sudo ./user-management/provision_users.sh harden-ssh
```

**CSV format for bulk provisioning:**
```csv
# username, groups, ssh_key_path, sudo_access, comment
alice, sudo,developers, /etc/sysguard/ssh_keys/alice.pub, yes, Lead Developer
bob,  developers,       /etc/sysguard/ssh_keys/bob.pub,   no,  Junior Developer
```

**Permission hardening applied automatically:**
- Home directory: `chmod 750`
- `.ssh/` directory: `chmod 700`
- `authorized_keys`: `chmod 600`
- Default umask: `027` (no world permissions)

---

### Backup (`backup/backup.sh`)

Performs incremental backups using rsync's `--link-dest` for space-efficient snapshots. Sends failure alerts with details; optionally sends a success report.

```bash
# Run all configured backups
./backup/backup.sh run

# Verify a backup label
./backup/backup.sh verify etc_config

# Prune snapshots older than N days
./backup/backup.sh prune etc_config 14

# Print a backup report
./backup/backup.sh report
```

**Configuration in `sysguard.conf`:**
```bash
BACKUP_DEST="/var/backups/sysguard"
BACKUP_RETENTION_DAYS=30
SEND_SUCCESS_REPORT=false

BACKUP_SOURCES=(
    "/etc:etc_config"
    "/home:home_dirs"
    "/var/www:web_data"
    "user@remote-host:/var/www:remote_web"   # remote via SSH
)

BACKUP_EXCLUDES=("*.tmp" "*.log" ".cache" "node_modules")
```

**Snapshot structure:**
```
/var/backups/sysguard/
└── etc_config/
    ├── current -> snapshots/2025-01-15_020000  (symlink)
    └── snapshots/
        ├── 2025-01-13_020000/
        ├── 2025-01-14_020000/
        └── 2025-01-15_020000/
```

---

## Cron Schedule

| Job | Schedule | Script |
|---|---|---|
| System monitor | Every 5 minutes | `monitoring/system_monitor.sh` |
| Service health | Every 2 minutes | `monitoring/service_health.sh check` |
| Log rotation | Daily at 02:00 | `monitoring/log_rotation.sh all` |
| Backup | Daily at 01:00 | `backup/backup.sh run` |
| Restart counter reset | Daily at midnight | `monitoring/service_health.sh reset` |
| Weekly backup report | Sundays at 03:00 | `backup/backup.sh report` |

Installed to `/etc/cron.d/sysguard` by `install_crons.sh`.

---

## Alert Emails

SysGuard sends alerts for:

- CPU/Memory/Disk exceeding thresholds
- Swap usage above 70%
- Service down or failed to restart
- Service hitting max restart limit (critical)
- Backup failure with rsync log excerpt
- Weekly backup status report (optional)

Configure the recipient in `sysguard.conf`:
```bash
ALERT_EMAIL="admin@example.com"
```

> **Prerequisite:** A mail agent must be installed (`mailutils` on Ubuntu, `mailx` on CentOS).
> ```bash
> # Ubuntu
> sudo apt-get install mailutils
> # CentOS
> sudo yum install mailx
> ```

---

## Tested Environments

- Ubuntu 20.04 LTS
- Ubuntu 22.04 LTS
- CentOS 7
- CentOS 8 / Rocky Linux 8

---

## Requirements

- Bash 4.x+
- rsync
- systemd (for service health checks)
- cron / crond
- mail agent for email alerts (`mailutils` / `mailx`)

---

## License

MIT License — free to use, modify, and distribute.

---

## Author

Built as part of a Linux systems administration portfolio project demonstrating:
- Bash scripting and automation
- systemd service management
- Cron scheduling
- rsync backup strategies
- Security hardening (SSH, sudoers, umask)
