#!/bin/bash

#######################################
# VPS Backup Restore Tool
# Supports both incremental (restic) and full (tar+openssl) backups
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

    # Set default backup method if not specified
    BACKUP_METHOD="${BACKUP_METHOD:-incremental}"
}

# List available backups (restic snapshots)
list_restic_snapshots() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}Available Backups (Restic Snapshots)${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if ! command -v restic &> /dev/null; then
        log_error "restic is not installed"
        return 1
    fi

    # Set up restic environment
    export RESTIC_REPOSITORY="rclone:${BACKUP_REMOTE_DIR}"
    export RESTIC_PASSWORD="${BACKUP_PASSWORD}"
    export RCLONE_CONFIG="${RCLONE_CONFIG:-$HOME/.config/rclone/rclone.conf}"

    # Check if repository exists
    if ! restic snapshots &> /dev/null; then
        log_warning "No restic repository found at ${BACKUP_REMOTE_DIR}"
        return 0
    fi

    # List snapshots
    local snapshots=$(restic snapshots --json 2>/dev/null)

    if [ -z "$snapshots" ] || [ "$snapshots" = "null" ] || [ "$snapshots" = "[]" ]; then
        log_warning "No snapshots found in restic repository"
        return 0
    fi

    echo ""
    echo -e "${GREEN}Available snapshots:${NC}"
    echo ""

    # Parse and display snapshots with numbering (sorted by date, newest first)
    echo "$snapshots" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if not data:
        print('No snapshots found')
        sys.exit(0)

    # Sort by time in descending order (newest first)
    sorted_data = sorted(data, key=lambda x: x.get('time', ''), reverse=True)

    for idx, snap in enumerate(sorted_data, 1):
        snap_id = snap.get('short_id', snap.get('id', '')[:8])
        snap_time = snap.get('time', '')
        snap_host = snap.get('hostname', '')
        snap_paths = snap.get('paths', [])

        print(f'  {idx}. \033[36m{snap_id}\033[0m  \033[33m{snap_time}\033[0m')
        print(f'     Host: \033[32m{snap_host}\033[0m')
        if snap_paths:
            paths_preview = ', '.join(snap_paths[:3])
            if len(snap_paths) > 3:
                paths_preview += f' ... ({len(snap_paths)} total)'
            print(f'     Paths: {paths_preview}')
        print()
except Exception as e:
    print(f'Error parsing snapshots: {e}', file=sys.stderr)
    sys.exit(1)
"

    if [ $? -eq 0 ]; then
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        return 0
    else
        # Fallback to simple text output
        restic snapshots 2>/dev/null
        return 0
    fi
}

