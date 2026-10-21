# Flash prebuilt firmware (quickstart)

This guide takes the release archive to a running Channel Sounding pair on two
nRF54LM20-DKs — no build step. To build and flash from source instead, see
[docs/build-from-source.md](build-from-source.md); for the board wiring,
presets, and UART mapping, see
[docs/hardware.md](hardware.md#supported-boards).

## What ships

Each release publishes one archive, `cs-ranging-firmware.zip`, containing one
`.hex` per role and preset:

| Firmware | Role | Mode |
|----------|------|------|
| `initiator_nrf54lm20dk_cent_a1_1.hex` | Initiator | RAS |
| `reflector_nrf54lm20dk_peri_a1_1.hex` | Reflector | RAS |
| `initiator_nrf54lm20dk_cent_a1_1_ipt.hex` | Initiator | IPT |
| `reflector_nrf54lm20dk_peri_a1_1_ipt.hex` | Reflector | IPT |

## 1. Download the archive

Download `cs-ranging-firmware.zip` from the
[latest release](https://github.com/Metirionic/mars-cs-nrf54lm/releases) and
unpack it. The `.hex` files are self-contained — no toolchain or build is
needed, only a way to program the DK.

## 2. Flash two DKs

Channel Sounding is a two-device protocol. Flash **one DK as the initiator and
a second DK as the reflector** — a single flashed board yields no ranging data.
Flash a **matched** pair: both boards in RAS **or** both in IPT. The two modes
use different BLE discovery and do not pair with each other.

For a RAS pair, program:

| DK | Firmware |
|----|----------|
| DK A (initiator) | `initiator_nrf54lm20dk_cent_a1_1.hex` |
| DK B (reflector) | `reflector_nrf54lm20dk_peri_a1_1.hex` |

For an IPT pair, use `initiator_nrf54lm20dk_cent_a1_1_ipt.hex` and
`reflector_nrf54lm20dk_peri_a1_1_ipt.hex` instead.

Program each DK through its on-board J-Link, for example with the nRF Connect
Programmer app or Nordic's `nrfutil device program --firmware <file>.hex`.
Flash one DK at a time, or pass the probe's serial number when both are
connected.

## 3. Identify the two virtual COM ports

Each DK exposes **two** J-Link virtual COM ports:

- **VCOM0 (`uart30`)** — the COBS ranging stream, **1,000,000 baud**, 8N1, no
  flow control. Only the initiator emits a stream.
- **VCOM1 (`uart20`)** — the console, **115200 baud**.

On Linux the ports appear as `/dev/ttyACM*`, on macOS as `/dev/cu.usbmodem*`,
and on Windows as `COMx`. Open the console port at 115200 first: readable log
text identifies it as VCOM1, and the other port on the same probe is VCOM0.

With both DKs connected you will see four ports (two per DK). Identify the
initiator's probe through its VCOM1 console output before selecting its VCOM0
port.

## 4. Open the COBS port at 1,000,000 baud

Configure the initiator's VCOM0 port for the DK rate and capture the stream.
Linux example:

```bash
stty -F /dev/ttyACM0 1000000 cs8 -cstopb -parenb -crtscts raw -echo
cat /dev/ttyACM0 > ranging.bin
```

On other hosts, open VCOM0 with any serial terminal set to 1,000,000 baud,
8N1, no flow control.

The output is COBS-encoded binary in the
[mars-bluetooth-hci](https://github.com/Metirionic/mars-bluetooth-hci) format.
Decode it with that library; the wire format is not reproduced here. The
console on VCOM1 stays readable at 115200 and shows boot and connection
progress.

## 5. Pair matched modes

Power both DKs and keep them close. The initiator scans for its peer and starts
Channel Sounding; the first completed procedure produces the first COBS event
on its VCOM0 port.

- **RAS** — initiator `nrf54lm20dk_cent_a1_1` with reflector
  `nrf54lm20dk_peri_a1_1`. The initiator pulls the reflector's step data over
  the Ranging Service.
- **IPT** — initiator `nrf54lm20dk_cent_a1_1_ipt` with reflector
  `nrf54lm20dk_peri_a1_1_ipt`. The reflector's phase contribution is embedded
  in the local tones; no GATT service is used.

See [docs/architecture.md](architecture.md#ranging-data-flow) for the full
RAS-vs-IPT contrast.
