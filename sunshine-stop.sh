#!/bin/bash
#
# sunshine-stop.sh — Sunshine session end script
#
# Restores the main display with full settings (mode, scale, adaptive sync,
# transform, position) and disables the HDMI dummy plug when the
# Sunshine/Moonlight streaming session ends.
#
# COSMIC Desktop does NOT persist display settings through disable/enable
# cycles, so this script must restore everything explicitly.
#
# Usage:
#   Add to Sunshine app prep-cmd "undo" field, or run manually:
#     ./sunshine-stop.sh
#

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────
# Edit these to match your setup (must match sunshine-start.sh)
MAIN_DISPLAY="DP-2"
VIRTUAL_DISPLAY="HDMI-A-1"

# Fallback values if state file is missing (your primary monitor's native settings)
# Note: refresh is in millihertz (same unit as KDL state file) for consistency
FALLBACK_WIDTH="3840"
FALLBACK_HEIGHT="2160"
FALLBACK_REFRESH="160000"
FALLBACK_SCALE="1.25"
FALLBACK_TRANSFORM="normal"
FALLBACK_ADAPTIVE_SYNC="automatic"
FALLBACK_POS_X="0"
FALLBACK_POS_Y="0"

# State file written by sunshine-start.sh
STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/cosmic-deck-switch.state"
# ───────────────────────────────────────────────────────────────────

log() { echo "[sunshine-stop] $*"; }

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

# ── Load saved state ──────────────────────────────────────────────

# Start with fallback values
RESTORE_WIDTH="$FALLBACK_WIDTH"
RESTORE_HEIGHT="$FALLBACK_HEIGHT"
RESTORE_REFRESH="$FALLBACK_REFRESH"
RESTORE_SCALE="$FALLBACK_SCALE"
RESTORE_TRANSFORM="$FALLBACK_TRANSFORM"
RESTORE_ADAPTIVE_SYNC="$FALLBACK_ADAPTIVE_SYNC"
RESTORE_POS_X="$FALLBACK_POS_X"
RESTORE_POS_Y="$FALLBACK_POS_Y"

if [ -f "$STATE_FILE" ]; then
    # Safe key=value parsing (no source/eval)
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
    log "WARNING: No state file found, using fallback values"
fi

# ── Main ───────────────────────────────────────────────────────────

log "Restoring displays after Sunshine streaming session"

# Step 1: Re-enable the main display
log "Enabling main display $MAIN_DISPLAY..."
if ! cosmic-randr enable "$MAIN_DISPLAY" 2>&1; then
    log "WARNING: Failed to enable $MAIN_DISPLAY (may already be enabled)"
fi

# Step 2: Fully restore main display settings
# COSMIC does NOT persist scale/transform/adaptive-sync/position through
# disable/enable cycles, so we must restore everything explicitly.

# Convert millihertz (from KDL/state) to Hz (for --refresh flag)
local_refresh="60.000"
if [ -n "$RESTORE_REFRESH" ]; then
    local_refresh=$(awk -v r="$RESTORE_REFRESH" 'BEGIN { printf "%.3f", r / 1000 }')
fi

log "Restoring $MAIN_DISPLAY to ${RESTORE_WIDTH}x${RESTORE_HEIGHT}@${local_refresh}Hz"
log "  Scale: ${RESTORE_SCALE}, Transform: ${RESTORE_TRANSFORM}"
log "  Adaptive Sync: ${RESTORE_ADAPTIVE_SYNC}, Position: ${RESTORE_POS_X},${RESTORE_POS_Y}"

RESTORE_CMD=(
    cosmic-randr mode "$MAIN_DISPLAY" "$RESTORE_WIDTH" "$RESTORE_HEIGHT"
)

# Add refresh
if [ -n "$RESTORE_REFRESH" ]; then
    RESTORE_CMD+=(--refresh "$local_refresh")
fi

# Add scale
if [ -n "$RESTORE_SCALE" ]; then
    RESTORE_CMD+=(--scale "$RESTORE_SCALE")
fi

# Add transform
if [ -n "$RESTORE_TRANSFORM" ]; then
    RESTORE_CMD+=(--transform "$RESTORE_TRANSFORM")
fi

# Add adaptive sync
if [ -n "$RESTORE_ADAPTIVE_SYNC" ]; then
    RESTORE_CMD+=(--adaptive-sync "$RESTORE_ADAPTIVE_SYNC")
fi

# Add position
if [ -n "$RESTORE_POS_X" ] && [ -n "$RESTORE_POS_Y" ]; then
    RESTORE_CMD+=(--pos-x "$RESTORE_POS_X" --pos-y "$RESTORE_POS_Y")
fi

if ! "${RESTORE_CMD[@]}" 2>&1; then
    log "WARNING: Full restore failed, trying basic mode restore..."
    if ! cosmic-randr mode "$MAIN_DISPLAY" "$RESTORE_WIDTH" "$RESTORE_HEIGHT" --refresh "$local_refresh" 2>&1; then
        log "ERROR: Failed to restore mode on $MAIN_DISPLAY"
    fi
fi

# Step 3: Short delay to let the compositor settle
sleep 1

# Step 4: Disable the virtual display
log "Disabling virtual display $VIRTUAL_DISPLAY..."
if ! cosmic-randr disable "$VIRTUAL_DISPLAY" 2>&1; then
    log "WARNING: Failed to disable $VIRTUAL_DISPLAY"
fi

# Step 5: Clean up state file
rm -f "$STATE_FILE"

log "Display restoration complete — $MAIN_DISPLAY fully restored"
