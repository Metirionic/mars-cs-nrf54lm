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

## References

- [docs/hardware.md](hardware.md) — the nRF54LM20-DK board contract and wiring.
- [docs/build-from-source.md](build-from-source.md) — toolchain and build flow.
- [bench/nrf54l15tag_rtt_bench.conf](../bench/nrf54l15tag_rtt_bench.conf) — the
  exact bench-only RTT logging fragment.
- [scripts/read-tag-rtt.py](../scripts/read-tag-rtt.py) — the RTT read-back tool.
- [Metirionic/mars-cs-nrf54l](https://github.com/Metirionic/mars-cs-nrf54l) — the
  sibling firmware repository.
- [nRF54L15 TAG board documentation](https://docs.nordicsemi.com/bundle/ncs-latest/page/zephyr/boards/nordic/nrf54l15tag/doc/index.html) —
  Nordic's TAG programming and power guidance.
