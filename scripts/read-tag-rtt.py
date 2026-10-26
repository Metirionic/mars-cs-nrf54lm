#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read the nRF54L15 TAG's SEGGER RTT console ring through the DEBUG OUT probe.

The TAG has no console UART and no USB. Its console is SEGGER RTT buffer 0,
reached over the L15-DK's onboard J-Link. The interop bench image applies
bench/nrf54l15tag_rtt_bench.conf (see that file for the buffer/mode rationale),
so a read after a run returns the most recent ring-full of console output.

This tool resolves _SEGGER_RTT from the image ELF, reads the control block and
the up-buffer with `nrfutil device read --direct`, and prints the valid ring
window. It is a post-run read: no RTT client drains the ring while the run is
in progress.

Usage:
    scripts/read-tag-rtt.py --serial 001057759725 \
        --elf ../mars-cs-nrf54l/reflector/build_bench_tag_rtt/reflector/zephyr/zephyr.elf

    # Write the console text to a file:
    scripts/read-tag-rtt.py ... --output /tmp/tag-rtt.txt

    # After `west flash --no-reset`, before the first boot: clobber the
    # control-block ID so the image re-initialises the ring instead of
    # reusing a stale one from the previous session.
    scripts/read-tag-rtt.py ... --invalidate-only

    # Read first, then clobber the ID for the next boot:
    scripts/read-tag-rtt.py ... --invalidate

