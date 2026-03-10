# Cosmic Virtual Screen for Steam Deck

> Based on [plasma-virtual-screen-for-steam-deck](https://github.com/iox/plasma-virtual-screen-for-steam-deck) by [iox](https://github.com/iox) — adapted for **COSMIC Desktop** and **Arch Linux**.

Create a virtual display using an HDMI dummy plug for streaming to a Steam Deck via Sunshine/Moonlight. Uses a custom EDID binary and the kernel `drm.edid_firmware` parameter to expose Steam Deck-optimized resolutions — works with any GPU driver (AMD, Nvidia, Intel).

## Requirements

- **Arch Linux** (or Arch-based: CachyOS, EndeavourOS, etc.)
- **COSMIC Desktop** with `cosmic-randr`
- **Python 3**, **mkinitcpio**
- **HDMI dummy plug** adapter
- **gamescope** *(optional, for HDR streaming — `sudo pacman -S gamescope`)*

## Installation

```bash
git clone https://github.com/zackslash/cosmic-virtual-screen-for-steam-deck.git
cd cosmic-virtual-screen-for-steam-deck
sudo ./install.sh
```

The installer lists all display outputs (e.g. `DP-2`, `HDMI-A-1`) and prompts you to select the connector where your dummy plug is connected. It then generates a custom EDID, installs it to firmware + initramfs, configures your bootloader (systemd-boot or GRUB), and installs the `cosmic-deck-switch` helper. **Reboot after installation.**

The installer also offers optional **HDR support** — enabling it generates an EDID with BT.2020 colorimetry and HDR10 Static Metadata, which allows Sunshine's KMS backend to signal HDR to Moonlight clients. Only enable HDR if your Sunshine version and Moonlight client both support it.

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

## HDR

When HDR is enabled during installation, the EDID is generated with:

- **BT.2020 colorimetry** (CTA-861 Extended Tag 0x05) — advertises wide-gamut colour space
- **HDR10 Static Metadata** (CTA-861 Extended Tag 0x06) — SMPTE ST 2084 (PQ) EOTF, ~1000 nit peak luminance
- **10-bit colour depth** signalled in the EDID video input byte

The EDID tells the GPU driver that the virtual display *supports* HDR. However, Sunshine determines whether to actually stream HDR by reading the `HDR_OUTPUT_METADATA` DRM connector property — a blob that **the Wayland compositor must write** at runtime, not the EDID itself.

**COSMIC Desktop (v1.0.x) does not yet implement HDR output**, so the standard `sunshine-start.sh` path will not produce HDR streaming even with the HDR EDID installed. The Gamescope HDR variant below is the recommended path for HDR today.

To regenerate the EDID with HDR enabled manually:

```bash
python3 edid_generator.py --hdr steamdeck_virtual.bin
```

## Gamescope HDR Streaming

As an alternative to the standard COSMIC path, `sunshine-start-gamescope.sh` launches [gamescope](https://github.com/ValveSoftware/gamescope) as a **standalone KMS compositor** on a separate virtual terminal, bypassing COSMIC entirely. Gamescope sets `HDR_OUTPUT_METADATA` directly on the DRM connector, which Sunshine reads to enable HDR streaming to Moonlight.

This is the same architecture SteamOS uses — gamescope owns the display, Steam and games run inside it.

### Why a separate compositor?

Sunshine detects HDR by reading the `HDR_OUTPUT_METADATA` property on the DRM connector. Only the active compositor can write this property. When gamescope runs standalone (not nested under COSMIC), it holds DRM master directly and writes the HDR metadata blob itself. When gamescope runs *nested* inside COSMIC (the default when launching Steam from the desktop), it is a Wayland client and cannot set DRM properties — COSMIC would need to forward the HDR intent, which it doesn't implement yet.

### How it works

1. **Before connecting** — run `switch-to-hdr.sh` on the host machine. This reconfigures Sunshine to use wlr-screencopy (`capture = wlr`) against gamescope's Wayland socket, installs a systemd drop-in to inject `WAYLAND_DISPLAY=gamescope-0`, and restarts Sunshine. Sunshine must be reconfigured *before* a Moonlight client connects — reconfiguring mid-session causes a 503 error.
2. **Connect from Moonlight** and launch "Steam Big Picture (Gamescope HDR)".
3. Sunshine's prep-command (`sunshine-start-gamescope.sh`) switches to a free VT, launches gamescope as a standalone KMS compositor with `--backend drm --hdr-enabled`, and waits for it to be ready.
4. COSMIC suspends (VT switch), gamescope takes DRM master and sets `HDR_OUTPUT_METADATA` on the connector.
5. Steam Big Picture runs inside gamescope. Sunshine captures via wlr-screencopy and streams in HDR10.
6. On disconnect, the undo-command (`sunshine-stop-gamescope.sh`) kills gamescope, switches back to COSMIC's VT, restores `sunshine.conf`, and schedules a Sunshine restart (deferred so it doesn't kill the script mid-teardown).
7. Run `switch-to-hdr.sh --restore` to switch Sunshine back to KMS capture for the standard COSMIC streaming path.

### Prerequisites

- **gamescope** installed: `sudo pacman -S gamescope`
- **seatd-launch** with SUID set — the installer handles this when you opt in to gamescope support:
  ```bash
  sudo chmod u+s /usr/bin/seatd-launch
  ```
- **Passwordless `chvt`** — the stop script switches VTs, which requires root:
  ```bash
  echo 'YOUR_USER ALL=(root) NOPASSWD: /usr/bin/chvt' | sudo tee /etc/sudoers.d/chvt
  sudo chmod 440 /etc/sudoers.d/chvt
  ```
- **HDR EDID installed** — run the installer with HDR enabled (or re-run with `python3 edid_generator.py --hdr steamdeck_virtual.bin` + reinstall)
- **Sunshine encoder** — set `hevc_mode = 3` (or `av1_mode = 3`) in `~/.config/sunshine/sunshine.conf`

### Setup

**Step 1 — Configure the Sunshine app**

A pre-configured **"Steam Big Picture (Gamescope HDR)"** Sunshine app is included in the repository's `apps.json`. Import it via the Sunshine web UI, or add the entry manually:

```json
{
    "name": "Steam Big Picture (Gamescope HDR)",
    "auto-detach": true,
    "cmd": [],
    "exit-timeout": 5,
    "prep-cmd": [
        {
            "do": "/path/to/sunshine-start-gamescope.sh",
            "undo": "/path/to/sunshine-stop-gamescope.sh"
        }
    ]
}
```

Replace `/path/to/` with the actual path to your cloned repository.

> **Note:** There is no `detached` Steam launch command — Steam runs *inside* gamescope, not as a separate detached process.

**Step 2 — Switch Sunshine to HDR mode before connecting**

Run this on the host machine from a terminal (not inside a Moonlight session):

```bash
./switch-to-hdr.sh
```

This reconfigures `~/.config/sunshine/sunshine.conf` to use `capture = wlr`, installs a transient systemd drop-in that sets `WAYLAND_DISPLAY=gamescope-0`, and restarts Sunshine. Wait for it to confirm Sunshine is ready before connecting from Moonlight.

**Step 3 — Connect and stream**

Connect from Moonlight and launch "Steam Big Picture (Gamescope HDR)". Gamescope will start and take over the display.

**Step 4 — Restore SDR mode when done**

After your session ends and you want to go back to standard COSMIC streaming:

```bash
./switch-to-hdr.sh --restore
```

This restores the original `sunshine.conf`, removes the systemd drop-in, and restarts Sunshine with `capture = kms`.

### Limitations

- **COSMIC is suspended** while gamescope is active — you cannot use the desktop during a gamescope session. COSMIC resumes automatically when the stream ends.
- **`switch-to-hdr.sh` must be run before connecting** — reconfiguring Sunshine while Moonlight is connected causes a 503 error. This is by design.
- **Startup time** — gamescope + Steam takes 30–60 seconds to be ready after you connect in Moonlight.
- **Logs** — gamescope output is saved to `$XDG_RUNTIME_DIR/gamescope-sunshine.log` for debugging.

## Sunshine Integration

The scripts automatically switch between your main display and the virtual display when a stream starts/stops.

### Setup

The installer automatically writes your display configuration to `~/.config/cosmic-deck-switch/config`. To change settings later, edit this file directly:

```bash
# ~/.config/cosmic-deck-switch/config
MAIN_DISPLAY=DP-2
VIRTUAL_DISPLAY=HDMI-A-2
DEFAULT_MODE=deck-oled
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
               "do": "/path/to/sunshine-start.sh deck-oled",
               "undo": "/path/to/sunshine-stop.sh"
           }
       ]
   }
   ```
   Replace `/path/to/` with the actual location of your cloned repository.

### Emergency Recovery

If your main display doesn't come back (Sunshine crash, etc.):

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
- **Gamescope session doesn't return to COSMIC desktop after stream ends** — The stop script uses `sudo chvt` to switch back to COSMIC's virtual terminal. If the sudoers rule wasn't installed, this silently fails and your display stays on a blank VT. Fix: run `sudo chvt 2` manually (or whichever VT number COSMIC is on), or add the sudoers rule: `echo 'YOUR_USER ALL=(root) NOPASSWD: /usr/bin/chvt' | sudo tee /etc/sudoers.d/chvt && sudo chmod 440 /etc/sudoers.d/chvt`

## How It Works

The installer generates a 256-byte EDID binary (base block + CTA-861 extension with HDMI VSDB for >165MHz pixel clocks, CVT Reduced Blanking timings, and optional HDR10 metadata with BT.2020 colorimetry) and loads it via the kernel's `drm.edid_firmware` parameter. This makes the GPU treat the dummy plug as a real monitor with the declared resolutions. The Sunshine scripts save/restore full display state (mode, scale, transform, adaptive sync, position) since COSMIC doesn't persist settings through enable/disable cycles.

The **Gamescope HDR path** works differently: instead of managing displays within COSMIC, gamescope runs as a standalone KMS compositor on a separate VT, taking DRM master directly from COSMIC via a VT switch. This allows gamescope to set `HDR_OUTPUT_METADATA` on the connector itself — the mechanism Sunshine uses to detect HDR — without relying on COSMIC to implement it. Because Sunshine needs to capture via wlr-screencopy from gamescope's Wayland socket (not KMS), `switch-to-hdr.sh` must be run before connecting to reconfigure `sunshine.conf` and inject `WAYLAND_DISPLAY=gamescope-0` via a transient systemd drop-in.

## License

MIT — see [LICENSE](LICENSE).
