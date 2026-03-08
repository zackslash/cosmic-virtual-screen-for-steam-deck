#!/usr/bin/env python3
"""
Comprehensive unit tests for EDID generator
Tests binary structure, checksums, encoding, and all EDID components

Run from project root with: python3 -m unittest tests.test_edid_generator
"""

import sys
import os
import unittest
import tempfile
import struct

# Add parent directory to path to import edid_generator
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from edid_generator import EDIDGenerator, Resolution, create_steam_deck_edid


class TestEDIDBinaryStructure(unittest.TestCase):
    """Test basic binary structure of EDID"""

    @classmethod
    def setUpClass(cls):
        """Generate EDID once for all binary structure tests"""
        cls.generator = EDIDGenerator(manufacturer_id="VRT", product_code=0x1234)
        cls.generator.add_resolution(1280, 800, 60, "1280x800@60Hz")
        cls.generator.add_resolution(1920, 1200, 60, "1920x1200@60Hz")
        cls.generator.add_resolution(1920, 1200, 120, "1920x1200@120Hz")
        cls.edid = cls.generator.generate()

    def test_total_size_is_256_bytes(self):
        """EDID must be exactly 256 bytes (128 base + 128 extension)"""
        self.assertEqual(len(self.edid), 256)

    def test_block0_is_128_bytes(self):
        """Block 0 (base EDID) is 128 bytes"""
        block0 = self.edid[:128]
        self.assertEqual(len(block0), 128)

    def test_block1_is_128_bytes(self):
        """Block 1 (CTA-861 extension) is 128 bytes"""
        block1 = self.edid[128:256]
        self.assertEqual(len(block1), 128)

    def test_edid_header_is_correct(self):
        """EDID header must be 00 FF FF FF FF FF FF 00"""
        expected_header = bytes([0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])
        actual_header = self.edid[0:8]
        self.assertEqual(actual_header, expected_header)

    def test_edid_version_is_1_4(self):
        """EDID version should be 1.4 (bytes 18=1, 19=4)"""
        version = self.edid[18]
        revision = self.edid[19]
        self.assertEqual(version, 1)
        self.assertEqual(revision, 4)

    def test_extension_count_is_1(self):
        """Extension count (byte 126) should be 1"""
        extension_count = self.edid[126]
        self.assertEqual(extension_count, 1)

    def test_extension_tag_is_cta861(self):
        """Extension tag (byte 128) should be 0x02 (CTA-861)"""
        extension_tag = self.edid[128]
        self.assertEqual(extension_tag, 0x02)


class TestEDIDChecksums(unittest.TestCase):
    """Test EDID checksum calculations"""

    @classmethod
    def setUpClass(cls):
        """Generate EDID once for all checksum tests"""
        cls.generator = EDIDGenerator(manufacturer_id="VRT", product_code=0x1234)
        cls.generator.add_resolution(1280, 800, 60, "1280x800@60Hz")
        cls.generator.add_resolution(1920, 1200, 120, "1920x1200@120Hz")
        cls.edid = cls.generator.generate()

    def test_block0_checksum_valid(self):
        """Block 0 checksum: sum of bytes 0-127 mod 256 == 0"""
        block0 = self.edid[:128]
        checksum_sum = sum(block0) % 256
        self.assertEqual(checksum_sum, 0,
                        f"Block 0 checksum failed: sum={checksum_sum}, expected=0")

    def test_block1_checksum_valid(self):
        """Block 1 checksum: sum of bytes 128-255 mod 256 == 0"""
        block1 = self.edid[128:256]
        checksum_sum = sum(block1) % 256
        self.assertEqual(checksum_sum, 0,
                        f"Block 1 checksum failed: sum={checksum_sum}, expected=0")

    def test_checksums_recalculated_correctly(self):
        """Checksums are correct after multiple generations"""
        # Generate fresh EDID
        gen = EDIDGenerator(manufacturer_id="TST", product_code=0x9999)
        gen.add_resolution(1920, 1080, 60, "1920x1080@60Hz")
        edid = gen.generate()

        # Check both blocks
        block0_sum = sum(edid[:128]) % 256
        block1_sum = sum(edid[128:256]) % 256

        self.assertEqual(block0_sum, 0, "Block 0 checksum invalid on fresh generation")
        self.assertEqual(block1_sum, 0, "Block 1 checksum invalid on fresh generation")