Exit status: 0 on success, 1 on a read/parse failure, 2 on usage.
"""

import argparse
import os
import re
import struct
import subprocess
import sys
import tempfile

RTT_ID = b"SEGGER RTT"
CB_MIN_SIZE = 24                      # acID[16] + MaxNumUpBuffers + MaxNumDownBuffers
BUFFER_UP_SIZE = 24                   # sName, pBuffer, SizeOfBuffer, WrOff, RdOff, Flags
MAX_BUFFERS = 8                       # read limit; the block declares the real count


def nm_symbol(elf_path, symbol):
    """Return the address of a symbol from an ELF via arm-none-eabi-nm."""
    for tool in ("arm-none-eabi-nm", "nm"):
        try:
            out = subprocess.run(
                [tool, elf_path], check=True, capture_output=True, text=True
            ).stdout
            break
        except FileNotFoundError:
            continue
        except subprocess.CalledProcessError as exc:
            sys.exit(f"error: {tool} failed on {elf_path}: {exc.stderr.strip()}")
    else:
        sys.exit("error: no nm tool found (tried arm-none-eabi-nm and nm)")

    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[2] == symbol:
            return int(parts[0], 16)
    sys.exit(f"error: symbol {symbol} not found in {elf_path}")


def _parse_ihex(path):
    """Parse an Intel HEX file into a sparse {address: byte} dict."""
    mem = {}
    base = 0
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line.startswith(":"):
                continue
            raw = bytes.fromhex(line[1:])
            count, addr, rectype = struct.unpack(">BHB", raw[:4])
            data = raw[4:4 + count]
            checksum = raw[4 + count]
            if (sum(raw[:-1]) + checksum) & 0xFF:
                sys.exit(f"error: bad Intel HEX checksum in {path}: {line}")
            if rectype == 0x00:
                for i, byte in enumerate(data):
                    mem[base + addr + i] = byte
            elif rectype == 0x01:
                break
            elif rectype == 0x04:
                base = struct.unpack(">H", data)[0] << 16
            elif rectype in (0x03, 0x05):
                continue                      # start-address metadata, no data
            else:
                sys.exit(f"error: unsupported Intel HEX record 0x{rectype:02x}")
    return mem


def read_memory(serial, address, length):
    """Read target RAM through nrfutil and return `length` bytes."""
    fd, hex_path = tempfile.mkstemp(prefix="rtt-read-", suffix=".hex")
    os.close(fd)
    cmd = [
        "nrfutil", "device", "read",
        "--serial-number", serial,
        "--address", hex(address),
        "--bytes", str(length),
        "--to-file", hex_path,
        "--direct",
    ]
    try:
        subprocess.run(cmd, check=True, capture_output=True, text=True)
        mem = _parse_ihex(hex_path)
    except subprocess.CalledProcessError as exc:
        sys.exit(f"error: nrfutil read at 0x{address:08x} failed: "
                 f"{exc.stderr.strip() or exc.stdout.strip()}")
    finally:
        try:
            os.unlink(hex_path)
        except FileNotFoundError:
            pass

    data = bytearray(length)
    for offset, byte in mem.items():
        if address <= offset < address + length:
            data[offset - address] = byte
    return bytes(data)


def read_control_block(serial, cb_address):
    """Read and parse the SEGGER RTT control block."""
    raw = read_memory(serial, cb_address, 0x100)
    ac_id, max_up, max_down = struct.unpack_from("<16sii", raw, 0)
    if ac_id[:10] != RTT_ID:
        sys.exit(
            f"error: no RTT control block at 0x{cb_address:08x} "
            f"(ID={ac_id[:16]!r}); the image may not have booted, or a "
            "different ELF is loaded (check the FICR device ID first)"
        )
    if not 0 < max_up <= MAX_BUFFERS:
        sys.exit(f"error: implausible MaxNumUpBuffers={max_up} at 0x{cb_address:08x}")

    buffers = []
    offset = CB_MIN_SIZE
    for _ in range(max_up):
        _, buf_ptr, size, wr_off, rd_off, flags = struct.unpack_from(
            "<IIIIII", raw, offset
        )
        buffers.append(
            {
                "buffer": buf_ptr,
                "size": size,
                "wr_off": wr_off,
                "rd_off": rd_off,
                "flags": flags,
            }
        )
        offset += BUFFER_UP_SIZE
    return ac_id, max_up, max_down, buffers


def ring_window(buf):
    """Return the valid [RdOff, WrOff) window as (start, end, wrapped)."""
    size = buf["size"]
    wr_off = buf["wr_off"]
    rd_off = buf["rd_off"]
    if size == 0 or wr_off >= size or rd_off >= size:
        sys.exit(
            f"error: invalid RTT ring (size={size}, WrOff={wr_off}, "
            f"RdOff={rd_off}); stale control block?"
        )
    if wr_off == rd_off:
        return 0, 0, False
    if wr_off > rd_off:
        return rd_off, wr_off, False
    return rd_off, wr_off, True


def invalidate_control_block(serial, cb_address):
    """Clobber acID[0] so the next boot re-initialises the RTT ring."""
    cmd = [
        "nrfutil", "device", "write",
        "--serial-number", serial,
        "--address", hex(cb_address),
        "--value", "0xAA",
        "--direct",
    ]
    subprocess.run(cmd, check=True, capture_output=True, text=True)
    print(f"invalidated RTT control block at 0x{cb_address:08x} "
          "(next boot re-initialises the ring)", file=sys.stderr)


ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--serial", required=True,
                        help="J-Link serial of the L15-DK whose DEBUG OUT drives the TAG")
    parser.add_argument("--elf", required=True,
                        help="ELF of the image running on the TAG (resolves _SEGGER_RTT)")
    parser.add_argument("--output", help="write the ring text here instead of stdout")
    parser.add_argument("--raw", action="store_true",
                        help="keep ANSI escapes (default: strip them)")
    invalidate = parser.add_mutually_exclusive_group()
    invalidate.add_argument("--invalidate", action="store_true",
                            help="clobber the control-block ID after reading")
    invalidate.add_argument("--invalidate-only", action="store_true",
                            help="clobber the control-block ID without reading "
                                 "(use after `west flash --no-reset`)")
    args = parser.parse_args()

    cb_address = nm_symbol(args.elf, "_SEGGER_RTT")
    if args.invalidate_only:
        invalidate_control_block(args.serial, cb_address)
        return 0

    ac_id, max_up, max_down, buffers = read_control_block(args.serial, cb_address)
    print(
        f"RTT control block at 0x{cb_address:08x}: ID={ac_id[:10].decode()!r}, "
        f"up_buffers={max_up}, down_buffers={max_down}",
        file=sys.stderr,
    )

    buf = buffers[0]
    start, end, wrapped = ring_window(buf)
    size = buf["size"]
    print(
        f"buffer 0: 0x{buf['buffer']:08x}, {size} bytes, "
        f"WrOff={buf['wr_off']}, RdOff={buf['rd_off']}, "
        f"flags=0x{buf['flags']:x}, "
        f"{'wrapped' if wrapped else 'linear'} window",
        file=sys.stderr,
    )

    if start == end:
        text = ""
    else:
        chunk = read_memory(args.serial, buf["buffer"], size)
        data = (chunk[start:] + chunk[:end]) if wrapped else chunk[start:end]
        text = data.decode("utf-8", errors="replace")

    if not args.raw:
        text = ANSI_RE.sub("", text)

    if args.output:
        with open(args.output, "w", encoding="utf-8") as fh:
            fh.write(text)
        print(f"wrote {len(text)} bytes to {args.output}", file=sys.stderr)
    else:
        sys.stdout.write(text)
        if text and not text.endswith("\n"):
            sys.stdout.write("\n")

    if args.invalidate:
        invalidate_control_block(args.serial, cb_address)
    return 0


if __name__ == "__main__":
    sys.exit(main())
