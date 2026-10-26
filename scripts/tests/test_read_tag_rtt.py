#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Hardware-free unit tests for scripts/read-tag-rtt.py."""

import importlib.util
import pathlib
import struct
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "read-tag-rtt.py"
_SPEC = importlib.util.spec_from_file_location("read_tag_rtt", SCRIPT)
rtt = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(rtt)


def ihex_record(rectype, addr, data):
    """Build one Intel HEX record, including its checksum."""
    payload = bytes([len(data)]) + struct.pack(">H", addr) + bytes([rectype]) + data
    checksum = (-sum(payload)) & 0xFF
    return ":" + (payload + bytes([checksum])).hex().upper()


def write_hex(lines):
    fd = tempfile.NamedTemporaryFile("w", suffix=".hex", delete=False)
    try:
        fd.write("\n".join(lines) + "\n")
        return pathlib.Path(fd.name)
    finally:
        fd.close()


class ParseIhexTest(unittest.TestCase):
    def test_data_and_extended_linear_address(self):
        path = write_hex([
            ihex_record(0x00, 0x0000, b"\xde\xad\xbe\xef"),
            ihex_record(0x04, 0x0000, struct.pack(">H", 0x2000)),
            ihex_record(0x00, 0x0010, b"\x01\x02"),
            ihex_record(0x01, 0x0000, b""),
        ])
        try:
            mem = rtt._parse_ihex(path)
        finally:
            path.unlink()
        self.assertEqual([mem[i] for i in range(4)], [0xDE, 0xAD, 0xBE, 0xEF])
        self.assertEqual(mem[0x20000010], 0x01)
        self.assertEqual(mem[0x20000011], 0x02)

    def test_bad_checksum_is_fatal(self):
        line = ihex_record(0x00, 0x0000, b"\x01")
        bad = line[:-2] + ("00" if line[-2:] != "00" else "01")
        path = write_hex([bad])
        try:
            with self.assertRaises(SystemExit):
                rtt._parse_ihex(path)
        finally:
            path.unlink()

    def test_start_address_records_are_ignored(self):
        path = write_hex([
            ihex_record(0x05, 0x0000, struct.pack(">I", 0x20000000)),
            ihex_record(0x00, 0x0000, b"\x42"),
            ihex_record(0x01, 0x0000, b""),
        ])
        try:
            mem = rtt._parse_ihex(path)
        finally:
            path.unlink()
        self.assertEqual(mem, {0x0000: 0x42})


class RingWindowTest(unittest.TestCase):
    def test_linear(self):
        self.assertEqual(
            rtt.ring_window({"size": 16, "wr_off": 10, "rd_off": 2}),
            (2, 10, False),
        )

    def test_wrapped(self):
        self.assertEqual(
            rtt.ring_window({"size": 16, "wr_off": 3, "rd_off": 12}),
            (12, 3, True),
        )

    def test_empty(self):
        self.assertEqual(
            rtt.ring_window({"size": 16, "wr_off": 5, "rd_off": 5}),
            (0, 0, False),
        )

    def test_out_of_range_is_fatal(self):
        with self.assertRaises(SystemExit):
            rtt.ring_window({"size": 16, "wr_off": 17, "rd_off": 0})
        with self.assertRaises(SystemExit):
            rtt.ring_window({"size": 0, "wr_off": 0, "rd_off": 0})


if __name__ == "__main__":
    unittest.main()
