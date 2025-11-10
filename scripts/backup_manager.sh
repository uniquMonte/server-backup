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

# Load configuration
load_config() {
    if [ -f "$BACKUP_ENV" ]; then
        source "$BACKUP_ENV"
    fi
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
        echo -e "  Remote Directory:  ${CYAN}${BACKUP_REMOTE_DIR:-Not set}${NC}"
        echo -e "  Log File:          ${CYAN}${BACKUP_LOG_FILE:-$DEFAULT_LOG_FILE}${NC}"
        echo -e "  Temp Directory:    ${CYAN}${BACKUP_TMP_DIR:-$DEFAULT_TMP_DIR}${NC}"
        echo -e "  Max Backups:       ${CYAN}${BACKUP_MAX_KEEP:-3}${NC}"

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
            local last_backup=$(grep "备份过程完成\|backup completed" "${BACKUP_LOG_FILE:-$DEFAULT_LOG_FILE}" | tail -1)
            if [ -n "$last_backup" ]; then
                echo -e "  ${CYAN}${last_backup}${NC}"
            else
                echo -e "  ${YELLOW}No backup history found${NC}"
            fi
        fi

        # Quick action hint
        echo ""
        echo -e "${BLUE}💡 Tip:${NC} Press Enter in the menu to run backup immediately"

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

    # Step 1: Configure backup sources
    echo ""
    log_info "Step 1/6: Configure Backup Sources"
    configure_backup_sources || return 1

    # Step 2: Configure remote directory
    echo ""
    log_info "Step 2/6: Configure Remote Storage"
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
                        log_error "无效的选择，请输入 0-${remote_count}"
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

    # Step 3: Setup rclone if needed
    echo ""
    log_info "Step 3/6: Configure Rclone"
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

    # Step 4: Configure encryption password
    echo ""
    log_info "Step 4/6: Configure Encryption"
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

    # Step 5: Configure Telegram notifications (recommended)
    echo ""
    log_info "Step 5/6: Configure Telegram Notifications (Recommended)"
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

    # Step 6: Other settings
    echo ""
    log_info "Step 6/6: Additional Settings"
    echo ""

    read -p "Max backups to keep [${BACKUP_MAX_KEEP:-3}] (press Enter for default): " max_keep
    BACKUP_MAX_KEEP="${max_keep:-${BACKUP_MAX_KEEP:-3}}"

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

    echo ""
    log_success "Configuration saved successfully!"
    echo ""
    echo -e "${GREEN}Configuration Summary:${NC}"
    echo -e "  VPS identifier:    ${CYAN}$BACKUP_HOSTNAME${NC}"
    echo -e "  Config file:       ${CYAN}$BACKUP_ENV${NC}"
    echo -e "  Backup script:     ${CYAN}$BACKUP_SCRIPT${NC}"
    echo -e "  Log file:          ${CYAN}$BACKUP_LOG_FILE${NC}"
    echo -e "  Remote directory:  ${CYAN}$BACKUP_REMOTE_DIR${NC}"
    echo -e "  Max backups:       ${CYAN}$BACKUP_MAX_KEEP${NC}"

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
EOF

    chmod 600 "$BACKUP_ENV"
    log_success "Configuration saved to $BACKUP_ENV"
}

