#!/bin/bash
#
# SillyTavern Incremental Save + Image Cache - Installer
#
# Applies patches to a running SillyTavern Docker container
# or a local SillyTavern installation.
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHES_DIR="$SCRIPT_DIR/patches"
NEW_FILES_DIR="$SCRIPT_DIR/new-files"

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ─── Detect installation mode ────────────────────────────────────────

if [ "$1" = "--docker" ] || [ "$1" = "-d" ]; then
    MODE="docker"
    CONTAINER="${2:-sillytavern}"
elif [ "$1" = "--local" ] || [ "$1" = "-l" ]; then
    MODE="local"
    ST_DIR="${2:-.}"
else
    echo "Usage:"
    echo "  $0 --docker [container_name]   Apply to Docker container (default: sillytavern)"
    echo "  $0 --local  [sillytavern_dir]  Apply to local installation (default: current dir)"
    exit 1
fi

# ─── Docker mode ─────────────────────────────────────────────────────

if [ "$MODE" = "docker" ]; then
    # Check container exists and is running
    if ! docker inspect "$CONTAINER" &>/dev/null; then
        error "Container '$CONTAINER' not found."
    fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" != "true" ]; then
        error "Container '$CONTAINER' is not running."
    fi

    info "Backing up original files from container '$CONTAINER'..."
    BACKUP_DIR="$SCRIPT_DIR/backups/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    docker cp "$CONTAINER:/home/node/app/src/endpoints/chats.js"          "$BACKUP_DIR/chats.server.js"
    docker cp "$CONTAINER:/home/node/app/public/script.js"                "$BACKUP_DIR/script.js"
    docker cp "$CONTAINER:/home/node/app/public/scripts/group-chats.js"   "$BACKUP_DIR/group-chats.js"
    docker cp "$CONTAINER:/home/node/app/public/scripts/chats.js"         "$BACKUP_DIR/chats.js"
    docker cp "$CONTAINER:/home/node/app/src/server-startup.js"           "$BACKUP_DIR/server-startup.js"
    info "Backups saved to $BACKUP_DIR"

    info "Applying patches inside container..."

    # Copy patches and new files into container
    docker cp "$PATCHES_DIR" "$CONTAINER:/tmp/_inc_save_patches"
    docker cp "$NEW_FILES_DIR" "$CONTAINER:/tmp/_inc_save_new_files"

    # Apply patches (incremental save)
    docker exec "$CONTAINER" sh -c "cd /home/node/app && patch -p1 < /tmp/_inc_save_patches/chats.server.patch"
    docker exec "$CONTAINER" sh -c "cd /home/node/app && patch -p1 < /tmp/_inc_save_patches/script.patch"
    docker exec "$CONTAINER" sh -c "cd /home/node/app && patch -p1 < /tmp/_inc_save_patches/group-chats.patch"

    # Apply patches (image proxy cache)
    docker exec "$CONTAINER" sh -c "cd /home/node/app && patch -p1 < /tmp/_inc_save_patches/server-startup.patch"
    docker exec "$CONTAINER" sh -c "cd /home/node/app && patch -p1 < /tmp/_inc_save_patches/chats.patch"

    # Copy new files (image proxy endpoint)
    docker exec "$CONTAINER" cp /tmp/_inc_save_new_files/image-proxy.js /home/node/app/src/endpoints/image-proxy.js

    # Cleanup
    docker exec "$CONTAINER" rm -rf /tmp/_inc_save_patches /tmp/_inc_save_new_files

    info "Restarting container..."
    docker restart "$CONTAINER"
    sleep 3

    if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" = "true" ]; then
        info "Done! Container '$CONTAINER' is running with incremental save + image cache enabled."
    else
        error "Container failed to start. Check logs: docker logs $CONTAINER"
    fi
fi

# ─── Local mode ──────────────────────────────────────────────────────

if [ "$MODE" = "local" ]; then
    if [ ! -f "$ST_DIR/server.js" ] || [ ! -f "$ST_DIR/public/script.js" ]; then
        error "'$ST_DIR' does not look like a SillyTavern installation."
    fi

    info "Backing up original files..."
    BACKUP_DIR="$SCRIPT_DIR/backups/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    cp "$ST_DIR/src/endpoints/chats.js"          "$BACKUP_DIR/chats.server.js"
    cp "$ST_DIR/public/script.js"                "$BACKUP_DIR/script.js"
    cp "$ST_DIR/public/scripts/group-chats.js"   "$BACKUP_DIR/group-chats.js"
    cp "$ST_DIR/public/scripts/chats.js"         "$BACKUP_DIR/chats.js"
    cp "$ST_DIR/src/server-startup.js"           "$BACKUP_DIR/server-startup.js"
    info "Backups saved to $BACKUP_DIR"

    info "Applying patches..."
    cd "$ST_DIR"
    patch -p1 < "$PATCHES_DIR/chats.server.patch"
    patch -p1 < "$PATCHES_DIR/script.patch"
    patch -p1 < "$PATCHES_DIR/group-chats.patch"
    patch -p1 < "$PATCHES_DIR/server-startup.patch"
    patch -p1 < "$PATCHES_DIR/chats.patch"

    info "Copying new files..."
    cp "$NEW_FILES_DIR/image-proxy.js" "$ST_DIR/src/endpoints/image-proxy.js"

    info "Done! Restart SillyTavern to activate incremental save + image cache."
fi
