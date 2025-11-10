#!/bin/bash

#######################################
# VPS Backup Manager - One-line Installer
# Author: uniquMonte
# Repository: https://github.com/uniquMonte/server-backup
# Purpose: Quickly setup automated backups for your VPS
#######################################

# Error handling
set -o pipefail

# Trap errors for cleanup
trap 'handle_error $? $LINENO' ERR

handle_error() {
    local exit_code=$1
    local line_num=$2
    if [ $exit_code -ne 0 ]; then
        log_error "Error occurred at line $line_num with exit code $exit_code"
    fi
}

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Print banner
print_banner() {
    echo -e "${CYAN}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║           VPS Backup Manager v1.0                         ║
║                                                           ║
║           Features:                                       ║
║           - Encrypted backups to cloud storage            ║
║           - Google Drive, Dropbox, OneDrive support       ║
║           - Automatic cleanup of old backups              ║
║           - Telegram notifications                        ║
║           - SHA256 integrity verification                 ║
║           - Easy restore functionality                    ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# Check root privileges
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Please run this script with root privileges"
        exit 1
    fi
}

# Check dependencies
check_dependencies() {
    local deps=("curl" "bash")
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required dependencies: ${missing[*]}"
        log_info "Please install them first and try again"
        exit 1
    fi
}

# Initialize remote execution mode
init_remote_mode() {
    local script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    local scripts_path="${script_dir}/scripts"

    if [ ! -d "$scripts_path" ]; then
        IS_REMOTE_MODE=true

        # Priority: CLI arg > env var > default (main)
        BRANCH="${BACKUP_BRANCH:-${VPS_BACKUP_BRANCH:-main}}"
        REPO_URL="https://raw.githubusercontent.com/uniquMonte/server-backup/${BRANCH}"
        TEMP_DIR="/tmp/vps-backup-$$"
        mkdir -p "$TEMP_DIR/scripts"

        SCRIPT_DIR="$TEMP_DIR"
        SCRIPTS_PATH="${SCRIPT_DIR}/scripts"

        log_info "Remote execution mode enabled"
        log_info "Using branch: ${BRANCH}"
    else
        IS_REMOTE_MODE=false
        SCRIPT_DIR="$script_dir"
        SCRIPTS_PATH="$scripts_path"
    fi
}

# Download script if needed (for remote execution)
download_script_if_needed() {
    local script_name="$1"
    local script_path="${SCRIPTS_PATH}/${script_name}"

    # If script already exists locally, no need to download
    if [ -f "$script_path" ] && [ "$IS_REMOTE_MODE" != "true" ]; then
        return 0
    fi

    # If not in remote execution mode, script should exist locally
    if [ "$IS_REMOTE_MODE" != "true" ]; then
        log_error "${script_name} not found at ${script_path}"
        return 1
    fi

    # Remote execution mode - download the script
    log_info "Downloading ${script_name}..."

    if ! curl -fsSL --proto '=https' --tlsv1.2 "${REPO_URL}/scripts/${script_name}" -o "${script_path}"; then
        log_error "Failed to download ${script_name}"
        log_error "URL: ${REPO_URL}/scripts/${script_name}"
        return 1
    fi

    chmod +x "${script_path}"
    return 0
}

# Main function
main() {
    # Clear screen
    clear

    # Print banner
    print_banner

    # Check root privileges
    check_root

    # Check dependencies
    check_dependencies

    # Initialize remote mode (if needed)
    init_remote_mode

    # Download required scripts
    if ! download_script_if_needed "backup_manager.sh"; then
        log_error "Failed to load backup manager script"
        exit 1
    fi

    # Also download backup_restore.sh for restore functionality
    if ! download_script_if_needed "backup_restore.sh"; then
        log_error "Failed to load backup restore script"
        exit 1
    fi

    log_info "Launching VPS Backup Manager..."
    echo ""

    # Execute backup manager with all arguments
    bash "${SCRIPTS_PATH}/backup_manager.sh" "$@"

    local exit_code=$?

    # Cleanup temp directory if in remote mode
    if [ "$IS_REMOTE_MODE" = "true" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi

    exit $exit_code
}

# Execute main function
main "$@"
