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
     (`boards/<board>..._usb_<role>.overlay`) instead of the VCOM overlay; see
     [Native USB transport](#native-usb-transport).

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
   `boards/nrf54lm20dk_usb_reflector.conf` on the DK) that sets the transport
   and role Kconfig and deferred logging; see
   [Transport Kconfig](#transport-kconfig).

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
   A USB preset uses the role's USB overlay and USB board fragment in place of
   the VCOM ones; see [Presets and naming](#presets-and-naming).

4. **Documentation** — a row per board in `docs/hardware.md` and, when the
   board has non-obvious wiring, a wiring-notes subsection.

5. **CI/release inclusion** — nothing else to edit: the workflows enumerate
   every preset in each `CMakePresets.json` via `ci/list-presets.sh`.

## Native USB transport

A board may expose the initiator's COBS ranging stream and both roles'
consoles on its native USB device controller instead of a debugger's virtual
COM ports. The decision and its constraints are recorded in
[ADR 0001](../docs/adr/0001-native-usb-transport.md); this section is the
per-board contract. The shared `common/mars_usb` module owns the device
context, identity, string descriptors, VBUS policy, and initialization; a board
adds only devicetree and Kconfig.

The board must expose a high-speed-capable USB device controller as
`zephyr_udc0` and support the device-next stack (`USB_DEVICE_STACK_NEXT`). It
should report VBUS detection (`usbd_can_detect_vbus()`); on a controller
without it, the shared module connects immediately after initialization instead
of waiting for a VBUS-ready message. High speed is the required link; full
speed is a fallback. `CONFIG_MARS_CS_TRANSPORT_USB` selects `HWINFO`, which the
shared module uses to derive the USB serial number from the SoC's unique device
ID.

### Role-specific overlays

Add `boards/<board>..._usb_initiator.overlay` and
`boards/<board>..._usb_reflector.overlay`. A USB preset applies exactly one of
them instead of the VCOM overlay; the VCOM overlay stays unchanged for the VCOM
presets. In both overlays:

- Declare the role's CDC ACM functions under `&zephyr_udc0` with
  `compatible = "zephyr,cdc-acm-uart"`.
- Set every console chosen node (`zephyr,console`, `zephyr,shell-uart`,
  `zephyr,uart-mcumgr`, `zephyr,bt-mon-uart`, `zephyr,bt-c2h-uart`) to the
  console function — except in the non-release debug console fragment below,
  which re-points them at the board's J-Link console UART while the COBS
  `cobs-uart` stays on the USB data function.
- Disable every UART node the USB build does not use, so the build carries no
  unused UART drivers or pin assignments. On the DK that is `&uart30` (VCOM0)
  and `&uart20` (VCOM1).

The initiator overlay declares exactly two functions, in interface order:

1. **data** — chosen `cobs-uart`, with `label = "CS Data"`. Its
   `tx-fifo-size` must hold one whole serialization run: at least
   `COBS_TX_RUN_MAX_SIZE` (29,000 bytes; the DK uses 32,768). Keep
   `rx-fifo-size` small because the data receive path is not enabled.
2. **console** — chosen `zephyr,console`, with `label = "Console"` and a small
   best-effort TX ring (the DK uses 1,024 bytes).

The labels become the interface strings the host shows for the functions.

The order is load-bearing: the USB COBS backend asserts that `cobs-uart` is
CDC ACM instance 0 and `zephyr,console` instance 1, and the order is what makes
the host's by-id names expose the data function as `if00` and the console as
`if02`.

The reflector overlay declares exactly one function — the console. It has no
`cobs-uart` chosen node and no data function. The shared module asserts that
the number of CDC ACM nodes matches the role's function count, so a mismatch
fails at build time.

### Debug console fragment (non-release)

The initiator may additionally apply a non-release debug posture that keeps the
COBS stream on the native USB data function but moves the log console back to
the board's J-Link console UART. It exists for bring-up: boot, pre-enumeration,
and hard-fault output stay visible on the onboard debugger even when USB has
not enumerated.

On the DK this is two files layered on the standard USB composition:

| File | Purpose |
|------|---------|
| `boards/nrf54lm20dk_nrf54lm20a_cpuapp_usb_initiator_debug.overlay` | Re-enables `&uart20` (VCOM1) and points the console chosen nodes at it; `cobs-uart` stays `&cdc_data` |
| `boards/nrf54lm20dk_usb_initiator_debug.conf` | Sets `CONFIG_MARS_CS_USB_DEBUG_CONSOLE_VCOM=y` |

Apply the overlay *after* the role overlay, as a later entry in the
semicolon-separated `DTC_OVERLAY_FILE` list, and the fragment after the USB
board fragment in `EXTRA_CONF_FILE`. `CONFIG_MARS_CS_USB_DEBUG_CONSOLE_VCOM`
marks the posture for the initiator's USB COBS backend, which then asserts that
the data function is still CDC ACM instance 0 and that the chosen console is
not CDC ACM.

The variant is deliberately not a CMake preset. CI and the release workflow
enumerate every preset via `ci/list-presets.sh` and package every resulting
image, so a debug preset would ship in the release archive. The manual
`west build` command is documented in
[docs/build-from-source.md](../docs/build-from-source.md#non-release-usb-debug-console-j-link-vcom).
The USB console function remains in the descriptor (the device is still the
two-function composite) but receives no log output.

### Transport Kconfig

Add `boards/<board>_usb_<role>.conf` and apply it from the USB presets. The
required symbols are:

| Symbol | Value | Purpose |
|--------|-------|---------|
| `CONFIG_MARS_CS_TRANSPORT_USB` | `y` | Selects the device-next stack, CDC ACM, and `HWINFO`; switches the initiator to the USB COBS backend. The VCOM presets never see it. |
| `CONFIG_MARS_CS_ROLE_INITIATOR` / `CONFIG_MARS_CS_ROLE_REFLECTOR` | exactly one `y` | Selects the product string and product ID. The shared module fails the build on none or both. |
| `CONFIG_USBD_MAX_SPEED_HIGH` | `y` | High speed is the required link; full speed is a fallback. |
| `CONFIG_CDC_ACM_SERIAL_INITIALIZE_AT_BOOT` | `n` | Avoids the NCSDK-38624 boot hang; the shared module enables the UDC on VBUS attach. |
| `CONFIG_UART_ASYNC_API` | `n` | CDC ACM implements only the interrupt-driven UART API, not the asynchronous one. |
| `CONFIG_LOG`, `CONFIG_LOG_MODE_DEFERRED`, `CONFIG_LOG_PROCESS_THREAD`, `CONFIG_LOG_BACKEND_UART` | `y` | Deferred console output: producers enqueue and never block on a host that does not read. |
| `CONFIG_LOG_BLOCK_IN_THREAD` | `n` | The bounded log queue drops under pressure instead of blocking. |
| `CONFIG_LOG_BUFFER_SIZE` | `4096` (DK) | Bounds the log queue. |
| `CONFIG_USBD_LOG_LEVEL_ERR`, `CONFIG_UDC_DRIVER_LOG_LEVEL_ERR` | `y` | Per-transfer USB logging at informational level measurably caps data throughput. |
| `CONFIG_USBD_CDC_ACM_LOG_LEVEL_OFF` | `y` | Same, for the CDC ACM class. |

The initiator fragment also sets `CONFIG_RING_BUFFER_LARGE=y`: its 32 KiB data
TX ring exceeds the default 32,767-byte ring-buffer limit. A board must not
size the data function below one whole run. `CONFIG_MARS_CS_USB_TX_TIMEOUT_MS`
(default 250 ms) bounds the host-stall wait and normally needs no board
override. `CONFIG_MARS_CS_USB_DEBUG_CONSOLE_VCOM` is not part of the release
composition; only the non-release debug fragment above sets it.

Deferred logging is set by the board fragment rather than selected by
`CONFIG_MARS_CS_TRANSPORT_USB`, because `LOG_MODE_DEFERRED` is a Kconfig choice
symbol and cannot be selected by another symbol.

### Presets and naming

USB presets follow `<board>_usb_<cent|peri>_a<antennas>_<paths>[_ipt]`: the
`usb` transport token follows the board name, and the role token, antenna
count, path count, and `_ipt` suffix keep their VCOM meaning. There is one USB
preset per role and ranging mode (four on the DK), and the existing VCOM
presets keep their names and composition. A USB preset sets `DTC_OVERLAY_FILE`
to the role's USB overlay and includes the role's USB `.conf` fragment in
`EXTRA_CONF_FILE` in place of the VCOM overlay and board fragment.

## Shared fragments already present

| Fragment | Purpose |
|----------|---------|
| `1_path_1_local.conf` | 1 antenna path, 1 antenna |
| `2_path_1_local.conf`, `2_path_2_local.conf` | 2 antenna paths, 1 or 2 antennas |
| `4_path_1_local.conf` … `4_path_4_local.conf` | 4 antenna paths, 1–4 antennas |
| `inline_pct_initiator.conf` | IPT mode for the initiator (drops RAS/GATT) |
| `inline_pct_reflector.conf` | IPT mode for the reflector (drops RAS responder) |
| `inline_pct_shared.conf` | IPT reflector device name (initiator scans for it) |
