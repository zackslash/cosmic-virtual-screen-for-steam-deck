#!/bin/bash
#
# restore-display.sh — Emergency display restore for COSMIC Desktop
#
# Restores the main display with full settings and disables the dummy plug.
# Use this as a recovery tool when Sunshine crashes or the display is stuck
# on the dummy output.
#
# Usage:
#   ./restore-display.sh          # Restore from saved state (or fallbacks)
#   ssh user@host ./restore-display.sh   # Remote recovery via SSH
#
# Can also be bound to a keyboard shortcut for quick recovery.
#

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────
# Loaded from config file (written by install.sh), with fallback defaults
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/cosmic-deck-switch/config"

MAIN_DISPLAY="DP-2"
VIRTUAL_DISPLAY="HDMI-A-1"

if [ -f "$CONFIG_FILE" ]; then
    while IFS='=' read -r key value; do
        case "$key" in
            MAIN_DISPLAY)    MAIN_DISPLAY="$value" ;;
            VIRTUAL_DISPLAY) VIRTUAL_DISPLAY="$value" ;;
        esac
    done < "$CONFIG_FILE"
fi

# Fallback values if no state file exists (your primary monitor's native settings)
# Refresh is in millihertz (KDL format) — converted to Hz automatically
FALLBACK_WIDTH="3840"
FALLBACK_HEIGHT="2160"
FALLBACK_REFRESH="160000"
FALLBACK_SCALE="1.25"
FALLBACK_TRANSFORM="normal"
FALLBACK_ADAPTIVE_SYNC="automatic"
FALLBACK_POS_X="0"
FALLBACK_POS_Y="0"

# State file written by sunshine-start.sh (if available)
STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/cosmic-deck-switch.state"
# ───────────────────────────────────────────────────────────────────

log() { echo "[restore-display] $*"; }

# ── Ensure Wayland display is reachable ────────────────────────────
if [ -z "${WAYLAND_DISPLAY:-}" ]; then
    for sock in wayland-1 wayland-0; do
        if [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/$sock" ]; then
            export WAYLAND_DISPLAY="$sock"
            break
        fi
    done
fi
if [ -z "${WAYLAND_DISPLAY:-}" ]; then
    log "ERROR: Cannot find Wayland display socket. Is COSMIC running?"
    exit 1
fi

# ── Load saved state or use fallbacks ─────────────────────────────

RESTORE_WIDTH="$FALLBACK_WIDTH"
RESTORE_HEIGHT="$FALLBACK_HEIGHT"
RESTORE_REFRESH="$FALLBACK_REFRESH"
RESTORE_SCALE="$FALLBACK_SCALE"
RESTORE_TRANSFORM="$FALLBACK_TRANSFORM"
RESTORE_ADAPTIVE_SYNC="$FALLBACK_ADAPTIVE_SYNC"
RESTORE_POS_X="$FALLBACK_POS_X"
RESTORE_POS_Y="$FALLBACK_POS_Y"

if [ -f "$STATE_FILE" ]; then
    while IFS='=' read -r key value; do
        case "$key" in
            MAIN_DISPLAY)    MAIN_DISPLAY="$value" ;;
            VIRTUAL_DISPLAY) VIRTUAL_DISPLAY="$value" ;;
            WIDTH)           RESTORE_WIDTH="$value" ;;
            HEIGHT)          RESTORE_HEIGHT="$value" ;;
            REFRESH)         RESTORE_REFRESH="$value" ;;
            SCALE)           RESTORE_SCALE="$value" ;;
            TRANSFORM)       RESTORE_TRANSFORM="$value" ;;
            ADAPTIVE_SYNC)   RESTORE_ADAPTIVE_SYNC="$value" ;;
            POS_X)           RESTORE_POS_X="$value" ;;
            POS_Y)           RESTORE_POS_Y="$value" ;;
        esac
    done < "$STATE_FILE"
    log "Loaded saved state from $STATE_FILE"
else
    log "No state file found — using fallback values"
fi

# ── Restore ───────────────────────────────────────────────────────

log "Restoring main display..."

# Convert millihertz → Hz
local_refresh="60.000"
if [ -n "$RESTORE_REFRESH" ]; then
    local_refresh=$(awk -v r="$RESTORE_REFRESH" 'BEGIN { printf "%.3f", r / 1000 }')
fi

# Enable main display
log "Enabling $MAIN_DISPLAY..."
cosmic-randr enable "$MAIN_DISPLAY" 2>&1 || true

# Full restore with all settings (COSMIC loses these on disable/enable)
log "Setting ${RESTORE_WIDTH}x${RESTORE_HEIGHT}@${local_refresh}Hz"
log "  Scale: ${RESTORE_SCALE}, Transform: ${RESTORE_TRANSFORM}"
log "  Adaptive Sync: ${RESTORE_ADAPTIVE_SYNC}, Position: ${RESTORE_POS_X},${RESTORE_POS_Y}"

RESTORE_CMD=(
    cosmic-randr mode "$MAIN_DISPLAY" "$RESTORE_WIDTH" "$RESTORE_HEIGHT"
)
[ -n "$RESTORE_REFRESH" ]      && RESTORE_CMD+=(--refresh "$local_refresh")
[ -n "$RESTORE_SCALE" ]        && RESTORE_CMD+=(--scale "$RESTORE_SCALE")
[ -n "$RESTORE_TRANSFORM" ]    && RESTORE_CMD+=(--transform "$RESTORE_TRANSFORM")
[ -n "$RESTORE_ADAPTIVE_SYNC" ] && RESTORE_CMD+=(--adaptive-sync "$RESTORE_ADAPTIVE_SYNC")
[ -n "$RESTORE_POS_X" ] && [ -n "$RESTORE_POS_Y" ] && RESTORE_CMD+=(--pos-x "$RESTORE_POS_X" --pos-y "$RESTORE_POS_Y")

if ! "${RESTORE_CMD[@]}" 2>&1; then
    log "WARNING: Full restore failed, trying basic mode..."
    cosmic-randr mode "$MAIN_DISPLAY" "$RESTORE_WIDTH" "$RESTORE_HEIGHT" --refresh "$local_refresh" 2>&1 || \
        log "ERROR: Basic mode restore also failed"
fi

sleep 1

# Disable dummy plug
log "Disabling $VIRTUAL_DISPLAY..."
cosmic-randr disable "$VIRTUAL_DISPLAY" 2>&1 || true

# Clean up state file
rm -f "$STATE_FILE"

log "Done — $MAIN_DISPLAY restored"
