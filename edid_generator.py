#!/usr/bin/env python3
"""
EDID Generator for Steam Deck Virtual Screens (COSMIC Desktop)
Generates custom EDID files with 16:10 resolutions optimized for Steam Deck streaming

This generator creates a 256-byte EDID binary (128-byte base + 128-byte CTA-861 extension)
with proper CVT Reduced Blanking timings, Display Range Limits, and HDMI VSDB for
high-bandwidth mode support.
"""

import struct
import sys
from typing import List, Tuple
from dataclasses import dataclass


@dataclass(frozen=True)
class Resolution:
    """Display resolution configuration"""
    width: int
    height: int
    refresh_rate: int
    name: str


class EDIDGenerator:
    """Generates EDID binary files with custom resolutions"""

    # EDID header (fixed)
    EDID_HEADER = bytes([0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])

    def __init__(self, manufacturer_id: str = "VRT", product_code: int = 0x1234):
        """
        Initialize EDID generator

        Args:
            manufacturer_id: 3-letter manufacturer ID (e.g., "VRT" for Virtual)
            product_code: Product code (16-bit)
        """
        self.manufacturer_id = manufacturer_id
        self.product_code = product_code
        self.resolutions: List[Resolution] = []

    def add_resolution(self, width: int, height: int, refresh_rate: int, name: str = ""):
        """Add a resolution to the EDID"""
        if not name:
            name = f"{width}x{height}@{refresh_rate}Hz"
        self.resolutions.append(Resolution(width, height, refresh_rate, name))

    def _encode_manufacturer_id(self) -> bytes:
        """Encode 3-letter manufacturer ID into 2 bytes"""
        if len(self.manufacturer_id) != 3:
            raise ValueError("Manufacturer ID must be 3 characters")

        # Convert to uppercase and get 5-bit values (A=1, B=2, etc.)
        chars = [ord(c.upper()) - ord('A') + 1 for c in self.manufacturer_id]

        # Pack into 16 bits: 0bccccccbbbbbaaaaa
        packed = (chars[0] << 10) | (chars[1] << 5) | chars[2]

        # Return as big-endian 2 bytes
        return struct.pack('>H', packed)

    def _calculate_dtd(self, res: Resolution) -> bytes:
        """
        Calculate Detailed Timing Descriptor for a resolution
        18 bytes total, using CVT Reduced Blanking timings
        """
        if res.width == 1280 and res.height == 800:
            h_blank = 160
            v_blank = 23
        elif res.width == 1920 and res.height == 1200:
            h_blank = 160
            v_blank = 25
        elif res.width == 2560 and res.height == 1600:
            h_blank = 160
            v_blank = 27
        elif res.width == 2560 and res.height == 1440:
            h_blank = 160
            v_blank = 25
        else:
            # Fallback to calculated values
            h_blank = 160  # CVT-RB standard
            v_blank = max(23, int(res.height * 0.03))

        h_sync_offset = 48
        h_sync_width = 32
        v_sync_offset = 3
        v_sync_width = 6

        h_total = res.width + h_blank
        v_total = res.height + v_blank

        # Pixel clock in Hz
        pixel_clock_hz = h_total * v_total * res.refresh_rate
        pixel_clock_10khz = pixel_clock_hz // 10000

        dtd = bytearray(18)

        # Byte 0-1: Pixel clock in 10kHz units (little-endian)
        dtd[0:2] = struct.pack('<H', pixel_clock_10khz)

        # Byte 2: Horizontal active pixels (low 8 bits)
        dtd[2] = res.width & 0xFF

        # Byte 3: Horizontal blanking (low 8 bits)
        dtd[3] = h_blank & 0xFF

        # Byte 4: H active/blanking high bits (4 bits each)
        dtd[4] = ((res.width >> 8) & 0x0F) << 4 | ((h_blank >> 8) & 0x0F)

        # Byte 5: Vertical active lines (low 8 bits)
        dtd[5] = res.height & 0xFF

        # Byte 6: Vertical blanking (low 8 bits)
        dtd[6] = v_blank & 0xFF

        # Byte 7: V active/blanking high bits (4 bits each)
        dtd[7] = ((res.height >> 8) & 0x0F) << 4 | ((v_blank >> 8) & 0x0F)

        # Byte 8: H sync offset (low 8 bits)
        dtd[8] = h_sync_offset & 0xFF

        # Byte 9: H sync pulse width (low 8 bits)
        dtd[9] = h_sync_width & 0xFF

        # Byte 10: V sync offset (low 4 bits) and V sync width (low 4 bits)
        dtd[10] = ((v_sync_offset & 0x0F) << 4) | (v_sync_width & 0x0F)

        # Byte 11: High bits for sync offset and width
        dtd[11] = (((h_sync_offset >> 8) & 0x03) << 6) | \
                  (((h_sync_width >> 8) & 0x03) << 4) | \
                  (((v_sync_offset >> 4) & 0x03) << 2) | \
                  ((v_sync_width >> 4) & 0x03)

        # Bytes 12-14: Physical image size (0 = virtual display)
        dtd[12] = 0
        dtd[13] = 0
        dtd[14] = 0

        # Byte 15-16: Borders (none)
        dtd[15] = 0
        dtd[16] = 0

        # Byte 17: Flags - CVT-RB requires H-Sync Positive, V-Sync Negative
        # 0x1A = 0001 1010 (Digital Separate Sync, V-, H+)
        dtd[17] = 0x1A

        return bytes(dtd)

    def _create_display_descriptor(self, desc_type: int, data: bytes) -> bytes:
        """Create a display descriptor block (18 bytes)"""
        descriptor = bytearray(18)
        descriptor[0:2] = b'\x00\x00'  # Not a DTD
        descriptor[2] = 0  # Reserved
        descriptor[3] = desc_type
        descriptor[4] = 0  # Reserved
        data_len = min(len(data), 13)
        descriptor[5:5+data_len] = data[:data_len]
        return bytes(descriptor)

    def _create_range_limits_descriptor(self) -> bytes:
        """
        Create Display Range Limits Descriptor (Tag 0xFD)
        Critical for allowing high refresh rates that exceed standard VESA limits
        """
        min_v_rate = 48
        max_v_rate = 125  # Covers 120Hz
        min_h_rate = 30
        max_h_rate = 160  # 1920x1200@120Hz needs ~150kHz
        max_pixel_clock = 60  # 600 MHz (2560x1600@90Hz needs ~398MHz)

        descriptor = bytearray(18)
        descriptor[0:3] = b'\x00\x00\x00'
        descriptor[3] = 0xFD  # Range Limits Tag
        descriptor[4] = 0x00
        descriptor[5] = min_v_rate
        descriptor[6] = max_v_rate
        descriptor[7] = min_h_rate
        descriptor[8] = max_h_rate
        descriptor[9] = max_pixel_clock
        descriptor[10] = 0x01  # Range Limits Only (prevents GTF fallback)
        descriptor[11] = 0x0A  # End of range limits
        descriptor[12:18] = b'\x20' * 6  # Pad with spaces

        return bytes(descriptor)

    def _calculate_checksum(self, block: bytearray) -> int:
        return (256 - sum(block)) % 256

    def _create_hdmi_vsdb(self) -> bytes:
        """
        Create HDMI Vendor Specific Data Block
        Required to unlock >165MHz pixel clock on HDMI ports.
        Includes Max TMDS Clock declaration for high-bandwidth modes.
        """
        # HDMI Licensing LLC OUI: 00-0C-03 (stored LSB first)
        oui = [0x03, 0x0C, 0x00]
        # Source Physical Address: 1.0.0.0
        phys_addr = [0x10, 0x00]
        # A/I flags: no audio/interlace support needed for virtual display
        ai_flags = [0x00]
        # Max TMDS Clock in 5MHz units: 600MHz / 5 = 120
        # Required for Nvidia drivers to allow >165MHz pixel clocks
        # (2560x1440@120Hz needs ~498MHz, 2560x1600@90Hz needs ~398MHz)
        max_tmds = [120]

        payload = bytes(oui + phys_addr + ai_flags + max_tmds)
        length = len(payload)
        # Header: Tag 3 (Vendor Specific) | Length
        header = (3 << 5) | length

        return struct.pack('B', header) + payload

    def _create_cta861_extension(self) -> bytes:
        """
        Create CTA-861 Extension Block (128 bytes)
        Contains HDMI VSDB and DTDs for all high-refresh modes
        """
        ext = bytearray(128)

        # Byte 0: Tag (0x02 = CTA-861)
        ext[0] = 0x02
        # Byte 1: Revision (3)
        ext[1] = 0x03

        # Bytes 4+: Data Blocks
        cursor = 4

        # Add HDMI VSDB
        hdmi_vsdb = self._create_hdmi_vsdb()
        ext[cursor:cursor+len(hdmi_vsdb)] = hdmi_vsdb
        cursor += len(hdmi_vsdb)

        # Byte 2: DTD Offset (DTDs start after data blocks)
        ext[2] = cursor
        # Byte 3: Flags / Native DTDs
        ext[3] = 0x00

        # Add DTDs for modes that aren't already covered by base block entries:
        # - All non-60Hz modes (since base block DTD1 is the 60Hz anchor)
        # - Wide 60Hz modes (width > 2288) that can't be in Standard Timings
        # Exclude base block DTDs (safe_res + DTD2-3) to avoid duplicates
        base_covered = self._base_dtd_modes | {self._safe_res}
        all_high_res = [r for r in self.resolutions
                        if (r.refresh_rate > 60 or r.width > 2288)
                        and r not in base_covered]
        all_high_res.sort(key=lambda x: (x.refresh_rate, x.width), reverse=True)

        for res in all_high_res:
            if cursor + 18 <= 127:
                ext[cursor:cursor+18] = self._calculate_dtd(res)
                cursor += 18
            else:
                print(f"Warning: Not enough space in Extension Block for {res.name}", file=sys.stderr)

        # Byte 127: Checksum
        ext[127] = self._calculate_checksum(ext[0:127])

        return bytes(ext)

    def generate(self) -> bytes:
        """Generate complete EDID binary (Base + Extension)"""
        if not self.resolutions:
            raise ValueError("No resolutions added")

        # --- Block 0: Base EDID (128 bytes) ---
        edid = bytearray(128)

        # Bytes 0-7: Header
        edid[0:8] = self.EDID_HEADER

        # Bytes 8-9: Manufacturer ID
        edid[8:10] = self._encode_manufacturer_id()

        # Bytes 10-11: Product code (little-endian)
        edid[10:12] = struct.pack('<H', self.product_code)

        # Bytes 12-15: Serial number
        edid[12:16] = b'\x00\x00\x00\x00'

        # Byte 16: Manufacture week
        edid[16] = 1

        # Byte 17: Manufacture year (2025 -> 35, since EDID year = value + 1990)
        edid[17] = 35

        # Bytes 18-19: EDID version 1.4
        edid[18] = 1
        edid[19] = 4

        # Byte 20: Video input definition (digital)
        edid[20] = 0x80

        # Bytes 21-22: Screen size (0 = undefined/virtual)
        edid[21] = 0
        edid[22] = 0

        # Byte 23: Gamma (2.20)
        edid[23] = 0x78

        # Byte 24: Feature support (RGB color, preferred timing in DTD1)
        edid[24] = 0x0A

        # Bytes 25-34: Chromaticity (unspecified for virtual)
        edid[25:35] = bytes(10)

        # Bytes 35-37: Established timings (none)
        edid[35:38] = b'\x00\x00\x00'

        # Bytes 38-53: Standard Timing Information (8 slots, 2 bytes each)
        std_timings = bytearray(16)
        std_idx = 0
        sorted_res = sorted(self.resolutions, key=lambda x: (x.width, x.height), reverse=True)
        seen_ratios = set()

        for res in sorted_res:
            if abs(res.refresh_rate - 60) > 1:
                continue

            # Standard Timings encode width as (width/8)-31 in a single byte (max 255)
            # This supports widths up to 2288px. Skip wider resolutions.
            if res.width > 2288 or res.width < 256:
                continue

            ratio = res.width / res.height
            if 1.59 <= ratio <= 1.61:    # 16:10
                ar_bits = 0
            elif 1.32 <= ratio <= 1.34:  # 4:3
                ar_bits = 1
            elif 1.24 <= ratio <= 1.26:  # 5:4
                ar_bits = 2
            elif 1.76 <= ratio <= 1.79:  # 16:9
                ar_bits = 3
            else:
                continue

            b1 = (res.width // 8) - 31
            b2 = (ar_bits << 6) | 0  # 60Hz

            key = (b1, b2)
            if key not in seen_ratios and std_idx < 16:
                std_timings[std_idx] = b1 & 0xFF
                std_timings[std_idx+1] = b2
                std_idx += 2
                seen_ratios.add(key)

        # Fill remainder with unused marker
        while std_idx < 16:
            std_timings[std_idx] = 0x01
            std_timings[std_idx+1] = 0x01
            std_idx += 2

        edid[38:54] = std_timings

        # Bytes 54-125: Four 18-byte descriptor blocks

        # DTD 1: Safe 60Hz anchor (largest 60Hz resolution for boot)
        safe_res = next((r for r in sorted_res if abs(r.refresh_rate - 60) <= 1), self.resolutions[0])
        self._safe_res = safe_res  # Store for extension block dedup
        edid[54:72] = self._calculate_dtd(safe_res)

        # DTD 2-3: Top 2 high-refresh modes
        high_refresh_modes = [r for r in self.resolutions if r.refresh_rate > 60]
        high_refresh_modes.sort(key=lambda x: (x.refresh_rate, x.width), reverse=True)
        self._base_dtd_modes = set()  # Track for extension block dedup

        cursor = 72
        for i in range(min(2, len(high_refresh_modes))):
            edid[cursor:cursor+18] = self._calculate_dtd(high_refresh_modes[i])
            self._base_dtd_modes.add(high_refresh_modes[i])
            cursor += 18

        # Fill remaining descriptor slots with dummy descriptors
        while cursor < 108:
            edid[cursor:cursor+18] = self._create_display_descriptor(0x10, b'')
            cursor += 18

        # Descriptor 4: Display Range Limits (critical for >60Hz support)
        edid[108:126] = self._create_range_limits_descriptor()

        # Byte 126: Extension count
        edid[126] = 1

        # Byte 127: Checksum
        edid[127] = self._calculate_checksum(edid[0:127])

        # --- Block 1: CTA-861 Extension ---
        ext_block = self._create_cta861_extension()

        return bytes(edid + ext_block)

    def save(self, filename: str):
        """Generate and save EDID to a file"""
        edid_data = self.generate()
        with open(filename, 'wb') as f:
            f.write(edid_data)
        print(f"Generated EDID file: {filename} ({len(edid_data)} bytes)")

        print(f"\nResolutions included:")
        for i, res in enumerate(self.resolutions, 1):
            print(f"  {i}. {res.name}")


def create_steam_deck_edid(output_file: str = "steamdeck_virtual.bin"):
    """Create EDID with all Steam Deck-optimized resolutions"""
    generator = EDIDGenerator(manufacturer_id="VRT", product_code=0x5344)

    # Native Steam Deck resolutions (16:10)
    generator.add_resolution(1280, 800, 60, "1280x800@60Hz")
    generator.add_resolution(1280, 800, 90, "1280x800@90Hz")

    # 1200p resolutions (16:10)
    generator.add_resolution(1920, 1200, 60, "1920x1200@60Hz")
    generator.add_resolution(1920, 1200, 90, "1920x1200@90Hz")
    generator.add_resolution(1920, 1200, 120, "1920x1200@120Hz")

    # 1440p resolutions (16:9)
    generator.add_resolution(2560, 1440, 60, "2560x1440@60Hz")
    generator.add_resolution(2560, 1440, 120, "2560x1440@120Hz")

    # 1600p resolutions (16:10)
    generator.add_resolution(2560, 1600, 60, "2560x1600@60Hz")
    generator.add_resolution(2560, 1600, 90, "2560x1600@90Hz")

    generator.save(output_file)
    return output_file


def main():
    """Main entry point"""
    if len(sys.argv) > 1:
        output_file = sys.argv[1]
    else:
        output_file = "steamdeck_virtual.bin"

    print("=" * 60)
    print("EDID Generator for Steam Deck Virtual Screens")
    print("(COSMIC Desktop Edition)")
    print("=" * 60)
    print()

    create_steam_deck_edid(output_file)

    print(f"\nTo use this EDID:")
    print(f"  1. Copy to firmware: sudo cp {output_file} /usr/lib/firmware/edid/")
    print(f"  2. Add kernel parameter: drm.edid_firmware=HDMI-A-1:edid/{output_file}")
    print(f"  3. Reboot")
    print()


if __name__ == "__main__":
    main()
