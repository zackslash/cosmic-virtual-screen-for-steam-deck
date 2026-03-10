#!/bin/bash
#
# Steam Deck Virtual Screen Installer for COSMIC Desktop (Arch Linux)
# Installs custom EDID and configures kernel parameters for use with
# a dummy HDMI adapter as a virtual display for Steam Deck streaming
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
EDID_FILENAME="steamdeck_virtual.bin"
FIRMWARE_DIR="/usr/lib/firmware/edid"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_SCRIPT="cosmic-deck-switch"

# Functions
print_header() {
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}============================================================${NC}"
    echo
}

print_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

check_dependencies() {
    local missing=()

    if ! command -v python3 &> /dev/null; then
        missing+=("python3")
    fi

    if ! command -v mkinitcpio &> /dev/null; then
        if command -v dracut &> /dev/null; then
            print_error "This system uses dracut instead of mkinitcpio"
            print_info "dracut support is not yet implemented"
            print_info "See README for manual dracut configuration"
            exit 1
        fi
        missing+=("mkinitcpio")
    fi

    if ! command -v cosmic-randr &> /dev/null; then
        print_warning "cosmic-randr not found - COSMIC Desktop may not be installed"
        print_info "The EDID will still be installed but you won't be able to use the mode switcher"
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        print_error "Missing required dependencies: ${missing[*]}"
        print_info "Install with: sudo pacman -S ${missing[*]}"
        exit 1
    fi
}

detect_bootloader() {
    # Check for systemd-boot
    if command -v bootctl &> /dev/null; then
        if bootctl status &> /dev/null; then
            echo "systemd-boot"
            return
        fi
    fi

    # Check for systemd-boot directories
    if [ -d "/boot/loader/entries" ] || [ -f "/boot/loader/loader.conf" ]; then
        echo "systemd-boot"
        return
    fi

    # Check for GRUB
    if [ -f "/etc/default/grub" ]; then
        echo "grub"
        return
    fi

    if [ -d "/boot/grub" ] || [ -d "/boot/grub2" ]; then
        echo "grub"
        return
    fi

    echo "unknown"
}

list_displays() {
    print_info "Detecting available display outputs..."
    echo

    if [ -d "/sys/class/drm" ]; then
        echo "Available outputs:"
        echo
        printf "  %-25s %-15s %s\n" "OUTPUT" "STATUS" "CARD"
        printf "  %-25s %-15s %s\n" "------" "------" "----"

        for card in /sys/class/drm/card*-*; do
            if [ -d "$card" ]; then
                full_name=$(basename "$card")
                # Extract card number and connector name
                card_num="${full_name%%-*}"
                output_name="${full_name#card*-}"
                status=$(cat "$card/status" 2>/dev/null || echo "unknown")

                # Colour code status
                if [ "$status" = "connected" ]; then
                    status_display="${GREEN}${status}${NC}"
                elif [ "$status" = "disconnected" ]; then
                    status_display="${YELLOW}${status}${NC}"
                else
                    status_display="$status"
                fi

                printf "  %-25s %-15b %s\n" "$output_name" "$status_display" "$card_num"
            fi
        done
        echo
    fi

    # Also show cosmic-randr output if available
    if command -v cosmic-randr &> /dev/null; then
        print_info "Active displays (via cosmic-randr):"
        cosmic-randr list 2>/dev/null || true
        echo
    fi
}

detect_main_display() {
    local dummy_connector="$1"
    for card in /sys/class/drm/card*-*; do
        if [ -d "$card" ]; then
            local output_name
            output_name="$(basename "$card")"
            output_name="${output_name#card*-}"
            if [ "$output_name" != "$dummy_connector" ]; then
                local status
                status=$(cat "$card/status" 2>/dev/null || echo "unknown")
                if [ "$status" = "connected" ]; then
                    echo "$output_name"
                    return
                fi
            fi
        fi
    done
    echo ""
}