# List available full backups
list_full_backups() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}Available Backups (Full)${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if ! command -v rclone &> /dev/null; then
        log_error "rclone is not installed"
        return 1
    fi

    local backups=$(rclone lsl "${BACKUP_REMOTE_DIR}" 2>/dev/null | grep "backup-.*\.tar\.gz\.enc$" | sort -r)

    if [ -z "$backups" ]; then
        log_warning "No full backups found in ${BACKUP_REMOTE_DIR}"
        return 0
    fi

    echo ""
    echo "$backups" | nl -w3 -s'. ' | while read -r line; do
        echo -e "${CYAN}$line${NC}"
    done

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Restore from restic snapshot
restore_restic_snapshot() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}Restore from Restic Snapshot${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Set up restic environment
    export RESTIC_REPOSITORY="rclone:${BACKUP_REMOTE_DIR}"
    export RESTIC_PASSWORD="${BACKUP_PASSWORD}"
    export RCLONE_CONFIG="${RCLONE_CONFIG:-$HOME/.config/rclone/rclone.conf}"

    # Get snapshots
    local snapshots=$(restic snapshots --json 2>/dev/null)

    if [ -z "$snapshots" ] || [ "$snapshots" = "null" ] || [ "$snapshots" = "[]" ]; then
        log_error "No snapshots found"
        return 1
    fi

    # Display snapshots with numbers
    echo ""
    echo -e "${GREEN}Available snapshots:${NC}"
    echo ""

    local snapshot_count=$(echo "$snapshots" | python3 -c "import sys,json; data=json.load(sys.stdin); print(len(data))")

    # Create temporary file to store sorted snapshot IDs
    local temp_ids=$(mktemp)

    # Display snapshots sorted by date (newest first) and store sorted IDs
    echo "$snapshots" | python3 -c "
import sys, json
data = json.load(sys.stdin)
# Sort by time in descending order (newest first)
sorted_data = sorted(data, key=lambda x: x.get('time', ''), reverse=True)

# Display snapshots
for idx, snap in enumerate(sorted_data, 1):
    snap_id = snap.get('short_id', snap.get('id', '')[:8])
    snap_time = snap.get('time', '')
    snap_host = snap.get('hostname', '')
    print(f'  {idx}. \033[36m{snap_id}\033[0m  \033[33m{snap_time}\033[0m  Host: \033[32m{snap_host}\033[0m')

# Save sorted snapshot IDs to file
with open('$temp_ids', 'w') as f:
    for snap in sorted_data:
        snap_id = snap.get('short_id', snap.get('id', '')[:8])
        f.write(snap_id + '\n')
"

    echo ""
    read -p "Select snapshot number to restore [1-${snapshot_count}] (or 'latest' for most recent): " selection

    # Get snapshot ID
    local snapshot_id=""
    if [[ "$selection" == "latest" ]] || [[ "$selection" == "l" ]] || [[ -z "$selection" ]]; then
        # Get the first (newest) snapshot ID from sorted list
        snapshot_id=$(head -1 "$temp_ids")
        log_info "Using latest snapshot: $snapshot_id"
    elif [[ $selection =~ ^[0-9]+$ ]] && [ $selection -ge 1 ] && [ $selection -le $snapshot_count ]; then
        # Get the selected snapshot ID from sorted list
        snapshot_id=$(sed -n "${selection}p" "$temp_ids")
        log_info "Selected snapshot: $snapshot_id"
    else
        rm -f "$temp_ids"
        log_error "Invalid selection"
        return 1
    fi

    # Clean up temp file
    rm -f "$temp_ids"

    # Ask for restore location
    echo ""
    read -p "Restore to directory [${RESTORE_DIR}] (press Enter for default): " restore_dir
    restore_dir="${restore_dir:-$RESTORE_DIR}"

    # Create restore directory
    mkdir -p "$restore_dir"

    # Show what will be restored
    echo ""
    log_info "Snapshot contents preview:"
    restic ls "$snapshot_id" --long 2>/dev/null | head -20
    echo "..."
    echo ""

    # Confirm restore
    echo ""
    log_warning "⚠️  WARNING: This will restore the backup snapshot"
    log_warning "Restore location: $restore_dir"
    echo ""
    read -p "Continue? [y/N] (press Enter to cancel): " confirm

    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        log_info "Restore cancelled"
        return 0
    fi

    # Perform restore
    echo ""
    log_info "Restoring snapshot $snapshot_id to $restore_dir..."
    echo ""

    if restic restore "$snapshot_id" --target "$restore_dir" 2>&1 | tee /tmp/restic-restore.log; then
        echo ""
        log_success "Restore completed successfully!"
        log_info "Restored files are in: $restore_dir"
        echo ""
        log_warning "Remember to:"
        echo "  1. Verify the restored files"
        echo "  2. Copy files to their original locations if needed"
        echo "  3. Set correct permissions"
        echo "  4. Restart services if necessary"
        return 0
    else
        echo ""
        log_error "Restore failed"
        log_info "Check log: /tmp/restic-restore.log"
        return 1
    fi
}

