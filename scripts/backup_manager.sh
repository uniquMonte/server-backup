#!/bin/bash

#######################################
# VPS Backup Manager
# Automated backup to cloud storage with encryption
#######################################

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Configuration paths
BACKUP_SCRIPT="/usr/local/bin/vps-backup.sh"
BACKUP_ENV="/usr/local/bin/vps-backup.env"
DEFAULT_LOG_FILE="/var/log/vps-backup.log"
DEFAULT_TMP_DIR="/tmp/vps-backups"

# Determine scripts path for locating restore script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_PATH="$SCRIPT_DIR"

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check if backup is configured
is_configured() {
    [ -f "$BACKUP_ENV" ] && [ -f "$BACKUP_SCRIPT" ]
}

# Get current logrotate configuration
get_logrotate_config() {
    local logrotate_conf="/etc/logrotate.d/vps-backup"

    if [ ! -f "$logrotate_conf" ]; then
        echo "Not configured"
        return 1
    fi

    # Parse size and rotate parameters
    local size=$(grep "^\s*size" "$logrotate_conf" | awk '{print $2}')
    local days=$(grep "^\s*rotate" "$logrotate_conf" | awk '{print $2}')

    if [ -n "$size" ] && [ -n "$days" ]; then
        echo "${size} / ${days} days"
        return 0
    else
        echo "Configured"
        return 0
    fi
}

# Load configuration
load_config() {
    if [ -f "$BACKUP_ENV" ]; then
        source "$BACKUP_ENV"
    fi

    # Apply default values for retention policy if not set
    RESTIC_KEEP_LAST="${RESTIC_KEEP_LAST:-7}"
    RESTIC_KEEP_DAILY="${RESTIC_KEEP_DAILY:-30}"
    RESTIC_KEEP_WEEKLY="${RESTIC_KEEP_WEEKLY:-8}"
    RESTIC_KEEP_MONTHLY="${RESTIC_KEEP_MONTHLY:-12}"
    RESTIC_KEEP_YEARLY="${RESTIC_KEEP_YEARLY:-3}"
}

# Check dependencies
check_dependency() {
    local tool="$1"
    if command -v "$tool" &> /dev/null; then
        echo -e "${GREEN}✓${NC} $tool"
        return 0
    else
        echo -e "${RED}✗${NC} $tool (not installed)"
        return 1
    fi
}

# Install rclone
install_rclone() {
    echo ""
    log_info "Installing rclone..."

    if command -v rclone &> /dev/null; then
        log_warning "rclone is already installed"
        return 0
    fi

    # Install rclone using official script
    curl https://rclone.org/install.sh | sudo bash

    if [ $? -eq 0 ]; then
        log_success "rclone installed successfully"
        return 0
    else
        log_error "Failed to install rclone"
        return 1
    fi
}

# Install restic
install_restic() {
    echo ""
    log_info "Installing restic..."

    if command -v restic &> /dev/null; then
        log_warning "restic is already installed"
        return 0
    fi

    # Detect architecture
    local arch=$(uname -m)
    local restic_arch=""

    case "$arch" in
        x86_64)
            restic_arch="amd64"
            ;;
        aarch64|arm64)
            restic_arch="arm64"
            ;;
        armv7l)
            restic_arch="arm"
            ;;
        *)
            log_error "Unsupported architecture: $arch"
            return 1
            ;;
    esac

    # Get latest version
    log_info "Fetching latest restic version..."
    local latest_version=$(curl -s https://api.github.com/repos/restic/restic/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')

    if [ -z "$latest_version" ]; then
        log_error "Failed to fetch latest restic version"
        return 1
    fi

    log_info "Downloading restic v${latest_version} for ${restic_arch}..."
    local download_url="https://github.com/restic/restic/releases/download/v${latest_version}/restic_${latest_version}_linux_${restic_arch}.bz2"

    cd /tmp
    curl -L -o restic.bz2 "$download_url"

    if [ $? -ne 0 ]; then
        log_error "Failed to download restic"
        return 1
    fi

    # Extract and install
    bunzip2 restic.bz2
    chmod +x restic
    mv restic /usr/local/bin/

    if command -v restic &> /dev/null; then
        log_success "restic installed successfully (version: v${latest_version})"
        return 0
    else
        log_error "Failed to install restic"
        return 1
    fi
}

# Install all dependencies (rclone and restic)
install_dependencies() {
    echo ""
    log_info "Installing dependencies..."

    local failed=false

    # Install rclone
    if ! command -v rclone &> /dev/null; then
        install_rclone || failed=true
    else
        log_warning "rclone is already installed"
    fi

    # Install restic
    if ! command -v restic &> /dev/null; then
        install_restic || failed=true
    else
        log_warning "restic is already installed"
    fi

    echo ""
    if [ "$failed" = true ]; then
        log_error "Some dependencies failed to install"
        return 1
    else
        log_success "All dependencies are installed"
        return 0
    fi
}

# Show current configuration status
show_status() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}VPS Backup Manager Status${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Check dependencies
    echo -e "${GREEN}Dependencies:${NC}"
    local deps_ok=true
    check_dependency "tar" || deps_ok=false
    check_dependency "openssl" || deps_ok=false
    check_dependency "curl" || deps_ok=false
    check_dependency "rclone" || deps_ok=false
    check_dependency "restic" || deps_ok=false

    echo ""

    if is_configured; then
        load_config

        echo -e "${GREEN}Configuration Status:${NC}  ${GREEN}Configured ✓${NC}"
        echo ""

        # Display backup sources
        if [ -n "$BACKUP_SRCS" ]; then
            echo -e "${GREEN}Backup Sources:${NC}"
            IFS='|' read -ra SOURCES <<< "$BACKUP_SRCS"
            for src in "${SOURCES[@]}"; do
                if [ -d "$src" ] || [ -f "$src" ]; then
                    echo -e "  ${GREEN}✓${NC} $src"
                else
                    echo -e "  ${YELLOW}⚠${NC} $src (not found)"
                fi
            done
        else
            echo -e "${YELLOW}Backup Sources:${NC}    Not configured"
        fi

        echo ""
        echo -e "${GREEN}Configuration Details:${NC}"
        echo -e "  Backup Method:     ${CYAN}${BACKUP_METHOD:-incremental}${NC}"
        echo -e "  Remote Directory:  ${CYAN}${BACKUP_REMOTE_DIR:-Not set}${NC}"

        # Check and display backup schedule
        if crontab -l 2>/dev/null | grep -q "$BACKUP_SCRIPT"; then
            local cron_line=$(crontab -l 2>/dev/null | grep "$BACKUP_SCRIPT" | head -1)
            local cron_schedule=$(echo "$cron_line" | awk '{print $1, $2, $3, $4, $5}')

            # Parse cron schedule to human-readable format
            local cron_desc=""
            if [[ "$cron_schedule" =~ ^0\ ([0-9]+)\ \*\ \*\ \*$ ]]; then
                local hour="${BASH_REMATCH[1]}"
                cron_desc="Daily at ${hour}:00"
            elif [[ "$cron_schedule" =~ ^0\ \*/([0-9]+)\ \*\ \*\ \*$ ]]; then
                local interval="${BASH_REMATCH[1]}"
                cron_desc="Every ${interval} hours"
            elif [[ "$cron_schedule" =~ ^0\ ([0-9]+)\ \*\ \*\ ([0-9]+)$ ]]; then
                local hour="${BASH_REMATCH[1]}"
                local day="${BASH_REMATCH[2]}"
                case $day in
                    0) cron_desc="Weekly (Sunday ${hour}:00)" ;;
                    1) cron_desc="Weekly (Monday ${hour}:00)" ;;
                    2) cron_desc="Weekly (Tuesday ${hour}:00)" ;;
                    3) cron_desc="Weekly (Wednesday ${hour}:00)" ;;
                    4) cron_desc="Weekly (Thursday ${hour}:00)" ;;
                    5) cron_desc="Weekly (Friday ${hour}:00)" ;;
                    6) cron_desc="Weekly (Saturday ${hour}:00)" ;;
                esac
            else
                cron_desc="Custom ($cron_schedule)"
            fi
            echo -e "  Backup Schedule:   ${GREEN}${cron_desc}${NC}"
        else
            echo -e "  Backup Schedule:   ${YELLOW}Not scheduled${NC}"
        fi

        # Show retention policy based on backup method
        if [ "$BACKUP_METHOD" = "incremental" ]; then
            echo -e "  ${GREEN}Retention Policy:${NC}"
            [ -n "$RESTIC_KEEP_LAST" ] && [ "$RESTIC_KEEP_LAST" != "0" ] && echo -e "    Keep Last:       ${CYAN}${RESTIC_KEEP_LAST} backups${NC}"
            [ -n "$RESTIC_KEEP_DAILY" ] && [ "$RESTIC_KEEP_DAILY" != "0" ] && echo -e "    Keep Daily:      ${CYAN}${RESTIC_KEEP_DAILY} days${NC}"
            [ -n "$RESTIC_KEEP_WEEKLY" ] && [ "$RESTIC_KEEP_WEEKLY" != "0" ] && echo -e "    Keep Weekly:     ${CYAN}${RESTIC_KEEP_WEEKLY} weeks${NC}"
            [ -n "$RESTIC_KEEP_MONTHLY" ] && [ "$RESTIC_KEEP_MONTHLY" != "0" ] && echo -e "    Keep Monthly:    ${CYAN}${RESTIC_KEEP_MONTHLY} months${NC}"
            [ -n "$RESTIC_KEEP_YEARLY" ] && [ "$RESTIC_KEEP_YEARLY" != "0" ] && echo -e "    Keep Yearly:     ${CYAN}${RESTIC_KEEP_YEARLY} years${NC}"
        else
            echo -e "  Max Backups:       ${CYAN}${BACKUP_MAX_KEEP:-3}${NC}"
        fi

        # Encryption status
        if [ -n "$BACKUP_PASSWORD" ]; then
            echo -e "  Encryption:        ${GREEN}Enabled ✓${NC}"
        else
            echo -e "  Encryption:        ${YELLOW}Not configured${NC}"
        fi

        # Telegram notification status
        if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
            echo -e "  Telegram Notify:   ${GREEN}Enabled ✓${NC}"
            echo -e "    Bot Token:       ${CYAN}${TG_BOT_TOKEN:0:10}...${NC}"
            echo -e "    Chat ID:         ${CYAN}${TG_CHAT_ID}${NC}"
        else
            echo -e "  Telegram Notify:   ${YELLOW}Disabled${NC}"
        fi

        echo -e "  Backup Script:     ${CYAN}${BACKUP_SCRIPT}${NC}"
        echo -e "  Config File:       ${CYAN}${BACKUP_ENV}${NC}"
        echo -e "  Log File:          ${CYAN}${BACKUP_LOG_FILE:-$DEFAULT_LOG_FILE}${NC}"

        # Log rotation status
        local logrotate_status=$(get_logrotate_config)
        if [ "$logrotate_status" = "Not configured" ]; then
            echo -e "  Log Rotation:      ${YELLOW}${logrotate_status}${NC}"
        else
            echo -e "  Log Rotation:      ${GREEN}${logrotate_status}${NC}"
            echo -e "    Config:          ${CYAN}/etc/logrotate.d/vps-backup${NC}"
        fi

        echo -e "  Temp Directory:    ${CYAN}${BACKUP_TMP_DIR:-$DEFAULT_TMP_DIR}${NC}"

        # Check if rclone remote is configured
        echo ""
        if command -v rclone &> /dev/null && [ -n "$BACKUP_REMOTE_DIR" ]; then
            local remote_name=$(echo "$BACKUP_REMOTE_DIR" | cut -d':' -f1)
            if rclone listremotes | grep -q "^${remote_name}:$"; then
                echo -e "${GREEN}Rclone Remote:${NC}     ${GREEN}Configured ✓${NC} ($remote_name)"
            else
                echo -e "${YELLOW}Rclone Remote:${NC}     ${YELLOW}Not found${NC} ($remote_name)"
            fi
        fi

        # Check last backup
        if [ -f "${BACKUP_LOG_FILE:-$DEFAULT_LOG_FILE}" ]; then
            echo ""
            echo -e "${GREEN}Last Backup Activity:${NC}"
            local last_backup=$(grep "Backup process completed\|backup completed" "${BACKUP_LOG_FILE:-$DEFAULT_LOG_FILE}" | tail -1)
            if [ -n "$last_backup" ]; then
                echo -e "  ${CYAN}${last_backup}${NC}"
            else
                echo -e "  ${YELLOW}No backup history found${NC}"
            fi
        fi

    else
        echo -e "${YELLOW}Configuration Status:${NC}  ${YELLOW}Not configured${NC}"
        echo ""
        log_info "Backup manager is not configured yet"
        log_info "Use 'configure' option to set up backup"
    fi

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Configure backup sources
configure_backup_sources() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}Configure Backup Sources${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    local sources=()

    # Load existing sources if available
    if [ -n "$BACKUP_SRCS" ]; then
        IFS='|' read -ra sources <<< "$BACKUP_SRCS"
        echo ""
        echo -e "${GREEN}Current backup sources:${NC}"
        for i in "${!sources[@]}"; do
            echo -e "  $((i+1)). ${CYAN}${sources[$i]}${NC}"
        done
    fi

    echo ""
    echo -e "${YELLOW}Common directories to backup:${NC}"
    echo -e "  • /var/www/html (Web files)"
    echo -e "  • /etc/nginx (Nginx config)"
    echo -e "  • /etc/apache2 (Apache config)"
    echo -e "  • /home (User home directories)"
    echo -e "  • /opt (Optional software)"
    echo -e "  • /root (Root home directory)"

    echo ""
    log_info "Enter directories to backup (one per line)"
    log_info "Press Enter on empty line to finish"
    log_info "Enter 'clear' to clear all existing sources"

    echo ""
    local new_sources=()
    local counter=1

    while true; do
        read -p "Source #$counter: " source

        if [ -z "$source" ]; then
            break
        fi

        if [ "$source" = "clear" ]; then
            new_sources=()
            log_info "All sources cleared"
            counter=1
            continue
        fi

        # Expand ~ to home directory
        source="${source/#\~/$HOME}"

        # Check if path exists
        if [ -d "$source" ] || [ -f "$source" ]; then
            new_sources+=("$source")
            log_success "Added: $source"
            counter=$((counter+1))
        else
            log_warning "Path does not exist: $source"
            read -p "Add anyway? [y/N] (press Enter to skip): " add_anyway
            if [[ $add_anyway =~ ^[Yy]$ ]]; then
                new_sources+=("$source")
                log_info "Added: $source"
                counter=$((counter+1))
            fi
        fi
    done

    if [ ${#new_sources[@]} -eq 0 ]; then
        if [ ${#sources[@]} -gt 0 ]; then
            log_info "Keeping existing sources"
        else
            log_error "No backup sources configured"
            return 1
        fi
    else
        sources=("${new_sources[@]}")
    fi

    # Join array with |
    BACKUP_SRCS=$(IFS='|'; echo "${sources[*]}")

    echo ""
    echo -e "${GREEN}Final backup sources:${NC}"
    IFS='|' read -ra FINAL_SOURCES <<< "$BACKUP_SRCS"
    for src in "${FINAL_SOURCES[@]}"; do
        echo -e "  ${GREEN}✓${NC} $src"
    done

    return 0
}

# Setup rclone remote
setup_rclone() {
    echo ""
    log_info "Setting up rclone remote..."

    if ! command -v rclone &> /dev/null; then
        log_error "rclone is not installed"
        read -p "Install rclone now? [Y/n] (press Enter to confirm): " install
        if [[ ! $install =~ ^[Nn]$ ]]; then
            install_rclone || return 1
        else
            return 1
        fi
    fi

    echo ""
    log_info "Current rclone remotes:"
    rclone listremotes

    echo ""
    echo -e "${YELLOW}Options:${NC}"
    echo -e "  1. Configure new remote"
    echo -e "  2. Use existing remote"
    echo -e "  3. Skip (configure later manually)"
    echo ""
    read -p "Select option [1-3]: " option

    case $option in
        1)
            log_info "Launching rclone config..."
            echo ""
            log_info "Common remotes: Google Drive (gdrive), Dropbox, OneDrive, S3, etc."
            echo ""
            rclone config
            ;;
        2)
            log_info "Using existing remote"
            ;;
        3)
            log_info "Skipping rclone setup"
            log_warning "You'll need to configure rclone manually: rclone config"
            return 0
            ;;
        *)
            log_error "Invalid option"
            return 1
            ;;
    esac

    return 0
}

