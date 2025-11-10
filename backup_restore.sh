#!/bin/bash

#######################################
# VPS Backup Restore Tool
# Decrypt and restore backups
#######################################

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
BACKUP_ENV="/usr/local/bin/vps-backup.env"
RESTORE_DIR="/tmp/vps-restore-$$"

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

# Load configuration
load_config() {
    if [ ! -f "$BACKUP_ENV" ]; then
        log_error "Backup configuration not found: $BACKUP_ENV"
        log_info "Please configure backup first"
        exit 1
    fi
    source "$BACKUP_ENV"
}

# List available backups
list_backups() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}Available Backups${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if ! command -v rclone &> /dev/null; then
        log_error "rclone is not installed"
        return 1
    fi

    local backups=$(rclone lsl "${BACKUP_REMOTE_DIR}" 2>/dev/null | grep "backup-.*\.tar\.gz\.enc")

    if [ -z "$backups" ]; then
        log_warning "No backups found in ${BACKUP_REMOTE_DIR}"
        return 0
    fi

    echo ""
    echo "$backups" | nl -w3 -s'. ' | while read -r line; do
        echo -e "${CYAN}$line${NC}"
    done

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Download and decrypt backup
restore_backup() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}Restore Backup${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # List backups
    local backups=$(rclone lsf "${BACKUP_REMOTE_DIR}" 2>/dev/null | grep "backup-.*\.tar\.gz\.enc")

    if [ -z "$backups" ]; then
        log_error "No backups found"
        return 1
    fi

    echo ""
    echo -e "${GREEN}Available backups:${NC}"
    local count=1
    local backup_array=()
    while IFS= read -r backup; do
        backup_array+=("$backup")
        echo -e "  ${CYAN}$count.${NC} $backup"
        count=$((count+1))
    done <<< "$backups"

    echo ""
    read -p "Select backup number to restore [1-${#backup_array[@]}]: " selection

    if ! [[ $selection =~ ^[0-9]+$ ]] || [ $selection -lt 1 ] || [ $selection -gt ${#backup_array[@]} ]; then
        log_error "Invalid selection"
        return 1
    fi

    local selected_backup="${backup_array[$((selection-1))]}"

    echo ""
    log_warning "Selected backup: ${selected_backup}"

    # Ask for restore location
    echo ""
    read -p "Restore to directory [${RESTORE_DIR}] (press Enter for default): " restore_dir
    restore_dir="${restore_dir:-$RESTORE_DIR}"

    # Create restore directory
    mkdir -p "$restore_dir"

    echo ""
    log_warning "⚠️  WARNING: This will download and decrypt the backup"
    log_warning "Restore location: $restore_dir"
    echo ""
    read -p "Continue? [y/N] (press Enter to cancel): " confirm

    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        log_info "Restore cancelled"
        return 0
    fi

    # Download backup
    echo ""
    log_info "Downloading backup from ${BACKUP_REMOTE_DIR}..."
    local encrypted_file="${restore_dir}/${selected_backup}"

    rclone copy "${BACKUP_REMOTE_DIR}/${selected_backup}" "${restore_dir}/"

    if [ $? -ne 0 ] || [ ! -f "$encrypted_file" ]; then
        log_error "Failed to download backup"
        return 1
    fi

    log_success "Downloaded: $encrypted_file"

    # Decrypt backup
    echo ""
    log_info "Decrypting backup..."
    local decrypted_file="${encrypted_file%.enc}"

    if [ -z "$BACKUP_PASSWORD" ]; then
        read -sp "Enter decryption password: " decrypt_pass
        echo ""
    else
        decrypt_pass="$BACKUP_PASSWORD"
    fi

    openssl enc -aes-256-cbc -d -salt -pbkdf2 -pass pass:"$decrypt_pass" \
        -in "$encrypted_file" \
        -out "$decrypted_file"

    if [ $? -ne 0 ]; then
        log_error "Decryption failed - incorrect password or corrupted file"
        rm -f "$encrypted_file"
        return 1
    fi

    log_success "Decrypted: $decrypted_file"
    rm -f "$encrypted_file"

    # Extract backup
    echo ""
    log_info "Extracting backup..."

    tar -xzf "$decrypted_file" -C "$restore_dir"

    if [ $? -ne 0 ]; then
        log_error "Extraction failed"
        rm -f "$decrypted_file"
        return 1
    fi

    log_success "Extracted to: $restore_dir"
    rm -f "$decrypted_file"

    # Show contents
    echo ""
    echo -e "${GREEN}Restored files:${NC}"
    ls -lh "$restore_dir"

    echo ""
    log_success "Restore completed successfully!"
    log_info "Restored files are in: $restore_dir"
    echo ""
    log_warning "Remember to:"
    echo "  1. Verify the restored files"
    echo "  2. Copy files to their original locations if needed"
    echo "  3. Set correct permissions"
    echo "  4. Restart services if necessary"
}

# Verify backup integrity
verify_backup() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}Verify Backup Integrity${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # List backups
    local backups=$(rclone lsf "${BACKUP_REMOTE_DIR}" 2>/dev/null | grep "backup-.*\.tar\.gz\.enc")

    if [ -z "$backups" ]; then
        log_error "No backups found"
        return 1
    fi

    echo ""
    echo -e "${GREEN}Available backups:${NC}"
    local count=1
    local backup_array=()
    while IFS= read -r backup; do
        backup_array+=("$backup")
        echo -e "  ${CYAN}$count.${NC} $backup"
        count=$((count+1))
    done <<< "$backups"

    echo ""
    read -p "Select backup to verify [1-${#backup_array[@]}]: " selection

    if ! [[ $selection =~ ^[0-9]+$ ]] || [ $selection -lt 1 ] || [ $selection -gt ${#backup_array[@]} ]; then
        log_error "Invalid selection"
        return 1
    fi

    local selected_backup="${backup_array[$((selection-1))]}"

    echo ""
    log_info "Verifying: ${selected_backup}"

    local temp_dir=$(mktemp -d)
    local encrypted_file="${temp_dir}/${selected_backup}"

    # Download
    log_info "Downloading..."
    rclone copy "${BACKUP_REMOTE_DIR}/${selected_backup}" "${temp_dir}/"

    if [ $? -ne 0 ] || [ ! -f "$encrypted_file" ]; then
        log_error "Download failed"
        rm -rf "$temp_dir"
        return 1
    fi

    # Try to decrypt (test only, don't save)
    echo ""
    log_info "Testing decryption..."

    if [ -z "$BACKUP_PASSWORD" ]; then
        read -sp "Enter password: " test_pass
        echo ""
    else
        test_pass="$BACKUP_PASSWORD"
    fi

    openssl enc -aes-256-cbc -d -salt -pbkdf2 -pass pass:"$test_pass" \
        -in "$encrypted_file" 2>/dev/null | tar -tz >/dev/null 2>&1

    if [ $? -eq 0 ]; then
        log_success "✓ Backup is valid and can be decrypted"
        log_success "✓ Archive structure is intact"
    else
        log_error "✗ Backup verification failed"
        log_error "File may be corrupted or password incorrect"
    fi

    rm -rf "$temp_dir"
}

# Main menu
main() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Please run with root privileges"
        exit 1
    fi

    load_config

    case "${1:-menu}" in
        list)
            list_backups
            ;;
        restore)
            restore_backup
            ;;
        verify)
            verify_backup
            ;;
        menu)
            while true; do
                echo ""
                echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                echo -e "${CYAN}VPS Backup Restore Tool${NC}"
                echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                echo ""
                echo -e "${GREEN}Available actions:${NC}"
                echo -e "  ${CYAN}1.${NC} List available backups"
                echo -e "  ${CYAN}2.${NC} Restore backup"
                echo -e "  ${CYAN}3.${NC} Verify backup integrity"
                echo -e "  ${CYAN}0.${NC} Exit"
                echo ""
                read -p "Select action [0-3]: " action

                case $action in
                    1) list_backups ;;
                    2) restore_backup ;;
                    3) verify_backup ;;
                    0)
                        log_info "Exiting"
                        exit 0
                        ;;
                    *)
                        log_error "Invalid selection"
                        ;;
                esac
            done
            ;;
        *)
            echo "Usage: $0 {list|restore|verify|menu}"
            exit 1
            ;;
    esac
}

main "$@"