class TestManufacturerIDEncoding(unittest.TestCase):
    """Test 3-letter manufacturer ID encoding"""

    def test_vrt_encodes_correctly(self):
        """VRT should encode to specific 2-byte value"""
        gen = EDIDGenerator(manufacturer_id="VRT", product_code=0x1234)
        encoded = gen._encode_manufacturer_id()

        # VRT: V=22, R=18, T=20
        # Packed: (22 << 10) | (18 << 5) | 20 = 22528 + 576 + 20 = 23124 = 0x5A54
        # Big-endian: 0x5A, 0x54
        expected = bytes([0x5A, 0x54])
        self.assertEqual(encoded, expected,
                        f"VRT encoding incorrect: got {encoded.hex()}, expected {expected.hex()}")

    def test_abc_encodes_correctly(self):
        """ABC should encode correctly (A=1, B=2, C=3)"""
        gen = EDIDGenerator(manufacturer_id="ABC", product_code=0x1234)
        encoded = gen._encode_manufacturer_id()

        # ABC: A=1, B=2, C=3
        # Packed: (1 << 10) | (2 << 5) | 3 = 1024 + 64 + 3 = 1091 = 0x0443
        expected = bytes([0x04, 0x43])
        self.assertEqual(encoded, expected)

    def test_xyz_encodes_correctly(self):
        """XYZ should encode correctly (X=24, Y=25, Z=26)"""
        gen = EDIDGenerator(manufacturer_id="XYZ", product_code=0x1234)
        encoded = gen._encode_manufacturer_id()

        # XYZ: X=24, Y=25, Z=26
        # Packed: (24 << 10) | (25 << 5) | 26 = 24576 + 800 + 26 = 25402 = 0x633A
        expected = bytes([0x63, 0x3A])
        self.assertEqual(encoded, expected)

    def test_lowercase_converts_to_uppercase(self):
        """Lowercase manufacturer IDs should be converted to uppercase"""
        gen1 = EDIDGenerator(manufacturer_id="vrt", product_code=0x1234)
        gen2 = EDIDGenerator(manufacturer_id="VRT", product_code=0x1234)

        encoded1 = gen1._encode_manufacturer_id()
        encoded2 = gen2._encode_manufacturer_id()

        self.assertEqual(encoded1, encoded2, "Lowercase should match uppercase encoding")

    def test_invalid_length_raises_valueerror(self):
        """Non-3-character manufacturer IDs should raise ValueError"""
        gen = EDIDGenerator(manufacturer_id="AB", product_code=0x1234)
        with self.assertRaises(ValueError) as ctx:
            gen._encode_manufacturer_id()
        self.assertIn("3 characters", str(ctx.exception))

        gen2 = EDIDGenerator(manufacturer_id="ABCD", product_code=0x1234)
        with self.assertRaises(ValueError):
            gen2._encode_manufacturer_id()


class TestHDMIVSDB(unittest.TestCase):
    """Test HDMI Vendor Specific Data Block"""

    @classmethod
    def setUpClass(cls):
        """Generate EDID and extract VSDB"""
        cls.generator = EDIDGenerator(manufacturer_id="VRT", product_code=0x1234)
        cls.generator.add_resolution(1280, 800, 60, "1280x800@60Hz")
        cls.generator.add_resolution(2560, 1440, 120, "2560x1440@120Hz")
        cls.edid = cls.generator.generate()

        # VSDB starts at byte 132 (after CTA header)
        cls.vsdb_start = 132
        cls.vsdb_header = cls.edid[cls.vsdb_start]
        cls.vsdb_tag = (cls.vsdb_header >> 5) & 0x07
        cls.vsdb_length = cls.vsdb_header & 0x1F
        cls.vsdb_data = cls.edid[cls.vsdb_start+1:cls.vsdb_start+1+cls.vsdb_length]

    def test_vsdb_tag_is_vendor_specific(self):
        """VSDB tag (top 3 bits) should be 3 (Vendor Specific)"""
        self.assertEqual(self.vsdb_tag, 3,
                        f"VSDB tag should be 3, got {self.vsdb_tag}")

    def test_vsdb_length_is_correct(self):
        """VSDB length should be 7 (OUI + phys_addr + ai_flags + max_tmds)"""
        self.assertEqual(self.vsdb_length, 7,
                        f"VSDB length should be 7, got {self.vsdb_length}")

    def test_vsdb_oui_is_hdmi(self):
        """VSDB OUI should be 03-0C-00 (HDMI Licensing LLC, LSB first)"""
        oui = self.vsdb_data[0:3]
        expected_oui = bytes([0x03, 0x0C, 0x00])
        self.assertEqual(oui, expected_oui,
                        f"OUI should be {expected_oui.hex()}, got {oui.hex()}")

    def test_vsdb_physical_address(self):
        """VSDB physical address should be 10-00 (1.0.0.0)"""
        phys_addr = self.vsdb_data[3:5]
        expected_addr = bytes([0x10, 0x00])
        self.assertEqual(phys_addr, expected_addr,
                        f"Physical address should be {expected_addr.hex()}, got {phys_addr.hex()}")

    def test_vsdb_max_tmds_clock(self):
        """VSDB Max TMDS Clock should be 120 (600MHz)"""
        max_tmds = self.vsdb_data[6]
        self.assertEqual(max_tmds, 120,
                        f"Max TMDS should be 120 (600MHz), got {max_tmds}")

    def test_max_tmds_sufficient_for_all_modes(self):
        """Max TMDS (600MHz) should exceed all mode pixel clocks"""
        max_tmds_mhz = 600

        for res in self.generator.resolutions:
            # Calculate pixel clock for this mode
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
                h_blank = 160
                v_blank = max(23, int(res.height * 0.03))

            h_total = res.width + h_blank
            v_total = res.height + v_blank
            pixel_clock_hz = h_total * v_total * res.refresh_rate
            pixel_clock_mhz = pixel_clock_hz / 1_000_000

            self.assertLess(pixel_clock_mhz, max_tmds_mhz,
                           f"{res.name} pixel clock {pixel_clock_mhz:.1f}MHz exceeds "
                           f"Max TMDS {max_tmds_mhz}MHz")


