# Flash prebuilt firmware (quickstart)

This guide takes the release archive to a running Channel Sounding pair on two
nRF54LM20-DKs — no build step. Each release ships two runtime transports:
**native USB (recommended)** and **J-Link VCOM (compatibility)**. Both carry
the same COBS wire format; only the ports differ. To build and flash from
source instead, see [docs/build-from-source.md](build-from-source.md); for the
board wiring, presets, and transport details, see
[docs/hardware.md](hardware.md#supported-boards).

## What ships

Each release publishes one archive, `cs-ranging-firmware.zip`, containing one
`.hex` per role, ranging mode, and transport — eight images:

| Firmware | Role | Mode | Transport |
|----------|------|------|-----------|
| `initiator_nrf54lm20dk_cent_a1_1.hex` | Initiator | RAS | J-Link VCOM |
| `reflector_nrf54lm20dk_peri_a1_1.hex` | Reflector | RAS | J-Link VCOM |
| `initiator_nrf54lm20dk_cent_a1_1_ipt.hex` | Initiator | IPT | J-Link VCOM |
| `reflector_nrf54lm20dk_peri_a1_1_ipt.hex` | Reflector | IPT | J-Link VCOM |
| `initiator_nrf54lm20dk_usb_cent_a1_1.hex` | Initiator | RAS | Native USB |
| `reflector_nrf54lm20dk_usb_peri_a1_1.hex` | Reflector | RAS | Native USB |
| `initiator_nrf54lm20dk_usb_cent_a1_1_ipt.hex` | Initiator | IPT | Native USB |
| `reflector_nrf54lm20dk_usb_peri_a1_1_ipt.hex` | Reflector | IPT | Native USB |

Each image is the build of the preset with the same name (see
[docs/hardware.md](hardware.md#presets)). The archive contains no debug builds:
the non-release initiator debug variant (COBS on native USB, logs on the J-Link
VCOM) is documented in
[docs/build-from-source.md](build-from-source.md#non-release-usb-debug-console-j-link-vcom).

## 1. Download the archive

Download `cs-ranging-firmware.zip` from the
[latest release](https://github.com/Metirionic/mars-cs-nrf54lm/releases) and
unpack it. The `.hex` files are self-contained — no toolchain or build is
needed, only a way to program the DK.

## 2. Flash two DKs

Channel Sounding is a two-device protocol. Flash **one DK as the initiator and
a second DK as the reflector** — a single flashed board yields no ranging data.
Flash a **matched** pair: both boards in the same ranging mode (RAS **or**
IPT). The two modes use different BLE discovery and do not pair with each
other. Flash both boards on the **same transport** too: the transport changes
only how each board reaches the host, so a mixed pair still forms a BLE link,
but you would then need both a native USB and a J-Link connection to observe
both boards.

For a native USB RAS pair:

| DK | Firmware |
|----|----------|
| DK A (initiator) | `initiator_nrf54lm20dk_usb_cent_a1_1.hex` |
| DK B (reflector) | `reflector_nrf54lm20dk_usb_peri_a1_1.hex` |

For a native USB IPT pair, use
`initiator_nrf54lm20dk_usb_cent_a1_1_ipt.hex` and
`reflector_nrf54lm20dk_usb_peri_a1_1_ipt.hex` instead. For a VCOM pair, use
the non-USB images: `initiator_nrf54lm20dk_cent_a1_1.hex` with
`reflector_nrf54lm20dk_peri_a1_1.hex` (RAS), or the `_ipt` images (IPT).

Program each DK through its on-board J-Link, for example with the nRF Connect
Programmer app or Nordic's `nrfutil device program --firmware <file>.hex`.
Flash one DK at a time, or pass the probe's serial number when both are
connected.

After programming a **native USB** image, the on-board debugger is no longer
needed at runtime: disconnect the J-Link cable and run the DK from its native
USB port. One native USB cable per DK carries the ranging stream, the console,
and power. The J-Link/ODB cable remains the programming and debugging path
only. A **VCOM** image keeps the J-Link cable connected at runtime, because
both VCOMs run through it.

## 3. Identify the ports

The ports depend on the transport baked into the image you flashed.

### Native USB (recommended)

The initiator enumerates as a composite CDC ACM device with two functions in
interface order — **data** first, **console** second. The reflector exposes a
single CDC ACM console function. CDC ACM is driver-free on Linux, Windows, and
macOS: the host sees ordinary serial ports, so the COBS tooling and wire format
are unchanged. The data port streams as soon as the host configures the device;
there is no DTR handshake or control sequence.

| Function | Initiator | Reflector |
|----------|-----------|-----------|
| COBS data | interface `if00`, label `CS Data` | — (no data function) |
| Console | interface `if02`, label `Console` | interface `if00`, label `Console` |

- **Linux** — use `/dev/serial/by-id/`; those names are stable across replug
  and independent of `ttyACM` numbering:
  ```text
  /dev/serial/by-id/usb-Metirionic_Mars_CS_Initiator_<serial>-if00   # initiator data
  /dev/serial/by-id/usb-Metirionic_Mars_CS_Initiator_<serial>-if02   # initiator console
  /dev/serial/by-id/usb-Metirionic_Mars_CS_Reflector_<serial>-if00   # reflector console
  ```
  `<serial>` is the SoC-derived USB serial, which differs per board; list the
  entries with `ls -l /dev/serial/by-id/`. The bench harness resolves the same
  names from that serial (`scripts/two-dk-bench.sh --transport usb ...`).
- **Windows 10+** — no vendor driver is required. The initiator appears as two
  `USB Serial Device (COMx)` entries under **Device Manager → Ports (COM &
  LPT)**, and the reflector as one. Windows does not put the function label in
  the port name: open each candidate at 115200 and keep the one that prints
  readable log text as the console; the other initiator port is the data port.
  The product strings (`Mars CS Initiator` / `Mars CS Reflector`) appear in the
  device properties.
- **macOS** — no vendor driver is required. The initiator exposes two
  `/dev/cu.usbmodem*` nodes and the reflector one. As on Windows, the node name
  does not identify the function: open each candidate at 115200 and use the one
  that prints readable log text as the console; the other initiator node is the
  data port. `system_profiler SPUSBDataType` shows the product string and
  serial number.

Two USB boards expose **three** serial ports (initiator data, initiator
console, reflector console), not four. The link is expected to negotiate
**480 Mbit/s** high speed; a full-speed-only host or hub falls back to
12 Mbit/s, which works but is parity-only and is not the headroom configuration
(see [docs/hardware.md](hardware.md#native-usb-transport)). On Linux,
`lsusb -t` shows `480M` for the device when high speed is negotiated. CDC ACM
ignores the configured baud rate; open the data port at **1,000,000 baud** to
match the VCOM workflow.

Both USB ports are best-effort before enumeration: output produced before the
host configures the device is dropped and counted, not buffered. Open the data
port before or at boot to capture the stream from the first procedure, and
expect the console boot banner to be missing if you attach after boot.

### J-Link VCOM (compatibility)

Each DK exposes **two** J-Link virtual COM ports:

- **VCOM0 (`uart30`)** — the COBS ranging stream, **1,000,000 baud**, 8N1, no
  flow control. Only the initiator emits a stream.
- **VCOM1 (`uart20`)** — the console, **115200 baud**.

On Linux the ports appear as `/dev/ttyACM*` (with stable
`usb-SEGGER_J-Link_<serial>-if00` / `-if02` names under `/dev/serial/by-id/`),
on macOS as `/dev/cu.usbmodem*`, and on Windows as `COMx`. Open the console
port at 115200 first: readable log text identifies it as VCOM1, and the other
port on the same probe is VCOM0.

With both DKs connected you will see four ports (two per DK). Identify the
initiator's probe through its VCOM1 console output before selecting its VCOM0
port.

## 4. Open the COBS port

The data port is the initiator's native USB data function or, for VCOM images,
VCOM0. Configure it for 8N1, no flow control, at 1,000,000 baud and capture the
stream. Native USB on Linux:

```bash
# Replace with the initiator's SoC-derived USB serial (see ls /dev/serial/by-id/)
SERIAL=0123456789ABCDEF
DATA="/dev/serial/by-id/usb-Metirionic_Mars_CS_Initiator_${SERIAL}-if00"
stty -F "$DATA" 1000000 cs8 -cstopb -parenb -crtscts raw -echo
cat "$DATA" > ranging.bin
```

VCOM on Linux:

```bash
stty -F /dev/ttyACM0 1000000 cs8 -cstopb -parenb -crtscts raw -echo
cat /dev/ttyACM0 > ranging.bin
```

On other hosts, open the data port with any serial terminal set to 8N1 and no
flow control. The 1,000,000-baud setting is required on VCOM and ignored by CDC
ACM; either way the bytes on the wire are identical.

The output is COBS-encoded binary in the
[mars-bluetooth-hci](https://github.com/Metirionic/mars-bluetooth-hci) format.
Decode it with that library; the wire format is not reproduced here. The
console — the native USB console function or VCOM1 — stays readable at 115200
and shows boot and connection progress.

## 5. Pair matched modes

Power both DKs and keep them close. The initiator scans for its peer and starts
Channel Sounding; the first completed procedure produces the first COBS event
on its data port.

- **RAS** — initiator `nrf54lm20dk_usb_cent_a1_1` with reflector
  `nrf54lm20dk_usb_peri_a1_1` on native USB, or
  `nrf54lm20dk_cent_a1_1` with `nrf54lm20dk_peri_a1_1` on VCOM. The initiator
  pulls the reflector's step data over the Ranging Service.
- **IPT** — initiator `nrf54lm20dk_usb_cent_a1_1_ipt` with reflector
  `nrf54lm20dk_usb_peri_a1_1_ipt` on native USB, or
  `nrf54lm20dk_cent_a1_1_ipt` with `nrf54lm20dk_peri_a1_1_ipt` on VCOM. The
  reflector's phase contribution is embedded in the local tones; no GATT
  service is used.

See [docs/architecture.md](architecture.md#ranging-data-flow) for the full
RAS-vs-IPT contrast.

## 6. First-run check

Before a long capture, confirm the transport end to end:

1. Reset or power-cycle the initiator with the data port already open. The
   console prints the boot lines and then
   `USB enumerated at high (480 Mbit/s) speed` on the USB image. If it says
   `full (12 Mbit/s)`, the host or hub fell back to the parity-only mode — try
   another cable and a direct host port.
2. Confirm the reflector console is live. It logs at boot and on connect, so
   silence after boot is normal until the initiator finds it.
3. Confirm the data port emits bytes once the peer connects, and that your
   `mars-bluetooth-hci`-based decoder accepts the stream. No bytes before the
   peer connects is expected.

Windows and macOS use the same three checks; only the port-discovery step in
[section 3](#3-identify-the-ports) differs.