prompt_default_mode() {
    echo -e "${YELLOW}Select a default streaming mode:${NC}"
    echo
    echo "  1) deck-lcd      1280x800@60Hz   (Steam Deck LCD native)"
    echo "  2) deck-oled     1280x800@90Hz   (Steam Deck OLED native)"
    echo "  3) deck-lcd-2x   2560x1600@60Hz  (Deck LCD supersampled)"
    echo "  4) deck-oled-2x  2560x1600@90Hz  (Deck OLED supersampled)"
    echo "  5) 1200p         1920x1200@60Hz"
    echo "  6) 1200p-90      1920x1200@90Hz"
    echo "  7) 1200p-120     1920x1200@120Hz"
    echo "  8) 1440p         2560x1440@60Hz"
    echo "  9) 1440p-120     2560x1440@120Hz"
    echo " 10) 1600p         2560x1600@60Hz"
    echo " 11) 1600p-90      2560x1600@90Hz"
    echo
    read -p "Choice [2]: " mode_choice

    case "${mode_choice:-2}" in
        1)  echo "deck-lcd" ;;
        2)  echo "deck-oled" ;;
        3)  echo "deck-lcd-2x" ;;
        4)  echo "deck-oled-2x" ;;
        5)  echo "1200p" ;;
        6)  echo "1200p-90" ;;
        7)  echo "1200p-120" ;;
        8)  echo "1440p" ;;
        9)  echo "1440p-120" ;;
        10) echo "1600p" ;;
        11) echo "1600p-90" ;;
        *)
            print_warning "Invalid choice, defaulting to deck-oled"
            echo "deck-oled"
            ;;
    esac
}

prompt_hdr() {
    # UI output goes to stderr so $() capture only receives "yes" or "no" on stdout
    echo -e "${YELLOW}Enable HDR support?${NC}" >&2
    echo >&2
    echo "  HDR adds BT.2020 colorimetry and HDR10 Static Metadata to the EDID." >&2
    echo "  When COSMIC adds HDR output support, Sunshine will be able to advertise" >&2
    echo "  HDR to Moonlight clients automatically via the KMS connector property." >&2
    echo "  Only enable if your Moonlight client and Sunshine version support HDR." >&2
    echo >&2
    read -p "Enable HDR? [y/N]: " hdr_choice <&1
    if [[ "$hdr_choice" =~ ^[Yy] ]]; then
        echo "yes"
    else
        echo "no"
    fi
}

write_config_file() {
    local main_display="$1"
    local virtual_display="$2"
    local default_mode="$3"
    local hdr_enabled="${4:-no}"

    # Determine the real user's home directory (installer runs as root via sudo)
    local real_home
    if [ -n "${SUDO_USER:-}" ]; then
        real_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        real_home="$HOME"
    fi

    local config_dir="${real_home}/.config/cosmic-deck-switch"
    local config_file="${config_dir}/config"

    mkdir -p "$config_dir"
    cat > "$config_file" <<EOF
# cosmic-deck-switch configuration
# Generated by install.sh — edit as needed
# Note: do not use inline comments on value lines
MAIN_DISPLAY=$main_display
VIRTUAL_DISPLAY=$virtual_display
DEFAULT_MODE=$default_mode
HDR_ENABLED=$hdr_enabled
EOF

    # Fix ownership if running via sudo
    if [ -n "${SUDO_USER:-}" ]; then
        chown -R "$SUDO_USER:" "$config_dir"
    fi

    print_success "Config written to $config_file"
    print_info "  Main display:    $main_display"
    print_info "  Virtual display: $virtual_display"
    print_info "  Default mode:    $default_mode"
    print_info "  HDR enabled:     $hdr_enabled"
}

generate_edid() {
    local hdr_enabled="${1:-no}"
    print_info "Generating EDID file..."

    if [ ! -f "$SCRIPT_DIR/edid_generator.py" ]; then
        print_error "edid_generator.py not found in $SCRIPT_DIR"
        exit 1
    fi

    local hdr_flag=""
    if [ "$hdr_enabled" = "yes" ]; then
        hdr_flag="--hdr"
    fi

    python3 "$SCRIPT_DIR/edid_generator.py" $hdr_flag "$SCRIPT_DIR/$EDID_FILENAME"

    if [ -f "$SCRIPT_DIR/$EDID_FILENAME" ]; then
        local size=$(stat -c%s "$SCRIPT_DIR/$EDID_FILENAME")
        print_success "EDID file generated: $EDID_FILENAME ($size bytes)"
        if [ "$hdr_enabled" = "yes" ]; then
            print_info "HDR mode: ENABLED (BT.2020 colorimetry + HDR10 Static Metadata)"
        fi
    else
        print_error "Failed to generate EDID file"
        exit 1
    fi
}

