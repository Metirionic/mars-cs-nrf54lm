# Build from source

This guide is for developers and contributors building the firmware from
source — the counterpart to [docs/flash-quickstart.md](flash-quickstart.md),
which covers flashing prebuilt firmware with no build step. For the board
support contract and the antenna/path reference, see
[docs/hardware.md](hardware.md).

## What you need

The native path targets a Debian/Ubuntu host. The install codifier (next
section) provisions the packages below automatically, so you do not normally
install them by hand — they are listed here so a non-Debian host or a fully
manual install knows what is required:

```bash
sudo apt-get install -y --no-install-recommends \
  build-essential cmake gperf wget ninja-build device-tree-compiler dfu-util \
  git python3 python3-venv curl ca-certificates
```

## Install the toolchain (native path)

From a fresh clone, run the install codifier from the repo root:

```bash
git clone https://github.com/Metirionic/mars-cs-nrf54lm.git
cd mars-cs-nrf54lm
bash scripts/install-toolchain.sh --with-rust
```

This guide **references**
[scripts/install-toolchain.sh](../scripts/install-toolchain.sh) rather than
duplicating its steps — that script is the single source of truth for the
install. One idempotent invocation hides the entire native toolchain:
host apt packages → an isolated Python venv (`~/.ncs-venv`) → the west
workspace → the Zephyr/NCS pip requirements → the Zephyr SDK (ARM-only; version
auto-detected from `zephyr/SDK_VERSION`, 1.0.1 for NCS v3.4.0) → and, with
`--with-rust`, the `thumbv8m.main-none-eabihf` target.

Every stage guards on existing state, so the script is safe to re-run on an
already-installed venv, workspace, or SDK, or to resume after a partial
failure. Pass `--with-rust` for the initiator (the Rust COBS-serializer
bridge); the reflector-only slice omits the flag. The
`nrfutil toolchain-manager` path is intentionally not used — the pip-distributed
legacy `nrfutil` is broken on Python 3.12.

After install, activate the venv before building (the script's final log prints
this):

```bash
source ~/.ncs-venv/bin/activate
```

The `onboarding-verification` CI job runs this exact command (with
`--with-rust`) from a clean `ubuntu:24.04` container on every pull request and
builds **both** the reflector and the initiator, so the documented native
install path — including the initiator's Rust COBS-serializer build — cannot
silently drift.

## Where the install lands (workspace layout)

The script runs `west init -l . --mf west.yml` from the repo root. With the
`-l` (local manifest) flag, west creates `.west/` and clones the NCS source
tree (`nrf/`, `zephyr/`, `nrfxlib/`, `modules/`, `bootloader/`, `test/`,
`tools/`) in the **parent** of the repo, not inside it — the workspace root is
hardcoded to the manifest directory's parent. Because those checkouts land
outside the repo, `git status` stays clean (`.west/` is gitignored).

The toolchain, the workspace source, and the venv are three separate things on
disk — do not conflate them:

| Thing | Location | Installed by |
|-------|----------|--------------|
| Repo (the manifest / `self` project) | `<parent>/mars-cs-nrf54lm/` | `git clone` |
| `.west/` + NCS source (`nrf/`, `zephyr/`, …) | the repo's **parent** dir, outside the repo | `west init -l .` + `west update` |
| Zephyr SDK toolchain (ARM-only) | `~/zephyr-sdk-1.0.1/`, outside both | `west sdk install` |
| Isolated Python venv | `~/.ncs-venv/` | the install codifier |

## Build the firmware

