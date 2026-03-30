# Cosmic Virtual Screen for Steam Deck

> Based on [plasma-virtual-screen-for-steam-deck](https://github.com/iox/plasma-virtual-screen-for-steam-deck) by [iox](https://github.com/iox) — adapted for **COSMIC Desktop** and **Arch Linux**.

Create a virtual display using an HDMI dummy plug for streaming to a Steam Deck via Sunshine/Moonlight. Uses a custom EDID binary and the kernel `drm.edid_firmware` parameter to expose Steam Deck-optimized resolutions — works with any GPU driver (AMD, Nvidia, Intel).

## Requirements

- **Arch Linux** (or Arch-based: CachyOS, EndeavourOS, etc.)
- **COSMIC Desktop** with `cosmic-randr`
- **Python 3**, **mkinitcpio**
- **HDMI dummy plug** adapter

## Installation

```bash
git clone https://github.com/zackslash/cosmic-virtual-screen-for-steam-deck.git
cd cosmic-virtual-screen-for-steam-deck
sudo ./install.sh
```

The installer lists all display outputs (e.g. `DP-2`, `HDMI-A-1`) and prompts you to select the connector where your dummy plug is connected. It then generates a custom EDID, installs it to firmware + initramfs, configures your bootloader (systemd-boot or GRUB), and installs the `cosmic-deck-switch` helper. **Reboot after installation.**

> **Tip:** Plug in the dummy adapter first, then run the installer — the HDMI port will show as connected, making it easy to identify.

To uninstall: `sudo ./uninstall.sh` then reboot.

## Available Modes

| Mode | Resolution | Use Case |
|------|-----------|----------|
| `deck-lcd` | 1280x800@60Hz | Steam Deck LCD native |
| `deck-oled` | 1280x800@90Hz | Steam Deck OLED native |
| `deck-lcd-2x` | 2560x1600@60Hz | Deck LCD supersampled |
| `deck-oled-2x` | 2560x1600@90Hz | Deck OLED supersampled |

Additional modes: `1200p`, `1200p-90`, `1200p-120`, `1440p`, `1440p-120`, `1600p`, `1600p-90` — run `cosmic-deck-switch list` for details.

```bash
cosmic-deck-switch deck-oled      # Set mode
cosmic-deck-switch list           # Show available modes
cosmic-deck-switch enable         # Enable virtual display
cosmic-deck-switch disable        # Disable virtual display
```

## Sunshine Integration

The scripts automatically switch between your main display and the virtual display when a stream starts/stops.

### Setup

The installer automatically writes your display configuration to `~/.config/cosmic-deck-switch/config`. To change settings later, edit this file directly:

```bash
# ~/.config/cosmic-deck-switch/config
MAIN_DISPLAY=DP-2
VIRTUAL_DISPLAY=HDMI-A-2
DEFAULT_MODE=deck-oled
HDR_ENABLED=no   # set to "yes" if you enabled HDR during installation
```

1. **Test manually** before adding to Sunshine:
   ```bash
   ./sunshine-start.sh deck-oled    # Main monitor goes dark (expected)
   ./sunshine-stop.sh               # Restores main monitor
   ```

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
               "do": "touch /tmp/sunshine-streaming",
               "undo": "rm -f /tmp/sunshine-streaming"
           },
           {
               "do": "/path/to/sunshine-start.sh deck-oled",
               "undo": "/path/to/sunshine-stop.sh"
           }
       ]
   }
   ```
   Replace `/path/to/` with the actual location of your cloned repository.

   The `/tmp/sunshine-streaming` sentinel file is used by the automated crash recovery below.

### Crash Recovery

If Sunshine crashes or is killed ungracefully, the `undo` prep-cmds don't fire and your main display stays disabled. Two layers of protection handle this:

**Automated — systemd `ExecStopPost=` drop-in (recommended):**

`sunshine-cleanup.sh` is called by systemd every time the Sunshine service stops, regardless of how it stopped (clean exit, crash, SIGKILL, `systemctl stop`). It checks for the `/tmp/sunshine-streaming` sentinel — on a clean shutdown the `undo` prep-cmd removes it first so cleanup does nothing; on a crash the sentinel survives and cleanup calls `sunshine-stop.sh` to restore your display.

Set it up with a drop-in:

```bash
mkdir -p ~/.config/systemd/user/sunshine.service.d/
```

Create `~/.config/systemd/user/sunshine.service.d/cleanup.conf`:

```ini
[Service]
ExecStopPost=/path/to/sunshine-cleanup.sh
```

```bash
systemctl --user daemon-reload
```

**Manual fallback:**

```bash
./restore-display.sh                          # Run locally
ssh user@your-pc /path/to/restore-display.sh  # Or via SSH
```

> **Tip:** Bind `restore-display.sh` to a keyboard shortcut in COSMIC Settings for quick recovery.

## Troubleshooting

- **Display doesn't appear after reboot** — Check `cat /proc/cmdline` for `drm.edid_firmware=`, check `dmesg | grep -i edid`, verify the dummy plug is in the right HDMI port
- **Wrong connector name** — Run `ls /sys/class/drm/card*-*` and plug/unplug the adapter to identify which one changes
- **No modes showing** — Verify EDID is in initramfs: `lsinitcpio /boot/initramfs-linux.img | grep edid`, then `sudo mkinitcpio -P`
- **High refresh rates unavailable** — Some cheap HDMI dummy plugs are limited to HDMI 1.4 bandwidth; try one rated higher

## HDR

The installer can generate an HDR-capable EDID (BT.2020 colorimetry, HDR10 Static Metadata, 10-bit colour depth) that tells the GPU driver the virtual display supports HDR.

> **HDR streaming does not work yet.** COSMIC Desktop (v1.0.x) does not implement HDR output, so Sunshine cannot advertise HDR to Moonlight clients. Enabling this future-proofs the EDID — no reinstall needed when COSMIC adds HDR support.

When COSMIC ships HDR you will also need Sunshine with HEVC/AV1 encoder and HDR enabled in Moonlight.

To regenerate manually:

```bash
python3 edid_generator.py --hdr steamdeck_virtual.bin
sudo cp steamdeck_virtual.bin /usr/lib/firmware/edid/
sudo mkinitcpio -P
```

## How It Works

The installer generates a 256-byte EDID binary (base block + CTA-861 extension with HDMI VSDB for >165MHz pixel clocks, CVT Reduced Blanking timings) and loads it via the kernel's `drm.edid_firmware` parameter. This makes the GPU treat the dummy plug as a real monitor with the declared resolutions. The Sunshine scripts save/restore full display state (mode, scale, transform, adaptive sync, position) since COSMIC doesn't persist settings through enable/disable cycles.

## License

MIT — see [LICENSE](LICENSE).
