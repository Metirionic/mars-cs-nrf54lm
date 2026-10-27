# Interop bench: nRF54L15 TAG reflector

This is the bench runbook for the mixed-pair Channel Sounding campaign: an
nRF54LM20-DK initiator ranging against an nRF54L15 TAG reflector running the
sibling repository's IPT firmware. It covers the rig, the decoy-SoC problem,
the bench-only RTT logging posture, and the verification that a flash landed on
the TAG rather than on the L15-DK's own SoC. For the LM20 board contract see
[docs/hardware.md](hardware.md); for the toolchain and build flow see
[docs/build-from-source.md](build-from-source.md).

The TAG is **not** a supported board of this repository. Its firmware, preset,
and overlays live in [Metirionic/mars-cs-nrf54l](https://github.com/Metirionic/mars-cs-nrf54l);
this runbook records only the bench composition and the LM20-side evidence.

## Bench map

| Role | Board | Probe / USB serial | SoC identity |
|------|-------|--------------------|--------------|
| Initiator | nRF54LM20-DK | USB `2B9A5DB40D555EE7`, J-Link `1051838360` | — |
| Reflector (LM20 reference) | nRF54LM20-DK | USB `F71FC00462052101`, J-Link `1051808351` | — |
| TAG debug/power | nRF54L15-DK `PCA10156`, v0.9.x | J-Link `001057759725` | L15-DK SoC `0xDC08B482EFBAC2E7`, `PART=0x00054B15`, `VARIANT=0x41414242` (`BBAA`), recovered blank |
| TAG reflector | nRF54L15 TAG | through the L15-DK `DEBUG OUT` (P19) | `0xFFC34F211C2820B8`, `PART=0x00054B15`, `VARIANT=0x41414330` (`0CAA`) |

The LM20 reflector is the reference peer for the LM20↔LM20 baseline. Power it
down and verify it is absent from USB and BLE before any TAG run (#37).

The `PCA10156` v0.9.x layout has no `P5` power connector, so the TAG cannot be
fed at `VDD SWD0` directly. It is powered at its own `VDD` from an L15-DK
`VDDIO` pin; see [Power arrangement](#power-arrangement).

## Decoy SoC and flash safety

The L15-DK's own SoC stays powered and keeps running its former application
when the TAG is unplugged. A former sibling-repo reflector advertises
`Nordic CS Reflector`, which is a decoy peer for a scan that filters on a CS
reflector name. The TAG's `P1` pin 3 is hard-wired to GND and asserts
`SWD0_SELECT` on `P19`, which reroutes the L15-DK's onboard J-Link from its own
SoC to the TAG. It is the seating that selects the target, not a switch.

Identify the target from the FICR **64-bit device ID**, not the variant:

```bash
nrfutil device read --serial-number 001057759725 \
  --address 0x00FFC300 --bytes 0x30 --width 32 --direct
```

`FICR.INFO` is at `0x00FFC300`; `DEVICEID[0]` is at `+0x04`, `DEVICEID[1]` at
`+0x08`, `PART` at `+0x1C`, and `VARIANT` at `+0x20`. The 64-bit ID is
`DEVICEID[1] << 32 | DEVICEID[0]`.

- TAG: `0xFFC34F211C2820B8`, `VARIANT=0x41414330` (`0CAA`).
- This L15-DK's own SoC: `0xDC08B482EFBAC2E7`, `VARIANT=0x41414242` (`BBAA`).

**Do not use the variant alone as the check.** An earlier L15-DK SoC on this
bench also reported `0CAA`, identical to the TAG's variant; only the device ID
differed.

The safe sequence is:

1. **Lift the TAG off P19 and remove its VDD feed** (or power the L15-DK down);
   leave the coin cell out. Lifting the TAG off P19 reroutes the probe back to
   the L15-DK SoC. If the TAG stays fed, it keeps advertising the IPT name —
   expected, and not the decoy — so remove the feed if a silent airspace is
   wanted for the check.
2. **Confirm the probe is on the L15-DK SoC** by its device ID
   `0xDC08B482EFBAC2E7` (record the ID on first use; it is board-specific).
3. **Recover the L15-DK SoC** with the TAG detached:
   `nrfutil device recover --serial-number 001057759725`. This erases every
   user non-volatile region and opens AP access, so the former application
   cannot advertise.
4. **Verify the decoy is off the air**: a BLE scan shows no
   `Nordic CS Reflector` advertiser.
5. **Power down, seat the TAG on P19** with pin 1 aligned, supply 3.3 V to the
   TAG's `VDD` from an L15-DK `VDDIO` pin, and power up. No coin cell.
6. **Confirm the probe switched to the TAG**: the device ID must be
   `0xFFC34F211C2820B8`. If it differs, the TAG's `P1` pin 3 is not grounded
   or the wrong target is on the debug bus — fix the seating before doing
   anything destructive.
7. **Open AP access if closed.** A stock TAG reports
   `nrfutil device protection-get --serial-number 001057759725` →
   `Debug access is currently disabled (status value: All)`. The recover step
   below clears it; after recover the status is
   `Debug access is enabled`, `erase protection: false`.
8. Flash the sibling build (next section), reset, and verify on the wire.
9. Scan the air: exactly one `Nordic CS IPT Reflector` advertiser (the TAG).

**Never flash without step 6.** With the TAG absent, the same probe silently
targets the L15-DK SoC; a TAG image flashed there runs and advertises normally,
and nothing in the RTT console distinguishes the two SoCs. The device ID is the
only reliable target check.

## Firmware provenance

- Sibling repository: `Metirionic/mars-cs-nrf54l`, commit `c2253fe`
  (`v1.17.0-2-gc2253fe`).
- Preset: `nrf54l15tag_peri_a2_4_ipt`
  (`inline_pct_reflector.conf; inline_pct_shared.conf; 4_path_2_local.conf;
  nrf54l15tag.conf`), plus the bench-only
  [`bench/nrf54l15tag_rtt_bench.conf`](../bench/nrf54l15tag_rtt_bench.conf).
  The fragment's header carries the buffer/mode rationale; it is deliberately
  not a sibling-repo preset, because CI and the release workflow enumerate
  every preset and a bench preset would ship.
- Built image: `reflector/build_bench_tag_rtt/reflector/zephyr/zephyr.hex`,
  `zephyr.bin` sha256 `a4fce0379a30aba44d76ae45827996a018d3a243f3eac3605eb8d7d90205bb8e`,
  260,692 bytes, RAM 91,068 B of 256 KiB (34.7 %).

Build and flash from this repository's root, with the NCS virtualenv active and
the sibling repo checked out as `../mars-cs-nrf54l`:

```bash
REPO=$(git rev-parse --show-toplevel)
SIBLING=$(realpath "$REPO/../mars-cs-nrf54l")

west build -p always -d "$SIBLING/reflector/build_bench_tag_rtt" \
  -b nrf54l15tag/nrf54l15/cpuapp "$SIBLING/reflector" -- \
  -DCONF_FILE="$SIBLING/reflector/prj.conf" \
  -DEXTRA_CONF_FILE="$SIBLING/boards/inline_pct_reflector.conf;$SIBLING/boards/inline_pct_shared.conf;$SIBLING/boards/4_path_2_local.conf;$SIBLING/boards/nrf54l15tag.conf;$REPO/bench/nrf54l15tag_rtt_bench.conf" \
  -DDTC_OVERLAY_FILE="$SIBLING/boards/nrf54l15tag_nrf54l15_cpuapp.overlay"

west flash -d "$SIBLING/reflector/build_bench_tag_rtt" \
  -i 001057759725 --erase-mode all --no-reset
```

The verified configuration is `BOARD_TARGET=nrf54l15tag/nrf54l15/cpuapp`,
`BT_DEVICE_NAME="Nordic CS IPT Reflector"`, `BT_CTLR_SDC_CS_NUM_ANTENNAS=2`,
`BT_CTLR_SDC_CS_MAX_ANTENNA_PATHS=4`, `MARS_CS_INLINE_PCT=y`,
`LOG_MODE_DEFERRED=y`, `LOG_BACKEND_RTT=y`,
`LOG_BACKEND_RTT_MODE_OVERWRITE=y`, `SEGGER_RTT_BUFFER_SIZE_UP=32768`.

## Power arrangement

`PCA10156` v1.0.0 and later expose `VDD SWD0` on `P5` pin 3; the documented
TAG power path is a jumper from an L15-DK `VDDIO` pin to that pin, with the TAG
fed through `P19` pin 1. The v0.9.x board used here has no `P5`, so the TAG is
fed at its own `VDD` (its `P2` header / battery `+` pad) from an L15-DK `VDDIO`
pin. When the TAG is seated, `P1` pin 1 (`VDD_DBG`) is the same rail and drives
the L15-DK's `VDD SWD0` level-shifter reference through `P19` pin 1, which is
the pre-v1.0.0 arrangement Nordic documents as "power the external board
separately". The 3.3 V reaches `VDD SWD0`; only the feed point differs from the
v1.0.0 wording.

- L15-DK `VDD` (and therefore `VDDIO`) is set to **3.3 V**.
- **No CR2032.** Feeding 3.3 V into `VDD SWD0` or the TAG's `VDD` with a coin
  cell inserted can permanently damage the TAG, the L15-DK, and the battery.
- The bench FT232R path is not used: the TAG is a reflector and emits no COBS
  stream, and its console is RTT over the `DEBUG OUT` probe.

## RTT read-back

Use [`scripts/read-tag-rtt.py`](../scripts/read-tag-rtt.py). It resolves
`_SEGGER_RTT` from the ELF, reads the control block and up-buffer through
`nrfutil device read --direct`, and prints the valid ring window:

```bash
SIBLING=$(realpath "$(git rev-parse --show-toplevel)/../mars-cs-nrf54l")
ELF="$SIBLING/reflector/build_bench_tag_rtt/reflector/zephyr/zephyr.elf"

python3 scripts/read-tag-rtt.py --serial 001057759725 --elf "$ELF"
```

After `west flash --no-reset`, invalidate the control block before the first
boot so the image does not reuse a stale ring from the previous session, then
reset and read:

```bash
python3 scripts/read-tag-rtt.py --serial 001057759725 --elf "$ELF" --invalidate-only
nrfutil device reset --serial-number 001057759725 --reset-kind RESET_HARD
python3 scripts/read-tag-rtt.py --serial 001057759725 --elf "$ELF" --output /tmp/tag-rtt.txt
```

A ring that shows two boot banners is a stale first boot plus the newest one;
the tail is the current session.

## Clean-start sequence for a TAG interop run

A TAG interop run needs both roles freshly booted and the TAG RTT ring scoped to
the session only. The verified order (used for the #38 120 s smoke) is:

1. **Halt the initiator** (`nrfutil device halt --serial-number <J-Link>`), then
   drain its J-Link VCOM console (`timeout 3 cat <VCOM1> >/dev/null`) if the
   debug image is in use, so no pre-run lines enter the capture.
2. **Invalidate the TAG RTT ring and hard-reset the TAG while the initiator is
   halted**, using the invalidation from [RTT read-back](#rtt-read-back) followed
   by `nrfutil device reset --serial-number <TAG probe> --reset-kind RESET_HARD`.
   The TAG boots with a fresh ring and advertises.
3. **Flash the initiator and attach its console for the image in use.** The
   flash reset is the initiator's fresh boot; the initiator's IPT
   advertise-name filter then matches the TAG.
   - *Debug-console image:* start the J-Link VCOM1 console capture before
     `west flash`, so the reader is open to catch the banner. The VCOM survives
     the reset.
   - *Standard image:* `west flash` first, wait for the USB device to
     re-enumerate (a changed `devnum`), then attach the console (`-if02`) and
     data (`-if00`) readers immediately, console first and both for the same
     window. The USB console is best-effort (see
     [ADR 0001](adr/0001-native-usb-transport.md)): the #39 gate still captured
     the banner, negotiation, and procedures after the re-attach, but a larger
     pre-enumeration burst can drop early lines.
4. **Capture the data stream for the full window.** With the standard image this
   is the data half of step 3; with the debug image, open the USB data port as
   soon as it re-enumerates (a changed USB device number proves the fresh
   enumeration). The TAG's connection and config creation happen a few seconds
   in.
5. **Read the TAG RTT after the window.** The 32 KiB overwrite ring holds the
   whole session at the reflector's boot/connection-only log rate (the 600 s
   gate used `WrOff=2207` bytes, so it would wrap after roughly 2.5 h); read
   before a longer soak wraps it. An early read is optional (the #38 early and
   late windows were identical).

Resetting the TAG *after* the initiator has connected is the failure mode to
avoid: the link drop makes the initiator reboot on disconnect, which closes its
USB data port and can leave the COBS capture empty. Halt the initiator first.

A pre-run TAG session left in the ring also makes a replay count aborts that
are outside the window. The invalidate+reset in step 2 scopes the ring to the
new session; #44 tracks a pre-run `NO_CS_SYNC_RECEIVED` burst observed before
#38's clean run.

If the console reader outlives the data capture, the first
`Serialize backlog: dropped ...` and `COBS USB: dropped run ...` lines after the
last serialized procedure are the reader-close artifact, not in-window drops.
Cut the console log at that boundary before replay, or stop the console reader
with the data timeout.

## Verification evidence (2026-10-26)

- Target checks: L15-DK SoC `0xDC08B482EFBAC2E7` before seating; TAG
  `0xFFC34F211C2820B8` after. `PART=0x00054B15` in both reads (`nRF54L15`).
- AP: the stock TAG reported `Debug access is currently disabled`; after
  `nrfutil device recover` it reported `Debug access is enabled`,
  `erase protection: false`.
- Flash identity: a `--code` RRAM dump over the probe matches the built
  `zephyr.bin` byte-for-byte over all 260,692 bytes (sha256 `a4fce037…`).
- RTT console: `*** Booting nRF Connect SDK v3.4.0-99553055607b ***`,
  `Starting Mars Channel Sounding Reflector`, SoftDevice Controller revision,
  `Identity: E4:E4:BC:CF:6D:4C (random)`. The build's `_SEGGER_RTT` is at
  `0x20008070`, buffer 0 at `0x20000070`, 32768 bytes.
- Air: a scan discovers `E4:E4:BC:CF:6D:4C Nordic CS IPT Reflector` and no other
  `Nordic CS IPT Reflector`; the L15-DK SoC's former `Nordic CS Reflector`
  decoy is gone after its recovery.

### A1_B2 smoke evidence (#38)

The 120 s smoke of the debug-console initiator against the TAG negotiated A1_B2.
Initiator console:

```text
[00:00:02.353,673] CS capability exchange completed. (peer antennas: 2)
[00:00:02.593,763] CS config creation complete.
 - mode: 2 (PBR)
 - role: Initiator
 - channel_map: 0x1FFFFFFFFFFFFC7FFFFC
[00:00:02.913,662] Local antennas: 1, paths: 4, using config: 4, preferred peer ant.: 3
[00:00:02.913,675] Dynamic timing: step 243 us, 2 paths, 75 steps, subevent 18225 us, interval 33725 us (27 units)
[00:00:03.654,915] CS procedures enabled:
 - antenna configuration index: 4
 - procedure interval: 2
[00:00:03.881,929] Run serialization for procedure 0
```

Controller index 4 is `BT_LE_CS_TONE_ANTENNA_CONFIGURATION_A1_B2`
(`zephyr/include/zephyr/bluetooth/conn.h:2078`); `common/antenna.c` maps one
local and two peer antennas to that selector. The procedure-enable complete
event reports the applied procedure interval 2 for the requested interval 1.

TAG RTT console:

```text
[00:00:10.441,469] Connected to E9:90:A8:55:22:BE (random) (err 0x00)
[00:00:12.523,533] CS capability exchange completed. (peer antennas: 1)
[00:00:12.763,699] CS config creation complete.
 - mode: 2 (PBR)
 - role: Reflector
 - channel_map: 0x1FFFFFFFFFFFFC7FFFFC
[00:00:13.825,163] CS procedures enabled:
 - antenna configuration index: 4
 - procedure interval: 2
```

The window-scoped replay found 3453 event frames among 5180 valid frames, 0
invalid, 1729 serialized procedures, 0 aborts/watchdog/backlog/USB-drop reports
in the window, and a captured COBS stream rate of 3.070 Mbit/s over 120 s.
Captures, capture notes, and the scoped replay are recorded in the #38 evidence
comment. The tone-phase fields in this A1_B2 capture are subject to the
[DRGN-29459 disposition](#drgn-29459-disposition-ncs-v341) below; the
link/framing conclusions are unaffected.

### A1_B2 600 s gate evidence (#39)

The measured gate used the standard A1/4 interval-1 USB image
(`initiator/build_nrf54lm20dk_usb_cent_a1_4_ipt_interval1`, hex
`f1a7b91d…`, bin `57d6e65f…`) against the TAG at sibling `c2253fe` (FICR
`0xFFC34F211C2820B8` on probe `001057759725`, bin `a4fce037…`, the image
verified over the probe in #36). The initiator was flashed fresh (`west flash`
exit 0; USB `devnum` 45 → 46), and the TAG RTT ring was invalidated and
hard-reset while the initiator was halted. A 12 s scan then found exactly one
`Nordic CS IPT Reflector` advertiser (`E4:E4:BC:CF:6D:4C`) before the
initiator was flashed. The TAG build configuration is in
[Firmware provenance](#firmware-provenance); the initiator's composition and
Kconfig are in [docs/build-from-source.md](build-from-source.md).

The standard image has its console on the native-USB CDC ACM `-if02` function
(see clean-start step 3), so the console and data readers were attached
immediately after re-enumeration with the same 600 s window, console first. The
console therefore ends just before the data reader, and no reader-close
artifact enters the capture. The re-attach still captured the boot banner, the
negotiation, and the procedures; the console remains best-effort
([ADR 0001](adr/0001-native-usb-transport.md)).

Initiator console:

```text
*** Booting nRF Connect SDK v3.4.0-99553055607b ***
*** Using Zephyr OS v4.4.0-b78f455b4053 ***
[00:00:00.012,973] Starting Mars Channel Sounding Initiator
[00:00:00.158,629] Filters matched. Address: E4:E4:BC:CF:6D:4C (random) connectable: 1
[00:00:00.264,010] Connected to E4:E4:BC:CF:6D:4C (random) (err 0x00)
[00:00:02.345,535] CS capability exchange completed. (peer antennas: 2)
[00:00:02.585,625] CS config creation complete.
 - mode: 2 (PBR)
 - role: Initiator
 - channel_map: 0x1FFFFFFFFFFFFC7FFFFC
[00:00:02.905,526] Local antennas: 1, paths: 4, using config: 4, preferred peer ant.: 3
[00:00:02.905,539] Dynamic timing: step 243 us, 2 paths, 75 steps, subevent 18225 us, interval 33725 us (27 units)
[00:00:03.646,778] CS procedures enabled:
 - antenna configuration index: 4
 - procedure interval: 2
[00:00:03.873,794] Run serialization for procedure 0
```

TAG RTT console:

```text
[00:00:23.432,012] Connected to E9:90:A8:55:22:BE (random) (err 0x00)
[00:00:25.514,075] CS capability exchange completed. (peer antennas: 1)
[00:00:25.754,241] CS config creation complete.
 - mode: 2 (PBR)
 - role: Reflector
 - channel_map: 0x1FFFFFFFFFFFFC7FFFFC
[00:00:26.815,706] CS procedures enabled:
 - antenna configuration index: 4
 - procedure interval: 2
```

The replay (`scripts/two-dk-bench.sh --mode ipt --analyze-dir <capture>`)
returned `RESULT: PASS (replay; not live evidence)` and passed all eight replay
assertions: 8,839 serialized procedures, 26,519 valid COBS frames (17,679 event
+ 8,840 log, 0 invalid), 0 empty-procedure signatures, 0 reflector aborts, 0
watchdog recoveries on either side, 0 serialize/diagnostic backlog reports, and
0 USB transport drops. The 13,320-byte leading segment decodes as a canonical
tag-0 event frame but is counted as a leading partial, so the true event count
is 17,680. The TAG RTT ring was linear, `WrOff=2207` of 32,768 bytes, so the
32 KiB overwrite buffer held the whole session. The initiator's native-USB link
was 480 Mbit/s at the end of the run (sysfs); the live link-speed/identity
assertions do not run under `--analyze-dir`, so that check is recorded here
separately from the replay.

The captured COBS stream rate was **392,836.6 B/s = 3.143 Mbit/s** over 600 s,
3.30 % below the 3.250 Mbit/s A1_B1 interval-1 reference and 3.76 % below the
#37 A1_B1 re-baseline (3.265 Mbit/s). The difference is cadence, not payload
size: 8,839 procedures in 600 s (14.73/s) versus 9,183 (15.31/s) in #37, at
26,666 bytes/procedure versus 26,669. A1_B2 negotiates two tone paths against
the TAG's two antennas (`subevent 18225 us`) where A1_B1 uses one. The rate is
reported, not hard-gated, because the TAG run is not config-matched to the
A1_B1 reference.

Capture: `/tmp/cs39-tag-gate-20261026-205400`
(`initiator-console.log`, `initiator-cobs.bin`, `reflector-console.log` from
the TAG RTT read, `capture-info.txt`, `capture-notes.txt`,
`harness-replay-summary.txt`; `initiator-cobs.bin` sha256 `04f0d20d…`). The
full evidence write-up is in the #39 issue.

Residual risks: the interop claim is link, procedure, and framing only — the
COBS check is framing/length based, not a postcard payload decode, and no
PCT/range semantics were validated; the TAG firmware is the bench-only sibling
build (`c2253fe` plus `bench/nrf54l15tag_rtt_bench.conf`), not a release image;
the standard initiator image is a manual build, not a CI preset; the initiator
USB console is best-effort ([ADR 0001](adr/0001-native-usb-transport.md)), so a
later attach can lose the pre-enumeration lines (this run captured them); the
TAG console is a post-run RTT read, so a ring wrap would lose the earliest
lines (not observed in this run); and one host/OS configuration was measured.
The tone-phase fields in this A1_B2 capture are subject to the
[DRGN-29459 disposition](#drgn-29459-disposition-ncs-v341) below; the
link/framing/rate conclusions are unaffected.

## DRGN-29459 disposition (NCS v3.4.1)

DRGN-29459 (SoftDevice Controller) — fixed in NCS v3.4.1 — corrected a CS
Reflector that shifted the CS tone phase incorrectly when IPT was used with
multiple antenna paths. This section records which of the bench runs above
match that combination and what each result may still be used for; the audit
is tracked in
[#53](https://github.com/Metirionic/mars-cs-nrf54lm/issues/53).

**Audit criterion.** The ticket's criterion is the **reflector** role, **IPT**,
and **more than one negotiated antenna path**. Configured path capacity is not
the negotiated count: `CONFIG_BT_CTLR_SDC_CS_MAX_ANTENNA_PATHS` sets the
controller's maximum, while the paths used follow the tone-antenna
configuration selected in the procedure (the `nrfxlib` SoftDevice Controller
Kconfig help says so explicitly). The TAG has two antennas; the LM20 DK has
one.

The SDK changelog describes DRGN-29459 only as IPT "with multiple antenna
paths" and does not say whether the trigger is the negotiated count or merely
multi-path support being **configured**. The table lists both. If the trigger
is configured capacity, the #41/#52 **IPT** runs (an `a1_4` reflector with
`MAX_ANTENNA_PATHS=4` but `NUM_ANTENNAS=1`) are also in scope for phase data;
their published conclusions and the disposition below do not change.

| Ticket | Run | Reflector | Mode | Configured paths (init / refl) | Antennas (init / refl) | Negotiated paths | Affected |
|--------|-----|-----------|------|-------------------------------|------------------------|------------------|----------|
| #20 | VCOM/USB gate | LM20, `a1_1` image | RAS/IPT | 1 / 1 | 1 / 1 | `A1_B1` (1) | no |
| #35 | Bring-up smoke | LM20, `a1_1` image | IPT | 4 / 1 | 1 / 1 | `A1_B1` (1) | no |
| #37 | LM20 re-baseline | LM20, `a1_1` image | IPT | 4 / 1 | 1 / 1 | `A1_B1` (1) | no |
| #38 | TAG smoke | nRF54L15 TAG, pre-v3.4.1 image | IPT | 4 / 4 | 1 / 2 | `A1_B2` (2) | **yes** |
| #39 | TAG 600 s gate | nRF54L15 TAG, pre-v3.4.1 image | IPT | 4 / 4 | 1 / 2 | `A1_B2` (2) | **yes** |
| #41 | v0.8.0 released-image gate | LM20, `a1_4` image | RAS/IPT | 4 / 4 | 1 / 1 | `A1_B1` (1) | no\* |
| #44 | TAG abort triage | nRF54L15 TAG, pre-v3.4.1 image | IPT | 4 / 4 | 1 / 2 | `A1_B2` (2) | **yes**, diagnostic only |
| #51 | v3.4.1 smoke | nRF54L15 TAG, pre-v3.4.1 image | IPT | 4 / 4 | 1 / 2 | `A1_B2` (2) | **yes** |
| #52 | v0.8.1 released-image gate | LM20, `a1_4` image | RAS/IPT | 4 / 4 | 1 / 1 | `A1_B1` (1) | no\* |

Configured paths are `CONFIG_BT_CTLR_SDC_CS_MAX_ANTENNA_PATHS`; antennas are
`CONFIG_BT_CTLR_SDC_CS_NUM_ANTENNAS`; the negotiated count is the `An_Bm` tone
configuration selected in the procedure. An `a1_4` preset is one antenna with
four-path capability, so #41/#52 configure four paths on each side yet
negotiate `A1_B1` because each peer advertises one antenna.

\* By the negotiated-path criterion. Under the configured-capacity reading
above, the #41/#52 **IPT** runs join the phase-data caveat; their published
conclusions are unchanged.

**What stands.** The published conclusions from the affected runs are link
establishment, the capability exchange, `A1_B2` negotiation, procedure
completion, COBS framing, wire rate/cadence, and per-procedure payload size.
The defect changes tone-phase values, not frame structure, lengths, counters, or
scheduling, so those conclusions stand. No published result analyzes tone phase,
PCT, range, or angle from these captures; the #39 residual risks above already
record that no PCT/range semantics were validated. The payload-size comparison
in [hardware.md](hardware.md#antenna-path-policy) (26,666 versus 26,669
bytes/procedure) and the same figure in the v0.8.0 release notes rely on the
`A1_B2` run for a framing/length result only.

**What does not.** The raw `initiator-cobs.bin` captures from the affected runs
must not be used for phase, PCT, range, or angle analysis. Under the
configured-capacity reading, the #41/#52 **IPT** captures join that caveat. In
IPT the reflector's phase contribution is embedded in the initiator's local
tones ([architecture.md](architecture.md#ranging-data-flow)), and the reflector
firmware in the TAG runs was the sibling `mars-cs-nrf54l` `c2253fe` build made
before the v3.4.1 pin. The #51 smoke moved only the initiator to v3.4.1; its
TAG reflector was still that pre-v3.4.1 build.

**Re-measurement.** None is required for the published conclusions above. A
future phase/PCT/range measurement on this bench must first rebuild the TAG
reflector on NCS v3.4.1 (in the sibling repository) and repeat the `A1_B2`
capture; do not mix historical and corrected captures. The sibling repository
owns its own TAG-side measurements and should record its own disposition.

The captured console output in the sections above is unchanged; this note is
the only added disposition.

## References

- [docs/hardware.md](hardware.md) — the nRF54LM20-DK board contract and wiring.
- [docs/build-from-source.md](build-from-source.md) — toolchain and build flow.
- [bench/nrf54l15tag_rtt_bench.conf](../bench/nrf54l15tag_rtt_bench.conf) — the
  exact bench-only RTT logging fragment.
- [scripts/read-tag-rtt.py](../scripts/read-tag-rtt.py) — the RTT read-back tool.
- [nRF Connect SDK v3.4.1 SoftDevice Controller changelog](https://github.com/nrfconnect/sdk-nrfxlib/blob/v3.4.1/softdevice_controller/CHANGELOG.rst) —
  the DRGN-29459 entry.
- [Metirionic/mars-cs-nrf54l](https://github.com/Metirionic/mars-cs-nrf54l) — the
  sibling firmware repository.
- [nRF54L15 TAG board documentation](https://docs.nordicsemi.com/bundle/ncs-latest/page/zephyr/boards/nordic/nrf54l15tag/doc/index.html) —
  Nordic's TAG programming and power guidance.
