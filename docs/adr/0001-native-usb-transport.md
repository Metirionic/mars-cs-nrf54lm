# Native USB transport for the ranging stream and console

- **Status:** accepted
- **Date:** 2026-10-22
- **Issues:** #13 (specification), #21 (this record)

## Context

Both firmware roles reach the host through the nRF54LM20-DK's onboard debugger
(ODB): the initiator's COBS ranging stream on the J-Link VCOM0 and the console
on VCOM1. That puts the debugger in the runtime data path. The J-Link VCOM
bridge supports at most 1 Mbaud and does not support 921600 baud, so the DK
runs its stream at a non-standard 1,000,000 baud. The bench stream already
measures about 82 KB/s at the default Channel Sounding cadence — close to that
ceiling — so tightening the procedure cadence makes the bridge, not the radio,
the limiter. The host additionally depends on J-Link-specific port names, and
each board needs its ODB cable even though the DK can be powered from its
native USB connector.

The nRF54LM20 has a native USB 2.0 High-Speed device controller (USBHS). The
specification (#13) asks for the initiator's COBS stream and both roles'
consoles on that controller while keeping the host-facing contract — ordinary
serial ports and the same COBS wire format — unchanged, and while retaining
the existing VCOM presets.

## Decision

Use the native USB controller as a second, build-time-selected runtime
transport, and take the ODB out of the runtime data path. The ODB remains the
programming and debugging path only.

### Transport selection and build composition

- `CONFIG_MARS_CS_TRANSPORT_USB` is an application-level Kconfig symbol enabled
  only by the role-specific USB board configuration fragment. It selects the
  device-next USB stack (`USB_DEVICE_STACK_NEXT`), the CDC ACM class, and
  `HWINFO`; switches the initiator from the VCOM COBS backend to the USB
  backend; and pulls the shared USB bring-up module into the build. VCOM builds
  compile no USB code, and USB builds compile no VCOM backend.
- `CONFIG_MARS_CS_ROLE_INITIATOR` and `CONFIG_MARS_CS_ROLE_REFLECTOR` are
  explicit per-application role symbols. They select the USB product string and
  product ID, and the shared module fails the build unless exactly one is set.
  The role is deliberately not inferred from the BLE role, because BLE role and
  ranging mode are orthogonal.
- Role-specific board overlays provide the USB devicetree and chosen nodes. The
  VCOM overlay is unchanged and is not applied by the USB presets. The per-board
  requirements are in the
  [board-support contract](../../boards/README.md#native-usb-transport).
- The transport choice lives in the board layer, not in application code. The
  serializer, ranging pipeline, and console logging are written once and work
  over either transport.

### Device and host interface

- The initiator enumerates as a composite CDC ACM device with two functions in
  interface order: **data first** (chosen `cobs-uart`, interface string
  `CS Data`) and **console second** (chosen `zephyr,console`, interface string
  `Console`). The reflector enumerates as a single CDC ACM console function and
  has no `cobs-uart` chosen node. The order is load-bearing: the USB COBS
  backend asserts it, and the host's by-id names expose the initiator data
  function as `if00` and the console as `if02`.
- CDC ACM was chosen because it is driver-free on Linux, Windows, and macOS:
  the host sees ordinary serial ports, so the existing COBS tooling and wire
  format need no change. The data port streams as soon as the host configures
  the device, with no DTR handshake or control protocol; the console is
  output-only, and the data function's receive path is not enabled.
- The device operates at high speed (480 Mbit/s) by default. Full speed is a
  supported fallback for full-speed-only hosts, but it is parity-only: high
  speed is required for the transport-headroom criterion.
- Identity is owned by the shared `common/mars_usb` module, not by a board:
  Nordic development VID `0x1915`, PID `0x0001` for the initiator and `0x0002`
  for the reflector, product strings `Mars CS Initiator` and
  `Mars CS Reflector`, manufacturer `Metirionic`, bus-powered at 500 mA, and a
  serial number derived from the SoC's unique device ID through `HWINFO`. The
  serial number is what gives two identical DKs stable, distinct by-id names. A
  USB-IF VID/PID remains pre-product work.
- `mars_usb_init()` is called after `bt_enable()` in both applications. On the
  DK, which reports VBUS detection, the UDC is enabled on the VBUS-ready
  message and disabled on removal — never at boot. Output produced before the
  host enumerates is dropped and counted rather than buffered, and a bus reset
  or VBUS removal returns the device to that state without a reboot.

### COBS transmit path

- The serializer calls a transport-neutral seam — `cobs_tx_acquire()`,
  `cobs_tx_write()`, `cobs_tx_release()` — and never a UART driver directly.
  Exactly one backend is compiled per build.
- The **VCOM backend** keeps the released asynchronous `uart_tx()` path and its
  TX-done semaphore. It is unchanged by this decision, so the VCOM presets keep
  their released behavior.
- The **USB backend** uses the CDC ACM interrupt-driven UART API: it waits
  until its full-run ring can take a whole run, copies the run in atomically,
  and drains the ring into the driver with `uart_fifo_fill()` from the CDC ACM
  IRQ callback (the only context that API allows). The run ring is
  `COBS_TX_RUN_MAX_SIZE` = 29,000 bytes, sized for one worst-case serialization
  run; the DK's data function has a 32 KiB TX FIFO. That FIFO exceeds the
  default 32,767-byte ring-buffer limit, so the initiator USB fragment sets
  `CONFIG_RING_BUFFER_LARGE`.
- Whole-run atomicity is the point: COBS frames are submitted as complete runs,
  so a host stall cannot truncate a run or interleave a new one into a
  partially transmitted frame. A run that cannot be accepted within
  `CONFIG_MARS_CS_USB_TX_TIMEOUT_MS` (default 250 ms, roughly one procedure
  interval at the default cadence) is dropped and counted; the first drop and
  every 128th are logged. The console function's small TX ring is best-effort.
- USB builds use deferred logging (`CONFIG_LOG_MODE_DEFERRED`,
  `CONFIG_LOG_BLOCK_IN_THREAD=n`, a bounded log queue, and the UART backend
  bound to the chosen `zephyr,console` node). Producers only enqueue, so a host
  that does not read the console cannot stall the firmware; logs may be
  delayed or lost, and the pre-enumeration burst can exceed the 1 KiB console
  TX ring. `CONFIG_MARS_CS_TRANSPORT_USB` cannot select the logging mode
  itself because `LOG_MODE_DEFERRED` is a Kconfig choice symbol, so the USB
  board fragment sets it — a deliberate, narrow deviation from #13's shorthand
  that the transport symbol selects deferred logging.

### Programming, recovery, and presets

- Programming and recovery stay on SWD. The device exposes no USB bootloader or
  DFU interface, and MCUboot is not used; the USBHS controller is device-only,
  so USB host mode is not available either.
- The four VCOM presets and their composition were not part of this decision.
  Four USB presets are added alongside them (`nrf54lm20dk_usb_cent_a1_4`,
  `nrf54lm20dk_usb_cent_a1_4_ipt`, `nrf54lm20dk_usb_peri_a1_4`,
  `nrf54lm20dk_usb_peri_a1_4_ipt`), so every release ships both transports. USB
  preset names follow the same `<board>_usb_<cent|peri>_a<antennas>_<paths>[_ipt]`
  rule as the VCOM presets. (The four-path policy later renamed all eight
  presets from `a1_1` to `a1_4`; see
  [docs/hardware.md](../hardware.md#antenna-path-policy).)
- A non-release debug posture re-points the log console at the board's J-Link
  console UART while leaving the COBS data function — and therefore the
  ranging stream — on native USB. It is selected by
  `CONFIG_MARS_CS_USB_DEBUG_CONSOLE_VCOM`, set only by the debug overlay/fragment
  pair, and exists so boot, pre-enumeration, and hard-fault output stay visible
  during bring-up. It is not a CMake preset, so neither CI nor the release
  archive builds or ships it. The USB console function remains in the
  descriptor but carries no logs in that posture.
- The two-DK bench harness selects the transport, resolves the role-specific
  by-id ports from the SoC serial, asserts the 480 Mbit/s link and expected
  interface mapping on USB runs, and reports wire rate and drop counts. The
  release gate is an A/B comparison over the same assertions.

## Alternatives considered

| Alternative | Why it was not taken |
|-------------|----------------------|
| Keep the ODB VCOM ports as the runtime path | Leaves the debugger in the data path; 1 Mbaud ceiling with no 921600 support; host tied to J-Link port names; two cables per board; the measured stream is already near the bridge ceiling. |
| Use the legacy Zephyr USB device stack | It is deprecated and planned for removal, and it has no devicetree binding for the nRF54LM20 USBHS controller. |
| Use Nordic `app_usbd` | Not present in NCS 3.4.0. |
| Use a vendor-specific bulk class or a custom USB protocol | Requires host drivers or custom tooling, breaking the driver-free, ordinary-serial-port contract and the unchanged COBS tooling. |
| Use one CDC ACM function for data and console | Readable logs would interleave with the binary stream; two functions keep the data port clean. |
| Gate streaming on DTR or a control handshake | The data port must stream on enumeration, and a DTR gate would fail the boot-with-no-host check. |
| Buffer output until a host attaches, or let the writer block | Unbounded memory, or a crashed or non-reading host parks the ranging consumer; bounded drop-and-count keeps memory predictable and the firmware live. |
| Select the transport in application code or infer the role from the BLE role | The transport is a board property and BLE role is orthogonal to product identity; explicit Kconfig and overlays keep shared firmware board-agnostic. |
| Add USB DFU or another USB programming path | Out of scope, and it would change the programming and recovery story; SWD stays the only path. |

## Consequences

- The ODB is needed only for SWD programming and debugging. At runtime each
  board can run from one native USB cable that carries data, console, and
  power.
- Host discovery is by role-specific by-id names derived from the SoC serial,
  not by J-Link port indices. The harness owns the assertions over link speed,
  interface mapping, wire rate, and drops.
- CI builds and the release archive carry eight images: four VCOM and four
  USB. Existing VCOM users keep their preset names and artifacts.
- The serialization output and the COBS wire format are unchanged, and no
  change reaches the `mars-bluetooth-hci` API. The VCOM path remains available
  for comparison and for hosts without native USB.

## Known limitations and constraints

- **NCSDK-38624.** CDC ACM serial initialization at boot can hang an
  nRF54LM20 until the USB cable is disconnected. The design avoids the path:
  `CONFIG_CDC_ACM_SERIAL_INITIALIZE_AT_BOOT=n`, and the UDC is enabled on VBUS
  attach instead of boot. This is an avoidance, not a fix; the SDK behavior
  remains.
- **HFCLK24M shared with MPSL (DRGN-29129).** USB high speed uses HFCLK24M,
  which MPSL also owns. USB initialization is ordered after `bt_enable()` to
  keep the MPSL initialization order safe; changing that order can trip the
  hazard.
- **DRGN-29277 deferred.** The sleep-current workaround after USB disconnect is
  not part of this change. HFCLK24M remains active while USB is in use, so
  sleep-current targets need the follow-up power-management work.
- **High speed is experimental in NCS 3.4.0.** Nordic describes high-speed
  support as experimental. The bench measured a working 480 Mbit/s link on the
  DK; full speed remains the fallback but does not meet the headroom criterion.
- **Throughput is stack-limited, not link-limited.** The bring-up measurement
  was 2.34 MB/s on the data port with a 16 KiB ring and the driver's 512-byte
  transfers; with UDC and USBD logging at informational level on the console,
  the same path fell to roughly 100 KB/s, which is why the USB stack is kept at
  error level. The #20 release gate measured about 0.654 Mbit/s at the default
  cadence, and 406,290 B/s (3.25 Mbit/s, 0.68 % of the link) in the interval-1
  headroom run (the controller clamps it to procedure interval 2), with zero
  USB transport drops — about 5.8× below the 2.34 MB/s baseline. The 480 Mbit/s
  link rate is not a throughput promise.
- **TF-M and non-secure ownership are unverified.** Only the secure
  application-core targets (`.../cpuapp`) are supported; the USB device has not
  been tested from a non-secure image.
- **VBUS removal is untested on the bench.** The UDC is disabled on the
  VBUS-removed message by design, but the release gate exercised boot with no
  host and a host read stall/close, not a literal port-power removal (the bench
  has no controllable port power).
- **The console is best-effort.** Its 1 KiB TX ring and the bounded deferred log
  queue can drop messages, especially before enumeration.
- **Release USB builds have no pre-enumeration console.** The log console is
  the CDC ACM console function, so a fault before the host enumerates is not
  visible over USB. The non-release debug posture moves the console to the
  J-Link VCOM for bring-up; it is deliberately not released.
- **The USB identity uses development IDs.** VID `0x1915` and PIDs `0x0001` /
  `0x0002` are Nordic development values; a USB-IF VID/PID is pre-product work.
- **Windows and macOS coverage is manual.** Linux is the merge and release
  gate; the other hosts are release smoke tests.

## References

- Specification: issue #13, "Native USB transport for the nRF54LM20-DK (remove
  the onboard debugger from the data path)".
- Per-board requirements: [board-support contract](../../boards/README.md#native-usb-transport).
- Preset table: [hardware reference](../hardware.md#presets).
- Implementation: `common/mars_usb.{c,h}`, `initiator/src/cobs_tx.h`,
  `initiator/src/cobs_tx_vcom.c`, `initiator/src/cobs_tx_usb.c`,
  `boards/nrf54lm20dk_nrf54lm20a_cpuapp_usb_*.overlay`,
  `boards/nrf54lm20dk_usb_*.conf`, and the non-release debug pair
  `boards/nrf54lm20dk_nrf54lm20a_cpuapp_usb_initiator_debug.overlay` /
  `boards/nrf54lm20dk_usb_initiator_debug.conf`.

## Update — NCS v3.4.1 (2026-10-27)

The constraints above were written against NCS v3.4.0. The repository now pins
v3.4.1 (released as v0.8.1, issue #50), and both MPSL defects this record names
are fixed there:

- **DRGN-29129 is fixed.** `mpsl_init` no longer hangs when called after
  `mpsl_uninit` with HFCLK24M still active on the nRF54LM Series. The firmware
  still calls `mars_usb_init()` after `bt_enable()`: the fix makes that
  ordering unnecessary, not wrong, and changing it is a behavior change that
  deserves its own justification and validation.
- **DRGN-29277 is fixed.** Releasing HFCLK24M now stops the clock, so the
  sleep-current work this record deferred is no longer blocked by the SDK. That
  follow-up power-management work is still not part of this firmware.

The decision body above, including its v3.4.0 references, is deliberately
unchanged: it records what was decided under v3.4.0.