# Download and decrypt full backup
restore_full_backup() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}Restore Full Backup${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # List backups
    local backups=$(rclone lsf "${BACKUP_REMOTE_DIR}" 2>/dev/null | grep "backup-.*\.tar\.gz\.enc$" | sort -r)

    if [ -z "$backups" ]; then
        log_error "No full backups found"
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
    read -p "Select backup number to restore [1-${#backup_array[@]}] (press Enter for latest): " selection
    selection="${selection:-1}"

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

    # Prompt for password
    local decrypt_pass=""
    if [ -n "$BACKUP_PASSWORD" ]; then
        echo ""
        echo -e "${GREEN}Password options:${NC}"
        echo -e "  ${CYAN}1.${NC} Use configured password (default)"
        echo -e "  ${CYAN}2.${NC} Enter password manually"
        echo ""
        read -p "Select [1-2] (press Enter for option 1): " pass_choice
        pass_choice="${pass_choice:-1}"

        if [ "$pass_choice" = "1" ]; then
            decrypt_pass="$BACKUP_PASSWORD"
            log_info "Using configured password"
        elif [ "$pass_choice" = "2" ]; then
            echo ""
            read -sp "Enter decryption password: " decrypt_pass
            echo ""
        else
            log_error "Invalid option, using configured password"
            decrypt_pass="$BACKUP_PASSWORD"
        fi
    else
        echo ""
        read -sp "Enter decryption password: " decrypt_pass
        echo ""
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

    if [ "$BACKUP_METHOD" = "incremental" ]; then
        # Verify restic repository
        echo ""
        log_info "Verifying restic repository..."

        export RESTIC_REPOSITORY="rclone:${BACKUP_REMOTE_DIR}"
        export RESTIC_PASSWORD="${BACKUP_PASSWORD}"
        export RCLONE_CONFIG="${RCLONE_CONFIG:-$HOME/.config/rclone/rclone.conf}"

        if ! command -v restic &> /dev/null; then
            log_error "restic is not installed"
            return 1
        fi

        echo ""
        echo -e "${GREEN}Check types:${NC}"
        echo -e "  ${CYAN}1.${NC} Quick check (metadata only) - Fast"
        echo -e "  ${CYAN}2.${NC} Data check (verify pack files) - Slower"
        echo -e "  ${CYAN}3.${NC} Full check (read all data) - Slowest but thorough"
        echo ""
        read -p "Select check type [1-3] (press Enter for option 1): " check_type
        check_type="${check_type:-1}"

        echo ""
        case $check_type in
            1)
                log_info "Running quick check (metadata only)..."
                restic check
                ;;
            2)
                log_info "Running data check (with --read-data)..."
                restic check --read-data
                ;;
            3)
                log_info "Running full check (read all pack files)..."
                restic check --read-data-subset=100%
                ;;
            *)
                log_error "Invalid check type"
                return 1
                ;;
        esac

        if [ $? -eq 0 ]; then
            echo ""
            log_success "✓ Repository verification passed"
        else
            echo ""
            log_error "✗ Repository verification failed"
            return 1
        fi

    else
        # Verify full backup file
        local backups=$(rclone lsf "${BACKUP_REMOTE_DIR}" 2>/dev/null | grep "backup-.*\.tar\.gz\.enc$" | sort -r)

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
        read -p "Select backup to verify [1-${#backup_array[@]}] (press Enter for latest): " selection
        selection="${selection:-1}"

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

        # Prompt for password
        local test_pass=""
        if [ -n "$BACKUP_PASSWORD" ]; then
            echo ""
            echo -e "${GREEN}Password options:${NC}"
            echo -e "  ${CYAN}1.${NC} Use configured password (default)"
            echo -e "  ${CYAN}2.${NC} Enter password manually"
            echo ""
            read -p "Select [1-2] (press Enter for option 1): " pass_choice
            pass_choice="${pass_choice:-1}"

            if [ "$pass_choice" = "1" ]; then
                test_pass="$BACKUP_PASSWORD"
                log_info "Using configured password"
            elif [ "$pass_choice" = "2" ]; then
                echo ""
                read -sp "Enter password: " test_pass
                echo ""
            else
                log_error "Invalid option, using configured password"
                test_pass="$BACKUP_PASSWORD"
            fi
        else
            echo ""
            read -sp "Enter password: " test_pass
            echo ""
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
    fi
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
            if [ "$BACKUP_METHOD" = "incremental" ]; then
                list_restic_snapshots
            else
                list_full_backups
            fi
            ;;
        restore)
            if [ "$BACKUP_METHOD" = "incremental" ]; then
                restore_restic_snapshot
            else
                restore_full_backup
            fi
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
                echo -e "${BLUE}Backup method: ${CYAN}${BACKUP_METHOD}${NC}"
                echo ""
                echo -e "${GREEN}Available actions:${NC}"
                echo -e "  ${CYAN}1.${NC} List available backups"
                echo -e "  ${CYAN}2.${NC} Restore backup"
                echo -e "  ${CYAN}3.${NC} Verify backup integrity"
                echo -e "  ${CYAN}0.${NC} Exit (default)"
                echo ""
                read -p "Select action [0-3] (press Enter to exit): " action
                action="${action:-0}"

                case $action in
                    1)
                        if [ "$BACKUP_METHOD" = "incremental" ]; then
                            list_restic_snapshots
                        else
                            list_full_backups
                        fi
                        ;;
                    2)
                        if [ "$BACKUP_METHOD" = "incremental" ]; then
                            restore_restic_snapshot
                        else
                            restore_full_backup
                        fi
                        ;;
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
