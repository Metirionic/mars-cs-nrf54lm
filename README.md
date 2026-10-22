# mars-cs-nrf54lm

Nordic nRF54LM20 Channel Sounding firmware samples. Runs on top of
[nRF Connect SDK v3.4.0](https://developer.nordicsemi.com/nRF_Connect_SDK/)
and uses [mars-bluetooth-hci](https://github.com/Metirionic/mars-bluetooth-hci)
for COBS serialization of CS measurement data.

## Get started

Channel Sounding needs a pair of boards — one initiator, one reflector. Pick a path:

- **Flash prebuilt firmware** — no build step. Download
  `cs-ranging-firmware.zip` from the
  [latest release](https://github.com/Metirionic/mars-cs-nrf54lm/releases),
  flash two nRF54LM20-DKs, and open the COBS data port. Native USB is the
  recommended transport; J-Link VCOM is retained as the compatibility path.
  See [docs/flash-quickstart.md](docs/flash-quickstart.md).
- **Build from source** — native toolchain + build. See
  [docs/build-from-source.md](docs/build-from-source.md).

## Supported boards

The nRF54LM20-DK is supported, built as `nrf54lm20dk/nrf54lm20a/cpuapp`, with
two runtime transports:

- **Native USB (recommended)** — the initiator is a two-function composite
  CDC ACM device (data on `if00`, console on `if02`) and the reflector exposes
  a single CDC ACM console. One cable per board carries data, console, and
  power; the onboard debugger is needed only for SWD programming. See
  [docs/hardware.md](docs/hardware.md#native-usb-transport).
- **J-Link VCOM (compatibility)** — the COBS ranging stream on VCOM0
  (`uart30`, 1,000,000 baud) and the console on VCOM1 (`uart20`, 115200 baud).

See [docs/hardware.md](docs/hardware.md#supported-boards) for the DK wiring
notes and the board-support contract.

## Firmware variants

Each build targets a BLE role and a ranging mode.

| Target | Description |
|--------|-------------|
| `initiator` | BLE Central that connects to a CS reflector, collects ranging data, and outputs COBS-encoded binary over the build-selected transport (native USB or VCOM UART) |
| `reflector` | BLE Peripheral that advertises and responds to CS procedures |

The ranging mode is a build-time choice, set by `CONFIG_MARS_CS_INLINE_PCT`:

- **RAS** (Ranging Service) — the initiator pulls the reflector's step data over
  a BLE GATT service and combines it with its own.
- **IPT** (Inline PCT) — the reflector's phase contribution is embedded in the
  local tones, so the initiator uses its own step data only (no GATT service).

Both modes emit the same COBS-encoded ranging stream over the selected
transport. See [docs/architecture.md](docs/architecture.md#ranging-data-flow)
for the full RAS-vs-IPT contrast and per-mode data flow, and
[docs/architecture.md](docs/architecture.md#native-usb-bring-up-and-deferred-logging)
for the native USB bring-up and console logging.

## Presets

Builds are driven by CMake presets in `initiator/CMakePresets.json` and
`reflector/CMakePresets.json`. The nRF54LM20-DK defines eight:

| Preset | Role | Mode | Transport |
|--------|------|------|-----------|
| `nrf54lm20dk_cent_a1_1` | Initiator | RAS | J-Link VCOM |
| `nrf54lm20dk_peri_a1_1` | Reflector | RAS | J-Link VCOM |
| `nrf54lm20dk_cent_a1_1_ipt` | Initiator | IPT | J-Link VCOM |
| `nrf54lm20dk_peri_a1_1_ipt` | Reflector | IPT | J-Link VCOM |
| `nrf54lm20dk_usb_cent_a1_1` | Initiator | RAS | Native USB |
| `nrf54lm20dk_usb_peri_a1_1` | Reflector | RAS | Native USB |
| `nrf54lm20dk_usb_cent_a1_1_ipt` | Initiator | IPT | Native USB |
| `nrf54lm20dk_usb_peri_a1_1_ipt` | Reflector | IPT | Native USB |

All eight are built by CI and shipped in `cs-ranging-firmware.zip` — four
VCOM and four native USB images. Preset names follow
`<board>_<cent|peri>_a<antennas>_<paths>`, with an `_ipt` suffix for IPT and a
`usb` transport token after the board name for native USB builds: `cent`/`peri`
is the BLE role, `a<n>` is the antenna count, and the trailing number is the
antenna-path count. See
[docs/hardware.md](docs/hardware.md#presets) for the full preset table and
[boards/README.md](boards/README.md) for the board-support contract.

A non-release debug variant keeps the COBS stream on native USB but puts the
log console on the J-Link VCOM for pre-enumeration and hard-fault visibility.
It is not a preset and is never shipped; see
[docs/build-from-source.md](docs/build-from-source.md#non-release-usb-debug-console-j-link-vcom).

## Hardware reference

For the board-support contract, DK wiring notes, antenna/path fragment
mapping, and the preset table, see [docs/hardware.md](docs/hardware.md).

## Architecture

For the firmware module map, ranging-data flow, and initiator main loop, see
[docs/architecture.md](docs/architecture.md).

## Contributing

For the commit convention, pre-commit hooks, and pull-request flow, see
[docs/contributing.md](docs/contributing.md).

## License

MIT