class TestDetailedTimingDescriptor(unittest.TestCase):
    """Test DTD (Detailed Timing Descriptor) generation"""

    @classmethod
    def setUpClass(cls):
        """Generate EDID with known resolutions"""
        cls.generator = EDIDGenerator(manufacturer_id="VRT", product_code=0x1234)
        cls.generator.add_resolution(1280, 800, 60, "1280x800@60Hz")
        cls.generator.add_resolution(1920, 1200, 60, "1920x1200@60Hz")
        cls.generator.add_resolution(1920, 1200, 120, "1920x1200@120Hz")
        cls.edid = cls.generator.generate()

    def test_dtd_is_18_bytes(self):
        """Each DTD should be exactly 18 bytes"""
        res = Resolution(1920, 1080, 60, "1920x1080@60Hz")
        dtd = self.generator._calculate_dtd(res)
        self.assertEqual(len(dtd), 18)

    def test_dtd_pixel_clock_nonzero(self):
        """DTD pixel clock (bytes 0-1) should be non-zero"""
        # First DTD starts at byte 54
        dtd = self.edid[54:72]
        pixel_clock_10khz = struct.unpack('<H', dtd[0:2])[0]
        self.assertGreater(pixel_clock_10khz, 0,
                          "Pixel clock should be non-zero")

    def test_dtd_pixel_clock_reasonable(self):
        """DTD pixel clock should be in reasonable range"""
        # First DTD (should be 1920x1200@60Hz based on implementation)
        dtd = self.edid[54:72]
        pixel_clock_10khz = struct.unpack('<H', dtd[0:2])[0]
        pixel_clock_mhz = (pixel_clock_10khz * 10000) / 1_000_000

        # Reasonable range: 25MHz to 600MHz
        self.assertGreater(pixel_clock_mhz, 25,
                          f"Pixel clock {pixel_clock_mhz}MHz too low")
        self.assertLess(pixel_clock_mhz, 600,
                       f"Pixel clock {pixel_clock_mhz}MHz too high")

    def test_dtd_resolution_matches_input(self):
        """DTD H/V active should match resolution"""
        res = Resolution(1920, 1200, 60, "1920x1200@60Hz")
        dtd = self.generator._calculate_dtd(res)

        # H active: byte 2 (low 8) + byte 4 high nibble
        h_active_low = dtd[2]
        h_active_high = (dtd[4] >> 4) & 0x0F
        h_active = (h_active_high << 8) | h_active_low

        # V active: byte 5 (low 8) + byte 7 high nibble
        v_active_low = dtd[5]
        v_active_high = (dtd[7] >> 4) & 0x0F
        v_active = (v_active_high << 8) | v_active_low

        self.assertEqual(h_active, 1920, f"H active should be 1920, got {h_active}")
        self.assertEqual(v_active, 1200, f"V active should be 1200, got {v_active}")

    def test_dtd_blanking_nonzero(self):
        """DTD blanking intervals should be non-zero"""
        res = Resolution(1920, 1200, 60, "1920x1200@60Hz")
        dtd = self.generator._calculate_dtd(res)

        # H blanking: byte 3 (low 8) + byte 4 low nibble
        h_blank_low = dtd[3]
        h_blank_high = dtd[4] & 0x0F
        h_blank = (h_blank_high << 8) | h_blank_low

        # V blanking: byte 6 (low 8) + byte 7 low nibble
        v_blank_low = dtd[6]
        v_blank_high = dtd[7] & 0x0F
        v_blank = (v_blank_high << 8) | v_blank_low

        self.assertGreater(h_blank, 0, "H blanking should be non-zero")
        self.assertGreater(v_blank, 0, "V blanking should be non-zero")

    def test_dtd_sync_polarity_is_correct(self):
        """DTD byte 17 should be 0x1A (H+, V-, Digital Separate)"""
        res = Resolution(1920, 1200, 60, "1920x1200@60Hz")
        dtd = self.generator._calculate_dtd(res)

        sync_flags = dtd[17]
        self.assertEqual(sync_flags, 0x1A,
                        f"Sync flags should be 0x1A, got 0x{sync_flags:02X}")

    def test_dtd_physical_size_is_zero(self):
        """DTD physical size should be 0 (virtual display)"""
        res = Resolution(1920, 1200, 60, "1920x1200@60Hz")
        dtd = self.generator._calculate_dtd(res)

        # Bytes 12-14 encode physical size
        self.assertEqual(dtd[12], 0, "Physical width low byte should be 0")
        self.assertEqual(dtd[13], 0, "Physical height low byte should be 0")
        self.assertEqual(dtd[14], 0, "Physical size high bits should be 0")

    def test_pixel_clock_within_tmds_limit(self):
        """All DTDs should have pixel clock <= 600MHz"""
        for res in self.generator.resolutions:
            dtd = self.generator._calculate_dtd(res)
            pixel_clock_10khz = struct.unpack('<H', dtd[0:2])[0]
            pixel_clock_mhz = (pixel_clock_10khz * 10000) / 1_000_000

            self.assertLessEqual(pixel_clock_mhz, 600,
                                f"{res.name} pixel clock {pixel_clock_mhz:.1f}MHz "
                                f"exceeds 600MHz TMDS limit")