# Create backup execution script
create_backup_script() {
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
❌ <b>备份错误</b>
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
        log_and_notify "另一个备份进程正在运行 (PID: $(cat "$LOCK_FILE"))" true
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
    log_and_notify "磁盘空间不足 (可用: $((AVAILABLE_SPACE/1024))MB, 需要: $((REQUIRED_SPACE/1024))MB)" true
    exit 1
fi

# Start backup
log_and_notify "开始备份过程 - ${DATE}"

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
        log_and_notify "警告: 备份源不存在 - $SRC"
    fi
done

# Compress
log_and_notify "正在压缩备份..."
tar "${TAR_ARGS[@]}" >> "$BACKUP_LOG_FILE" 2>&1
rc=$?

if [ $rc -ne 0 ] && [ $rc -ne 1 ]; then
    log_and_notify "压缩失败 (tar exit code $rc)" true
    exit 1
fi

# Encrypt
log_and_notify "正在加密备份..."
openssl enc -aes-256-cbc -salt -pbkdf2 -pass pass:"$BACKUP_PASSWORD" \
    -in "${BACKUP_TMP_DIR}/${BACKUP_FILE}" \
    -out "${BACKUP_TMP_DIR}/${ENCRYPTED_BACKUP_FILE}" >> "$BACKUP_LOG_FILE" 2>&1

if [ $? -ne 0 ]; then
    log_and_notify "加密失败" true
    exit 1
fi

rm -f "${BACKUP_TMP_DIR}/${BACKUP_FILE}"

# Generate SHA256 checksum
log_and_notify "生成校验和..."
sha256sum "${BACKUP_TMP_DIR}/${ENCRYPTED_BACKUP_FILE}" | awk '{print $1}' > "${BACKUP_TMP_DIR}/${CHECKSUM_FILE}"

# Get file size
BACKUP_SIZE=$(du -h "${BACKUP_TMP_DIR}/${ENCRYPTED_BACKUP_FILE}" | cut -f1)

# Upload with retry (max 3 attempts)
log_and_notify "正在上传到 ${BACKUP_REMOTE_DIR}..."
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
            log_and_notify "上传成功，大小验证通过"
            break
        else
            log_and_notify "警告: 文件大小不匹配 (本地: $LOCAL_SIZE, 远程: $REMOTE_SIZE)"
        fi
    fi

    UPLOAD_ATTEMPTS=$((UPLOAD_ATTEMPTS + 1))
    if [ $UPLOAD_ATTEMPTS -lt $MAX_ATTEMPTS ]; then
        log_and_notify "上传失败，重试 $UPLOAD_ATTEMPTS/$MAX_ATTEMPTS..."
        sleep 5
    fi
done

if [ $UPLOAD_ATTEMPTS -eq $MAX_ATTEMPTS ]; then
    log_and_notify "上传失败，已达最大重试次数" true
    exit 1
fi

# Upload checksum file
rclone copy "${BACKUP_TMP_DIR}/${CHECKSUM_FILE}" "${BACKUP_REMOTE_DIR}" >> "$BACKUP_LOG_FILE" 2>&1

# Cleanup local files
rm -f "${BACKUP_TMP_DIR}/${ENCRYPTED_BACKUP_FILE}"
rm -f "${BACKUP_TMP_DIR}/${CHECKSUM_FILE}"

# Remove old backups
log_and_notify "正在清理旧备份..."
OLD_BACKUPS=$(rclone lsf "${BACKUP_REMOTE_DIR}" | grep "^backup-${HOSTNAME}-.*\.tar\.gz\.enc$" | sort -r | tail -n +$((BACKUP_MAX_KEEP + 1)))

for file in $OLD_BACKUPS; do
    rclone delete "${BACKUP_REMOTE_DIR}/${file}" --drive-use-trash=false >> "$BACKUP_LOG_FILE" 2>&1
    rclone delete "${BACKUP_REMOTE_DIR}/${file}.sha256" --drive-use-trash=false >> "$BACKUP_LOG_FILE" 2>&1
    log_and_notify "已删除旧备份: $file"
done

# Get backup stats
BACKUP_COUNT=$(rclone lsf "${BACKUP_REMOTE_DIR}" | grep "^backup-${HOSTNAME}-" | grep "\.tar\.gz\.enc$" | wc -l)

# Success notification
send_telegram_message "🖥️ <b>$HOSTNAME 备份完成</b>
✅ 备份成功
📦 文件大小: ${BACKUP_SIZE}
📚 保留备份数: ${BACKUP_COUNT}
📅 备份文件: ${ENCRYPTED_BACKUP_FILE}
✓ 已生成 SHA256 校验和"

log_and_notify "备份过程完成! 文件: ${ENCRYPTED_BACKUP_FILE} (${BACKUP_SIZE})"

exit 0
EOFSCRIPT

    chmod +x "$BACKUP_SCRIPT"
    log_success "Backup script created at $BACKUP_SCRIPT"
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
    echo -e "${GREEN}Max backups to keep:${NC}   ${CYAN}${BACKUP_MAX_KEEP}${NC}"
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

    echo -e "${YELLOW}Common schedules:${NC}"
    echo -e "  1. Daily at 2:00 AM      (0 2 * * *)"
    echo -e "  2. Daily at 3:00 AM      (0 3 * * *)"
    echo -e "  3. Every 12 hours        (0 */12 * * *)"
    echo -e "  4. Weekly (Sunday 2 AM)  (0 2 * * 0)"
    echo -e "  5. Custom schedule"
    echo -e "  6. Remove scheduled backup"
    echo ""

    read -p "Select option [1-6]: " schedule_option

    local cron_schedule=""
    case $schedule_option in
        1) cron_schedule="0 2 * * *" ;;
        2) cron_schedule="0 3 * * *" ;;
        3) cron_schedule="0 */12 * * *" ;;
        4) cron_schedule="0 2 * * 0" ;;
        5)
            read -p "Enter cron schedule (e.g., '0 2 * * *'): " cron_schedule
            ;;
        6)
            # Remove existing cron job
            crontab -l 2>/dev/null | grep -v "$BACKUP_SCRIPT" | crontab -
            log_success "Scheduled backup removed"
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
        echo -e "  ${CYAN}1.${NC} VPS identifier (hostname/label)"
        echo -e "  ${CYAN}2.${NC} Backup sources (add/remove directories)"
        echo -e "  ${CYAN}3.${NC} Remote storage directory"
        echo -e "  ${CYAN}4.${NC} Encryption password"
        echo -e "  ${CYAN}5.${NC} Telegram notifications"
        echo -e "  ${CYAN}6.${NC} Backup retention (max backups)"
        echo -e "  ${CYAN}7.${NC} Log and temp paths"
        echo -e "  ${CYAN}8.${NC} View current configuration"
        echo -e "  ${CYAN}9.${NC} Setup/modify backup schedule (cron)"
        echo -e "  ${CYAN}0.${NC} Return to main menu"
        echo ""
        read -p "Select option [0-9]: " edit_choice

        case $edit_choice in
            1)
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

            2)
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
                        read -p "Enter path to add: " new_src
                        new_src="${new_src/#\~/$HOME}"
                        if [ -e "$new_src" ]; then
                            SOURCES+=("$new_src")
                            BACKUP_SRCS=$(IFS='|'; echo "${SOURCES[*]}")
                            save_config
                            create_backup_script
                            log_success "Added: $new_src"
                        else
                            log_warning "Path does not exist: $new_src"
                            read -p "Add anyway? [y/N] (press Enter to skip): " add_anyway
                            if [[ $add_anyway =~ ^[Yy]$ ]]; then
                                SOURCES+=("$new_src")
                                BACKUP_SRCS=$(IFS='|'; echo "${SOURCES[*]}")
                                save_config
                                create_backup_script
                                log_success "Added: $new_src"
                            fi
                        fi
                        ;;
                    r|R)
                        echo ""
                        read -p "Enter number to remove (1-${#SOURCES[@]}): " remove_idx
                        if [[ $remove_idx =~ ^[0-9]+$ ]] && [ $remove_idx -ge 1 ] && [ $remove_idx -le ${#SOURCES[@]} ]; then
                            removed="${SOURCES[$((remove_idx-1))]}"
                            unset 'SOURCES[$((remove_idx-1))]'
                            SOURCES=("${SOURCES[@]}")  # Reindex array
                            BACKUP_SRCS=$(IFS='|'; echo "${SOURCES[*]}")
                            save_config
                            create_backup_script
                            log_success "Removed: $removed"
                        else
                            log_error "Invalid selection"
                        fi
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

            3)
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

            4)
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

            5)
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

            6)
                # Edit max backups
                echo ""
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
                ;;

            7)
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

            8)
                # View configuration
                show_status
                echo ""
                read -p "Press Enter to continue..."
                ;;

            9)
                # Setup cron
                setup_cron
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
            install_rclone
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
                    echo -e "  ${GREEN}1.${NC} ${GREEN}⚡ 立即运行备份 (Run backup now)${NC}"
                    echo -e "  ${CYAN}2.${NC} List remote backups"
                    echo -e "  ${MAGENTA}3.${NC} ${MAGENTA}🔓 Restore backup (decrypt & restore)${NC}"
                    echo -e "  ${CYAN}4.${NC} View logs"
                    echo -e "  ${CYAN}5.${NC} Test configuration"
                    echo -e "  ${YELLOW}6.${NC} ${YELLOW}📝 Edit configuration (modify settings)${NC}"
                    echo -e "  ${CYAN}7.${NC} Reconfigure backup (full setup)"
                    echo -e "  ${CYAN}8.${NC} Setup automatic backup (cron)"
                    echo -e "  ${CYAN}9.${NC} Install dependencies"
                    echo -e "  ${CYAN}0.${NC} Exit"
                    echo ""
                    read -p "Select action [0-9] (press Enter to run backup): " action
                    action="${action:-1}"  # Default to option 1 (run backup)

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
                        8) setup_cron ;;
                        9) install_rclone ;;
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
            echo "Usage: $0 {status|configure|edit|run|restore|list|logs|test|cron|menu}"
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
            echo "  menu       - Interactive menu (default)"
            exit 1
            ;;
    esac
}

main "$@"