# Full configuration wizard
configure_backup() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}Backup Configuration Wizard${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Load existing config if available
    load_config

    # Step 1: Choose backup method
    echo ""
    log_info "Step 1/9: Choose Backup Method"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}Select Backup Method${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${GREEN}Choose the backup method for your VPS:${NC}"
    echo ""
    echo -e "  ${GREEN}1.${NC} ${GREEN}Incremental Backup (Recommended) - Using restic${NC}"
    echo -e "     ${CYAN}• Only backs up changed data${NC}"
    echo -e "     ${CYAN}• Faster backup and restore${NC}"
    echo -e "     ${CYAN}• Efficient storage usage${NC}"
    echo -e "     ${CYAN}• Automatic deduplication${NC}"
    echo ""
    echo -e "  ${CYAN}2.${NC} Full Backup - Using tar + openssl + rclone"
    echo -e "     ${CYAN}• Complete backup every time${NC}"
    echo -e "     ${CYAN}• Simple and reliable${NC}"
    echo -e "     ${CYAN}• More storage space required${NC}"
    echo ""

    if [ -n "$BACKUP_METHOD" ]; then
        local default_choice="1"
        [ "$BACKUP_METHOD" = "full" ] && default_choice="2"
        echo -e "Current method: ${CYAN}$BACKUP_METHOD${NC}"
        read -p "Select backup method [1-2] (press Enter for incremental): " method_choice
        method_choice="${method_choice:-$default_choice}"
    else
        read -p "Select backup method [1-2] (press Enter for incremental): " method_choice
        method_choice="${method_choice:-1}"
    fi

    case $method_choice in
        1)
            BACKUP_METHOD="incremental"
            log_success "Selected: Incremental backup (restic)"
            ;;
        2)
            BACKUP_METHOD="full"
            log_success "Selected: Full backup (tar + openssl)"
            ;;
        *)
            log_error "Invalid choice, using incremental backup (default)"
            BACKUP_METHOD="incremental"
            ;;
    esac

    # Step 2: Configure backup sources
    echo ""
    log_info "Step 2/9: Configure Backup Sources"
    configure_backup_sources || return 1

    # Step 3: Configure remote directory
    echo ""
    log_info "Step 3/9: Configure Remote Storage"
    echo ""

    # First, configure hostname identifier for this VPS
    local current_hostname=$(hostname)

    # Loop to allow re-entering hostname if remote path exists
    while true; do
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${CYAN}Configure VPS Identifier${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "Each VPS should have a unique identifier to avoid backup conflicts."
        echo -e "This will be used in the backup path: ${CYAN}vps-{identifier}-backup${NC}"
        echo ""

        if [ -n "$BACKUP_HOSTNAME" ]; then
            echo -e "Current identifier: ${CYAN}${BACKUP_HOSTNAME}${NC}"
            echo -e "System hostname: ${CYAN}${current_hostname}${NC}"
            echo ""
            read -p "VPS identifier [${BACKUP_HOSTNAME}] (press Enter to keep current): " hostname_input
            BACKUP_HOSTNAME="${hostname_input:-$BACKUP_HOSTNAME}"
        else
            echo -e "Detected system hostname: ${GREEN}${current_hostname}${NC}"
            echo ""
            read -p "VPS identifier [${current_hostname}] (press Enter to use system hostname): " hostname_input
            BACKUP_HOSTNAME="${hostname_input:-$current_hostname}"
        fi

        # Sanitize hostname (remove special characters, convert to lowercase)
        BACKUP_HOSTNAME=$(echo "$BACKUP_HOSTNAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
        log_success "VPS identifier set to: ${BACKUP_HOSTNAME}"

        # Break from loop - will check remote path later after full path is constructed
        break
    done
    echo ""

    # Now configure the remote
    if command -v rclone &> /dev/null; then
        local existing_remotes=$(rclone listremotes 2>/dev/null)
        if [ -n "$existing_remotes" ]; then
            echo -e "${GREEN}Found existing rclone remotes:${NC}"
            echo "$existing_remotes" | nl
            echo ""

            local remote_count=$(echo "$existing_remotes" | wc -l)

            # Unified prompt for both single and multiple remotes
            if [ $remote_count -eq 1 ]; then
                # Single remote: default to use it (most common case)
                local remote_name=$(echo "$existing_remotes" | head -1 | tr -d ':')
                echo -e "${CYAN}Options:${NC}"
                echo -e "  ${GREEN}1.${NC} Use existing ${CYAN}${remote_name}${NC}"
                echo -e "  ${GREEN}0.${NC} Manual input (other config)"
                echo ""
                read -p "Select [1 or 0] (press Enter to use existing): " remote_choice
                remote_choice="${remote_choice:-1}"
            else
                # Multiple remotes: require explicit choice (no default)
                echo -e "${CYAN}Options:${NC}"
                echo "$existing_remotes" | nl | sed 's/^/  /'
                echo -e "  ${GREEN}0.${NC} Manual input (other config)"
                echo ""

                # Loop until valid input
                while true; do
                    read -p "Select [1-${remote_count} or 0]: " remote_choice

                    if [[ -z "$remote_choice" ]]; then
                        log_warning "Please select an option"
                        continue
                    fi

                    if [[ $remote_choice =~ ^[0-9]+$ ]] && [ $remote_choice -ge 0 ] && [ $remote_choice -le $remote_count ]; then
                        break
                    else
                        log_error "Invalid choice, please enter 0-${remote_count}"
                    fi
                done
            fi

            # Process user choice
            if [[ $remote_choice =~ ^[1-9][0-9]*$ ]] && [ $remote_choice -ge 1 ] && [ $remote_choice -le $remote_count ]; then
                # User selected an existing remote
                local selected_remote=$(echo "$existing_remotes" | sed -n "${remote_choice}p" | tr -d ':')
                log_success "Selected remote: ${selected_remote}"
                echo ""
                local default_path="vps-${BACKUP_HOSTNAME}-backup"
                echo -e "${CYAN}Suggested path: ${default_path}${NC}"
                read -p "Remote directory path [${default_path}] (press Enter for default): " remote_path
                remote_path="${remote_path:-$default_path}"
                BACKUP_REMOTE_DIR="${selected_remote}:${remote_path}"
                log_success "Full path: $BACKUP_REMOTE_DIR"
            else
                # Manual input - user chose 0 or pressed Enter (for multiple) or chose 2 (for single)
                local default_full_path="gdrive:vps-${BACKUP_HOSTNAME}-backup"
                if [ -n "$BACKUP_REMOTE_DIR" ]; then
                    echo -e "Current config: ${CYAN}$BACKUP_REMOTE_DIR${NC}"
                    default_full_path="$BACKUP_REMOTE_DIR"
                fi
                log_info "Format: remote_name:path (e.g. gdrive:vps-${BACKUP_HOSTNAME}-backup)"
                read -p "Remote directory [${default_full_path}] (press Enter for default): " remote_dir
                BACKUP_REMOTE_DIR="${remote_dir:-${default_full_path}}"
            fi
        else
            # No existing remotes
            log_info "No existing rclone remotes found"
            local default_full_path="gdrive:vps-${BACKUP_HOSTNAME}-backup"
            if [ -n "$BACKUP_REMOTE_DIR" ]; then
                echo -e "Current config: ${CYAN}$BACKUP_REMOTE_DIR${NC}"
                default_full_path="$BACKUP_REMOTE_DIR"
            fi
            log_info "Format: remote_name:path (e.g. gdrive:vps-${BACKUP_HOSTNAME}-backup)"
            read -p "Remote directory [${default_full_path}] (press Enter for default): " remote_dir
            BACKUP_REMOTE_DIR="${remote_dir:-${default_full_path}}"
        fi
    else
        # rclone not installed
        log_warning "rclone is not installed"
        local default_full_path="gdrive:vps-${BACKUP_HOSTNAME}-backup"
        if [ -n "$BACKUP_REMOTE_DIR" ]; then
            echo -e "Current config: ${CYAN}$BACKUP_REMOTE_DIR${NC}"
            default_full_path="$BACKUP_REMOTE_DIR"
        fi
        log_info "Format: remote_name:path (e.g. gdrive:vps-${BACKUP_HOSTNAME}-backup)"
        read -p "Remote directory [${default_full_path}] (press Enter for default): " remote_dir
        BACKUP_REMOTE_DIR="${remote_dir:-${default_full_path}}"
    fi

    # Check if remote path already exists
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}Checking Remote Path${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    log_info "Remote path: ${BACKUP_REMOTE_DIR}"

    if command -v rclone &> /dev/null; then
        local remote_name_check=$(echo "$BACKUP_REMOTE_DIR" | cut -d':' -f1)
        if rclone listremotes 2>/dev/null | grep -q "^${remote_name_check}:$"; then
            log_info "Checking if path exists on remote..."
            if rclone lsd "${BACKUP_REMOTE_DIR}" &> /dev/null 2>&1; then
                echo ""
                echo -e "${YELLOW}⚠️  WARNING: Remote path already exists!${NC}"
                echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                echo -e "${RED}Path:${NC} ${CYAN}${BACKUP_REMOTE_DIR}${NC}"
                echo ""
                echo -e "${YELLOW}Possible consequences if you continue:${NC}"
                echo -e "  • ${RED}Existing backups may be overwritten${NC}"
                echo -e "  • ${RED}Backups from different servers may be mixed${NC}"
                echo -e "  • ${RED}Old backups may be deleted (based on retention policy)${NC}"
                echo ""
                echo -e "${GREEN}Recommendations:${NC}"
                echo -e "  1. Use a different VPS identifier (e.g., csthk, tokyo, uswest)"
                echo -e "  2. Manually specify a different remote path"
                echo -e "  3. Only continue if you're SURE this is correct"
                echo ""

                while true; do
                    echo -e "${CYAN}What would you like to do?${NC}"
                    echo -e "  ${GREEN}1.${NC} Continue with existing path (may overwrite!)"
                    echo -e "  ${GREEN}2.${NC} Change VPS identifier and regenerate path"
                    echo -e "  ${GREEN}3.${NC} Manually enter a different path"
                    echo ""
                    read -p "Select [1-3]: " path_choice

                    case $path_choice in
                        1)
                            log_warning "Continuing with existing path: ${BACKUP_REMOTE_DIR}"
                            break
                            ;;
                        2)
                            echo ""
                            echo -e "Current identifier: ${CYAN}${BACKUP_HOSTNAME}${NC}"
                            read -p "Enter new VPS identifier: " new_id
                            if [ -n "$new_id" ]; then
                                BACKUP_HOSTNAME=$(echo "$new_id" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
                                local new_path="vps-${BACKUP_HOSTNAME}-backup"
                                BACKUP_REMOTE_DIR="${remote_name_check}:${new_path}"
                                log_success "New path: ${BACKUP_REMOTE_DIR}"
                                # Re-check if new path exists (recursive check would go here, but keep it simple)
                                if rclone lsd "${BACKUP_REMOTE_DIR}" &> /dev/null 2>&1; then
                                    log_warning "New path also exists. Continuing anyway..."
                                else
                                    log_success "New path is available ✓"
                                fi
                                break
                            else
                                log_error "No identifier entered, keeping current"
                            fi
                            ;;
                        3)
                            echo ""
                            read -p "Enter full remote path (e.g., gdrive:vps-myserver-backup): " manual_path

                            if [ -n "$manual_path" ]; then
                                BACKUP_REMOTE_DIR="$manual_path"
                                log_success "Path set to: ${BACKUP_REMOTE_DIR}"
                                break
                            fi
                            ;;
                        *)
                            log_error "Invalid choice, please select 1-3"
                            ;;
                    esac
                done
                echo ""
            else
                echo -e "  ${GREEN}✓${NC} Path is available (does not exist yet)"
            fi
        else
            log_info "Remote not configured yet, will check after rclone setup"
        fi
    else
        log_info "rclone not installed yet, will check after installation"
    fi

    # Step 4: Setup rclone/restic if needed
    echo ""
    if [ "$BACKUP_METHOD" = "incremental" ]; then
        log_info "Step 4/9: Configure Restic"
        # Check if restic is installed
        if ! command -v restic &> /dev/null; then
            log_warning "restic is not installed"
            read -p "Install restic now? [Y/n] (press Enter to confirm): " install
            if [[ ! $install =~ ^[Nn]$ ]]; then
                install_restic || return 1
            else
                log_error "restic is required for incremental backup"
                return 1
            fi
        else
            log_success "restic is already installed ✓"
        fi
    else
        log_info "Step 4/9: Configure Rclone"
    fi
    local remote_name=$(echo "$BACKUP_REMOTE_DIR" | cut -d':' -f1)
    if command -v rclone &> /dev/null; then
        if rclone listremotes | grep -q "^${remote_name}:$"; then
            log_success "Rclone remote '$remote_name' already configured ✓"
        else
            log_warning "Rclone remote '$remote_name' not found"
            read -p "Configure rclone now? [Y/n] (press Enter to confirm): " setup
            if [[ ! $setup =~ ^[Nn]$ ]]; then
                setup_rclone
            fi
        fi
    else
        log_warning "rclone is not installed"
        read -p "Install and configure rclone now? [Y/n] (press Enter to confirm): " install
        if [[ ! $install =~ ^[Nn]$ ]]; then
            install_rclone && setup_rclone
        fi
    fi

    # Step 5: Configure encryption password
    echo ""
    log_info "Step 5/9: Configure Encryption"
    echo ""
    if [ -n "$BACKUP_PASSWORD" ]; then
        echo -e "Current password: ${CYAN}${BACKUP_PASSWORD:0:3}***${NC}"
        read -p "Change password? [y/N] (press Enter to skip): " change_pass
        if [[ ! $change_pass =~ ^[Yy]$ ]]; then
            log_info "Keeping existing password"
        else
            read -sp "Enter encryption password: " BACKUP_PASSWORD
            echo ""
            read -sp "Confirm password: " pass_confirm
            echo ""
            if [ "$BACKUP_PASSWORD" != "$pass_confirm" ]; then
                log_error "Passwords do not match"
                return 1
            fi
        fi
    else
        read -sp "Enter encryption password: " BACKUP_PASSWORD
        echo ""
        read -sp "Confirm password: " pass_confirm
        echo ""
        if [ "$BACKUP_PASSWORD" != "$pass_confirm" ]; then
            log_error "Passwords do not match"
            return 1
        fi
    fi

    # Step 6: Configure Telegram notifications (recommended)
    echo ""
    log_info "Step 6/9: Configure Telegram Notifications (Recommended)"
    echo ""
    read -p "Enable Telegram notifications? [Y/n] (press Enter to enable): " enable_tg
    if [[ ! $enable_tg =~ ^[Nn]$ ]]; then
        if [ -n "$TG_BOT_TOKEN" ]; then
            read -p "Telegram Bot Token [${TG_BOT_TOKEN}] (press Enter to keep current): " bot_token
        else
            read -p "Telegram Bot Token: " bot_token
        fi
        TG_BOT_TOKEN="${bot_token:-$TG_BOT_TOKEN}"

        if [ -n "$TG_CHAT_ID" ]; then
            read -p "Telegram Chat ID [${TG_CHAT_ID}] (press Enter to keep current): " chat_id
        else
            read -p "Telegram Chat ID: " chat_id
        fi
        TG_CHAT_ID="${chat_id:-$TG_CHAT_ID}"
    else
        log_info "Telegram notifications disabled"
        TG_BOT_TOKEN=""
        TG_CHAT_ID=""
    fi

    # Step 7: Other settings
    echo ""
    log_info "Step 7/9: Additional Settings"
    echo ""

    # Retention policy configuration
    if [ "$BACKUP_METHOD" = "incremental" ]; then
        echo -e "${GREEN}Restic Retention Policy${NC}"
        echo "Configure how many backups to keep for different time periods."
        echo "Leave empty to skip that retention policy."
        echo ""

        read -p "Keep last N backups [${RESTIC_KEEP_LAST:-7}]: " keep_last
        RESTIC_KEEP_LAST="${keep_last:-${RESTIC_KEEP_LAST:-7}}"

        read -p "Keep daily backups for N days [${RESTIC_KEEP_DAILY:-30}]: " keep_daily
        RESTIC_KEEP_DAILY="${keep_daily:-${RESTIC_KEEP_DAILY:-30}}"

        read -p "Keep weekly backups for N weeks [${RESTIC_KEEP_WEEKLY:-8}]: " keep_weekly
        RESTIC_KEEP_WEEKLY="${keep_weekly:-${RESTIC_KEEP_WEEKLY:-8}}"

        read -p "Keep monthly backups for N months [${RESTIC_KEEP_MONTHLY:-12}]: " keep_monthly
        RESTIC_KEEP_MONTHLY="${keep_monthly:-${RESTIC_KEEP_MONTHLY:-12}}"

        read -p "Keep yearly backups for N years [${RESTIC_KEEP_YEARLY:-3}]: " keep_yearly
        RESTIC_KEEP_YEARLY="${keep_yearly:-${RESTIC_KEEP_YEARLY:-3}}"

        echo ""
    else
        read -p "Max backups to keep [${BACKUP_MAX_KEEP:-3}] (press Enter for default): " max_keep
        BACKUP_MAX_KEEP="${max_keep:-${BACKUP_MAX_KEEP:-3}}"
    fi

    read -p "Log file path [${BACKUP_LOG_FILE:-$DEFAULT_LOG_FILE}] (press Enter for default): " log_file
    BACKUP_LOG_FILE="${log_file:-${BACKUP_LOG_FILE:-$DEFAULT_LOG_FILE}}"

    read -p "Temp directory [${BACKUP_TMP_DIR:-$DEFAULT_TMP_DIR}] (press Enter for default): " tmp_dir
    BACKUP_TMP_DIR="${tmp_dir:-${BACKUP_TMP_DIR:-$DEFAULT_TMP_DIR}}"

    # Save configuration
    echo ""
    log_info "Saving configuration..."
    save_config

    # Create backup script
    create_backup_script

    # Step 8: Configure log rotation
    echo ""
    log_info "Step 8/9: Configure Log Rotation"
    echo ""
    echo -e "${GREEN}Configure automatic log rotation to prevent disk space issues${NC}"
    echo ""
    echo -e "${CYAN}Recommended settings:${NC}"
    echo -e "  • Max log size: ${GREEN}10MB${NC} (rotate when file reaches this size)"
    echo -e "  • Keep logs: ${GREEN}7 days${NC} (older logs will be deleted)"
    echo ""
    read -p "Use default settings? [Y/n] (press Enter for defaults): " use_log_defaults

    local log_max_size="10M"
    local log_keep_days="7"

    if [[ $use_log_defaults =~ ^[Nn]$ ]]; then
        echo ""
        echo -e "${CYAN}Custom log rotation settings:${NC}"
        echo ""
        read -p "Max log file size (e.g., 10M, 50M, 100M) [10M]: " custom_size
        log_max_size="${custom_size:-10M}"

        read -p "Number of days to keep logs [7]: " custom_days
        log_keep_days="${custom_days:-7}"

        echo ""
        log_info "Custom settings: Max size ${log_max_size}, Keep ${log_keep_days} days"
    else
        log_info "Using default settings: Max size 10MB, Keep 7 days"
    fi

    setup_logrotate "$log_max_size" "$log_keep_days"

    # Step 9: Configure automatic backup schedule
    echo ""
    log_info "Step 9/9: Setup Automatic Backup Schedule"
    echo ""
    echo -e "${GREEN}Would you like to enable automatic backups?${NC}"
    echo ""
    read -p "Enable automatic backup schedule? [Y/n] (press Enter to enable): " enable_cron

    if [[ ! $enable_cron =~ ^[Nn]$ ]]; then
        echo ""
        echo -e "${CYAN}Backup Frequency:${NC}"
        echo -e "  ${GREEN}1.${NC} Daily (default)"
        echo -e "  ${GREEN}2.${NC} Every 12 hours"
        echo -e "  ${GREEN}3.${NC} Weekly (Sunday)"
        echo -e "  ${GREEN}0.${NC} Skip automatic backup setup"
        echo ""
        read -p "Select frequency [1-3,0] (press Enter for daily): " freq_choice
        freq_choice="${freq_choice:-1}"

        case $freq_choice in
            1)
                # Daily backup - ask for time
                echo ""
                echo -e "${CYAN}Select backup time (hour in 24h format):${NC}"
                echo -e "  ${GREEN}Recommended:${NC} 2-4 AM (low activity hours)"
                echo ""
                read -p "Hour [0-23] (press Enter for 2 AM): " backup_hour
                backup_hour="${backup_hour:-2}"

                # Validate hour
                if ! [[ "$backup_hour" =~ ^[0-9]+$ ]] || [ "$backup_hour" -lt 0 ] || [ "$backup_hour" -gt 23 ]; then
                    log_warning "Invalid hour, using default (2 AM)"
                    backup_hour=2
                fi

                local cron_schedule="0 $backup_hour * * *"
                local cron_cmd="$cron_schedule $BACKUP_SCRIPT >> ${BACKUP_LOG_FILE:-$DEFAULT_LOG_FILE} 2>&1"
                crontab -l 2>/dev/null | grep -v "$BACKUP_SCRIPT" | { cat; echo "$cron_cmd"; } | crontab -
                log_success "Daily backup scheduled at ${backup_hour}:00"
                ;;
            2)
                # Every 12 hours
                local cron_schedule="0 */12 * * *"
                local cron_cmd="$cron_schedule $BACKUP_SCRIPT >> ${BACKUP_LOG_FILE:-$DEFAULT_LOG_FILE} 2>&1"
                crontab -l 2>/dev/null | grep -v "$BACKUP_SCRIPT" | { cat; echo "$cron_cmd"; } | crontab -
                log_success "Backup scheduled every 12 hours"
                ;;
            3)
                # Weekly on Sunday
                echo ""
                read -p "Hour [0-23] (press Enter for 2 AM): " backup_hour
                backup_hour="${backup_hour:-2}"

                if ! [[ "$backup_hour" =~ ^[0-9]+$ ]] || [ "$backup_hour" -lt 0 ] || [ "$backup_hour" -gt 23 ]; then
                    log_warning "Invalid hour, using default (2 AM)"
                    backup_hour=2
                fi

                local cron_schedule="0 $backup_hour * * 0"
                local cron_cmd="$cron_schedule $BACKUP_SCRIPT >> ${BACKUP_LOG_FILE:-$DEFAULT_LOG_FILE} 2>&1"
                crontab -l 2>/dev/null | grep -v "$BACKUP_SCRIPT" | { cat; echo "$cron_cmd"; } | crontab -
                log_success "Weekly backup scheduled (Sunday at ${backup_hour}:00)"
                ;;
            0)
                log_info "Automatic backup not configured"
                log_info "You can set it up later from the main menu (option 8)"
                ;;
            *)
                log_warning "Invalid choice, skipping automatic backup setup"
                ;;
        esac
    else
        log_info "Automatic backup not configured"
        log_info "You can set it up later from the main menu (option 8)"
    fi

    echo ""
    log_success "Configuration saved successfully!"
    echo ""
    echo -e "${GREEN}Configuration Summary:${NC}"
    echo -e "  VPS identifier:    ${CYAN}$BACKUP_HOSTNAME${NC}"
    echo -e "  Config file:       ${CYAN}$BACKUP_ENV${NC}"
    echo -e "  Backup script:     ${CYAN}$BACKUP_SCRIPT${NC}"
    echo -e "  Log file:          ${CYAN}$BACKUP_LOG_FILE${NC}"
    echo -e "  Remote directory:  ${CYAN}$BACKUP_REMOTE_DIR${NC}"

    # Show retention policy based on backup method
    if [ "$BACKUP_METHOD" = "incremental" ]; then
        echo -e "  ${GREEN}Retention Policy:${NC}"
        [ -n "$RESTIC_KEEP_LAST" ] && [ "$RESTIC_KEEP_LAST" != "0" ] && echo -e "    Keep Last:       ${CYAN}${RESTIC_KEEP_LAST} backups${NC}"
        [ -n "$RESTIC_KEEP_DAILY" ] && [ "$RESTIC_KEEP_DAILY" != "0" ] && echo -e "    Keep Daily:      ${CYAN}${RESTIC_KEEP_DAILY} days${NC}"
        [ -n "$RESTIC_KEEP_WEEKLY" ] && [ "$RESTIC_KEEP_WEEKLY" != "0" ] && echo -e "    Keep Weekly:     ${CYAN}${RESTIC_KEEP_WEEKLY} weeks${NC}"
        [ -n "$RESTIC_KEEP_MONTHLY" ] && [ "$RESTIC_KEEP_MONTHLY" != "0" ] && echo -e "    Keep Monthly:    ${CYAN}${RESTIC_KEEP_MONTHLY} months${NC}"
        [ -n "$RESTIC_KEEP_YEARLY" ] && [ "$RESTIC_KEEP_YEARLY" != "0" ] && echo -e "    Keep Yearly:     ${CYAN}${RESTIC_KEEP_YEARLY} years${NC}"
    else
        echo -e "  Max backups:       ${CYAN}$BACKUP_MAX_KEEP${NC}"
    fi

    echo ""
    read -p "Test backup configuration now? [Y/n] (press Enter to confirm): " test
    if [[ ! $test =~ ^[Nn]$ ]]; then
        test_configuration

        # After testing, offer to run backup immediately
        echo ""
        read -p "Run backup now to verify everything works? [Y/n] (press Enter to confirm): " run_now
        if [[ ! $run_now =~ ^[Nn]$ ]]; then
            echo ""
            run_backup
        fi
    else
        # If user skipped test, still offer to run backup
        echo ""
        read -p "Run backup now? [y/N] (press Enter to skip): " run_now
        if [[ $run_now =~ ^[Yy]$ ]]; then
            echo ""
            run_backup
        fi
    fi
}