install_edid() {
    print_info "Installing EDID to firmware directory..."

    mkdir -p "$FIRMWARE_DIR"
    cp "$SCRIPT_DIR/$EDID_FILENAME" "$FIRMWARE_DIR/"
    chmod 644 "$FIRMWARE_DIR/$EDID_FILENAME"

    print_success "EDID installed to $FIRMWARE_DIR/$EDID_FILENAME"
}

configure_mkinitcpio() {
    local mkinitcpio_conf="/etc/mkinitcpio.conf"
    local edid_path="$FIRMWARE_DIR/${EDID_FILENAME}"

    if [ ! -f "$mkinitcpio_conf" ]; then
        print_warning "mkinitcpio.conf not found - skipping initramfs configuration"
        return
    fi

    print_info "Configuring mkinitcpio to include EDID in initramfs..."

    # Backup
    cp "$mkinitcpio_conf" "${mkinitcpio_conf}.backup.$(date +%Y%m%d_%H%M%S)"

    # Check if EDID is already in FILES array
    if grep "^FILES=" "$mkinitcpio_conf" | grep -q "$edid_path"; then
        print_info "EDID already present in mkinitcpio.conf"
        return
    fi

    # Check if FILES line exists and modify it
    if grep -q "^FILES=" "$mkinitcpio_conf"; then
        # Get current FILES content
        current=$(grep "^FILES=" "$mkinitcpio_conf" | sed 's/^FILES=(\(.*\))/\1/' | xargs)
        if [ -z "$current" ]; then
            sed -i "s|^FILES=(.*)|FILES=($edid_path)|" "$mkinitcpio_conf"
        else
            sed -i "s|^FILES=(\(.*\))|FILES=(\1 $edid_path)|" "$mkinitcpio_conf"
        fi
    else
        # Add FILES line after MODULES
        if grep -q "^MODULES=" "$mkinitcpio_conf"; then
            sed -i "/^MODULES=/a FILES=($edid_path)" "$mkinitcpio_conf"
        else
            echo "FILES=($edid_path)" >> "$mkinitcpio_conf"
        fi
    fi

    print_success "Added EDID to mkinitcpio.conf FILES array"
}

regenerate_initramfs() {
    print_info "Regenerating initramfs..."

    configure_mkinitcpio

    if command -v mkinitcpio &> /dev/null; then
        if ! mkinitcpio -P; then
            print_warning "mkinitcpio returned an error (this may be non-fatal firmware warnings)"
            print_info "You may need to run 'sudo mkinitcpio -P' manually after fixing any issues"
            print_info "Continuing installation..."
        else
            print_success "Initramfs regenerated with mkinitcpio"
        fi
    else
        print_warning "mkinitcpio not found - you must regenerate initramfs manually"
        print_info "  sudo mkinitcpio -P"
    fi
}

