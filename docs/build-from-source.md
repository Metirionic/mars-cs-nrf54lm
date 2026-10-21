# Build from source

This guide is for developers and contributors building the firmware from
source — the counterpart to [docs/flash-quickstart.md](flash-quickstart.md),
which covers flashing prebuilt firmware with no build step. For the board
support contract and the antenna/path reference, see
[docs/hardware.md](hardware.md).

> **No board presets yet.** The build system is complete, but
> `initiator/CMakePresets.json` and `reflector/CMakePresets.json` are empty
> until the first development board lands. The commands below use a
> `<preset>` placeholder; see [boards/README.md](../boards/README.md) for what
> a board support change adds.

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
builds **both** the reflector and the initiator once board presets exist, so
the documented native install path — including the initiator's Rust
COBS-serializer build — cannot silently drift.

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

Activate the venv and build an app the same way CI does:

```bash
source ~/.ncs-venv/bin/activate

# Once the first board lands, <preset> is a name from
# initiator/CMakePresets.json or reflector/CMakePresets.json.
bash ci/build.sh --target initiator --preset <preset>
bash ci/build.sh --target reflector --preset <preset>
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

If you drive `west build` by hand instead, pass the same `CONF_FILE`,
`EXTRA_CONF_FILE`, and `DTC_OVERLAY_FILE` values the preset carries, and use a
preset-specific `-d` build directory. A bare `west build` (no `-d`) uses a
single `./build/` and the two apps collide:

```
Build directory "<build_dir>" is for application "<cached_app_dir>", but source
directory "<new_app_dir>" was specified; please clean it, use --pristine, or
use --build-dir to set another build directory
```

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

With no presets defined yet, `ci/list-presets.sh` prints nothing; the CI and
release workflows gate their build jobs on a non-zero preset count, so they
are skipped until the first board support change lands. Passing an empty
`--preset` to `ci/build.sh` is rejected.

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

Both paths are CI-verified once presets exist — the native path by
`onboarding-verification` (a clean `ubuntu:24.04` container), the Docker path
by the `build-initiator` / `build-reflector` and `release` jobs. The Docker
image is the secondary path; for day-to-day work and `west flash`, prefer the
native install above.

## Flash your build

Once a build completes, flash it to a board over the board's debug probe. Each
preset builds into its own directory (`initiator/build_<preset>`), so point
`west flash` at the build directory you want to flash:

```bash
west flash -d initiator/build_<preset>      # initiator
west flash -d reflector/build_<preset>      # reflector
```

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