# Save configuration to env file
save_config() {
    cat > "$BACKUP_ENV" << EOF
# VPS Backup Configuration
# Generated on $(date)

# VPS identifier (hostname/label for this server)
BACKUP_HOSTNAME="$BACKUP_HOSTNAME"

# Backup method: incremental (restic) or full (tar+openssl)
BACKUP_METHOD="${BACKUP_METHOD:-incremental}"

# Backup sources (separated by |)
BACKUP_SRCS="$BACKUP_SRCS"

# Remote directory (rclone format: remote:path)
BACKUP_REMOTE_DIR="$BACKUP_REMOTE_DIR"

# Encryption password
BACKUP_PASSWORD="$BACKUP_PASSWORD"

# Telegram notifications (optional)
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"

# Backup settings
BACKUP_MAX_KEEP="$BACKUP_MAX_KEEP"
BACKUP_LOG_FILE="$BACKUP_LOG_FILE"
BACKUP_TMP_DIR="$BACKUP_TMP_DIR"

# Restic retention policy (for incremental backups)
RESTIC_KEEP_LAST="${RESTIC_KEEP_LAST:-7}"
RESTIC_KEEP_DAILY="${RESTIC_KEEP_DAILY:-30}"
RESTIC_KEEP_WEEKLY="${RESTIC_KEEP_WEEKLY:-8}"
RESTIC_KEEP_MONTHLY="${RESTIC_KEEP_MONTHLY:-12}"
RESTIC_KEEP_YEARLY="${RESTIC_KEEP_YEARLY:-3}"
EOF

    chmod 600 "$BACKUP_ENV"
    log_success "Configuration saved to $BACKUP_ENV"
}

