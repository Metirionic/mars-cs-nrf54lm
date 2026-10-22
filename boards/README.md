# Board support

The nRF54LM20-DK is supported. This file documents the contract every board
support change follows, so the shared firmware and CI stay board-agnostic.

## Supported boards

| Board | Build target | Overlay | Presets |
|-------|--------------|---------|---------|
| nRF54LM20-DK | `nrf54lm20dk/nrf54lm20a/cpuapp` | `boards/nrf54lm20dk_nrf54lm20a_cpuapp.overlay` (VCOM) or `boards/nrf54lm20dk_nrf54lm20a_cpuapp_usb_<role>.overlay` (native USB) | `nrf54lm20dk_cent_a1_1`, `nrf54lm20dk_cent_a1_1_ipt`, `nrf54lm20dk_peri_a1_1`, `nrf54lm20dk_peri_a1_1_ipt`, `nrf54lm20dk_usb_cent_a1_1`, `nrf54lm20dk_usb_cent_a1_1_ipt`, `nrf54lm20dk_usb_peri_a1_1`, `nrf54lm20dk_usb_peri_a1_1_ipt` |

Each supported board gets a row here and in the
[hardware reference](../docs/hardware.md#supported-boards), which also carries
the wiring notes and the preset table.

## What a board support change adds

1. **A devicetree overlay** at
   `boards/<board>_nrf54lm20a_cpuapp.overlay` (and/or
   `..._nrf54lm20b_cpuapp.overlay`). It must provide:
   - `chosen { cobs-uart = &uartXX; }` — the initiator's COBS ranging stream.
     Set that UART to the board-declared baud (`921600` where the transport
     supports it, `1,000,000` on the nRF54LM20-DK VCOM), 8N1, no flow control.
     The rate is board-declared: it lives in the board overlay's
     `current-speed`, so a future board picks a rate its own transport supports
     without changing shared firmware. The DK uses 1,000,000 because its J-Link
     VCOM bridge supports up to 1 Mbps but not 921600.
   - The console chosen nodes (`zephyr,console`, `zephyr,shell-uart`,
     `zephyr,uart-mcumgr`, `zephyr,bt-mon-uart`, `zephyr,bt-c2h-uart`) when the
     board has a console UART that its board definition does not already
     choose. Boards without one select the RTT console in a board `.conf`
     fragment instead.
   - An optional `cs_antenna_switch` node for multi-antenna boards:
     ```dts
     cs_antenna_switch: cs-antenna-config {
         status = "okay";
         compatible = "nordic,bt-cs-antenna-switch";
         ant-gpios = <&gpio1 17 GPIO_ACTIVE_HIGH>, ...;
         multiplexing-mode = <1>;
     };
     ```
   - An optional RF-switch supply rail when the board's RF switch needs a
     supply GPIO driven high before CS starts — an app-owned property on the
     `zephyr,user` node:
     ```dts
     / {
         zephyr,user {
             rf-switch-supply-gpios = <&gpio2 5 GPIO_ACTIVE_HIGH>;
         };
     };
     ```
     The initiator drives it with `GPIO_OUTPUT_ACTIVE` at boot. Boards without
     the property skip the code entirely.
   - For a native USB transport, a role-specific USB overlay
     (`boards/<board>..._usb_<role>.overlay`) instead of the VCOM overlay. It
     declares the CDC ACM functions under `&zephyr_udc0` in interface order
     (initiator: data first via the `cobs-uart` chosen node, console second via
     `zephyr,console`; reflector: the single console function), sets the
     console chosen nodes to the console function, and disables the UART nodes
     the USB build does not use.

2. **An optional board `.conf` fragment** (`boards/<board>.conf`) when the
   board needs board-level Kconfig, typically the RTT console backend:
   ```
   CONFIG_USE_SEGGER_RTT=y
   CONFIG_CONSOLE=y
   CONFIG_RTT_CONSOLE=y
   CONFIG_UART_CONSOLE=n
   ```
   A native USB transport adds a role/transport fragment
   (`boards/nrf54lm20dk_usb_initiator.conf` or
   `boards/nrf54lm20dk_usb_reflector.conf` on the DK) that sets
   `CONFIG_MARS_CS_TRANSPORT_USB`, the role symbol, the USB stack and CDC ACM
   options, and deferred logging.

3. **Presets** in `initiator/CMakePresets.json` and
   `reflector/CMakePresets.json`. Each preset sets:
   - `BOARD` — e.g. `nrf54lm20dk/nrf54lm20a/cpuapp`, or the board's own NCS
     board definition when one exists.
   - `CONF_FILE` — `prj.conf`.
   - `EXTRA_CONF_FILE` — the role fragment (`initiator/central.overlay` for
     initiators), the IPT fragments for `_ipt` presets, the path-local fragment
     from `boards/`, and any board `.conf`.
   - `DTC_OVERLAY_FILE` — the board overlay.
   - `binaryDir` — `${sourceDir}/build_<preset>`.

   Preset names follow `<board>[_usb]_<cent|peri>_a<antennas>_<paths>[_ipt]`.

4. **Documentation** — a row per board in `docs/hardware.md` and, when the
   board has non-obvious wiring, a wiring-notes subsection.

5. **CI/release inclusion** — nothing else to edit: the workflows enumerate
   every preset in each `CMakePresets.json` via `ci/list-presets.sh`.

## Shared fragments already present

| Fragment | Purpose |
|----------|---------|
| `1_path_1_local.conf` | 1 antenna path, 1 antenna |
| `2_path_1_local.conf`, `2_path_2_local.conf` | 2 antenna paths, 1 or 2 antennas |
| `4_path_1_local.conf` … `4_path_4_local.conf` | 4 antenna paths, 1–4 antennas |
| `inline_pct_initiator.conf` | IPT mode for the initiator (drops RAS/GATT) |
| `inline_pct_reflector.conf` | IPT mode for the reflector (drops RAS responder) |
| `inline_pct_shared.conf` | IPT reflector device name (initiator scans for it) |
