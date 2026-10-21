# Flash prebuilt firmware (quickstart)

> **No prebuilt firmware has been published yet.** The release workflow is in
> place, but the preset matrix is empty until the first board support change
> lands. This guide will be completed with that change: it will cover flashing
> the release archive and reading the COBS ranging output for the supported
> board.

To build and flash from source in the meantime, see
[docs/build-from-source.md](build-from-source.md).

## What will ship

The release workflow builds every preset and publishes one archive,
`cs-ranging-firmware.zip`, containing `<role>_<preset>.hex` files — one
initiator and one reflector binary per preset.

## Channel Sounding needs two boards

Channel Sounding is a two-device protocol. You must flash **one board as the
initiator and a second board as the reflector** — flashing only one board
yields nothing. Flash a **matched** pair — both boards in the same mode
(RAS **or** IPT); the two modes use different BLE discovery and will not pair
with each other:

- **RAS** — the initiator pulls the reflector's step data over the Ranging
  Service.
- **IPT** — the reflector's phase contribution is embedded in the local tones;
  no GATT service is used.

See [docs/architecture.md](architecture.md#ranging-data-flow) for the full
RAS-vs-IPT contrast.

## Until the first board lands

- The board-support contract: [docs/hardware.md](hardware.md#board-support-contract).
- Build from source: [docs/build-from-source.md](build-from-source.md).