# Create backup execution script
create_backup_script() {
    # Load config to determine backup method
    load_config

    if [ "$BACKUP_METHOD" = "incremental" ]; then
        create_restic_backup_script
    else
        create_full_backup_script
    fi
}

# Create restic incremental backup script
create_restic_backup_script() {
    cat > "$BACKUP_SCRIPT" << 'EOFSCRIPT'
#!/bin/bash

# Load configuration
if [ ! -f "/usr/local/bin/vps-backup.env" ]; then
    echo "Error: Configuration file not found"
    exit 1
fi

source "/usr/local/bin/vps-backup.env"

# Parse backup sources
IFS='|' read -ra BACKUP_SRCS_ARRAY <<< "$BACKUP_SRCS"

# Variables
HOSTNAME=$(hostname)
LOCK_FILE="/var/lock/vps-backup.lock"

# Set restic environment
export RESTIC_REPOSITORY="${BACKUP_REMOTE_DIR}"
export RESTIC_PASSWORD="${BACKUP_PASSWORD}"

# Cleanup function
cleanup() {
    local exit_code=$?
    rm -f "$LOCK_FILE"
    exit $exit_code
}

trap cleanup EXIT INT TERM

# Functions
send_telegram_message() {
    local message="$1"
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${TG_CHAT_ID}" \
            --data-urlencode "text=${message}" \
            --data-urlencode "parse_mode=HTML" > /dev/null 2>&1
    fi
}

log_and_notify() {
    local message="$1"
    local is_error="${2:-false}"

    echo "$(date): ${message}" >> "$BACKUP_LOG_FILE"

    if [ "$is_error" = "true" ]; then
        echo "ERROR: ${message}"
        send_telegram_message "🖥️ <b>$HOSTNAME</b>
❌ <b>Backup Error</b>
${message}"
        return 1
    else
        echo "INFO: ${message}"
        return 0
    fi
}

# Check if another backup is running
if [ -f "$LOCK_FILE" ]; then
    if kill -0 $(cat "$LOCK_FILE") 2>/dev/null; then
        log_and_notify "Another backup process is already running (PID: $(cat "$LOCK_FILE"))" true
        exit 1
    else
        # Stale lock file
        rm -f "$LOCK_FILE"
    fi
fi

# Create lock file
echo $$ > "$LOCK_FILE"

# Check disk space (need at least 1GB free)
AVAILABLE_SPACE=$(df /tmp | tail -1 | awk '{print $4}')
REQUIRED_SPACE=$((1024 * 1024))  # 1GB in KB

if [ "$AVAILABLE_SPACE" -lt "$REQUIRED_SPACE" ]; then
    log_and_notify "Insufficient disk space (available: $((AVAILABLE_SPACE/1024))MB, required: $((REQUIRED_SPACE/1024))MB)" true
    exit 1
fi

# Start backup
log_and_notify "Starting incremental backup process (restic)"

# Initialize repository if it doesn't exist
log_and_notify "Checking repository..."
if ! restic snapshots &> /dev/null; then
    log_and_notify "Initializing new restic repository..."
    if ! restic init >> "$BACKUP_LOG_FILE" 2>&1; then
        log_and_notify "Failed to initialize repository" true
        exit 1
    fi
    log_and_notify "Repository initialized successfully"
fi

# Perform backup
log_and_notify "Creating backup snapshot..."

# Build backup arguments
BACKUP_ARGS=()
for SRC in "${BACKUP_SRCS_ARRAY[@]}"; do
    if [ -e "$SRC" ]; then
        BACKUP_ARGS+=("$SRC")
    else
        log_and_notify "Warning: Backup source does not exist - $SRC"
    fi
done

# Run restic backup
BACKUP_OUTPUT=$(restic backup "${BACKUP_ARGS[@]}" \
    --tag "$HOSTNAME" \
    --host "$HOSTNAME" 2>&1)
BACKUP_RC=$?

echo "$BACKUP_OUTPUT" >> "$BACKUP_LOG_FILE"

if [ $BACKUP_RC -ne 0 ]; then
    log_and_notify "Backup failed (restic exit code $BACKUP_RC)" true
    exit 1
fi

# Extract stats from output
FILES_NEW=$(echo "$BACKUP_OUTPUT" | grep "Files:" | awk '{print $3}' | head -1)
FILES_CHANGED=$(echo "$BACKUP_OUTPUT" | grep "Files:" | awk '{print $5}' | head -1)
FILES_UNCHANGED=$(echo "$BACKUP_OUTPUT" | grep "Files:" | awk '{print $7}' | head -1)
DATA_ADDED=$(echo "$BACKUP_OUTPUT" | grep "Added to the repository:" | awk '{print $5, $6}')

log_and_notify "Backup snapshot created successfully"

# Cleanup old snapshots
log_and_notify "Cleaning up old snapshots using retention policy..."

# Build restic forget command with retention policies
FORGET_CMD="restic forget --host \"$HOSTNAME\" --prune"

[ -n "$RESTIC_KEEP_LAST" ] && [ "$RESTIC_KEEP_LAST" != "0" ] && FORGET_CMD="$FORGET_CMD --keep-last $RESTIC_KEEP_LAST"
[ -n "$RESTIC_KEEP_DAILY" ] && [ "$RESTIC_KEEP_DAILY" != "0" ] && FORGET_CMD="$FORGET_CMD --keep-daily $RESTIC_KEEP_DAILY"
[ -n "$RESTIC_KEEP_WEEKLY" ] && [ "$RESTIC_KEEP_WEEKLY" != "0" ] && FORGET_CMD="$FORGET_CMD --keep-weekly $RESTIC_KEEP_WEEKLY"
[ -n "$RESTIC_KEEP_MONTHLY" ] && [ "$RESTIC_KEEP_MONTHLY" != "0" ] && FORGET_CMD="$FORGET_CMD --keep-monthly $RESTIC_KEEP_MONTHLY"
[ -n "$RESTIC_KEEP_YEARLY" ] && [ "$RESTIC_KEEP_YEARLY" != "0" ] && FORGET_CMD="$FORGET_CMD --keep-yearly $RESTIC_KEEP_YEARLY"

# Execute forget command
eval "$FORGET_CMD" >> "$BACKUP_LOG_FILE" 2>&1

if [ $? -eq 0 ]; then
    log_and_notify "Old snapshots cleaned up successfully"
else
    log_and_notify "Warning: Failed to cleanup old snapshots"
fi

# Get repository stats
REPO_STATS=$(restic stats --json 2>/dev/null)
TOTAL_SIZE=$(echo "$REPO_STATS" | grep -o '"total_size":[0-9]*' | cut -d':' -f2)
if [ -n "$TOTAL_SIZE" ]; then
    TOTAL_SIZE_MB=$((TOTAL_SIZE / 1024 / 1024))
else
    TOTAL_SIZE_MB="N/A"
fi

# Get snapshot count
SNAPSHOT_COUNT=$(restic snapshots --json 2>/dev/null | grep -o '"hostname"' | wc -l)

# Success notification
send_telegram_message "🖥️ <b>$HOSTNAME Backup Completed</b>
✅ Incremental backup successful
📦 Data added: ${DATA_ADDED:-N/A}
📊 Files: new=${FILES_NEW:-0}, changed=${FILES_CHANGED:-0}, unchanged=${FILES_UNCHANGED:-0}
📚 Total snapshots: ${SNAPSHOT_COUNT}
💾 Repository size: ${TOTAL_SIZE_MB}MB"

log_and_notify "Backup process completed! Method: restic (incremental)"

exit 0
EOFSCRIPT

    chmod +x "$BACKUP_SCRIPT"
    log_success "Restic backup script created at $BACKUP_SCRIPT"
}