Activate the venv and build a preset the same way CI does. The nRF54LM20-DK
defines four RAS and four IPT presets — J-Link VCOM and native USB for each
role (see the [preset table](hardware.md#presets)):

```bash
source ~/.ncs-venv/bin/activate

# RAS pair
bash ci/build.sh --target initiator --preset nrf54lm20dk_cent_a1_4
bash ci/build.sh --target reflector --preset nrf54lm20dk_peri_a1_4

# IPT pair
bash ci/build.sh --target initiator --preset nrf54lm20dk_cent_a1_4_ipt
bash ci/build.sh --target reflector --preset nrf54lm20dk_peri_a1_4_ipt
```

Channel Sounding needs **both** an initiator and a reflector, so build a
matched pair (one of each, same mode). The two modes use different BLE
discovery and do not pair with each other.

`ci/build.sh` finds the west workspace automatically: it checks `NCS_DIR` (if
set), then `/opt/nordic/ncs/current` (the nrfutil toolchain-manager NCS), then
falls back to `west topdir` — the current directory's workspace root. So no
prefix is needed when run from inside a west workspace (e.g. the repo root,
which is the manifest project *inside* the workspace — west walks up to the
parent's `.west/`). An explicit `NCS_DIR` still overrides both fallbacks.

If you drive `west build` by hand for a preset build instead, pass the same
`CONF_FILE`, `EXTRA_CONF_FILE`, and `DTC_OVERLAY_FILE` values the preset
carries, and use a preset-specific `-d` build directory. The preset-less bench
builds below — the interval-1 cadence override, the non-release debug variant,
and the A1 4-path interop images — are deliberate exceptions. A bare
`west build` (no `-d`) uses a single `./build/` and the two apps collide:

```
Build directory "<build_dir>" is for application "<cached_app_dir>", but source
directory "<new_app_dir>" was specified; please clean it, use --pristine, or
use --build-dir to set another build directory
```

### Bench cadence override (procedure interval)

The initiator's CS procedure cadence is set at build time by
`CONFIG_MARS_CS_PROCEDURE_INTERVAL` (`initiator/Kconfig`), which feeds both the
minimum and maximum procedure interval handed to the controller. It defaults
to `10`, so the commands above need no extra flags.

The bench's transport-headroom run builds it at `1` — requesting one procedure
per connection event — so the COBS transport, rather than the procedure
scheduler, is the limiting factor. The controller applies its own minimum
(the SDC on the nRF54LM20-DK reports `procedure interval: 2`), which still
tightens the cadence about fivefold against the default. Build it into a
separate build directory so the preset build stays at the default:

```bash
west build -p always -d initiator/build_nrf54lm20dk_cent_a1_4_interval1 \
  -b nrf54lm20dk/nrf54lm20a/cpuapp initiator -- \
  -DCONF_FILE=prj.conf \
  -DEXTRA_CONF_FILE="central.overlay;../boards/4_path_1_local.conf" \
  -DDTC_OVERLAY_FILE=../boards/nrf54lm20dk_nrf54lm20a_cpuapp.overlay \
  -DCONFIG_MARS_CS_PROCEDURE_INTERVAL=1
```

Confirm the override landed in the generated configuration
(`initiator/build_nrf54lm20dk_cent_a1_4_interval1/initiator/zephyr/.config`
contains `CONFIG_MARS_CS_PROCEDURE_INTERVAL=1`). The initiator console then
reports the controller's applied interval when CS procedures are enabled
(`procedure interval: 2` on the DK, versus `10` at the default). This is a
bench lever only — there is no runtime command surface, and release builds
keep the default.

### Non-release USB debug console (J-Link VCOM)

For bring-up, the native USB initiator can keep its COBS stream on the USB data
function while moving the log console back to the DK's J-Link VCOM1. Boot,
pre-enumeration, and hard-fault output then stay visible when USB has not
enumerated. This posture is deliberately **not** a release preset: CI and the
release workflow enumerate every preset via `ci/list-presets.sh`, so a debug
preset would be built and shipped. Build it only with this manual command:

```bash
west build -p always -d initiator/build_nrf54lm20dk_usb_cent_a1_4_debug \
  -b nrf54lm20dk/nrf54lm20a/cpuapp initiator -- \
  -DCONF_FILE=prj.conf \
  -DEXTRA_CONF_FILE="central.overlay;../boards/nrf54lm20dk_usb_initiator.conf;../boards/nrf54lm20dk_usb_initiator_debug.conf;../boards/4_path_1_local.conf" \
  -DDTC_OVERLAY_FILE="../boards/nrf54lm20dk_nrf54lm20a_cpuapp_usb_initiator.overlay;../boards/nrf54lm20dk_nrf54lm20a_cpuapp_usb_initiator_debug.overlay"
```

The overlay order is load-bearing: the debug overlay is applied **after** the
USB initiator overlay and re-points the console chosen nodes at `uart20`
(VCOM1, 115200 baud), while `cobs-uart` stays on the CDC ACM data function.
Open the J-Link VCOM1 for logs and the native USB data function (`if00`) for
the COBS stream. The USB console function (`if02`) remains enumerated but
carries no log output in this variant.

The debug overlay and fragment are mode-independent. For an IPT debug build,
put `inline_pct_initiator.conf` and `inline_pct_shared.conf` after
`central.overlay` and before the USB fragments, exactly as the `_ipt` preset
does.

Confirm the posture in the generated configuration
(`initiator/build_nrf54lm20dk_usb_cent_a1_4_debug/initiator/zephyr/.config`):

```text
CONFIG_MARS_CS_TRANSPORT_USB=y
CONFIG_MARS_CS_ROLE_INITIATOR=y
CONFIG_MARS_CS_USB_DEBUG_CONSOLE_VCOM=y
```

This image is not built by CI and is never part of
`cs-ranging-firmware.zip`. Do not add it to `CMakePresets.json`.

### Bench images for the A1 4-path IPT interop run (interval 1)

The interop run uses two non-release initiator images: a standard native-USB
image for the measured run and a debug-console image for bring-up. Both are IPT
builds on the native USB transport with the one-antenna/four-path fragment
(`boards/4_path_1_local.conf`), and both request procedure interval 1. Neither
is a preset: CI and the release workflow build every preset via
`ci/list-presets.sh`, so these postures stay manual.

Standard image:

```bash
west build -p always -d initiator/build_nrf54lm20dk_usb_cent_a1_4_ipt_interval1 \
  -b nrf54lm20dk/nrf54lm20a/cpuapp initiator -- \
  -DCONF_FILE=prj.conf \
  -DEXTRA_CONF_FILE="central.overlay;../boards/inline_pct_initiator.conf;../boards/inline_pct_shared.conf;../boards/nrf54lm20dk_usb_initiator.conf;../boards/4_path_1_local.conf" \
  -DDTC_OVERLAY_FILE=../boards/nrf54lm20dk_nrf54lm20a_cpuapp_usb_initiator.overlay \
  -DCONFIG_MARS_CS_PROCEDURE_INTERVAL=1
```

Debug-console image — the debug overlay goes after the USB overlay and the
debug fragment after the USB fragment, as in
[Non-release USB debug console (J-Link VCOM)](#non-release-usb-debug-console-j-link-vcom):

```bash
west build -p always -d initiator/build_nrf54lm20dk_usb_cent_a1_4_ipt_interval1_debug \
  -b nrf54lm20dk/nrf54lm20a/cpuapp initiator -- \
  -DCONF_FILE=prj.conf \
  -DEXTRA_CONF_FILE="central.overlay;../boards/inline_pct_initiator.conf;../boards/inline_pct_shared.conf;../boards/nrf54lm20dk_usb_initiator.conf;../boards/nrf54lm20dk_usb_initiator_debug.conf;../boards/4_path_1_local.conf" \
  -DDTC_OVERLAY_FILE="../boards/nrf54lm20dk_nrf54lm20a_cpuapp_usb_initiator.overlay;../boards/nrf54lm20dk_nrf54lm20a_cpuapp_usb_initiator_debug.overlay" \
  -DCONFIG_MARS_CS_PROCEDURE_INTERVAL=1
```

Both generated configurations
(`initiator/build_<name>/initiator/zephyr/.config`, where `<name>` is one of the
two build directories above) show:

```text
CONFIG_MARS_CS_TRANSPORT_USB=y
CONFIG_MARS_CS_ROLE_INITIATOR=y
CONFIG_MARS_CS_INLINE_PCT=y
CONFIG_MARS_CS_PROCEDURE_INTERVAL=1
CONFIG_BT_CTLR_SDC_CS_MAX_ANTENNA_PATHS=4
CONFIG_BT_CTLR_SDC_CS_NUM_ANTENNAS=1
```

The debug image additionally shows `CONFIG_MARS_CS_USB_DEBUG_CONSOLE_VCOM=y`
and routes every console chosen node to `&uart20` (J-Link VCOM1, 115200 baud)
while `cobs-uart` stays on `&cdc_data`; the standard image keeps
`zephyr,console` on `&cdc_console` and disables both UARTs. See
[Device and host interface](hardware.md#device-and-host-interface) for the
function mapping.

The four-path maximum is a controller capability, not a claim of four physical
antennas: the DK has one antenna (`CONFIG_BT_CTLR_SDC_CS_NUM_ANTENNAS=1`), and
the capability is what lets it accept a two-antenna peer's `A1_B2` tone
configuration. The
fragment's `CONFIG_BT_RAS_MAX_ANTENNA_PATHS=4` is dropped with a Kconfig warning
because IPT mode sets `CONFIG_BT_RAS=n`, and
`CONFIG_BT_CS_DE_MAX_NUM_ANTENNA_PATHS` is not set by the fragment and stays at
its default of 1; the controller symbol governs the CS capability exchange.
See [Antenna and path presets](hardware.md#antenna-and-path-presets).

The two builds linked with about 272 KiB of SRAM headroom: the standard image
used 244,332 B of the 511 KiB RAM region (46.69 %) and the debug image
244,396 B (46.71 %). The images are
`initiator/build_<name>/initiator/zephyr/zephyr.hex`; neither is built by CI or
included in `cs-ranging-firmware.zip`.

### Multiple presets (driven like CI)

`--preset` accepts a comma-separated list, and `--release-dir` collects each
merged `.hex` into a flat output directory. CI and the release workflow have
no hand-maintained preset lists: they enumerate every preset in each
`CMakePresets.json` via `ci/list-presets.sh`. The same command works locally:

```bash
bash ci/build.sh --target initiator \
  --preset "$(bash ci/list-presets.sh initiator)" --release-dir release
bash ci/build.sh --target reflector \
  --preset "$(bash ci/list-presets.sh reflector)" --release-dir release
```

`ci/list-presets.sh` prints the comma-separated preset names for a role. In
`ci.yml`, each role's build job is skipped independently when that role has no
presets. The release workflow is stricter: its build job requires a non-zero
preset count for **both** roles, so a role with no presets skips the whole
release build. Passing an empty `--preset` to `ci/build.sh` is rejected.

## Reproduce CI exactly (Docker, zero local install)

To debug a CI failure with byte-for-byte CI parity and **no local install**,
build inside the same toolchain image the CI workflows use:

```
ghcr.io/nrfconnect/sdk-nrf-toolchain:v3.4.0
```

Start a shell in the image with the repo mounted and run the CI steps. Two
image quirks need handling: the entrypoint is `bash -c`, so pass
`--entrypoint /bin/bash` to run a script with `-lc`; and the mounted volume is
owned by the host, so set `git config --global --add safe.directory` before any
`git` or `west` call. The image ships no Rust and no `curl` (CI installs Rust
via an Action and `apt-get install curl`), so fetch the rustup installer with
`wget` and add the `thumbv8m.main-none-eabihf` target for the initiator. The
script also removes any pre-existing build directories — caches from a native
build reference host paths the container cannot see. Then run the same two
`ci/build.sh` invocations as CI:

```bash
docker run --rm -it --entrypoint /bin/bash -v "$PWD":/work -w /work \
  ghcr.io/nrfconnect/sdk-nrf-toolchain:v3.4.0 -lc '
    git config --global --add safe.directory /work
    west init -l . --mf west.yml
    west update -o=--depth=1 -n
    # remove any pre-existing build dirs: the container configures against its
    # own NCS checkout and cannot reuse build caches that reference host paths
    rm -rf initiator/build_* reflector/build_*
    # initiator only: the image ships no Rust and no curl — fetch the rustup
    # installer with wget, then add the ARM target
    wget -qO- https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
    rustup target add thumbv8m.main-none-eabihf
    NCS_DIR=$(pwd) bash ci/build.sh --target initiator --preset "$(bash ci/list-presets.sh initiator)"
    NCS_DIR=$(pwd) bash ci/build.sh --target reflector --preset "$(bash ci/list-presets.sh reflector)"
  '
```

Both paths are CI-verified — the native path by `onboarding-verification` (a
clean `ubuntu:24.04` container), the Docker path by the `build-initiator` /
`build-reflector` and `release` jobs. The Docker image is the secondary path;
for day-to-day work and `west flash`, prefer the native install above.

## Flash your build

Once a build completes, flash it over the DK's on-board J-Link. Each preset
builds into its own directory (`initiator/build_<preset>`), so point
`west flash` at the build directory you want to flash:

```bash
west flash -d initiator/build_nrf54lm20dk_cent_a1_4      # initiator, RAS
west flash -d reflector/build_nrf54lm20dk_peri_a1_4      # reflector, RAS
```

For an IPT pair, use the `_ipt` build directories:
`initiator/build_nrf54lm20dk_cent_a1_4_ipt` and
`reflector/build_nrf54lm20dk_peri_a1_4_ipt`.

For flashing **prebuilt** firmware with no build step, see
[docs/flash-quickstart.md](flash-quickstart.md).

## Out of scope

- A generated documentation site (Sphinx/MkDocs) — docs stay plain Markdown.
- The `nrfutil toolchain-manager` native path (broken on Python 3.12).
- Prebuilt flashing and reading the COBS UART — see
  [docs/flash-quickstart.md](flash-quickstart.md).
- The board, preset, and antenna/path reference — see
  [docs/hardware.md](hardware.md).
- The firmware architecture and ranging-data flow — see
  [docs/architecture.md](architecture.md).
- The commit convention and pre-commit hooks — see
  [docs/contributing.md](contributing.md).

## References

- [README](../README.md) — project overview and firmware variants.
- [docs/flash-quickstart.md](flash-quickstart.md) — flashing prebuilt firmware
  and reading the COBS ranging output.
- [docs/hardware.md](hardware.md) — the board support contract and preset
  reference.
- [docs/architecture.md](architecture.md) — module map and ranging-data flow.
- [docs/contributing.md](contributing.md) — commit convention, hooks, and PR flow.
- [scripts/install-toolchain.sh](../scripts/install-toolchain.sh) — the install codifier.
- [ci/build.sh](../ci/build.sh) and [ci/common.sh](../ci/common.sh) — the build wrapper.
- [ci/list-presets.sh](../ci/list-presets.sh) — preset enumeration for CI/release.
- [.github/workflows/ci.yml](../.github/workflows/ci.yml) — `onboarding-verification`
  (native) and `build-initiator` / `build-reflector` (Docker).
- [.github/workflows/release.yml](../.github/workflows/release.yml) — the
  multi-preset release build (Docker).
- [west.yml](../west.yml) — pins NCS v3.4.0 (`nrf` / sdk-nrf @ v3.4.0, `import: true`).
- [nRF Connect SDK v3.4.0](https://developer.nordicsemi.com/nRF_Connect_SDK/)
  and Zephyr SDK 1.0.1.
