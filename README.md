# VPS Backup Manager

Automated backup solution for VPS servers with cloud storage support, encryption, and Telegram notifications.

## Features

- 🔐 **Encrypted Backups**: AES-256 encryption with password protection
- ☁️ **Cloud Storage**: Support for Google Drive, Dropbox, OneDrive, and more (via rclone)
- 📱 **Telegram Notifications**: Real-time backup status notifications
- 🔄 **Automatic Cleanup**: Configurable retention policy for old backups
- ✅ **Integrity Verification**: SHA256 checksums and upload verification
- 🛡️ **Safety Features**: Lock files, disk space checks, remote path validation
- 🎯 **Multi-VPS Support**: Unique identifiers to distinguish backups from multiple servers
- 🔧 **Easy Configuration**: Interactive wizard for first-time setup
- 📦 **Flexible Restore**: Simple restoration interface

## Quick Start

### One-line Installation

```bash
bash <(curl -Ls https://raw.githubusercontent.com/uniquMonte/server-backup/main/install.sh)