# Create full backup script (original tar+openssl method)
create_full_backup_script() {
    cat > "$BACKUP_SCRIPT" << 'EOFSCRIPT'
#!/bin/bash

# Load configuration
if [ ! -f "/usr/local/bin/vps-backup.env" ]; then
    echo "Error: Configuration file not found"
    exit 1
fi

source "/usr/local/bin/vps-backup.env"

# Parse backup sources
IFS='|' read -ra BACKUP_SRCS_ARRAY <<< "$BACKUP_SRCS"

# Variables
DATE=$(date +"%Y%m%d-%H%M%S")
HOSTNAME=$(hostname)
BACKUP_FILE="backup-${HOSTNAME}-${DATE}.tar.gz"
ENCRYPTED_BACKUP_FILE="${BACKUP_FILE}.enc"
CHECKSUM_FILE="${ENCRYPTED_BACKUP_FILE}.sha256"
LOCK_FILE="/var/lock/vps-backup.lock"

# Cleanup function
cleanup() {
    local exit_code=$?
    rm -f "$LOCK_FILE"
    if [ -d "${BACKUP_TMP_DIR}" ]; then
        rm -rf "${BACKUP_TMP_DIR}"
    fi
    exit $exit_code
}

trap cleanup EXIT INT TERM

# Functions
send_telegram_message() {
    local message="$1"
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${TG_CHAT_ID}" \
            --data-urlencode "text=${message}" \
            --data-urlencode "parse_mode=HTML" > /dev/null 2>&1
    fi
}

log_and_notify() {
    local message="$1"
    local is_error="${2:-false}"

    echo "$(date): ${message}" >> "$BACKUP_LOG_FILE"

    if [ "$is_error" = "true" ]; then
        echo "ERROR: ${message}"
        send_telegram_message "🖥️ <b>$HOSTNAME</b>
❌ <b>Backup Error</b>
${message}"
        return 1
    else
        echo "INFO: ${message}"
        return 0
    fi
}

# Check if another backup is running
if [ -f "$LOCK_FILE" ]; then
    if kill -0 $(cat "$LOCK_FILE") 2>/dev/null; then
        log_and_notify "Another backup process is already running (PID: $(cat "$LOCK_FILE"))" true
        exit 1
    else
        # Stale lock file
        rm -f "$LOCK_FILE"
    fi
fi

# Create lock file
echo $$ > "$LOCK_FILE"

# Check disk space (need at least 1GB free)
AVAILABLE_SPACE=$(df "${BACKUP_TMP_DIR%/*}" | tail -1 | awk '{print $4}')
REQUIRED_SPACE=$((1024 * 1024))  # 1GB in KB

if [ "$AVAILABLE_SPACE" -lt "$REQUIRED_SPACE" ]; then
    log_and_notify "Insufficient disk space (available: $((AVAILABLE_SPACE/1024))MB, required: $((REQUIRED_SPACE/1024))MB)" true
    exit 1
fi

# Start backup
log_and_notify "Starting backup process - ${DATE}"

# Clean and create temp directory
rm -rf "${BACKUP_TMP_DIR}"
mkdir -p "${BACKUP_TMP_DIR}"

# Build tar command
TAR_ARGS=(
    "--ignore-failed-read"
    "--warning=no-file-changed"
    "-czf" "${BACKUP_TMP_DIR}/${BACKUP_FILE}"
)

for SRC in "${BACKUP_SRCS_ARRAY[@]}"; do
    if [ -e "$SRC" ]; then
        TAR_ARGS+=("-C" "$(dirname "$SRC")" "$(basename "$SRC")")
    else
        log_and_notify "Warning: Backup source does not exist - $SRC"
    fi
done

# Compress
log_and_notify "Compressing backup..."
tar "${TAR_ARGS[@]}" >> "$BACKUP_LOG_FILE" 2>&1
rc=$?

if [ $rc -ne 0 ] && [ $rc -ne 1 ]; then
    log_and_notify "Compression failed (tar exit code $rc)" true
    exit 1
fi

# Encrypt
log_and_notify "Encrypting backup..."
openssl enc -aes-256-cbc -salt -pbkdf2 -pass pass:"$BACKUP_PASSWORD" \
    -in "${BACKUP_TMP_DIR}/${BACKUP_FILE}" \
    -out "${BACKUP_TMP_DIR}/${ENCRYPTED_BACKUP_FILE}" >> "$BACKUP_LOG_FILE" 2>&1

if [ $? -ne 0 ]; then
    log_and_notify "Encryption failed" true
    exit 1
fi

rm -f "${BACKUP_TMP_DIR}/${BACKUP_FILE}"

# Generate SHA256 checksum
log_and_notify "Generating checksum..."
sha256sum "${BACKUP_TMP_DIR}/${ENCRYPTED_BACKUP_FILE}" | awk '{print $1}' > "${BACKUP_TMP_DIR}/${CHECKSUM_FILE}"

# Get file size
BACKUP_SIZE=$(du -h "${BACKUP_TMP_DIR}/${ENCRYPTED_BACKUP_FILE}" | cut -f1)

# Upload with retry (max 3 attempts)
log_and_notify "Uploading to ${BACKUP_REMOTE_DIR}..."
UPLOAD_ATTEMPTS=0
MAX_ATTEMPTS=3

while [ $UPLOAD_ATTEMPTS -lt $MAX_ATTEMPTS ]; do
    rclone copy "${BACKUP_TMP_DIR}/${ENCRYPTED_BACKUP_FILE}" "${BACKUP_REMOTE_DIR}" \
        --log-file="$BACKUP_LOG_FILE" \
        --log-level INFO \
        --retries 3 \
        --low-level-retries 10

    if [ $? -eq 0 ]; then
        # Verify upload
        REMOTE_SIZE=$(rclone size "${BACKUP_REMOTE_DIR}/${ENCRYPTED_BACKUP_FILE}" --json 2>/dev/null | grep -o '"bytes":[0-9]*' | grep -o '[0-9]*')
        LOCAL_SIZE=$(stat -f%z "${BACKUP_TMP_DIR}/${ENCRYPTED_BACKUP_FILE}" 2>/dev/null || stat -c%s "${BACKUP_TMP_DIR}/${ENCRYPTED_BACKUP_FILE}")

        if [ "$REMOTE_SIZE" = "$LOCAL_SIZE" ]; then
            log_and_notify "Upload successful, size verified"
            break
        else
            log_and_notify "Warning: File size mismatch (local: $LOCAL_SIZE, remote: $REMOTE_SIZE)"
        fi
    fi

    UPLOAD_ATTEMPTS=$((UPLOAD_ATTEMPTS + 1))
    if [ $UPLOAD_ATTEMPTS -lt $MAX_ATTEMPTS ]; then
        log_and_notify "Upload failed, retrying $UPLOAD_ATTEMPTS/$MAX_ATTEMPTS..."
        sleep 5
    fi
done

if [ $UPLOAD_ATTEMPTS -eq $MAX_ATTEMPTS ]; then
    log_and_notify "Upload failed after maximum retry attempts" true
    exit 1
fi

# Upload checksum file
rclone copy "${BACKUP_TMP_DIR}/${CHECKSUM_FILE}" "${BACKUP_REMOTE_DIR}" >> "$BACKUP_LOG_FILE" 2>&1

# Cleanup local files
rm -f "${BACKUP_TMP_DIR}/${ENCRYPTED_BACKUP_FILE}"
rm -f "${BACKUP_TMP_DIR}/${CHECKSUM_FILE}"

# Remove old backups
log_and_notify "Cleaning up old backups..."
OLD_BACKUPS=$(rclone lsf "${BACKUP_REMOTE_DIR}" | grep "^backup-${HOSTNAME}-.*\.tar\.gz\.enc$" | sort -r | tail -n +$((BACKUP_MAX_KEEP + 1)))

for file in $OLD_BACKUPS; do
    rclone delete "${BACKUP_REMOTE_DIR}/${file}" --drive-use-trash=false >> "$BACKUP_LOG_FILE" 2>&1
    rclone delete "${BACKUP_REMOTE_DIR}/${file}.sha256" --drive-use-trash=false >> "$BACKUP_LOG_FILE" 2>&1
    log_and_notify "Deleted old backup: $file"
done

# Get backup stats
BACKUP_COUNT=$(rclone lsf "${BACKUP_REMOTE_DIR}" | grep "^backup-${HOSTNAME}-" | grep "\.tar\.gz\.enc$" | wc -l)

# Success notification
send_telegram_message "🖥️ <b>$HOSTNAME Backup Completed</b>
✅ Backup successful
📦 File size: ${BACKUP_SIZE}
📚 Backups retained: ${BACKUP_COUNT}
📅 Backup file: ${ENCRYPTED_BACKUP_FILE}
✓ SHA256 checksum generated"

log_and_notify "Backup process completed! File: ${ENCRYPTED_BACKUP_FILE} (${BACKUP_SIZE})"

exit 0
EOFSCRIPT

    chmod +x "$BACKUP_SCRIPT"
    log_success "Backup script created at $BACKUP_SCRIPT"
}

# Setup logrotate for backup logs
setup_logrotate() {
    local log_file="${BACKUP_LOG_FILE:-$DEFAULT_LOG_FILE}"
    local logrotate_conf="/etc/logrotate.d/vps-backup"
    local max_size="${1:-10M}"
    local keep_days="${2:-7}"

    echo ""
    log_info "Setting up log rotation..."

    # Create logrotate configuration
    cat > "$logrotate_conf" << EOF
# VPS Backup log rotation configuration
$log_file {
    # Rotate daily or when size reaches $max_size
    daily
    size $max_size
    # Keep $keep_days days of logs
    rotate $keep_days
    # Compress old logs
    compress
    # Delay compression until next rotation
    delaycompress
    # Don't error if log file is missing
    missingok
    # Don't rotate if log is empty
    notifempty
    # Create new log with these permissions
    create 0640 root root
    # Use date as suffix for rotated files
    dateext
    dateformat -%Y%m%d
}
EOF

    if [ $? -eq 0 ]; then
        log_success "Logrotate configured at $logrotate_conf"
        log_info "Logs will be rotated daily or when reaching $max_size"
        log_info "Logs will be kept for $keep_days days and compressed"
    else
        log_warning "Failed to create logrotate configuration"
    fi
}

# Test configuration
test_configuration() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}Testing Backup Configuration${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    load_config

    # Test 1: Check backup sources
    echo ""
    log_info "Test 1: Checking backup sources..."
    IFS='|' read -ra SOURCES <<< "$BACKUP_SRCS"
    local sources_ok=true
    for src in "${SOURCES[@]}"; do
        if [ -e "$src" ]; then
            echo -e "  ${GREEN}✓${NC} $src"
        else
            echo -e "  ${RED}✗${NC} $src (not found)"
            sources_ok=false
        fi
    done

    # Test 2: Check rclone remote
    echo ""
    log_info "Test 2: Checking rclone remote..."
    local remote_name=$(echo "$BACKUP_REMOTE_DIR" | cut -d':' -f1)
    if rclone listremotes | grep -q "^${remote_name}:$"; then
        echo -e "  ${GREEN}✓${NC} Remote '$remote_name' is configured"

        # Test connection
        if rclone lsd "${BACKUP_REMOTE_DIR}" &> /dev/null; then
            echo -e "  ${GREEN}✓${NC} Remote is accessible and working"
        else
            echo -e "  ${YELLOW}⚠${NC} Remote '$remote_name' is configured but cannot access '${BACKUP_REMOTE_DIR}'"
            echo -e "      ${CYAN}Possible reasons:${NC}"
            echo -e "      • Network connectivity issues"
            echo -e "      • Authentication token expired (may need to re-authorize)"
            echo -e "      • Remote path does not exist yet (will be created on first backup)"
            echo -e "      • Insufficient permissions"
            echo -e "      ${CYAN}Note:${NC} This may be normal if it's a new setup. Try running a backup to test."
        fi
    else
        echo -e "  ${RED}✗${NC} Remote '$remote_name' not found"
    fi

    # Test 3: Check encryption
    echo ""
    log_info "Test 3: Testing encryption..."
    if [ -n "$BACKUP_PASSWORD" ]; then
        echo -e "  ${GREEN}✓${NC} Encryption password is set"

        # Test encryption/decryption
        local test_file=$(mktemp)
        local test_enc=$(mktemp)
        echo "test" > "$test_file"

        if openssl enc -aes-256-cbc -salt -pbkdf2 -pass pass:"$BACKUP_PASSWORD" \
            -in "$test_file" -out "$test_enc" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} Encryption works"
            rm -f "$test_file" "$test_enc"
        else
            echo -e "  ${RED}✗${NC} Encryption test failed"
            rm -f "$test_file" "$test_enc"
        fi
    else
        echo -e "  ${RED}✗${NC} Encryption password not set"
    fi

    # Test 4: Check Telegram
    echo ""
    log_info "Test 4: Testing Telegram notifications..."
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        echo -e "  ${GREEN}✓${NC} Telegram credentials configured"
        read -p "Send test message? [Y/n] (press Enter to send): " send_test
        if [[ ! $send_test =~ ^[Nn]$ ]]; then
            local test_msg="🖥️ <b>$(hostname) - Test Message</b>