configure_systemd_boot() {
    local connector="$1"
    local kernel_param="drm.edid_firmware=${connector}:edid/${EDID_FILENAME}"

    print_info "Configuring systemd-boot..."

    # Find ESP path
    local esp_path="/boot"
    if command -v bootctl &> /dev/null; then
        esp_path=$(bootctl -p 2>/dev/null || echo "/boot")
    fi

    # Try to find loader entries
    local entries_dir=""
    for dir in "$esp_path/loader/entries" "/boot/loader/entries" "/boot/efi/loader/entries"; do
        if [ -d "$dir" ]; then
            entries_dir="$dir"
            break
        fi
    done

    if [ -n "$entries_dir" ]; then
        # Standard systemd-boot with entry files
        local entry_files=("$entries_dir"/*.conf)
        local entry_count=${#entry_files[@]}

        if [ "$entry_count" -eq 0 ] || [ ! -f "${entry_files[0]}" ]; then
            print_warning "No boot entries found in $entries_dir"
        else
            if [ "$entry_count" -gt 1 ]; then
                print_warning "Found $entry_count boot entries - modifying all of them"
            fi

            for entry_file in "${entry_files[@]}"; do
                if [ -f "$entry_file" ]; then
                    print_info "Modifying entry: $(basename "$entry_file")"

                    # Backup
                    cp "$entry_file" "${entry_file}.backup.$(date +%Y%m%d_%H%M%S)"

                    # Remove any existing drm.edid_firmware parameter
                    if grep -q "drm.edid_firmware" "$entry_file"; then
                        print_info "Updating existing drm.edid_firmware parameter..."
                        sed -i 's|drm\.edid_firmware=[^[:space:]]*||g' "$entry_file"
                    fi

                    # Append new parameter to end of options line
                    sed -i "s|^options \(.*\)|options \1 ${kernel_param}|" "$entry_file"
                    # Clean up double spaces on options line only
                    sed -i '/^options/s|  *| |g' "$entry_file"

                    print_success "Updated: $(basename "$entry_file")"
                fi
            done
            return
        fi
    fi

    # Check for /etc/kernel/cmdline (used by mkinitcpio UKI or kernel-install)
    if [ -f "/etc/kernel/cmdline" ]; then
        print_info "Found /etc/kernel/cmdline (UKI configuration)"

        cp "/etc/kernel/cmdline" "/etc/kernel/cmdline.backup.$(date +%Y%m%d_%H%M%S)"

        # Remove existing parameter if present
        if grep -q "drm.edid_firmware" "/etc/kernel/cmdline"; then
            sed -i 's|drm\.edid_firmware=[^[:space:]]*||g; s|  *| |g' "/etc/kernel/cmdline"
        fi

        # Append parameter
        sed -i "s|$| ${kernel_param}|; s|  *| |g; s|^ ||" "/etc/kernel/cmdline"
        print_success "Updated /etc/kernel/cmdline"

        print_info "Regenerating UKI..."
        if command -v mkinitcpio &> /dev/null; then
            if ! mkinitcpio -P; then
                print_warning "mkinitcpio returned an error - you may need to regenerate manually"
            else
                print_success "UKI regenerated"
            fi
        fi
        return
    fi

    # No entries and no /etc/kernel/cmdline — try to create one from /proc/cmdline
    if [ -f "/proc/cmdline" ]; then
        print_warning "No boot entries or /etc/kernel/cmdline found"
        print_info "This appears to be a UKI or custom systemd-boot setup"
        print_info "Current kernel cmdline from /proc/cmdline:"
        echo "  $(cat /proc/cmdline)"
        echo
        print_info "We can create /etc/kernel/cmdline from the current boot parameters"
        print_info "and append the EDID firmware parameter."
        read -p "Create /etc/kernel/cmdline? [y/N]: " create_cmdline
        if [[ "$create_cmdline" =~ ^[Yy] ]]; then
            cat /proc/cmdline > /etc/kernel/cmdline
            # Remove any initrd= params that may have been added by the bootloader
            sed -i 's|initrd=[^[:space:]]*||g; s|  *| |g; s|^ ||; s| $||' "/etc/kernel/cmdline"
            # Append our parameter
            sed -i "s|$| ${kernel_param}|; s|  *| |g; s|^ ||" "/etc/kernel/cmdline"
            print_success "Created /etc/kernel/cmdline with EDID parameter"

            print_info "Regenerating UKI..."
            if command -v mkinitcpio &> /dev/null; then
                if ! mkinitcpio -P; then
                    print_warning "mkinitcpio returned an error - you may need to regenerate manually"
                else
                    print_success "UKI regenerated"
                fi
            fi
            return
        fi
    fi

    # No entries found - provide manual instructions
    print_warning "systemd-boot detected but could not find entry files"
    print_info ""
    print_info "Manual configuration required. Add this kernel parameter:"
    echo "  ${kernel_param}"
    print_info ""
    print_info "Common approaches:"
    print_info "  1. Create /etc/kernel/cmdline with your full command line + this param"
    print_info "  2. Edit your boot entry in $esp_path/loader/entries/"
    print_info "  3. If using UKI, add to cmdline and regenerate"
}

configure_grub() {
    local connector="$1"
    local grub_file="/etc/default/grub"
    local kernel_param="drm.edid_firmware=${connector}:edid/${EDID_FILENAME}"

    print_info "Configuring GRUB..."

    # Backup
    cp "$grub_file" "${grub_file}.backup.$(date +%Y%m%d_%H%M%S)"
    print_success "Backup created"

    # Remove existing parameter if present
    if grep -q "drm.edid_firmware" "$grub_file"; then
        print_info "Updating existing drm.edid_firmware parameter..."
        sed -i 's|drm\.edid_firmware=[^[:space:]"]*||g' "$grub_file"
    fi

    # Add to GRUB_CMDLINE_LINUX_DEFAULT
    sed -i "s|GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"|GRUB_CMDLINE_LINUX_DEFAULT=\"\1 ${kernel_param}\"|" "$grub_file"
    # Clean up double spaces on the GRUB cmdline only
    sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT/s|  *| |g' "$grub_file"

    print_success "GRUB configuration updated"

    # Update GRUB
    print_info "Regenerating GRUB config..."
    if command -v update-grub &> /dev/null; then
        update-grub
    elif command -v grub-mkconfig &> /dev/null; then
        if [ -f "/boot/grub/grub.cfg" ]; then
            grub-mkconfig -o /boot/grub/grub.cfg
        elif [ -f "/boot/grub2/grub.cfg" ]; then
            grub-mkconfig -o /boot/grub2/grub.cfg
        fi
    else
        print_warning "Could not find GRUB update command - run grub-mkconfig manually"
        return 1
    fi

    print_success "GRUB updated successfully"
}

configure_kernel_params() {
    local connector="$1"
    local bootloader=$(detect_bootloader)

    print_info "Detected bootloader: $bootloader"
    echo

    case "$bootloader" in
        grub)
            configure_grub "$connector"
            ;;
        systemd-boot)
            configure_systemd_boot "$connector"
            ;;
        *)
            print_warning "Unknown bootloader"
            print_info ""
            print_info "Manual configuration required. Add this kernel parameter:"
            echo "  drm.edid_firmware=${connector}:edid/${EDID_FILENAME}"
            print_info ""
            print_info "Common methods:"
            print_info "  GRUB: Edit /etc/default/grub -> GRUB_CMDLINE_LINUX_DEFAULT"
            print_info "  systemd-boot: Add to options line in boot entry .conf"
            print_info "  UKI: Add to /etc/kernel/cmdline and regenerate"
            ;;
    esac
}

install_helper_script() {
    local connector="$1"
    local helper_path="/usr/local/bin/${HELPER_SCRIPT}"

    print_info "Installing cosmic-randr mode switcher helper..."

    cat > "$helper_path" << HELPEREOF
#!/bin/bash
#
# cosmic-deck-switch - Quick mode switcher for Steam Deck virtual display
# Installed by cosmic-virtual-screen-for-steam-deck
#

CONNECTOR="${connector}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

show_help() {
    echo "cosmic-deck-switch - Steam Deck Virtual Display Mode Switcher"
    echo ""
    echo "Usage: cosmic-deck-switch [command]"
    echo ""
    echo "Quick modes:"
    echo "  deck-lcd      Set 1280x800@60Hz  (Steam Deck LCD native)"
    echo "  deck-oled     Set 1280x800@90Hz  (Steam Deck OLED native)"
    echo "  deck-lcd-2x   Set 2560x1600@60Hz (Deck LCD supersampled)"
    echo "  deck-oled-2x  Set 2560x1600@90Hz (Deck OLED supersampled)"
    echo "  1200p         Set 1920x1200@60Hz (16:10)"
    echo "  1200p-90      Set 1920x1200@90Hz"
    echo "  1200p-120     Set 1920x1200@120Hz"
    echo "  1440p         Set 2560x1440@60Hz (16:9)"
    echo "  1440p-120     Set 2560x1440@120Hz"
    echo "  1600p         Set 2560x1600@60Hz (16:10)"
    echo "  1600p-90      Set 2560x1600@90Hz"
    echo ""
    echo "Commands:"
    echo "  list          Show available modes on the virtual display"
    echo "  status        Show current display status"
    echo "  custom WxH R  Set custom mode (e.g. cosmic-deck-switch custom 1920x1200 60)"
    echo "  enable        Enable the virtual display"
    echo "  disable       Disable the virtual display"
    echo "  help          Show this help message"
    echo ""
    echo "Connector: \$CONNECTOR"
}

set_mode() {
    local width="\$1"
    local height="\$2"
    local refresh="\$3"
    local label="\$4"

    echo -e "\${BLUE}Setting \${CONNECTOR} to \${label}...\${NC}"

    local output
    if output=\$(cosmic-randr mode "\$CONNECTOR" "\$width" "\$height" --refresh "\$refresh" 2>&1); then
        echo -e "\${GREEN}[OK]\${NC} Mode set to \${label}"
    else
        echo -e "\${RED}[ERROR]\${NC} Failed to set mode \${label}"
        [ -n "\$output" ] && echo "\$output"
        echo "Make sure the virtual display is connected and enabled"
        exit 1
    fi
}

case "\${1:-help}" in
    deck-lcd)    set_mode 1280  800  60   "1280x800@60Hz (Deck LCD)" ;;
    deck-oled)   set_mode 1280  800  90   "1280x800@90Hz (Deck OLED)" ;;
    deck-lcd-2x) set_mode 2560  1600 60   "2560x1600@60Hz (Deck LCD 2x)" ;;
    deck-oled-2x) set_mode 2560  1600 90  "2560x1600@90Hz (Deck OLED 2x)" ;;
    1200p)       set_mode 1920  1200 60   "1920x1200@60Hz" ;;
    1200p-90)    set_mode 1920  1200 90   "1920x1200@90Hz" ;;
    1200p-120)   set_mode 1920  1200 120  "1920x1200@120Hz" ;;
    1440p)       set_mode 2560  1440 60   "2560x1440@60Hz" ;;
    1440p-120)   set_mode 2560  1440 120  "2560x1440@120Hz" ;;
    1600p)       set_mode 2560  1600 60   "2560x1600@60Hz" ;;
    1600p-90)    set_mode 2560  1600 90   "2560x1600@90Hz" ;;
    list)
        echo "Available modes on \$CONNECTOR:"
        cosmic-randr list 2>&1 | grep -A 100 "\$CONNECTOR" | head -30
        ;;
    status)
        echo "Display status:"
        cosmic-randr list 2>&1
        ;;
    enable)
        echo -e "\${BLUE}Enabling \${CONNECTOR}...\${NC}"
        if output=\$(cosmic-randr enable "\$CONNECTOR" 2>&1); then
            echo -e "\${GREEN}[OK]\${NC} \$CONNECTOR enabled"
        else
            echo -e "\${RED}[ERROR]\${NC} Failed to enable \$CONNECTOR"
            [ -n "\$output" ] && echo "\$output"
        fi
        ;;
    disable)
        echo -e "\${BLUE}Disabling \${CONNECTOR}...\${NC}"
        if output=\$(cosmic-randr disable "\$CONNECTOR" 2>&1); then
            echo -e "\${GREEN}[OK]\${NC} \$CONNECTOR disabled"
        else
            echo -e "\${RED}[ERROR]\${NC} Failed to disable \$CONNECTOR"
            [ -n "\$output" ] && echo "\$output"
        fi
        ;;
    custom)
        if [ -z "\$2" ] || [ -z "\$3" ]; then
            echo "Usage: cosmic-deck-switch custom <WxH> <refresh_Hz>"
            echo "Example: cosmic-deck-switch custom 1920x1200 60"
            exit 1
        fi
        resolution="\$2"
        refresh="\$3"
        width="\${resolution%%x*}"
        height="\${resolution##*x}"
        set_mode "\$width" "\$height" "\$refresh" "\${resolution}@\${refresh}Hz"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Unknown command: \$1"
        echo "Run 'cosmic-deck-switch help' for usage"
        exit 1
        ;;
esac
HELPEREOF

    chmod +x "$helper_path"
    print_success "Helper script installed: $helper_path"
    print_info "Usage: cosmic-deck-switch help"
}

show_next_steps() {
    local connector="$1"

    echo
    print_header "Installation Complete!"

    print_warning "REBOOT REQUIRED for EDID changes to take effect"
    echo

    print_info "After reboot:"
    echo "  1. Plug in your HDMI dummy adapter (if not already connected)"
    echo "  2. The virtual display will appear on connector: $connector"
    echo "  3. Use cosmic-deck-switch to set modes, or COSMIC Display Settings"
    echo
    print_info "Configuration saved to ~/.config/cosmic-deck-switch/config"
    echo "  Edit this file to change main display, virtual display, or default mode"
    echo
    print_info "Quick start:"
    echo "  cosmic-deck-switch deck-oled-2x  # Set mode"
    echo "  cosmic-deck-switch list           # Show available modes"
    echo "  cosmic-deck-switch enable         # Enable virtual display"
    echo "  cosmic-deck-switch disable        # Disable virtual display"
    echo

    print_info "Verify installation after reboot:"
    echo "  cosmic-randr list"
    echo "  cat /proc/cmdline | grep -o 'drm.edid_firmware=[^ ]*'"
    echo

    print_info "To uninstall:"
    echo "  sudo $SCRIPT_DIR/uninstall.sh"
    echo
}

# Main installation flow
main() {
    print_header "Steam Deck Virtual Screen Installer (COSMIC Desktop / Arch Linux)"

    check_root
    check_dependencies

    echo

    # List available displays
    list_displays

    # Prompt for display connector
    echo -e "${YELLOW}Which display output should use the virtual EDID?${NC}"
    echo "Enter the connector name from the list above (e.g., HDMI-A-1, HDMI-A-2)"
    echo -e "${BLUE}Tip:${NC} Choose a disconnected HDMI output where your dummy plug will go"
    echo
    read -p "Connector name: " connector

    if [ -z "$connector" ]; then
        print_error "No connector specified"
        exit 1
    fi

    # Validate connector name (prevent sed injection and catch typos)
    if [[ ! "$connector" =~ ^[A-Za-z0-9_-]+$ ]]; then
        print_error "Invalid connector name. Expected format: HDMI-A-1, DP-2, etc."
        exit 1
    fi

    # Validate connector exists in DRM
    local found=false
    for card in /sys/class/drm/card*-*; do
        if [ -d "$card" ]; then
            local output_name
            output_name="$(basename "$card")"
            output_name="${output_name#card*-}"
            if [ "$output_name" = "$connector" ]; then
                found=true
                break
            fi
        fi
    done
    if [ "$found" = false ]; then
        print_warning "Connector '$connector' not found in current DRM outputs"
        read -p "Continue anyway? [y/N]: " confirm_connector
        if [[ ! "$confirm_connector" =~ ^[Yy] ]]; then
            print_info "Aborted"
            exit 0
        fi
    fi

    echo
    print_info "Using connector: $connector"
    echo

    # Auto-detect main display
    local main_display
    main_display=$(detect_main_display "$connector")
    if [ -n "$main_display" ]; then
        print_info "Detected main display: $main_display"
    else
        print_warning "Could not auto-detect main display"
        main_display="DP-2"
    fi
    read -p "Main display [$main_display]: " user_main
    main_display="${user_main:-$main_display}"
    echo

    # Prompt for default streaming mode
    local default_mode
    default_mode=$(prompt_default_mode)
    echo
    print_info "Default mode: $default_mode"
    echo

    # Prompt for HDR EDID support
    local hdr_enabled
    hdr_enabled=$(prompt_hdr)
    echo
    if [ "$hdr_enabled" = "yes" ]; then
        print_info "HDR: ENABLED (BT.2020 + HDR10 Static Metadata in EDID)"
    else
        print_info "HDR: disabled"
    fi
    echo

    # Confirm before making system changes
    print_warning "This will modify: mkinitcpio.conf, bootloader config, initramfs"
    read -p "Proceed with connector '$connector'? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        print_info "Aborted"
        exit 0
    fi
    echo

    # Step 1: Generate EDID
    generate_edid "$hdr_enabled"
    echo

    # Step 2: Install EDID to firmware
    install_edid
    echo

    # Step 3: Regenerate initramfs with EDID included
    regenerate_initramfs
    echo

    # Step 4: Configure bootloader with kernel parameter
    configure_kernel_params "$connector"
    echo

    # Step 5: Install helper script
    install_helper_script "$connector"
    echo

    # Step 6: Write config file
    write_config_file "$main_display" "$connector" "$default_mode" "$hdr_enabled"
    echo

    # Done
    show_next_steps "$connector"
}

# Run
main
