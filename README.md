# mars-cs-nrf54lm

Nordic nRF54LM20 Channel Sounding firmware samples. Runs on top of
[nRF Connect SDK v3.4.0](https://developer.nordicsemi.com/nRF_Connect_SDK/)
and uses [mars-bluetooth-hci](https://github.com/Metirionic/mars-bluetooth-hci)
for COBS serialization of CS measurement data.

> **Status: repository scaffold.** The firmware sources, build system, CI, and
> documentation structure are in place. No board support is shipped yet — the
> first development board (overlays, build presets, and the CI/release matrix)
> lands in the next change. See [docs/hardware.md](docs/hardware.md#board-support-contract)
> for what that change adds.

## Get started

Channel Sounding needs a pair of boards — one initiator, one reflector. Pick a path:

- **Flash prebuilt firmware** — no build step; flash and run. No release has
  been published yet; see [docs/flash-quickstart.md](docs/flash-quickstart.md).
- **Build from source** — native toolchain + build. See [docs/build-from-source.md](docs/build-from-source.md).

## Firmware variants

Each build targets a BLE role and a ranging mode.

| Target | Description |
|--------|-------------|
| `initiator` | BLE Central that connects to a CS reflector, collects ranging data, and outputs COBS-encoded binary over UART |
| `reflector` | BLE Peripheral that advertises and responds to CS procedures |

The ranging mode is a build-time choice, set by `CONFIG_MARS_CS_INLINE_PCT`:

- **RAS** (Ranging Service) — the initiator pulls the reflector's step data over
  a BLE GATT service and combines it with its own.
- **IPT** (Inline PCT) — the reflector's phase contribution is embedded in the
  local tones, so the initiator uses its own step data only (no GATT service).

Both modes emit the same COBS-encoded ranging stream over UART. See
[docs/architecture.md](docs/architecture.md#ranging-data-flow) for the full
RAS-vs-IPT contrast and per-mode data flow.

## Presets

Builds are driven by CMake presets in `initiator/CMakePresets.json` and
`reflector/CMakePresets.json`. Preset names follow
`<board>_<cent|peri>_a<antennas>_<paths>`, with an `_ipt` suffix for IPT:
`cent`/`peri` is the BLE role, `a<n>` is the antenna count, and the trailing
number is the antenna-path count.

No presets are defined yet. The first board support change adds them together
with the board overlays; see [docs/hardware.md](docs/hardware.md) for the
board-support contract and the antenna/path fragment mapping.

## Hardware reference

For the board-support contract, antenna/path fragment mapping, and the eventual
board table, see [docs/hardware.md](docs/hardware.md).

## Architecture

For the firmware module map, ranging-data flow, and initiator main loop, see
[docs/architecture.md](docs/architecture.md).

## Contributing

For the commit convention, pre-commit hooks, and pull-request flow, see
[docs/contributing.md](docs/contributing.md).

## License

MIT