✅ Telegram notification configured successfully"
            curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
                --data-urlencode "chat_id=${TG_CHAT_ID}" \
                --data-urlencode "text=${test_msg}" \
                --data-urlencode "parse_mode=HTML" > /dev/null 2>&1
            if [ $? -eq 0 ]; then
                echo -e "  ${GREEN}✓${NC} Test message sent successfully"
            else
                echo -e "  ${RED}✗${NC} Failed to send test message"
            fi
        else
            log_info "Test message skipped"
        fi
    else
        echo -e "  ${YELLOW}⚠${NC} Telegram notifications disabled"
    fi

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Run backup
run_backup() {
    if ! is_configured; then
        log_error "Backup is not configured"
        log_info "Please run configuration wizard first"
        return 1
    fi

    if [ ! -x "$BACKUP_SCRIPT" ]; then
        log_error "Backup script not found or not executable"
        return 1
    fi

    load_config

    # Show backup summary before execution
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}Backup Summary${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${GREEN}What will be backed up:${NC}"
    IFS='|' read -ra SOURCES <<< "$BACKUP_SRCS"
    for src in "${SOURCES[@]}"; do
        if [ -e "$src" ]; then
            local size=$(du -sh "$src" 2>/dev/null | cut -f1)
            echo -e "  ${GREEN}✓${NC} $src ${CYAN}(${size})${NC}"
        else
            echo -e "  ${YELLOW}⚠${NC} $src ${YELLOW}(not found)${NC}"
        fi
    done
    echo ""
    echo -e "${GREEN}Backup destination:${NC}    ${CYAN}${BACKUP_REMOTE_DIR}${NC}"
    echo -e "${GREEN}Encryption:${NC}            ${CYAN}Enabled (AES-256-CBC)${NC}"

    # Show retention policy based on backup method
    if [ "$BACKUP_METHOD" = "incremental" ]; then
        echo -e "${GREEN}Retention Policy:${NC}"
        [ -n "$RESTIC_KEEP_LAST" ] && [ "$RESTIC_KEEP_LAST" != "0" ] && echo -e "  Keep Last:         ${CYAN}${RESTIC_KEEP_LAST} backups${NC}"
        [ -n "$RESTIC_KEEP_DAILY" ] && [ "$RESTIC_KEEP_DAILY" != "0" ] && echo -e "  Keep Daily:        ${CYAN}${RESTIC_KEEP_DAILY} days${NC}"
        [ -n "$RESTIC_KEEP_WEEKLY" ] && [ "$RESTIC_KEEP_WEEKLY" != "0" ] && echo -e "  Keep Weekly:       ${CYAN}${RESTIC_KEEP_WEEKLY} weeks${NC}"
        [ -n "$RESTIC_KEEP_MONTHLY" ] && [ "$RESTIC_KEEP_MONTHLY" != "0" ] && echo -e "  Keep Monthly:      ${CYAN}${RESTIC_KEEP_MONTHLY} months${NC}"
        [ -n "$RESTIC_KEEP_YEARLY" ] && [ "$RESTIC_KEEP_YEARLY" != "0" ] && echo -e "  Keep Yearly:       ${CYAN}${RESTIC_KEEP_YEARLY} years${NC}"
    else
        echo -e "${GREEN}Max backups to keep:${NC}   ${CYAN}${BACKUP_MAX_KEEP}${NC}"
    fi

    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        echo -e "${GREEN}Telegram notify:${NC}       ${CYAN}Enabled${NC}"
    fi
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    read -p "Proceed with backup? [Y/n] (press Enter to confirm): " proceed
    if [[ $proceed =~ ^[Nn]$ ]]; then
        log_info "Backup cancelled"
        return 0
    fi

    echo ""
    log_info "Starting backup process..."
    echo ""

    "$BACKUP_SCRIPT"

    local exit_code=$?
    echo ""
    if [ $exit_code -eq 0 ]; then
        log_success "Backup completed successfully!"
        echo ""
        log_info "Check logs for details: ${BACKUP_LOG_FILE}"
    else
        log_error "Backup failed with exit code: $exit_code"
        echo ""
        log_info "Check logs for details: ${BACKUP_LOG_FILE}"
    fi

    return $exit_code
}

# List remote backups
list_backups() {
    if ! is_configured; then
        log_error "Backup is not configured"
        return 1
    fi

    load_config

    echo ""
    log_info "Listing backups in $BACKUP_REMOTE_DIR..."
    echo ""

    if ! command -v rclone &> /dev/null; then
        log_error "rclone is not installed"
        return 1
    fi

    local backups=$(rclone lsl "${BACKUP_REMOTE_DIR}" 2>/dev/null | grep "backup-")

    if [ -z "$backups" ]; then
        log_warning "No backups found"
        return 0
    fi

    echo -e "${GREEN}Available backups:${NC}"
    echo "$backups" | while read -r size date time file; do
        # Convert size to human readable
        local size_mb=$((size / 1024 / 1024))
        echo -e "  ${CYAN}$file${NC}"
        echo -e "    Size: ${YELLOW}${size_mb}MB${NC}  Date: ${YELLOW}$date $time${NC}"
    done

    echo ""
    local total_size=$(rclone size "${BACKUP_REMOTE_DIR}" 2>/dev/null | grep "Total size:" | awk '{print $3, $4}')
    echo -e "Total size: ${CYAN}${total_size}${NC}"
}

# View logs
view_logs() {
    if ! is_configured; then
        log_error "Backup is not configured"
        return 1
    fi

    load_config

    local log_file="${BACKUP_LOG_FILE:-$DEFAULT_LOG_FILE}"

    if [ ! -f "$log_file" ]; then
        log_warning "Log file not found: $log_file"
        return 0
    fi

    echo ""
    echo -e "${CYAN}Last 50 log entries:${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    tail -50 "$log_file"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "Full log: ${CYAN}$log_file${NC}"
}

# Setup cron job
setup_cron() {
    if ! is_configured; then
        log_error "Backup is not configured"
        log_info "Please run configuration wizard first"
        return 1
    fi

    echo ""
    log_info "Setting up automatic backup schedule..."
    echo ""

    echo -e "${YELLOW}Select backup time:${NC}"
    echo -e "  ${CYAN}1.${NC} Daily at 1:00 AM      (0 1 * * *)"
    echo -e "  ${CYAN}2.${NC} Daily at 2:00 AM      (0 2 * * *) ${GREEN}[Recommended]${NC}"
    echo -e "  ${CYAN}3.${NC} Daily at 3:00 AM      (0 3 * * *)"
    echo -e "  ${CYAN}4.${NC} Daily at 4:00 AM      (0 4 * * *)"
    echo -e "  ${CYAN}5.${NC} Daily at 5:00 AM      (0 5 * * *)"
    echo -e "  ${CYAN}6.${NC} Daily at 6:00 AM      (0 6 * * *)"
    echo -e "  ${CYAN}7.${NC} Daily at 7:00 AM      (0 7 * * *)"
    echo -e "  ${CYAN}8.${NC} Daily at 8:00 AM      (0 8 * * *)"
    echo -e "  ${CYAN}9.${NC} Custom schedule"
    echo -e "  ${RED}10.${NC} Remove scheduled backup"
    echo ""

    read -p "Select option [1-10] (press Enter for option 2): " schedule_option
    schedule_option="${schedule_option:-2}"  # Default to option 2 (2:00 AM)

    local cron_schedule=""
    case $schedule_option in
        1) cron_schedule="0 1 * * *" ;;
        2) cron_schedule="0 2 * * *" ;;
        3) cron_schedule="0 3 * * *" ;;
        4) cron_schedule="0 4 * * *" ;;
        5) cron_schedule="0 5 * * *" ;;
        6) cron_schedule="0 6 * * *" ;;
        7) cron_schedule="0 7 * * *" ;;
        8) cron_schedule="0 8 * * *" ;;
        9)
            echo ""
            log_info "Enter cron schedule in format: minute hour day month weekday"
            log_info "Examples: '0 2 * * *' (daily 2 AM), '30 14 * * 5' (Friday 2:30 PM)"
            echo ""
            read -p "Enter cron schedule: " cron_schedule
            if [ -z "$cron_schedule" ]; then
                log_error "No schedule entered"
                return 1
            fi
            ;;
        10)
            # Remove existing cron job
            if crontab -l 2>/dev/null | grep -q "$BACKUP_SCRIPT"; then
                crontab -l 2>/dev/null | grep -v "$BACKUP_SCRIPT" | crontab -
                log_success "Scheduled backup removed"
            else
                log_info "No scheduled backup found"
            fi
            return 0
            ;;
        *)
            log_error "Invalid option"
            return 1
            ;;
    esac

    # Add to crontab
    local cron_cmd="$cron_schedule $BACKUP_SCRIPT >> ${BACKUP_LOG_FILE:-$DEFAULT_LOG_FILE} 2>&1"

    # Remove old entry if exists
    crontab -l 2>/dev/null | grep -v "$BACKUP_SCRIPT" | { cat; echo "$cron_cmd"; } | crontab -

    log_success "Backup scheduled: $cron_schedule"
    echo ""
    log_info "Current crontab:"
    crontab -l | grep "$BACKUP_SCRIPT"
}