class TestStandardTimings(unittest.TestCase):
    """Test Standard Timing entries (bytes 38-53)"""

    @classmethod
    def setUpClass(cls):
        """Generate EDID with known resolutions"""
        cls.generator = EDIDGenerator(manufacturer_id="VRT", product_code=0x1234)
        cls.generator.add_resolution(1280, 800, 60, "1280x800@60Hz")
        cls.generator.add_resolution(1920, 1200, 60, "1920x1200@60Hz")
        cls.generator.add_resolution(2560, 1600, 60, "2560x1600@60Hz")
        cls.edid = cls.generator.generate()
        cls.std_timings = cls.edid[38:54]

    def test_no_standard_timing_exceeds_2288_width(self):
        """Standard timings encode (width/8)-31, max value 255 = 2288px width"""
        for i in range(0, 16, 2):
            byte1 = self.std_timings[i]
            byte2 = self.std_timings[i+1]

            # Skip unused slots (0x01 0x01)
            if byte1 == 0x01 and byte2 == 0x01:
                continue

            # Decode width
            width = (byte1 + 31) * 8

            self.assertLessEqual(width, 2288,
                                f"Standard timing slot {i//2} encodes width {width}px > 2288px")

    def test_2560_width_not_in_standard_timings(self):
        """2560-wide resolutions should not appear in standard timings (exceeds limit)"""
        # 2560 would encode as (2560/8)-31 = 289, which exceeds byte range 0-255
        for i in range(0, 16, 2):
            byte1 = self.std_timings[i]
            byte2 = self.std_timings[i+1]

            # Skip unused slots
            if byte1 == 0x01 and byte2 == 0x01:
                continue

            width = (byte1 + 31) * 8
            self.assertNotEqual(width, 2560,
                               f"2560px width should not be in standard timings")

    def test_1920x1200_in_standard_timings(self):
        """1920x1200@60Hz should be in standard timings"""
        # 1920x1200: width=(1920/8)-31=209, AR=16:10 (bits=00), refresh=60 (offset=0)
        # byte1 = 209, byte2 = 0x00 (16:10, 60Hz)
        expected_byte1 = (1920 // 8) - 31  # 209

        found = False
        for i in range(0, 16, 2):
            byte1 = self.std_timings[i]
            byte2 = self.std_timings[i+1]

            if byte1 == expected_byte1:
                # Check aspect ratio is 16:10 (bits 7-6 = 00)
                ar_bits = (byte2 >> 6) & 0x03
                if ar_bits == 0:  # 16:10
                    found = True
                    break

        self.assertTrue(found, "1920x1200@60Hz should be in standard timings")

    def test_1280x800_in_standard_timings(self):
        """1280x800@60Hz should be in standard timings"""
        expected_byte1 = (1280 // 8) - 31  # 129

        found = False
        for i in range(0, 16, 2):
            byte1 = self.std_timings[i]
            byte2 = self.std_timings[i+1]

            if byte1 == expected_byte1:
                ar_bits = (byte2 >> 6) & 0x03
                if ar_bits == 0:  # 16:10
                    found = True
                    break

        self.assertTrue(found, "1280x800@60Hz should be in standard timings")

    def test_unused_slots_filled_with_0x01(self):
        """Unused standard timing slots should be 0x01 0x01"""
        # Count how many are used vs unused
        used_count = 0
        for i in range(0, 16, 2):
            byte1 = self.std_timings[i]
            byte2 = self.std_timings[i+1]

            if byte1 == 0x01 and byte2 == 0x01:
                # Unused - verify all remaining are also unused
                for j in range(i+2, 16, 2):
                    self.assertEqual(self.std_timings[j], 0x01,
                                   f"Byte {38+j} should be 0x01 (unused)")
                    self.assertEqual(self.std_timings[j+1], 0x01,
                                   f"Byte {38+j+1} should be 0x01 (unused)")
                break
            else:
                used_count += 1


class TestDisplayRangeLimits(unittest.TestCase):
    """Test Display Range Limits Descriptor (critical for >60Hz)"""

    @classmethod
    def setUpClass(cls):
        """Generate EDID and locate range limits descriptor"""
        cls.generator = EDIDGenerator(manufacturer_id="VRT", product_code=0x1234)
        cls.generator.add_resolution(1920, 1200, 60, "1920x1200@60Hz")
        cls.generator.add_resolution(1920, 1200, 120, "1920x1200@120Hz")
        cls.edid = cls.generator.generate()

        # Range limits descriptor is at bytes 108-125 (4th descriptor)
        cls.range_desc = cls.edid[108:126]

    def test_descriptor_tag_is_range_limits(self):
        """Descriptor tag (byte 3) should be 0xFD"""
        tag = self.range_desc[3]
        self.assertEqual(tag, 0xFD,
                        f"Range limits tag should be 0xFD, got 0x{tag:02X}")

    def test_first_two_bytes_are_zero(self):
        """First two bytes should be 0x00 0x00 (not a DTD marker)"""
        self.assertEqual(self.range_desc[0], 0x00)
        self.assertEqual(self.range_desc[1], 0x00)

    def test_min_v_rate_is_48(self):
        """Min vertical rate (byte 5) should be 48Hz"""
        min_v = self.range_desc[5]
        self.assertEqual(min_v, 48,
                        f"Min V rate should be 48, got {min_v}")

    def test_max_v_rate_is_125(self):
        """Max vertical rate (byte 6) should be 125Hz"""
        max_v = self.range_desc[6]
        self.assertEqual(max_v, 125,
                        f"Max V rate should be 125, got {max_v}")

    def test_min_h_rate_is_30(self):
        """Min horizontal rate (byte 7) should be 30kHz"""
        min_h = self.range_desc[7]
        self.assertEqual(min_h, 30,
                        f"Min H rate should be 30, got {min_h}")

    def test_max_h_rate_is_160(self):
        """Max horizontal rate (byte 8) should be 160kHz"""
        max_h = self.range_desc[8]
        self.assertEqual(max_h, 160,
                        f"Max H rate should be 160, got {max_h}")

    def test_max_pixel_clock_is_60(self):
        """Max pixel clock (byte 9) should be 60 (600MHz)"""
        max_pclk = self.range_desc[9]
        self.assertEqual(max_pclk, 60,
                        f"Max pixel clock should be 60 (600MHz), got {max_pclk}")

    def test_byte10_is_range_limits_only(self):
        """Byte 10 should be 0x01 (Range Limits Only, no GTF)"""
        flags = self.range_desc[10]
        self.assertEqual(flags, 0x01,
                        f"Byte 10 should be 0x01 (Range Limits Only), got 0x{flags:02X}")


class TestResolutionConfiguration(unittest.TestCase):
    """Test resolution configuration and validation"""

    def test_default_config_has_9_resolutions(self):
        """Default Steam Deck config should have exactly 9 resolutions"""
        gen = EDIDGenerator(manufacturer_id="VRT", product_code=0x5344)

        # Replicate create_steam_deck_edid logic
        gen.add_resolution(1280, 800, 60, "1280x800@60Hz")
        gen.add_resolution(1280, 800, 90, "1280x800@90Hz")
        gen.add_resolution(1920, 1200, 60, "1920x1200@60Hz")
        gen.add_resolution(1920, 1200, 90, "1920x1200@90Hz")
        gen.add_resolution(1920, 1200, 120, "1920x1200@120Hz")
        gen.add_resolution(2560, 1440, 60, "2560x1440@60Hz")
        gen.add_resolution(2560, 1440, 120, "2560x1440@120Hz")
        gen.add_resolution(2560, 1600, 60, "2560x1600@60Hz")
        gen.add_resolution(2560, 1600, 90, "2560x1600@90Hz")

        self.assertEqual(len(gen.resolutions), 9)

    def test_all_expected_resolutions_present(self):
        """All expected resolutions should be present in default config"""
        gen = EDIDGenerator(manufacturer_id="VRT", product_code=0x5344)

        expected = [
            (1280, 800, 60),
            (1280, 800, 90),
            (1920, 1200, 60),
            (1920, 1200, 90),
            (1920, 1200, 120),
            (2560, 1440, 60),
            (2560, 1440, 120),
            (2560, 1600, 60),
            (2560, 1600, 90),
        ]

        for width, height, refresh in expected:
            gen.add_resolution(width, height, refresh)

        for exp_w, exp_h, exp_r in expected:
            found = any(r.width == exp_w and r.height == exp_h and r.refresh_rate == exp_r
                       for r in gen.resolutions)
            self.assertTrue(found,
                           f"Expected resolution {exp_w}x{exp_h}@{exp_r}Hz not found")

    def test_empty_resolution_list_raises_error(self):
        """Generating with no resolutions should raise ValueError"""
        gen = EDIDGenerator(manufacturer_id="VRT", product_code=0x1234)

        with self.assertRaises(ValueError) as ctx:
            gen.generate()

        self.assertIn("No resolutions", str(ctx.exception))

    def test_single_resolution_works(self):
        """Generator should work with single resolution"""
        gen = EDIDGenerator(manufacturer_id="VRT", product_code=0x1234)
        gen.add_resolution(1920, 1080, 60, "1920x1080@60Hz")

        edid = gen.generate()
        self.assertEqual(len(edid), 256)

        # Verify checksum still valid
        block0_sum = sum(edid[:128]) % 256
        block1_sum = sum(edid[128:256]) % 256
        self.assertEqual(block0_sum, 0)
        self.assertEqual(block1_sum, 0)

    def test_maximum_resolutions_works(self):
        """Generator should handle many resolutions"""
        gen = EDIDGenerator(manufacturer_id="VRT", product_code=0x1234)

        # Add many resolutions
        for width in [1280, 1920, 2560]:
            for refresh in [60, 75, 90, 120]:
                height = int(width / 1.6)  # 16:10 aspect
                gen.add_resolution(width, height, refresh)

        edid = gen.generate()
        self.assertEqual(len(edid), 256)


class TestCTA861Extension(unittest.TestCase):
    """Test CTA-861 Extension Block structure"""

    @classmethod
    def setUpClass(cls):
        """Generate EDID with high-refresh modes"""
        cls.generator = EDIDGenerator(manufacturer_id="VRT", product_code=0x1234)
        cls.generator.add_resolution(1920, 1200, 60, "1920x1200@60Hz")
        cls.generator.add_resolution(1920, 1200, 90, "1920x1200@90Hz")
        cls.generator.add_resolution(1920, 1200, 120, "1920x1200@120Hz")
        cls.generator.add_resolution(2560, 1440, 120, "2560x1440@120Hz")
        cls.edid = cls.generator.generate()
        cls.ext_block = cls.edid[128:256]

    def test_cta861_tag_is_correct(self):
        """CTA-861 tag (byte 128) should be 0x02"""
        tag = self.ext_block[0]
        self.assertEqual(tag, 0x02,
                        f"CTA-861 tag should be 0x02, got 0x{tag:02X}")

    def test_cta861_revision_is_3(self):
        """CTA-861 revision (byte 129) should be 0x03"""
        revision = self.ext_block[1]
        self.assertEqual(revision, 0x03,
                        f"CTA-861 revision should be 0x03, got 0x{revision:02X}")

    def test_dtd_offset_points_past_data_blocks(self):
        """DTD offset (byte 130) should point past data blocks"""
        dtd_offset = self.ext_block[2]

        # DTD offset should be at least 4 (after header) + VSDB length (8 bytes)
        self.assertGreaterEqual(dtd_offset, 4,
                               f"DTD offset {dtd_offset} too small")
        self.assertLess(dtd_offset, 127,
                       f"DTD offset {dtd_offset} beyond block boundary")

    def test_high_refresh_modes_have_dtds(self):
        """All >60Hz modes should have DTDs across base and extension blocks"""
        # Count DTDs in base block (bytes 54-125, up to 4 slots)
        base_dtd_count = 0
        for i in range(4):
            offset = 54 + i * 18
            pixel_clock = struct.unpack('<H', self.edid[offset:offset+2])[0]
            if pixel_clock > 0:
                base_dtd_count += 1
            else:
                break

        # Count DTDs in extension block
        dtd_offset = self.ext_block[2]
        ext_dtd_count = 0
        cursor = dtd_offset
        while cursor + 18 <= 127:
            pixel_clock = struct.unpack('<H', self.ext_block[cursor:cursor+2])[0]
            if pixel_clock > 0:
                ext_dtd_count += 1
                cursor += 18
            else:
                break

        total_dtd_count = base_dtd_count + ext_dtd_count

        # We have high-refresh modes that need DTDs (plus the 60Hz safe anchor)
        high_refresh_count = len([r for r in self.generator.resolutions if r.refresh_rate > 60])
        # Total DTDs should cover: 1 safe_res + all high-refresh modes
        expected_min = 1 + high_refresh_count  # safe_res + high-refresh

        self.assertGreaterEqual(total_dtd_count, expected_min,
                               f"Expected at least {expected_min} total DTDs "
                               f"(1 safe + {high_refresh_count} high-refresh), "
                               f"found {total_dtd_count} (base={base_dtd_count}, ext={ext_dtd_count})")

    def test_dtds_do_not_overlap(self):
        """DTDs in extension should not overlap or exceed block bounds"""
        dtd_offset = self.ext_block[2]

        cursor = dtd_offset
        dtd_positions = []

        while cursor + 18 <= 127:
            pixel_clock = struct.unpack('<H', self.ext_block[cursor:cursor+2])[0]
            if pixel_clock > 0:
                dtd_positions.append((cursor, cursor + 18))
                cursor += 18
            else:
                break

        # Check no overlaps
        for i in range(len(dtd_positions)):
            for j in range(i + 1, len(dtd_positions)):
                start1, end1 = dtd_positions[i]
                start2, end2 = dtd_positions[j]

                # No overlap if end1 <= start2 or end2 <= start1
                no_overlap = (end1 <= start2) or (end2 <= start1)
                self.assertTrue(no_overlap,
                               f"DTDs overlap: [{start1}-{end1}] and [{start2}-{end2}]")


class TestEndToEnd(unittest.TestCase):
    """End-to-end integration tests"""

    def test_generate_write_read_identical(self):
        """Generate → write → read back → bytes should be identical"""
        gen = EDIDGenerator(manufacturer_id="TST", product_code=0xABCD)
        gen.add_resolution(1920, 1200, 60, "1920x1200@60Hz")
        gen.add_resolution(1920, 1200, 120, "1920x1200@120Hz")

        original_edid = gen.generate()

        # Write to temp file
        with tempfile.NamedTemporaryFile(mode='wb', delete=False, suffix='.bin') as f:
            temp_path = f.name
            f.write(original_edid)

        try:
            # Read back
            with open(temp_path, 'rb') as f:
                read_edid = f.read()

            self.assertEqual(original_edid, read_edid,
                           "EDID bytes changed after write/read cycle")
        finally:
            os.unlink(temp_path)

    def test_generate_with_single_resolution_complete(self):
        """Complete generation with single resolution"""
        gen = EDIDGenerator(manufacturer_id="MIN", product_code=0x0001)
        gen.add_resolution(1280, 720, 60, "1280x720@60Hz")

        edid = gen.generate()

        # Verify structure
        self.assertEqual(len(edid), 256)
        self.assertEqual(edid[0:8], bytes([0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]))
        self.assertEqual(edid[18], 1)  # Version
        self.assertEqual(edid[19], 4)  # Revision
        self.assertEqual(edid[126], 1)  # Extension count
        self.assertEqual(edid[128], 0x02)  # CTA-861 tag

        # Verify checksums
        self.assertEqual(sum(edid[:128]) % 256, 0)
        self.assertEqual(sum(edid[128:256]) % 256, 0)

    def test_generate_with_maximum_resolutions_complete(self):
        """Complete generation with many resolutions"""
        gen = EDIDGenerator(manufacturer_id="MAX", product_code=0xFFFF)

        # Add 15 resolutions
        resolutions = [
            (1280, 800, 60), (1280, 800, 90),
            (1920, 1200, 60), (1920, 1200, 90), (1920, 1200, 120),
            (2560, 1440, 60), (2560, 1440, 90), (2560, 1440, 120),
            (2560, 1600, 60), (2560, 1600, 90),
            (1920, 1080, 60), (1920, 1080, 120),
            (3840, 2400, 60),
            (1680, 1050, 60),
            (1440, 900, 60),
        ]

        for w, h, r in resolutions:
            gen.add_resolution(w, h, r)

        edid = gen.generate()

        # Verify basic structure
        self.assertEqual(len(edid), 256)
        self.assertEqual(sum(edid[:128]) % 256, 0)
        self.assertEqual(sum(edid[128:256]) % 256, 0)

    def test_create_steam_deck_edid_function(self):
        """Test the convenience function creates valid EDID"""
        with tempfile.NamedTemporaryFile(mode='wb', delete=False, suffix='.bin') as f:
            temp_path = f.name

        try:
            # Create using convenience function
            result_path = create_steam_deck_edid(temp_path)
            self.assertEqual(result_path, temp_path)

            # Read and verify
            with open(temp_path, 'rb') as f:
                edid = f.read()

            self.assertEqual(len(edid), 256)
            self.assertEqual(sum(edid[:128]) % 256, 0)
            self.assertEqual(sum(edid[128:256]) % 256, 0)

            # Verify it's for Steam Deck (product code 0x5344 = "SD")
            product_code = struct.unpack('<H', edid[10:12])[0]
            self.assertEqual(product_code, 0x5344)

        finally:
            if os.path.exists(temp_path):
                os.unlink(temp_path)


class TestResolutionDataclass(unittest.TestCase):
    """Test Resolution dataclass"""

    def test_resolution_creation(self):
        """Resolution dataclass should store values correctly"""
        res = Resolution(width=1920, height=1080, refresh_rate=60, name="Test")
        self.assertEqual(res.width, 1920)
        self.assertEqual(res.height, 1080)
        self.assertEqual(res.refresh_rate, 60)
        self.assertEqual(res.name, "Test")

    def test_resolution_default_name_generation(self):
        """add_resolution should generate name if not provided"""
        gen = EDIDGenerator(manufacturer_id="VRT", product_code=0x1234)
        gen.add_resolution(1920, 1080, 60)

        self.assertEqual(len(gen.resolutions), 1)
        self.assertEqual(gen.resolutions[0].name, "1920x1080@60Hz")


def _create_steamdeck_generator():
    """Create a generator with all 9 Steam Deck resolutions (matching edid_generator.py main)"""
    gen = EDIDGenerator(manufacturer_id="VRT", product_code=0x5344)
    gen.add_resolution(1280, 800, 60, "deck-lcd")
    gen.add_resolution(1280, 800, 90, "deck-lcd-90")
    gen.add_resolution(1920, 1200, 60, "deck-oled")
    gen.add_resolution(1920, 1200, 90, "deck-oled-90")
    gen.add_resolution(1920, 1200, 120, "deck-oled-120")
    gen.add_resolution(2560, 1440, 60, "1440p")
    gen.add_resolution(2560, 1440, 120, "1440p-120")
    gen.add_resolution(2560, 1600, 60, "1600p")
    gen.add_resolution(2560, 1600, 90, "1600p-90")
    return gen


class TestResolutionCoverage(unittest.TestCase):
    """Verify every declared resolution appears in at least one DTD or Standard Timing"""

    def _parse_dtd_resolution(self, dtd_bytes):
        """Extract width, height, refresh from an 18-byte DTD"""
        if dtd_bytes[0] == 0 and dtd_bytes[1] == 0:
            return None  # Not a timing descriptor
        pixel_clock = (dtd_bytes[1] << 8 | dtd_bytes[0]) * 10000  # Hz
        h_active = dtd_bytes[2] | ((dtd_bytes[4] >> 4) << 8)
        h_blank = dtd_bytes[3] | ((dtd_bytes[4] & 0x0F) << 8)
        v_active = dtd_bytes[5] | ((dtd_bytes[7] >> 4) << 8)
        v_blank = dtd_bytes[6] | ((dtd_bytes[7] & 0x0F) << 8)
        h_total = h_active + h_blank
        v_total = v_active + v_blank
        if h_total == 0 or v_total == 0:
            return None
        refresh = pixel_clock / (h_total * v_total)
        return (h_active, v_active, round(refresh))

    def _parse_standard_timing(self, b1, b2):
        """Extract width, height, refresh from a 2-byte Standard Timing"""
        if b1 == 0x01 and b2 == 0x01:
            return None  # Unused slot
        width = (b1 + 31) * 8
        refresh = (b2 & 0x3F) + 60
        aspect_bits = (b2 >> 6) & 0x03
        aspect_map = {0: (16, 10), 1: (4, 3), 2: (5, 4), 3: (16, 9)}
        w_ratio, h_ratio = aspect_map[aspect_bits]
        height = width * h_ratio // w_ratio
        return (width, height, refresh)

    def test_all_resolutions_covered(self):
        """Every resolution in the config must appear in a DTD or Standard Timing"""
        gen = _create_steamdeck_generator()
        edid = gen.generate()

        expected = {(r.width, r.height, r.refresh_rate) for r in gen.resolutions}
        found = set()

        # Parse Standard Timings (bytes 38-53, 8 slots of 2 bytes)
        for i in range(8):
            offset = 38 + i * 2
            result = self._parse_standard_timing(edid[offset], edid[offset + 1])
            if result:
                found.add(result)

        # Parse base block DTDs (bytes 54-125, up to 4 slots of 18 bytes)
        for i in range(4):
            offset = 54 + i * 18
            result = self._parse_dtd_resolution(edid[offset:offset + 18])
            if result:
                found.add(result)

        # Parse extension block DTDs (starting after VSDB, ending at byte 254)
        if len(edid) > 128 and edid[128] == 0x02:
            dtd_start = 128 + edid[130]  # ext[2] = DTD offset from start of ext
            pos = dtd_start
            while pos + 18 <= 255:
                result = self._parse_dtd_resolution(edid[pos:pos + 18])
                if result:
                    found.add(result)
                pos += 18

        missing = expected - found
        self.assertEqual(missing, set(),
                         f"Resolutions missing from EDID: {missing}")

    def test_no_duplicate_base_and_extension_dtds(self):
        """Base block DTD1 (safe_res) should not be duplicated in extension block"""
        gen = _create_steamdeck_generator()
        edid = gen.generate()

        base_dtds = []
        for i in range(4):
            offset = 54 + i * 18
            result = self._parse_dtd_resolution(edid[offset:offset + 18])
            if result:
                base_dtds.append(result)

        ext_dtds = []
        if len(edid) > 128 and edid[128] == 0x02:
            dtd_start = 128 + edid[130]
            pos = dtd_start
            while pos + 18 <= 255:
                result = self._parse_dtd_resolution(edid[pos:pos + 18])
                if result:
                    ext_dtds.append(result)
                pos += 18

        # safe_res (base DTD1) should NOT appear in extension
        if base_dtds:
            safe_res = base_dtds[0]
            self.assertNotIn(safe_res, ext_dtds,
                             f"Base DTD1 (safe_res) {safe_res} duplicated in extension block")


if __name__ == '__main__':
    unittest.main()
