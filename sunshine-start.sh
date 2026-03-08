#!/bin/bash
#
# sunshine-start.sh — Sunshine session start script
#
# Switches from the main display to the HDMI dummy plug with
# Steam Deck resolutions for streaming via Sunshine/Moonlight.
#
# Saves full display configuration (mode, scale, adaptive sync,
# transform, position) so sunshine-stop.sh can restore everything.
#
# Usage:
#   Add to Sunshine app prep-cmd "do" field, or run manually:
#     ./sunshine-start.sh [mode]
#
#   Modes: deck-lcd, deck-oled, 1200p, 1200p-90, 1200p-120,
#          1440p, 1440p-120, 1600p, 1600p-90
#   Default: deck-oled (configurable via ~/.config/cosmic-deck-switch/config)
#

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────
# Loaded from config file (written by install.sh), with fallback defaults
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/cosmic-deck-switch/config"

MAIN_DISPLAY="DP-2"
VIRTUAL_DISPLAY="HDMI-A-1"
DEFAULT_MODE="deck-oled"

if [ -f "$CONFIG_FILE" ]; then
    while IFS='=' read -r key value; do
        case "$key" in
            MAIN_DISPLAY)    MAIN_DISPLAY="$value" ;;
            VIRTUAL_DISPLAY) VIRTUAL_DISPLAY="$value" ;;
            DEFAULT_MODE)    DEFAULT_MODE="$value" ;;
        esac
    done < "$CONFIG_FILE"
fi

# State file to remember what was running before
STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/cosmic-deck-switch.state"
# ───────────────────────────────────────────────────────────────────

MODE="${1:-$DEFAULT_MODE}"

log() { echo "[sunshine-start] $*"; }

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

# Save full main display configuration for restoration
# Parses cosmic-randr --kdl output to capture mode, scale, transform,
# adaptive sync, and position — all of which are lost on disable/enable.
save_state() {
    local kdl_output
    kdl_output=$(cosmic-randr list --kdl 2>&1)

    # Extract settings for the main display from KDL output
    local in_output=false
    local in_modes=false
    local width="" height="" refresh=""
    local scale="" transform="" adaptive_sync=""
    local pos_x="" pos_y=""

    while IFS= read -r line; do
        # Detect our output block
        if echo "$line" | grep -q "^output \"${MAIN_DISPLAY}\""; then
            in_output=true
            continue
        fi

        # Stop at next output block
        if $in_output && echo "$line" | grep -q "^output "; then
            break
        fi

        if $in_output; then
            # Parse position
            if echo "$line" | grep -qP '^\s+position\s'; then
                read -r _ pos_x pos_y <<< "$(echo "$line" | sed 's/^\s*//')"
            fi
            # Parse scale
            if echo "$line" | grep -qP '^\s+scale\s'; then
                scale=$(echo "$line" | grep -oP 'scale\s+\K[\d.]+')
            fi
            # Parse transform
            if echo "$line" | grep -qP '^\s+transform\s'; then
                transform=$(echo "$line" | grep -oP 'transform\s+"\K[^"]+')
            fi
            # Parse adaptive_sync
            if echo "$line" | grep -qP '^\s+adaptive_sync\s'; then
                adaptive_sync=$(echo "$line" | grep -oP 'adaptive_sync\s+"\K[^"]+')
            fi
            # Parse current mode
            if echo "$line" | grep -qP '^\s+modes\s'; then
                in_modes=true
                continue
            fi
            if $in_modes; then
                if echo "$line" | grep -q '}'; then
                    in_modes=false
                    continue
                fi
                if echo "$line" | grep -q 'current=#true'; then
                    read -r _ width height refresh _ <<< "$(echo "$line" | sed 's/^\s*//')"
                fi
            fi
        fi
    done <<< "$kdl_output"

    # Write state file with all captured settings
    cat > "$STATE_FILE" <<EOF
MAIN_DISPLAY=$MAIN_DISPLAY
VIRTUAL_DISPLAY=$VIRTUAL_DISPLAY
WIDTH=$width
HEIGHT=$height
REFRESH=$refresh
SCALE=$scale
TRANSFORM=$transform
ADAPTIVE_SYNC=$adaptive_sync
POS_X=$pos_x
POS_Y=$pos_y
EOF
    log "Saved full display state to $STATE_FILE"
    log "  Mode: ${width}x${height}@${refresh}mHz, Scale: ${scale}, Transform: ${transform}"
    log "  Adaptive Sync: ${adaptive_sync}, Position: ${pos_x},${pos_y}"
}

# Resolve mode name to cosmic-randr arguments (WIDTH HEIGHT REFRESH_HZ)
resolve_mode() {
    local mode="$1"
    case "$mode" in
        deck-lcd)    echo "1280 800 60" ;;
        deck-oled)   echo "1280 800 90" ;;
        deck-lcd-2x) echo "2560 1600 60" ;;
        deck-oled-2x) echo "2560 1600 90" ;;
        1200p)       echo "1920 1200 60" ;;
        1200p-90)    echo "1920 1200 90" ;;
        1200p-120)   echo "1920 1200 120" ;;
        1440p)       echo "2560 1440 60" ;;
        1440p-120)   echo "2560 1440 120" ;;
        1600p)       echo "2560 1600 60" ;;
        1600p-90)    echo "2560 1600 90" ;;
        *)
            log "ERROR: Unknown mode '$mode'"
            log "Valid modes: deck-lcd, deck-oled, deck-lcd-2x, deck-oled-2x, 1200p, 1200p-90, 1200p-120, 1440p, 1440p-120, 1600p, 1600p-90"
            exit 1
            ;;
    esac
}

# ── Main ───────────────────────────────────────────────────────────

log "Starting display switch for Sunshine streaming"
log "Mode: $MODE | Main: $MAIN_DISPLAY | Virtual: $VIRTUAL_DISPLAY"

# Save current state before changing anything
save_state

# Parse mode
read -r WIDTH HEIGHT REFRESH <<< "$(resolve_mode "$MODE")"

# Step 1: Enable the virtual display (dummy HDMI)
log "Enabling virtual display $VIRTUAL_DISPLAY..."
if ! cosmic-randr enable "$VIRTUAL_DISPLAY" 2>&1; then
    log "WARNING: Failed to enable $VIRTUAL_DISPLAY (may already be enabled)"
fi

# Step 2: Set the desired resolution on the virtual display
log "Setting ${WIDTH}x${HEIGHT}@${REFRESH}Hz on $VIRTUAL_DISPLAY..."
if ! cosmic-randr mode "$VIRTUAL_DISPLAY" "$WIDTH" "$HEIGHT" --refresh "$REFRESH" 2>&1; then
    log "ERROR: Failed to set mode on $VIRTUAL_DISPLAY"
    log "Rolling back — disabling $VIRTUAL_DISPLAY"
    cosmic-randr disable "$VIRTUAL_DISPLAY" 2>&1 || true
    exit 1
fi

# Step 3: Short delay to let the compositor settle
sleep 1

# Step 4: Disable the main display
log "Disabling main display $MAIN_DISPLAY..."
if ! cosmic-randr disable "$MAIN_DISPLAY" 2>&1; then
    log "WARNING: Failed to disable $MAIN_DISPLAY"
fi

log "Display switch complete — streaming on $VIRTUAL_DISPLAY at ${WIDTH}x${HEIGHT}@${REFRESH}Hz"
