#!/bin/bash
#
# Uninstall Steam Deck Virtual Screen EDID (COSMIC Desktop / Arch Linux)
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root (use sudo)"
    exit 1
fi

echo
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}Uninstalling Steam Deck Virtual Screen EDID${NC}"
echo -e "${BLUE}============================================================${NC}"
echo

EDID_PATH="/usr/lib/firmware/edid/steamdeck_virtual.bin"
HELPER_PATH="/usr/local/bin/cosmic-deck-switch"

needs_initramfs_rebuild=false

# ── Step 1: Remove EDID firmware file ──────────────────────────────
if [ -f "$EDID_PATH" ]; then
    rm -f "$EDID_PATH"
    print_success "EDID file removed: $EDID_PATH"
else
    print_info "EDID file not found (already removed)"
fi

# ── Step 2: Remove helper script ───────────────────────────────────
if [ -f "$HELPER_PATH" ]; then
    rm -f "$HELPER_PATH"
    print_success "Helper script removed: $HELPER_PATH"
else
    print_info "Helper script not found (already removed)"
fi

# ── Step 3: Remove config directory ────────────────────────────────
CONFIG_DIR=""
if [ -n "${SUDO_USER:-}" ]; then
    real_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    CONFIG_DIR="${real_home}/.config/cosmic-deck-switch"
else
    CONFIG_DIR="$HOME/.config/cosmic-deck-switch"
fi

if [ -d "$CONFIG_DIR" ]; then
    rm -rf "$CONFIG_DIR"
    print_success "Config directory removed: $CONFIG_DIR"
else
    print_info "Config directory not found (already removed)"
fi

# ── Step 4: Remove from mkinitcpio.conf ────────────────────────────
if [ -f "/etc/mkinitcpio.conf" ]; then
    if grep -q "steamdeck_virtual.bin" /etc/mkinitcpio.conf; then
        cp /etc/mkinitcpio.conf "/etc/mkinitcpio.conf.backup.uninstall.$(date +%Y%m%d_%H%M%S)"
        # Remove the EDID path from FILES array (handle both /lib and /usr/lib paths)
        sed -i 's| */usr/lib/firmware/edid/steamdeck_virtual\.bin||g' /etc/mkinitcpio.conf
        sed -i 's| */lib/firmware/edid/steamdeck_virtual\.bin||g' /etc/mkinitcpio.conf
        sed -i 's|FILES=( *)|FILES=()|g' /etc/mkinitcpio.conf
        print_success "Removed EDID from mkinitcpio.conf"
        needs_initramfs_rebuild=true
    fi
fi

# ── Step 5: Remove from /etc/kernel/cmdline (UKI setups) ──────────
if [ -f "/etc/kernel/cmdline" ]; then
    if grep -q "drm.edid_firmware" "/etc/kernel/cmdline"; then
        cp "/etc/kernel/cmdline" "/etc/kernel/cmdline.backup.uninstall.$(date +%Y%m%d_%H%M%S)"
        sed -i 's| *drm\.edid_firmware=[^[:space:]]*||g; s|  *| |g; s|^ ||; s| $||' "/etc/kernel/cmdline"
        print_success "Removed from /etc/kernel/cmdline"
        needs_initramfs_rebuild=true
    fi
fi

# ── Step 6: Remove from GRUB ──────────────────────────────────────
if [ -f "/etc/default/grub" ]; then
    if grep -q "drm.edid_firmware" /etc/default/grub; then
        cp /etc/default/grub "/etc/default/grub.backup.uninstall.$(date +%Y%m%d_%H%M%S)"
        sed -i 's| *drm\.edid_firmware=[^[:space:]"]*||g' /etc/default/grub

        if command -v update-grub &> /dev/null; then
            update-grub
        elif command -v grub-mkconfig &> /dev/null; then
            grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || \
            grub-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true
        fi
        print_success "Removed from GRUB config"
    fi
fi

# ── Step 7: Remove from systemd-boot entries ──────────────────────
for entries_dir in /boot/loader/entries /boot/efi/loader/entries; do
    if [ -d "$entries_dir" ]; then
        for entry in "$entries_dir"/*.conf; do
            if [ -f "$entry" ] && grep -q "drm.edid_firmware" "$entry"; then
                cp "$entry" "${entry}.backup.uninstall.$(date +%Y%m%d_%H%M%S)"
                sed -i 's| *drm\.edid_firmware=[^[:space:]]*||g' "$entry"
                sed -i '/^options/s|  *| |g' "$entry"
                print_success "Removed from systemd-boot: $(basename "$entry")"
            fi
        done
    fi
done

# ── Step 8: Regenerate initramfs (single rebuild after all changes) ─
if [ "$needs_initramfs_rebuild" = true ]; then
    print_info "Regenerating initramfs..."
    if command -v mkinitcpio &> /dev/null; then
        if ! mkinitcpio -P; then
            print_warning "mkinitcpio returned an error - you may need to regenerate manually"
            print_info "Run: sudo mkinitcpio -P"
        else
            print_success "Initramfs regenerated"
        fi
    else
        print_warning "mkinitcpio not found - regenerate initramfs manually"
    fi
else
    print_info "No initramfs changes needed"
fi

echo
print_success "Uninstallation complete"
print_warning "Reboot required for changes to take effect"
echo