# Edit specific configuration items
edit_configuration() {
    if ! is_configured; then
        log_error "Backup is not configured"
        log_info "Please run configuration wizard first"
        return 1
    fi

    load_config

    while true; do
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${CYAN}Edit Backup Configuration${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "${GREEN}What do you want to modify?${NC}"
        echo -e "  ${CYAN}1.${NC} View current configuration"
        echo -e "  ${CYAN}2.${NC} Backup method (incremental/full)"
        echo -e "  ${CYAN}3.${NC} Backup sources (add/remove directories)"
        echo -e "  ${CYAN}4.${NC} Backup retention (max backups)"
        echo -e "  ${CYAN}5.${NC} Setup/modify backup schedule (cron)"
        echo -e "  ${CYAN}6.${NC} VPS identifier (hostname/label)"
        echo -e "  ${CYAN}7.${NC} Remote storage directory"
        echo -e "  ${CYAN}8.${NC} Encryption password"
        echo -e "  ${CYAN}9.${NC} Telegram notifications"
        echo -e "  ${CYAN}10.${NC} Log and temp paths"
        echo -e "  ${CYAN}11.${NC} Configure log rotation"
        echo -e "  ${CYAN}12.${NC} Regenerate backup script"
        echo -e "  ${CYAN}0.${NC} Return to main menu (default)"
        echo ""
        read -p "Select option [0-12] (press Enter to return): " edit_choice
        edit_choice="${edit_choice:-0}"  # Default to option 0 (return to main menu)

        case $edit_choice in
            1)
                # View configuration
                show_status
                echo ""
                read -p "Press Enter to continue..."
                ;;

            2)
                # Change backup method
                echo ""
                echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                echo -e "${CYAN}Change Backup Method${NC}"
                echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                echo ""
                echo -e "Current method: ${CYAN}${BACKUP_METHOD:-incremental}${NC}"
                echo ""
                echo -e "${GREEN}Available methods:${NC}"
                echo -e "  ${GREEN}1.${NC} ${GREEN}Incremental (restic)${NC} - Only backs up changed data"
                echo -e "  ${CYAN}2.${NC} Full (tar+openssl) - Complete backup every time"
                echo ""
                read -p "Select backup method [1-2]: " method_choice

                case $method_choice in
                    1)
                        if [ "$BACKUP_METHOD" = "incremental" ]; then
                            log_info "Already using incremental backup"
                        else
                            # Check if restic is installed
                            if ! command -v restic &> /dev/null; then
                                log_warning "restic is not installed"
                                read -p "Install restic now? [Y/n]: " install_restic_now
                                if [[ ! $install_restic_now =~ ^[Nn]$ ]]; then
                                    install_restic
                                    if [ $? -eq 0 ]; then
                                        BACKUP_METHOD="incremental"
                                        save_config
                                        create_backup_script
                                        log_success "Switched to incremental backup (restic)"
                                        echo ""
                                        log_warning "Note: Your existing full backups will remain in storage"
                                        log_info "Restic will create a new repository for incremental backups"
                                    fi
                                else
                                    log_error "restic is required for incremental backup"
                                fi
                            else
                                BACKUP_METHOD="incremental"
                                save_config
                                create_backup_script
                                log_success "Switched to incremental backup (restic)"
                                echo ""
                                log_warning "Note: Your existing full backups will remain in storage"
                                log_info "Restic will create a new repository for incremental backups"
                            fi
                        fi
                        ;;
                    2)
                        if [ "$BACKUP_METHOD" = "full" ]; then
                            log_info "Already using full backup"
                        else
                            BACKUP_METHOD="full"
                            save_config
                            create_backup_script
                            log_success "Switched to full backup (tar+openssl)"
                            echo ""
                            log_warning "Note: Your existing restic snapshots will remain in storage"
                            log_info "Full backups will be stored as separate encrypted files"
                        fi
                        ;;
                    *)
                        log_error "Invalid choice"
                        ;;
                esac
                echo ""
                read -p "Press Enter to continue..."
                ;;

            3)
                # Edit backup sources
                echo ""
                log_info "Current backup sources:"
                IFS='|' read -ra SOURCES <<< "$BACKUP_SRCS"
                for i in "${!SOURCES[@]}"; do
                    echo -e "  $((i+1)). ${CYAN}${SOURCES[$i]}${NC}"
                done

                echo ""
                echo -e "${YELLOW}Options:${NC}"
                echo -e "  a. Add new source"
                echo -e "  r. Remove source"
                echo -e "  c. Clear all and reconfigure"
                echo -e "  b. Back"
                echo ""
                read -p "Select [a/r/c/b]: " src_action

                case $src_action in
                    a|A)
                        echo ""
                        log_info "Add backup sources"
                        echo -e "${CYAN}Tip: Press Enter on empty line when you're done${NC}"
                        echo ""

                        while true; do
                            read -p "Enter path to add (or press Enter to finish): " new_src

                            # If empty input, break the loop
                            if [ -z "$new_src" ]; then
                                echo ""
                                log_info "Finished adding sources"
                                break
                            fi

                            # Expand ~ to home directory
                            new_src="${new_src/#\~/$HOME}"

                            if [ -e "$new_src" ]; then
                                SOURCES+=("$new_src")
                                BACKUP_SRCS=$(IFS='|'; echo "${SOURCES[*]}")
                                save_config
                                create_backup_script
                                log_success "Added: $new_src"
                                echo ""
                            else
                                log_warning "Path does not exist: $new_src"
                                read -p "Add anyway? [y/N] (press Enter to skip): " add_anyway
                                if [[ $add_anyway =~ ^[Yy]$ ]]; then
                                    SOURCES+=("$new_src")
                                    BACKUP_SRCS=$(IFS='|'; echo "${SOURCES[*]}")
                                    save_config
                                    create_backup_script
                                    log_success "Added: $new_src"
                                else
                                    log_info "Skipped: $new_src"
                                fi
                                echo ""
                            fi
                        done
                        ;;
                    r|R)
                        echo ""
                        log_info "Remove backup sources"
                        echo -e "${CYAN}Tip: Press Enter on empty line when you're done${NC}"
                        echo ""

                        while true; do
                            # Reload current sources to show updated list
                            IFS='|' read -ra SOURCES <<< "$BACKUP_SRCS"

                            if [ ${#SOURCES[@]} -eq 0 ]; then
                                log_warning "No backup sources configured"
                                break
                            fi

                            # Display current sources
                            echo "Current backup sources:"
                            for i in "${!SOURCES[@]}"; do
                                echo -e "  $((i+1)). ${CYAN}${SOURCES[$i]}${NC}"
                            done
                            echo ""

                            read -p "Enter number to remove [1-${#SOURCES[@]}] (or press Enter to finish): " remove_idx

                            # If empty input, break the loop
                            if [ -z "$remove_idx" ]; then
                                echo ""
                                log_info "Finished removing sources"
                                break
                            fi

                            if [[ $remove_idx =~ ^[0-9]+$ ]] && [ $remove_idx -ge 1 ] && [ $remove_idx -le ${#SOURCES[@]} ]; then
                                removed="${SOURCES[$((remove_idx-1))]}"
                                unset 'SOURCES[$((remove_idx-1))]'
                                SOURCES=("${SOURCES[@]}")  # Reindex array
                                BACKUP_SRCS=$(IFS='|'; echo "${SOURCES[*]}")
                                save_config
                                create_backup_script
                                log_success "Removed: $removed"
                                echo ""
                            else
                                log_error "Invalid selection"
                                echo ""
                            fi
                        done
                        ;;
                    c|C)
                        configure_backup_sources
                        save_config
                        create_backup_script
                        ;;
                    *)
                        ;;
                esac
                ;;

            4)
                # Edit backup retention
                echo ""
                echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                echo -e "${CYAN}Edit Backup Retention Policy${NC}"
                echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                echo ""

                if [ "$BACKUP_METHOD" = "incremental" ]; then
                    echo -e "${GREEN}Current Restic Retention Policy:${NC}"
                    echo -e "  Keep Last:    ${CYAN}${RESTIC_KEEP_LAST:-7}${NC} backups"
                    echo -e "  Keep Daily:   ${CYAN}${RESTIC_KEEP_DAILY:-30}${NC} days"
                    echo -e "  Keep Weekly:  ${CYAN}${RESTIC_KEEP_WEEKLY:-8}${NC} weeks"
                    echo -e "  Keep Monthly: ${CYAN}${RESTIC_KEEP_MONTHLY:-12}${NC} months"
                    echo -e "  Keep Yearly:  ${CYAN}${RESTIC_KEEP_YEARLY:-3}${NC} years"
                    echo ""
                    echo -e "${YELLOW}Enter new values (or press Enter to keep current, enter 0 to disable):${NC}"
                    echo ""

                    read -p "Keep last N backups [${RESTIC_KEEP_LAST:-7}]: " new_last
                    RESTIC_KEEP_LAST="${new_last:-${RESTIC_KEEP_LAST:-7}}"

                    read -p "Keep daily for N days [${RESTIC_KEEP_DAILY:-30}]: " new_daily
                    RESTIC_KEEP_DAILY="${new_daily:-${RESTIC_KEEP_DAILY:-30}}"

                    read -p "Keep weekly for N weeks [${RESTIC_KEEP_WEEKLY:-8}]: " new_weekly
                    RESTIC_KEEP_WEEKLY="${new_weekly:-${RESTIC_KEEP_WEEKLY:-8}}"

                    read -p "Keep monthly for N months [${RESTIC_KEEP_MONTHLY:-12}]: " new_monthly
                    RESTIC_KEEP_MONTHLY="${new_monthly:-${RESTIC_KEEP_MONTHLY:-12}}"

                    read -p "Keep yearly for N years [${RESTIC_KEEP_YEARLY:-3}]: " new_yearly
                    RESTIC_KEEP_YEARLY="${new_yearly:-${RESTIC_KEEP_YEARLY:-3}}"

                    save_config
                    create_backup_script
                    echo ""
                    log_success "Retention policy updated"
                else
                    echo -e "Current max backups: ${CYAN}$BACKUP_MAX_KEEP${NC}"
                    read -p "New max backups to keep: " new_max
                    if [[ $new_max =~ ^[0-9]+$ ]]; then
                        BACKUP_MAX_KEEP="$new_max"
                        save_config
                        create_backup_script
                        log_success "Max backups updated to $new_max"
                    else
                        log_error "Invalid number"
                    fi
                fi
                echo ""
                read -p "Press Enter to continue..."
                ;;

            5)
                # Setup cron
                setup_cron
                ;;

            6)
                # Edit VPS identifier
                echo ""
                echo -e "Current VPS identifier: ${CYAN}$BACKUP_HOSTNAME${NC}"
                echo -e "Current remote path: ${CYAN}$BACKUP_REMOTE_DIR${NC}"
                echo ""
                local current_hostname=$(hostname)
                echo -e "System hostname: ${CYAN}${current_hostname}${NC}"
                read -p "New VPS identifier [${BACKUP_HOSTNAME}] (press Enter to keep current): " new_hostname
                if [ -n "$new_hostname" ]; then
                    # Sanitize hostname
                    new_hostname=$(echo "$new_hostname" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')

                    echo ""
                    log_success "VPS identifier will be updated to: ${new_hostname}"

                    # Automatically update remote path to match new identifier
                    echo ""
                    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                    echo -e "${YELLOW}Automatic Path Update${NC}"
                    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

                    local old_remote=$(echo "$BACKUP_REMOTE_DIR" | cut -d':' -f1)
                    local new_suggested_path="${old_remote}:vps-${new_hostname}-backup"

                    echo -e "Old path:  ${CYAN}$BACKUP_REMOTE_DIR${NC}"
                    echo -e "New path:  ${GREEN}${new_suggested_path}${NC}"
                    echo ""
                    echo -e "${YELLOW}ℹ️  Remote path will be automatically updated to match the new identifier${NC}"
                    echo ""
                    read -p "Keep old remote path instead? [y/N] (press Enter to auto-update): " keep_old

                    if [[ $keep_old =~ ^[Yy]$ ]]; then
                        # Only update hostname, keep old path
                        BACKUP_HOSTNAME="$new_hostname"
                        save_config
                        create_backup_script
                        echo ""
                        log_success "VPS identifier updated to: $BACKUP_HOSTNAME"
                        log_warning "Remote path unchanged: $BACKUP_REMOTE_DIR"
                        echo ""
                        log_info "Note: Your backups will still use the old path"
                    else
                        # Update both hostname and remote path (default behavior)
                        BACKUP_HOSTNAME="$new_hostname"
                        BACKUP_REMOTE_DIR="$new_suggested_path"
                        save_config
                        create_backup_script
                        echo ""
                        log_success "✓ VPS identifier updated to: $BACKUP_HOSTNAME"
                        log_success "✓ Remote path updated to: $BACKUP_REMOTE_DIR"
                        echo ""
                        log_warning "Important: Old backups at the previous path will NOT be moved"
                        log_info "If you need to access old backups, they remain at: $old_remote:vps-backup"
                    fi
                fi
                ;;

            7)
                # Edit remote directory
                echo ""
                echo -e "Current remote: ${CYAN}$BACKUP_REMOTE_DIR${NC}"
                read -p "New remote directory (or Enter to keep): " new_remote
                if [ -n "$new_remote" ]; then
                    BACKUP_REMOTE_DIR="$new_remote"
                    save_config
                    create_backup_script
                    log_success "Remote directory updated"
                fi
                ;;

            8)
                # Change encryption password
                echo ""
                log_warning "Changing password will not re-encrypt existing backups"
                read -sp "Enter new encryption password: " new_pass
                echo ""
                read -sp "Confirm password: " pass_confirm
                echo ""
                if [ "$new_pass" = "$pass_confirm" ] && [ -n "$new_pass" ]; then
                    BACKUP_PASSWORD="$new_pass"
                    save_config
                    create_backup_script
                    log_success "Encryption password updated"
                else
                    log_error "Passwords do not match or empty"
                fi
                ;;

            9)
                # Edit Telegram settings
                echo ""
                if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
                    echo -e "Current Bot Token: ${CYAN}${TG_BOT_TOKEN:0:10}...${NC}"
                    echo -e "Current Chat ID:   ${CYAN}${TG_CHAT_ID}${NC}"
                    echo ""
                    read -p "Disable Telegram notifications? [y/N] (press Enter to skip): " disable
                    if [[ $disable =~ ^[Yy]$ ]]; then
                        TG_BOT_TOKEN=""
                        TG_CHAT_ID=""
                        save_config
                        create_backup_script
                        log_success "Telegram notifications disabled"
                    else
                        read -p "New Bot Token (or Enter to keep): " new_token
                        read -p "New Chat ID (or Enter to keep): " new_chat
                        if [ -n "$new_token" ]; then
                            TG_BOT_TOKEN="$new_token"
                        fi
                        if [ -n "$new_chat" ]; then
                            TG_CHAT_ID="$new_chat"
                        fi
                        save_config
                        create_backup_script
                        log_success "Telegram settings updated"
                    fi
                else
                    log_info "Telegram notifications are currently disabled"
                    read -p "Enable Telegram notifications? [Y/n] (press Enter to enable): " enable
                    if [[ ! $enable =~ ^[Nn]$ ]]; then
                        read -p "Bot Token: " TG_BOT_TOKEN
                        read -p "Chat ID: " TG_CHAT_ID
                        save_config
                        create_backup_script
                        log_success "Telegram notifications enabled"
                    fi
                fi
                ;;

            10)
                # Edit paths
                echo ""
                echo -e "Current log file:  ${CYAN}$BACKUP_LOG_FILE${NC}"
                echo -e "Current temp dir:  ${CYAN}$BACKUP_TMP_DIR${NC}"
                echo ""
                read -p "New log file path (or Enter to keep): " new_log
                read -p "New temp directory (or Enter to keep): " new_tmp
                if [ -n "$new_log" ]; then
                    BACKUP_LOG_FILE="$new_log"
                fi
                if [ -n "$new_tmp" ]; then
                    BACKUP_TMP_DIR="$new_tmp"
                fi
                save_config
                create_backup_script
                log_success "Paths updated"
                ;;

            11)
                # Configure log rotation
                echo ""
                echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                echo -e "${CYAN}Configure Log Rotation${NC}"
                echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                echo ""

                # Get current configuration
                local logrotate_conf="/etc/logrotate.d/vps-backup"
                if [ -f "$logrotate_conf" ]; then
                    local current_size=$(grep "^\s*size" "$logrotate_conf" | awk '{print $2}')
                    local current_days=$(grep "^\s*rotate" "$logrotate_conf" | awk '{print $2}')

                    echo -e "${GREEN}Current configuration:${NC}"
                    echo -e "  Max log size: ${CYAN}${current_size:-Not set}${NC}"
                    echo -e "  Keep logs:    ${CYAN}${current_days:-Not set} days${NC}"
                else
                    echo -e "${YELLOW}Log rotation is not configured yet${NC}"
                    local current_size="10M"
                    local current_days="7"
                fi

                echo ""
                echo -e "${CYAN}Recommended settings:${NC}"
                echo -e "  • Max log size: ${GREEN}10MB${NC} (rotate when file reaches this size)"
                echo -e "  • Keep logs: ${GREEN}7 days${NC} (older logs will be deleted)"
                echo ""

                read -p "Max log file size (e.g., 10M, 50M, 100M) [${current_size:-10M}]: " new_size
                new_size="${new_size:-${current_size:-10M}}"

                read -p "Number of days to keep logs [${current_days:-7}]: " new_days
                new_days="${new_days:-${current_days:-7}}"

                echo ""
                log_info "Updating log rotation configuration..."
                setup_logrotate "$new_size" "$new_days"

                echo ""
                read -p "Press Enter to continue..."
                ;;

            12)
                # Regenerate backup script
                echo ""
                echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                echo -e "${CYAN}Regenerate Backup Script${NC}"
                echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                echo ""
                log_info "This will regenerate the backup script based on your current configuration"
                echo ""
                echo -e "${GREEN}What this does:${NC}"
                echo -e "  • Applies latest code updates from manager script"
                echo -e "  • Uses your current configuration from: ${CYAN}${BACKUP_ENV}${NC}"
                echo -e "  • Generates new script at: ${CYAN}${BACKUP_SCRIPT}${NC}"
                echo ""
                read -p "Continue? [Y/n] (press Enter to continue): " confirm

                if [[ ! $confirm =~ ^[Nn]$ ]]; then
                    echo ""
                    create_backup_script
                else
                    log_info "Regeneration cancelled"
                fi
                echo ""
                read -p "Press Enter to continue..."
                ;;

            0)
                return 0
                ;;

            *)
                log_error "Invalid selection"
                ;;
        esac
    done
}

