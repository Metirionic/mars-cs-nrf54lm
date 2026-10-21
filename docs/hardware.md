# Hardware reference

This is the reference for the board overlays and antenna/path presets used by
this firmware. To build from source, see
[docs/build-from-source.md](build-from-source.md); to flash prebuilt firmware,
see [docs/flash-quickstart.md](flash-quickstart.md).

This document is a reference only — it does not cover physical antenna wiring,
RF placement, antenna tuning, the COBS wire format, or the mars-bluetooth-hci
API.

## Supported boards

| Board | Build target | COBS stream | Console |
|-------|--------------|-------------|---------|
| nRF54LM20-DK | `nrf54lm20dk/nrf54lm20a/cpuapp` | VCOM0 (`uart30`), 1,000,000 baud, 8N1, no flow control | VCOM1 (`uart20`), 115200 baud |

The DK is built as the **A** variant (`nRF54LM20A`), the NPU-less variant
**built for** the B-silicon DK (`SOC_NRF54LM20A_DEVELOP_IN_NRF54LM20B`; both
bench DKs report `nRF54LM20A ENGA`). The A-only target is deliberate.

### nRF54LM20-DK wiring notes

- **VCOM0 (`uart30`) — COBS ranging stream.** The initiator writes the
  COBS-encoded ranging stream here at **1,000,000 baud (1 Mbps)**, 8N1, no flow
  control.
  The DK's J-Link VCOM bridge supports up to 1 Mbps and explicitly does **not**
  support 921600 baud, so 1,000,000 is the board-declared rate — it is not a
  typo for the 921600 used where the transport supports it.
- **VCOM1 (`uart20`) — console.** The board-default console stays at 115200
  baud. Use it to tell the two virtual COM ports apart: VCOM1 prints readable
  log output, while VCOM0 carries the binary stream.
- **One antenna, one RF path, no switch.** The DK has a single 2.4 GHz trace
  antenna and no antenna-switch IC or RF-supply rail. The overlay therefore
  deliberately omits both `cs_antenna_switch` and `rf-switch-supply-gpios`.
  The upstream sample's antenna-switch pins (P1.17–P1.20) collide with the
  console UART/LFXO on this board — do not copy them.

## Board support contract

**Supported board: nRF54LM20-DK** (`nrf54lm20dk/nrf54lm20a/cpuapp`). The
firmware sources stay board-agnostic; a board support change consists of:

1. **A devicetree overlay** in `boards/`, named
   `<board>_nrf54lm20a_cpuapp.overlay` (and/or `..._nrf54lm20b_cpuapp.overlay`).
   It provides:
   - `chosen { cobs-uart = &uartXX; }` — the initiator's COBS ranging stream,
     run at the board-declared baud (`921600` where the transport supports it,
     `1,000,000` on the nRF54LM20-DK VCOM), 8N1, no flow control. The rate is
     board-declared: it lives in the overlay's `current-speed`, so a future
     board picks a rate its own transport supports without touching shared
     firmware.
   - The console chosen nodes when the board has a console UART that its board
     definition does not already choose: `zephyr,console`, `zephyr,shell-uart`,
     `zephyr,uart-mcumgr`, `zephyr,bt-mon-uart`, and `zephyr,bt-c2h-uart`.
     Boards without a console UART select the RTT console in a board `.conf`
     fragment instead.
   - An optional `cs_antenna_switch` node for multi-antenna boards (see
     [Antenna-switch node](#antenna-switch-node)).
   - An optional RF-switch supply rail when the board's RF switch needs a
     supply GPIO driven high before Channel Sounding starts — an app-owned
     property on the `zephyr,user` node:
     ```dts
     / {
         zephyr,user {
             rf-switch-supply-gpios = <&gpio2 5 GPIO_ACTIVE_HIGH>;
         };
     };
     ```
     The initiator drives it with `GPIO_OUTPUT_ACTIVE` at boot
     (`initiator/src/main.c`). Boards without the property skip the code
     entirely.
2. **An optional board `.conf` fragment** in `boards/` for board-level
   Kconfig — typically the RTT console backend:
   ```
   CONFIG_USE_SEGGER_RTT=y
   CONFIG_CONSOLE=y
   CONFIG_RTT_CONSOLE=y
   CONFIG_UART_CONSOLE=n
   ```
3. **Presets** in `initiator/CMakePresets.json` and
   `reflector/CMakePresets.json`, setting `BOARD`, `CONF_FILE`,
   `EXTRA_CONF_FILE`, `DTC_OVERLAY_FILE`, and the preset-local `binaryDir`.
4. **Documentation** — a row per board in the
   [Supported boards](#supported-boards) table and, when the board has
   non-obvious wiring, a wiring-notes subsection (see
   [nRF54LM20-DK wiring notes](#nrf54lm20-dk-wiring-notes)).
5. **Nothing else.** CI and the release workflow enumerate every preset via
   `ci/list-presets.sh`, so a new preset is built automatically.

## Antenna and path presets

### What "A1 2-path" and "A2 4-path" mean

"A1" / "A2" is the antenna count, set by `CONFIG_BT_CTLR_SDC_CS_NUM_ANTENNAS`.
"2-path" / "4-path" is the antenna-path count, set by
`CONFIG_BT_CTLR_SDC_CS_MAX_ANTENNA_PATHS` (mirrored on the host side by
`CONFIG_BT_RAS_MAX_ANTENNA_PATHS`). So "A1 2-path" means 1 antenna, 2 paths;
"A2 4-path" means 2 antennas, 4 paths.

### Kconfig fragments

Every preset pulls a `boards/*_local.conf` path-local fragment. RAS presets
pull just that one (plus `initiator/central.overlay` for initiators, and a
board `.conf` fragment wherever a board's RTT-console/serial-driver Kconfig is
needed). Each local fragment is three lines setting the same three symbols:

| Fragment | `RAS_MAX_ANTENNA_PATHS` | `SDC_CS_MAX_ANTENNA_PATHS` | `SDC_CS_NUM_ANTENNAS` | Antennas / Paths |
|----------|------------------------|----------------------------|------------------------|------------------|
| `1_path_1_local.conf` | 1 | 1 | 1 | A1 / 1-path |
| `2_path_1_local.conf` | 2 | 2 | 1 | A1 / 2-path |
| `2_path_2_local.conf` | 2 | 2 | 2 | A2 / 2-path |
| `4_path_1_local.conf` | 4 | 4 | 1 | A1 / 4-path |
| `4_path_2_local.conf` | 4 | 4 | 2 | A2 / 4-path |
| `4_path_3_local.conf` | 4 | 4 | 3 | A3 / 4-path |
| `4_path_4_local.conf` | 4 | 4 | 4 | A4 / 4-path |

Fragment filenames follow `<paths>_path_<antennas>_local.conf` — paths first,
antennas second.

IPT presets pull the same path-local fragment **plus** two Inline PCT fragments
that switch the firmware from RAS to IPT mode (see
[docs/architecture.md](architecture.md#ranging-data-flow) for what IPT mode is).
Applied via `EXTRA_CONF_FILE` after `CONF_FILE`, they override the RAS defaults:

| Fragment | Applied to | Purpose |
|----------|-----------|---------|
| `boards/inline_pct_shared.conf` | both initiator & reflector | Sets `CONFIG_BT_DEVICE_NAME="Nordic CS IPT Reflector"` — the single source of truth for the IPT reflector's advertised name. The reflector advertises it; the initiator scans for it by name instead of the Ranging Service UUID. |
| `boards/inline_pct_initiator.conf` | initiator only | Enables `CONFIG_MARS_CS_INLINE_PCT=y`, disables RAS (`CONFIG_BT_RAS=n`…), drops the GATT client / large MTU (the reflector's PCT contribution is embedded in the local tones — no RAS ranging-data transfer), and sets `CONFIG_BT_SCAN_NAME_CNT=1` to discover the reflector by name. |
| `boards/inline_pct_reflector.conf` | reflector only | Enables `CONFIG_MARS_CS_INLINE_PCT=y` + `CONFIG_BT_CTLR_EXTENDED_FEAT_SET=y` and disables the RAS responder (`CONFIG_BT_RAS_RRSP=n`…). |

### Presets

The nRF54LM20-DK presets live in `initiator/CMakePresets.json` and
`reflector/CMakePresets.json`:

| Preset | Mode | Role | Board | Overlay | `EXTRA_CONF_FILE` | Antennas / Paths |
|--------|------|------|-------|---------|-------------------|------------------|
| `nrf54lm20dk_cent_a1_1` | RAS | Initiator | `nrf54lm20dk/nrf54lm20a/cpuapp` | `boards/nrf54lm20dk_nrf54lm20a_cpuapp.overlay` | `initiator/central.overlay`; `boards/1_path_1_local.conf` | A1 / 1-path |
| `nrf54lm20dk_cent_a1_1_ipt` | IPT | Initiator | `nrf54lm20dk/nrf54lm20a/cpuapp` | `boards/nrf54lm20dk_nrf54lm20a_cpuapp.overlay` | `initiator/central.overlay`; `boards/inline_pct_initiator.conf`; `boards/inline_pct_shared.conf`; `boards/1_path_1_local.conf` | A1 / 1-path |
| `nrf54lm20dk_peri_a1_1` | RAS | Reflector | `nrf54lm20dk/nrf54lm20a/cpuapp` | `boards/nrf54lm20dk_nrf54lm20a_cpuapp.overlay` | `boards/1_path_1_local.conf` | A1 / 1-path |
| `nrf54lm20dk_peri_a1_1_ipt` | IPT | Reflector | `nrf54lm20dk/nrf54lm20a/cpuapp` | `boards/nrf54lm20dk_nrf54lm20a_cpuapp.overlay` | `boards/inline_pct_reflector.conf`; `boards/inline_pct_shared.conf`; `boards/1_path_1_local.conf` | A1 / 1-path |

Preset names follow `<board>_<cent|peri>_a<antennas>_<paths>`, with an `_ipt`
suffix for IPT. Note the deliberate naming asymmetry:

- **Preset names** are `<board>_<cent|peri>_a<antennas>_<paths>` — antennas
  first, paths second (e.g. `example_cent_a2_4` = A2, 4 paths).
- **Fragment filenames** are `<paths>_path_<antennas>_local.conf` — paths
  first, antennas second. The two orders are reversed; cross-check carefully.

Initiator presets include `initiator/central.overlay` (the scanning-central
Kconfig fragment, mislabeled `.overlay` but a conf fragment) in
`EXTRA_CONF_FILE`; reflector presets do not. IPT presets insert the
`inline_pct_initiator.conf` / `inline_pct_reflector.conf` and
`inline_pct_shared.conf` fragments between the role fragment and the
path-local fragment.

### How a preset composes overlay + fragments

Each preset sets `DTC_OVERLAY_FILE` (the board overlay) and `EXTRA_CONF_FILE`
(the role fragment `;`-separated from the path-local fragment, plus the board
`.conf` fragment and the IPT fragments where applicable).
`ci/common.sh` parses `CMakePresets.json`, splits `EXTRA_CONF_FILE` on `;`,
and resolves each part relative to the app directory; `ci/build.sh` passes them
to `west build -b <BOARD>` as `-DDTC_OVERLAY_FILE`, `-DEXTRA_CONF_FILE`, and
`-DCONF_FILE`. See [docs/build-from-source.md](build-from-source.md) for the
full build flow.

### Tone-antenna configuration (supplementary)

The firmware maps the antenna counts to a BLE CS tone-antenna configuration
(`An_Bm`) in `common/antenna.c`. The lookup is **role-aware**:
`antenna_get_config_for_role(role)` takes the local antenna count from
`CONFIG_BT_CTLR_SDC_CS_NUM_ANTENNAS` and the peer count from the CS
capabilities exchange — `remote_capabilities_cb` stores the peer's
`num_antennas_supported` via `antenna_set_peer_count()` — then indexes
`ANTENNA_MAPPING[dev_a - 1][dev_b - 1]` with the local and peer counts swapped
by role:

- **Initiator** — `antenna_get_config_from_ab(local, peer)`:
  `ANTENNA_MAPPING[NUM_ANTENNAS - 1][peer - 1]`
- **Reflector** — `antenna_get_config_from_ab(peer, local)`:
  `ANTENNA_MAPPING[peer - 1][NUM_ANTENNAS - 1]`

Before the capabilities exchange completes (or if it fails), the peer count
falls back to the heuristic `peer = CONFIG_BT_CTLR_SDC_CS_MAX_ANTENNA_PATHS /
CONFIG_BT_CTLR_SDC_CS_NUM_ANTENNAS` (integer division). For a **matched** pair
the negotiated count equals the heuristic, so the table below still holds; for
a **mismatched** pair the negotiated count wins.

The same `(antennas, paths)` config can therefore resolve to a different
`An_Bm` depending on which role runs it — the local and peer counts land in
opposite index slots. For the fragment combinations this repo expresses:

| Antennas / Paths | Initiator `An_Bm` | Reflector `An_Bm` |
|------------------|-------------------|--------------------|
| A1 / 1           | `A1_B1`           | `A1_B1`            |
| A1 / 2           | `A1_B2`           | —                  |
| A2 / 2           | —                 | `A1_B2`            |
| A1 / 4           | `A1_B4`           | `A4_B1`            |
| A2 / 4           | `A2_B2`           | `A2_B2`            |
| A3 / 4           | `A3_B1`           | `A1_B3`            |
| A4 / 4           | `A4_B1`           | `A1_B4`            |

A `—` marks a role/path combination not currently expressed by a fragment pair
(A1 2-path is intended as initiator-only; A2 2-path as reflector-only). A2
4-path is symmetric — `A2_B2` either way. The `ANTENNA_MAPPING` table also
carries placeholder `A1_B1` entries for index combinations no preset uses.

_Supplementary — from `common/antenna.c`, not from presets/fragments._

### Antenna-switch node

- The `cs_antenna_switch` node (`compatible = "nordic,bt-cs-antenna-switch"`)
  is owned and consumed internally by the Nordic controller library in NCS; no
  code in this repo reads `ant-gpios` directly.
- Single-antenna boards omit the node: the controller's `cs_antenna_switch.c`
  is compiled only under `CONFIG_BT_CTLR_SDC_CS_MULTIPLE_ANTENNA_SUPPORT`,
  i.e. `NUM_ANTENNAS >= 2`.
- `multiplexing-mode` follows the board's RF switch wiring; derive it from the
  board documentation and the controller implementation, not by guesswork.

## Out of scope

- Physical antenna wiring diagrams.
- RF placement guidance.
- Antenna tuning advice (the LFXO load-capacitance notes in a board's wiring
  notes are factual overlay content, not tuning guidance).
- The COBS wire format and the mars-bluetooth-hci API (see the
  [mars-bluetooth-hci](https://github.com/Metirionic/mars-bluetooth-hci) repo).
- A generated documentation site.

## References

- [README](../README.md) — project overview, firmware variants, and the flash and build entry points.
- [docs/flash-quickstart.md](flash-quickstart.md) — flashing prebuilt firmware.
- [docs/build-from-source.md](build-from-source.md) — toolchain and build flow.
- [docs/architecture.md](architecture.md) — module map and ranging-data flow.
- [mars-bluetooth-hci](https://github.com/Metirionic/mars-bluetooth-hci) — COBS
  serialization library.
- [nRF Connect SDK](https://developer.nordicsemi.com/nRF_Connect_SDK/) —
  controller-owned `cs_antenna_switch` binding.
