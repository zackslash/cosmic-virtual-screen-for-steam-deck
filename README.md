# Cosmic Virtual Screen for Steam Deck

> Based on [plasma-virtual-screen-for-steam-deck](https://github.com/iox/plasma-virtual-screen-for-steam-deck) by iox — adapted for **COSMIC Desktop** and **Arch Linux** with `cosmic-randr`.

Create a virtual display output using an HDMI dummy plug for streaming to your Steam Deck. Designed for **Arch Linux** with the **COSMIC Desktop Environment**.

Uses a custom EDID (Extended Display Identification Data) file to expose Steam Deck-optimized resolutions on an HDMI dummy adapter, so streaming software (Sunshine/Moonlight, Steam Remote Play, etc.) can capture a display perfectly matched to the Deck's screen.

## How It Works

```
HDMI Dummy Plug → GPU detects "monitor" → Custom EDID tells GPU what resolutions to support
                                         → COSMIC Desktop sees virtual display with all modes
                                         → Stream capture software uses this display
                                         → Steam Deck receives a perfectly matched stream
```

The mechanism is **kernel-level** (`drm.edid_firmware` boot parameter), so it works with any Wayland compositor and any GPU driver (including Nvidia proprietary).

## Resolutions Included

| Resolution | Refresh | Aspect | Use Case |
|------------|---------|--------|----------|
| 1280x800 | 60 Hz | 16:10 | Steam Deck LCD native |
| 1280x800 | 90 Hz | 16:10 | Steam Deck OLED native |
| 1920x1200 | 60 Hz | 16:10 | Upscaled 16:10 |
| 1920x1200 | 90 Hz | 16:10 | Upscaled OLED |
| 1920x1200 | 120 Hz | 16:10 | High-refresh gaming |
| 2560x1440 | 60 Hz | 16:9 | Desktop standard |
| 2560x1440 | 120 Hz | 16:9 | Desktop high-refresh |
| 2560x1600 | 60 Hz | 16:10 | 2x Deck LCD (supersampled) |
| 2560x1600 | 90 Hz | 16:10 | 2x Deck OLED (supersampled) |

## Requirements

- **Arch Linux** (or Arch-based: CachyOS, EndeavourOS, Manjaro, etc.)
- **COSMIC Desktop** with `cosmic-randr`
- **Python 3** (for EDID generation)
- **HDMI dummy plug** adapter (also called "headless display emulator")
- **mkinitcpio** (standard on Arch)

## Project Structure

```
├── edid_generator.py      # Generates custom 256-byte EDID binary
├── install.sh             # Installer (EDID, initramfs, bootloader, helper)
├── uninstall.sh           # Clean uninstaller
├── sunshine-start.sh      # Sunshine prep-cmd: switch to virtual display
├── sunshine-stop.sh       # Sunshine prep-cmd: restore main display
├── restore-display.sh     # Emergency display restore (standalone recovery)
├── steamdeck_virtual.bin  # Generated EDID binary (created by installer)
└── README.md
```

## Installation

```bash
git clone https://github.com/zackslash/cosmic-virtual-screen-for-steam-deck.git
cd cosmic-virtual-screen-for-steam-deck
sudo ./install.sh
```

The installer will:
1. Show all available display outputs and their status
2. Ask which connector your dummy plug is on (e.g., `HDMI-A-1`)
3. Generate a custom 256-byte EDID binary
4. Install it to `/usr/lib/firmware/edid/`
5. Add it to initramfs via `mkinitcpio`
6. Configure your bootloader (systemd-boot or GRUB)
7. Install the `cosmic-deck-switch` helper command

**Reboot after installation.**

## Sunshine Integration

The primary use case for this project is streaming to a Steam Deck via **Sunshine + Moonlight**. The included scripts automatically switch between your main display and the virtual display when a streaming session starts and stops.

### How It Works

```
Stream starts → sunshine-start.sh → Enable HDMI dummy → Set Deck resolution → Disable main monitor
                                     (Sunshine captures the dummy display)
Stream ends   → sunshine-stop.sh  → Enable main monitor → Restore resolution → Disable dummy
```

### Setup

1. **Edit the scripts** to match your setup — open `sunshine-start.sh` and `sunshine-stop.sh` and set:
   - `MAIN_DISPLAY` — your primary monitor connector (e.g., `DP-2`)
   - `VIRTUAL_DISPLAY` — the dummy plug connector (e.g., `HDMI-A-1`)
   - `FALLBACK_WIDTH` / `FALLBACK_HEIGHT` / `FALLBACK_REFRESH` — your primary monitor's native mode (in `sunshine-stop.sh` and `restore-display.sh`)
   - `DEFAULT_MODE` — which Steam Deck mode to use (in `sunshine-start.sh`, default: `deck-oled`)

2. **Add to Sunshine** via the web UI (`https://localhost:47990`) or edit `~/.config/sunshine/apps.json`:

   ```json
   {
       "name": "Steam Deck",
       "cmd": "setsid steam steam://open/bigpicture",
       "auto-detach": true,
       "wait-all": true,
       "exit-timeout": 5,
       "prep-cmd": [
           {
               "do": "/home/YOUR_USER/dev/cosmic-virtual-screen-for-steam-deck/sunshine-start.sh deck-oled",
               "undo": "/home/YOUR_USER/dev/cosmic-virtual-screen-for-steam-deck/sunshine-stop.sh"
           },
           {
               "do": "",
               "undo": "setsid steam steam://close/bigpicture"
           },
           {
               "do": "",
               "undo": "loginctl lock-session"
           }
       ]
   }
   ```

3. **Available modes** for `sunshine-start.sh`:
   - `deck-lcd` — 1280x800@60Hz (Steam Deck LCD)
   - `deck-oled` — 1280x800@90Hz (Steam Deck OLED) ← default
   - `deck-lcd-2x` — 2560x1600@60Hz (Deck LCD supersampled)
   - `deck-oled-2x` — 2560x1600@90Hz (Deck OLED supersampled)
   - `1200p` / `1200p-90` / `1200p-120` — 1920x1200
   - `1440p` / `1440p-120` — 2560x1440
   - `1600p` / `1600p-90` — 2560x1600

### Testing

Test the scripts manually before using with Sunshine:

```bash
# Switch to virtual display (Steam Deck OLED mode)
./sunshine-start.sh deck-oled

# Restore main display
./sunshine-stop.sh
```

> **Note:** When `sunshine-start.sh` runs, your main monitor will go dark. This is expected — use `sunshine-stop.sh` to restore it, or SSH in if needed.

### Emergency Recovery

If Sunshine crashes and `sunshine-stop.sh` doesn't run automatically, use `restore-display.sh` to recover:

```bash
# Run locally (if you have a terminal accessible)
./restore-display.sh

# Or via SSH from another device (Steam Deck, phone, etc.)
ssh user@your-pc /path/to/restore-display.sh
```

This reads the saved display state (if available) or uses the hardcoded fallback values to fully restore your main monitor — including scale, adaptive sync, transform, and position.

> **Tip:** You can also bind `restore-display.sh` to a keyboard shortcut in COSMIC Settings for quick recovery.

## Usage

### Quick Mode Switching

After reboot with the dummy plug connected:

```bash
# Steam Deck native resolutions
cosmic-deck-switch deck-lcd       # 1280x800@60Hz
cosmic-deck-switch deck-oled      # 1280x800@90Hz

# Supersampled (2x Deck resolution — downscaled on Deck for sharper image)
cosmic-deck-switch deck-lcd-2x    # 2560x1600@60Hz
cosmic-deck-switch deck-oled-2x   # 2560x1600@90Hz

# Higher resolutions
cosmic-deck-switch 1200p          # 1920x1200@60Hz
cosmic-deck-switch 1200p-120      # 1920x1200@120Hz
cosmic-deck-switch 1440p          # 2560x1440@60Hz
cosmic-deck-switch 1600p          # 2560x1600@60Hz

# Display management
cosmic-deck-switch list           # Show available modes
cosmic-deck-switch status         # Full display status
cosmic-deck-switch enable         # Enable the virtual display
cosmic-deck-switch disable        # Disable the virtual display
```

### Direct cosmic-randr Commands

```bash
# List all outputs and modes
cosmic-randr list

# Set mode (width height --refresh Hz)
cosmic-randr mode HDMI-A-1 1280 800 --refresh 90

# Enable/disable
cosmic-randr enable HDMI-A-1
cosmic-randr disable HDMI-A-1
```

### COSMIC Display Settings

The virtual display also appears in **COSMIC Settings > Displays** where you can configure resolution, position, and scaling graphically.

## Verify Installation

After reboot:

```bash
# Check kernel parameter is active
cat /proc/cmdline | grep -o 'drm.edid_firmware=[^ ]*'

# Check EDID firmware file exists
ls -la /usr/lib/firmware/edid/steamdeck_virtual.bin

# Check display appears in cosmic-randr
cosmic-randr list

# Check modes are available
cosmic-deck-switch list
```

## Uninstallation

```bash
sudo ./uninstall.sh
# Reboot after uninstall
```

This removes:
- The EDID firmware file
- The `cosmic-deck-switch` helper
- The mkinitcpio FILES entry
- The kernel boot parameter (from GRUB, systemd-boot, or /etc/kernel/cmdline)

> **Note:** The Sunshine scripts (`sunshine-start.sh`, `sunshine-stop.sh`) are not removed by the uninstaller since they live in the project directory. Remove any Sunshine prep-cmd references manually via the Sunshine web UI.

## Troubleshooting

### Display doesn't appear after reboot
- Verify the dummy plug is firmly seated in the correct HDMI port
- Check `cat /proc/cmdline` for the `drm.edid_firmware=` parameter
- Check `dmesg | grep -i edid` for EDID loading messages
- Verify the connector name matches: `ls /sys/class/drm/card*-*/status`

### Wrong connector name
- Run `ls /sys/class/drm/card*-*` to see all connectors
- Plug/unplug the dummy adapter and check which connector changes from `disconnected` to `connected`
- Re-run `sudo ./install.sh` with the correct connector name

### No modes showing in cosmic-randr
- Ensure EDID file is in initramfs: `lsinitcpio /boot/initramfs-linux.img | grep edid`
- Regenerate: `sudo mkinitcpio -P`
- Check EDID is valid: `edid-decode /usr/lib/firmware/edid/steamdeck_virtual.bin`

### High refresh rates not available
- The EDID includes an HDMI VSDB (Vendor Specific Data Block) to unlock pixel clocks >165MHz
- Some HDMI dummy plugs are limited to HDMI 1.4 bandwidth
- Try a different dummy plug rated for higher bandwidth

## Technical Details

### EDID Structure

The generated EDID is 256 bytes (128-byte base block + 128-byte CTA-861 extension):

- **Base block**: Header, manufacturer/product IDs, standard timings for 60Hz modes, 3 DTDs (Detailed Timing Descriptors) for anchor and high-refresh modes, Display Range Limits (48-125Hz V-rate, 30-160kHz H-rate, 600MHz max pixel clock)
- **Extension block**: HDMI VSDB (unlocks >165MHz pixel clock), DTDs for all >60Hz modes

All timings use **CVT Reduced Blanking** for minimal bandwidth overhead.

### Kernel Mechanism

The `drm.edid_firmware=CONNECTOR:edid/FILE.bin` kernel parameter tells the DRM subsystem to load a custom EDID from `/usr/lib/firmware/` instead of reading from the physical cable. This happens at the kernel/driver level before any desktop environment loads.

## Tested On

- Arch Linux (CachyOS), COSMIC Desktop
- Nvidia RTX series (proprietary driver)
- HDMI dummy plug adapters

## Credits

Based on [plasma-virtual-screen-for-steam-deck](https://github.com/iox/plasma-virtual-screen-for-steam-deck) by [iox](https://github.com/iox), adapted for COSMIC Desktop and Arch Linux.

## License

MIT License — see [LICENSE](LICENSE) for details.