# Uninstall backup system
uninstall_backup() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}Uninstall VPS Backup System${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    log_warning "This will remove all backup scripts and configuration"
    echo ""
    echo -e "${GREEN}What will be removed:${NC}"
    echo -e "  • Backup script: ${CYAN}${BACKUP_SCRIPT}${NC}"
    echo -e "  • Configuration file: ${CYAN}${BACKUP_ENV}${NC}"
    echo -e "  • Manager script: ${CYAN}/usr/local/bin/backup_manager.sh${NC}"
    echo -e "  • Restore script: ${CYAN}/usr/local/bin/backup_restore.sh${NC}"
    echo -e "  • Cron jobs for automated backups"
    echo -e "  • Logrotate configuration: ${CYAN}/etc/logrotate.d/vps-backup${NC}"

    # Check if log file exists and show it
    local log_file_path=""
    if [ -f "$BACKUP_ENV" ]; then
        source "$BACKUP_ENV"
        if [ -n "$BACKUP_LOG_FILE" ] && [ -f "$BACKUP_LOG_FILE" ]; then
            log_file_path="$BACKUP_LOG_FILE"
            echo -e "  • Log file: ${CYAN}${BACKUP_LOG_FILE}${NC}"
        fi
    fi

    echo ""
    echo -e "${GREEN}What will NOT be removed:${NC}"
    echo -e "  • rclone configuration and program"
    echo -e "  • Remote backup files in cloud storage"
    echo ""

    log_warning "This action cannot be undone!"
    read -p "Are you sure you want to uninstall? [y/N] (press Enter to cancel): " confirm
    confirm="${confirm:-N}"  # Default to N (cancel)

    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        log_info "Uninstall cancelled"
        return 0
    fi

    echo ""
    log_info "Starting uninstall..."

    # Remove cron jobs
    if crontab -l 2>/dev/null | grep -q "vps-backup.sh"; then
        log_info "Removing cron jobs..."
        crontab -l 2>/dev/null | grep -v "vps-backup.sh" | crontab -
        log_success "Cron jobs removed"
    fi

    # Remove backup script
    if [ -f "$BACKUP_SCRIPT" ]; then
        rm -f "$BACKUP_SCRIPT"
        log_success "Backup script removed: $BACKUP_SCRIPT"
    fi

    # Remove configuration file
    if [ -f "$BACKUP_ENV" ]; then
        rm -f "$BACKUP_ENV"
        log_success "Configuration file removed: $BACKUP_ENV"
    fi

    # Remove restore script
    if [ -f "/usr/local/bin/backup_restore.sh" ]; then
        rm -f "/usr/local/bin/backup_restore.sh"
        log_success "Restore script removed"
    fi

    # Remove log file
    if [ -n "$log_file_path" ] && [ -f "$log_file_path" ]; then
        rm -f "$log_file_path"
        log_success "Log file removed: $log_file_path"
    fi

    # Remove logrotate configuration
    if [ -f "/etc/logrotate.d/vps-backup" ]; then
        rm -f "/etc/logrotate.d/vps-backup"
        log_success "Logrotate configuration removed"
    fi

    # Remove manager script itself (last step)
    if [ -f "/usr/local/bin/backup_manager.sh" ]; then
        log_success "Manager script will be removed: /usr/local/bin/backup_manager.sh"
        log_info "Removing manager script..."
        rm -f "/usr/local/bin/backup_manager.sh"
    fi

    echo ""
    log_success "Uninstall completed!"
    echo ""
    log_info "Your remote backup files remain in cloud storage"
    log_info "rclone is still installed and configured"
    echo ""
}

# Main menu
main() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Please run this script with root privileges"
        exit 1
    fi

    case "${1:-menu}" in
        status)
            show_status
            ;;
        configure|config|setup)
            configure_backup
            ;;
        run|backup)
            run_backup
            ;;
        list)
            list_backups
            ;;
        logs)
            view_logs
            ;;
        test)
            test_configuration
            ;;
        cron|schedule)
            setup_cron
            ;;
        edit|modify)
            edit_configuration
            ;;
        install-deps)
            echo ""
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${CYAN}Install Dependencies${NC}"
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
            echo -e "${GREEN}Select dependencies to install:${NC}"
            echo -e "  ${CYAN}1.${NC} rclone (required for full backup)"
            echo -e "  ${CYAN}2.${NC} restic (required for incremental backup)"
            echo -e "  ${CYAN}3.${NC} Both"
            echo ""
            read -p "Select [1-3]: " dep_choice

            case $dep_choice in
                1)
                    install_rclone
                    ;;
                2)
                    install_restic
                    ;;
                3)
                    install_rclone
                    install_restic
                    ;;
                *)
                    log_error "Invalid choice"
                    ;;
            esac
            ;;
        regenerate)
            # Regenerate backup script with latest code
            if ! is_configured; then
                log_error "Backup is not configured"
                log_info "Please run configuration wizard first"
                return 1
            fi

            load_config
            echo ""
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${CYAN}Regenerate Backup Script${NC}"
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
            log_info "This will regenerate the backup script based on your current configuration"
            echo ""
            echo -e "${GREEN}Configuration details:${NC}"
            echo -e "  Config file: ${CYAN}${BACKUP_ENV}${NC}"
            echo -e "  Script path: ${CYAN}${BACKUP_SCRIPT}${NC}"
            echo ""
            create_backup_script
            ;;
        uninstall|remove)
            uninstall_backup
            exit 0
            ;;
        restore)
            # Launch restore tool
            if [ -f "${SCRIPTS_PATH}/backup_restore.sh" ]; then
                bash "${SCRIPTS_PATH}/backup_restore.sh" menu
            elif [ -f "$(dirname "$0")/backup_restore.sh" ]; then
                bash "$(dirname "$0")/backup_restore.sh" menu
            else
                log_error "Restore script not found"
                return 1
            fi
            ;;
        menu)
            while true; do
                show_status
                echo ""

                if is_configured; then
                    echo -e "${GREEN}Available actions:${NC}"
                    echo -e "  ${GREEN}1.${NC} ${GREEN}Run backup now${NC}"
                    echo -e "  ${CYAN}2.${NC} List remote backups"
                    echo -e "  ${MAGENTA}3.${NC} ${MAGENTA}Restore backup${NC}"
                    echo -e "  ${CYAN}4.${NC} View logs"
                    echo -e "  ${CYAN}5.${NC} Test configuration"
                    echo -e "  ${YELLOW}6.${NC} ${YELLOW}Edit configuration${NC}"
                    echo -e "  ${CYAN}7.${NC} Reconfigure backup (full setup)"
                    echo -e "  ${CYAN}8.${NC} Install dependencies"
                    echo -e "  ${RED}9.${NC} ${RED}Uninstall backup system${NC}"
                    echo -e "  ${CYAN}0.${NC} Exit (default)"
                    echo ""
                    read -p "Select action [0-9] (press Enter to exit): " action
                    action="${action:-0}"  # Default to option 0 (exit)

                    case $action in
                        1) run_backup ;;
                        2) list_backups ;;
                        3)
                            if [ -f "${SCRIPTS_PATH}/backup_restore.sh" ]; then
                                bash "${SCRIPTS_PATH}/backup_restore.sh" menu
                            elif [ -f "$(dirname "$0")/backup_restore.sh" ]; then
                                bash "$(dirname "$0")/backup_restore.sh" menu
                            else
                                log_error "Restore script not found"
                            fi
                            ;;
                        4) view_logs ;;
                        5) test_configuration ;;
                        6) edit_configuration ;;
                        7) configure_backup ;;
                        8) install_dependencies ;;
                        9)
                            uninstall_backup
                            exit 0
                            ;;
                        0)
                            log_info "Exiting"
                            exit 0
                            ;;
                        *) log_error "Invalid selection" ;;
                    esac
                else
                    echo ""
                    read -p "Backup is not configured. Configure now? [Y/n] (press Enter to confirm): " config
                    if [[ ! $config =~ ^[Nn]$ ]]; then
                        configure_backup
                    else
                        log_info "Exiting"
                        exit 0
                    fi
                fi
            done
            ;;
        *)
            log_error "Unknown command: $1"
            echo "Usage: $0 {status|configure|edit|run|restore|list|logs|test|cron|regenerate|menu}"
            echo ""
            echo "Commands:"
            echo "  status     - Show backup configuration status"
            echo "  configure  - Run full configuration wizard"
            echo "  edit       - Edit specific configuration items"
            echo "  run        - Run backup now"
            echo "  restore    - Restore from backup (decrypt & extract)"
            echo "  list       - List remote backups"
            echo "  logs       - View backup logs"
            echo "  test       - Test backup configuration"
            echo "  cron       - Setup automatic backup schedule"
            echo "  regenerate - Regenerate backup script (updates translations)"
            echo "  menu       - Interactive menu (default)"
            exit 1
            ;;
    esac
}

main "$@"
