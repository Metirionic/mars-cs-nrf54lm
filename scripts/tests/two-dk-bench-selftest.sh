#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Offline tests for scripts/two-dk-bench.sh.
#
# The repository has no unit-test framework, so these tests exercise the
# harness at its public CLI boundary:
#   - argument validation and --help (no hardware);
#   - /dev/serial/by-id port resolution through --dry-run against a fake by-id
#     tree;
#   - the offline replay path (--analyze-dir) against synthetic console logs
#     and COBS frames.
#
# The live two-DK smoke run is not reproducible without the bench; it is
# deferred to the bench-gate ticket.
#
# Run: bash scripts/tests/two-dk-bench-selftest.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS="${REPO_ROOT}/scripts/two-dk-bench.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

PASSED=0
FAILED=0
LAST_OUTPUT=""

pass() { PASSED=$((PASSED + 1)); printf '[PASS] %s\n' "$1"; }

fail() {
  FAILED=$((FAILED + 1))
  printf '[FAIL] %s\n' "$1"
}

# expect_status <expected> <name> <command...>
# Runs the command, records combined output in LAST_OUTPUT, and checks the
# exit status.
expect_status() {
  local expected="$1" name="$2" status
  shift 2
  LAST_OUTPUT="$("$@" 2>&1)"
  status=$?
  if [[ "${status}" -eq "${expected}" ]]; then
    pass "${name}"
  else
    fail "${name} (expected exit ${expected}, got ${status})"
    printf '%s\n' "${LAST_OUTPUT}" | sed 's/^/       /'
  fi
}

# expect_contains <name> <needle>
expect_contains() {
  if [[ "${LAST_OUTPUT}" == *"$2"* ]]; then
    pass "$1"
  else
    fail "$1 (output missing '$2')"
    printf '%s\n' "${LAST_OUTPUT}" | sed 's/^/       /'
  fi
}

# expect_lacks <name> <needle>
expect_lacks() {
  if [[ "${LAST_OUTPUT}" != *"$2"* ]]; then
    pass "$1"
  else
    fail "$1 (output unexpectedly contains '$2')"
  fi
}

# --- syntax and CLI contract ------------------------------------------------

expect_status 0 "harness passes bash -n" bash -n "${HARNESS}"

expect_status 0 "--help exits 0" "${HARNESS}" --help
for flag in --initiator --reflector --mode --duration --analyze-dir --dry-run \
  --transport --attach-after --stall-after; do
  expect_contains "--help documents ${flag}" "${flag}"
done

if grep -Eq '[0-9]{12}' "${HARNESS}"; then
  # The bench serials are 12 digits; none may be baked into the harness.
  fail "harness has no hard-coded 12-digit bench serial"
else
  pass "harness has no hard-coded 12-digit bench serial"
fi

expect_status 2 "no arguments is a usage error" "${HARNESS}"
expect_contains "missing --initiator is reported" "--initiator"
expect_status 2 "missing --reflector is a usage error" \
  "${HARNESS}" --initiator FAKE --mode ras --duration 5
expect_contains "missing --reflector is reported" "--reflector"
expect_status 2 "missing --mode is a usage error" \
  "${HARNESS}" --initiator FAKE --reflector FAKE2 --duration 5
expect_contains "missing --mode is reported" "--mode"
expect_status 2 "missing --duration is a usage error" \
  "${HARNESS}" --initiator FAKE --reflector FAKE2 --mode ras
expect_contains "missing --duration is reported" "--duration"

expect_status 2 "unknown option is a usage error" \
  "${HARNESS}" --initiator FAKE --reflector FAKE2 --mode ras --duration 5 --bogus
expect_status 2 "unknown mode is a usage error" \
  "${HARNESS}" --initiator FAKE --reflector FAKE2 --mode fsk --duration 5
expect_contains "invalid mode reports the accepted modes" \
  "--mode must be 'ras' or 'ipt'"

expect_status 2 "unknown transport is a usage error" \
  "${HARNESS}" --initiator FAKE --reflector FAKE2 --mode ras --duration 5 \
  --transport fsk
expect_contains "invalid transport reports the accepted values" \
  "--transport must be 'vcom' or 'usb'"
expect_status 2 "missing --transport value is a usage error" \
  "${HARNESS}" --initiator FAKE --reflector FAKE2 --mode ras --duration 5 \
  --transport

for duration in 0 00 -1 abc 1.5 "" 86401 999999 18446744073709551617; do
  expect_status 2 "duration '${duration}' is a usage error" \
    "${HARNESS}" --initiator FAKE --reflector FAKE2 --mode ras --duration "${duration}"
done

for offset in 0 -1 abc 1.5 3 86400; do
  expect_status 2 "--attach-after '${offset}' is a usage error" \
    "${HARNESS}" --initiator FAKE --reflector FAKE2 --mode ras --duration 3 \
    --attach-after "${offset}"
  expect_status 2 "--stall-after '${offset}' is a usage error" \
    "${HARNESS}" --initiator FAKE --reflector FAKE2 --mode ras --duration 3 \
    --stall-after "${offset}"
done
expect_status 2 "--attach-after and --stall-after together is a usage error" \
  "${HARNESS}" --initiator FAKE --reflector FAKE2 --mode ras --duration 5 \
  --attach-after 1 --stall-after 2
expect_contains "the procedure conflict says to pass only one" "only one"

# --- /dev/serial/by-id port resolution -------------------------------------

FAKE_BY_ID="${TMP}/by-id"
mkdir -p "${FAKE_BY_ID}"
for name in \
  usb-SEGGER_J-Link_TESTINIT-if00 \
  usb-SEGGER_J-Link_TESTINIT-if02 \
  usb-SEGGER_J-Link_TESTREFL-if00 \
  usb-SEGGER_J-Link_TESTREFL-if02; do
  : >"${FAKE_BY_ID}/${name}"
done

expect_status 0 "dry-run resolves a serial pair" \
  env SERIAL_BY_ID_DIR="${FAKE_BY_ID}" "${HARNESS}" \
  --initiator TESTINIT --reflector TESTREFL --mode ras --duration 10 --dry-run
expect_contains "initiator COBS resolves to -if00" \
  "${FAKE_BY_ID}/usb-SEGGER_J-Link_TESTINIT-if00"
expect_contains "initiator console resolves to -if02" \
  "${FAKE_BY_ID}/usb-SEGGER_J-Link_TESTINIT-if02"
expect_contains "reflector console resolves to -if02" \
  "${FAKE_BY_ID}/usb-SEGGER_J-Link_TESTREFL-if02"
expect_contains "dry-run reports the COBS baud" "1000000"
expect_contains "dry-run reports the console baud" "115200"
expect_lacks "dry-run does not use a ttyACM name" "/dev/ttyACM"

expect_status 0 "duration 01 is accepted as decimal" \
  env SERIAL_BY_ID_DIR="${FAKE_BY_ID}" "${HARNESS}" \
  --initiator TESTINIT --reflector TESTREFL --mode ras --duration 01 --dry-run
expect_status 0 "duration 007 is accepted as decimal" \
  env SERIAL_BY_ID_DIR="${FAKE_BY_ID}" "${HARNESS}" \
  --initiator TESTINIT --reflector TESTREFL --mode ras --duration 007 --dry-run
expect_status 0 "duration 86400 (24 h maximum) is accepted" \
  env SERIAL_BY_ID_DIR="${FAKE_BY_ID}" "${HARNESS}" \
  --initiator TESTINIT --reflector TESTREFL --mode ras --duration 86400 --dry-run
expect_status 0 "duration 00086400 with leading zeros is accepted" \
  env SERIAL_BY_ID_DIR="${FAKE_BY_ID}" "${HARNESS}" \
  --initiator TESTINIT --reflector TESTREFL --mode ras --duration 00086400 --dry-run

expect_status 0 "dry-run accepts a by-id path with an interface suffix" \
  env SERIAL_BY_ID_DIR="${FAKE_BY_ID}" "${HARNESS}" \
  --initiator "${FAKE_BY_ID}/usb-SEGGER_J-Link_TESTINIT-if02" \
  --reflector "${FAKE_BY_ID}/usb-SEGGER_J-Link_TESTREFL-if00" \
  --mode ipt --duration 10 --dry-run
expect_contains "suffixed initiator path still resolves COBS to -if00" \
  "${FAKE_BY_ID}/usb-SEGGER_J-Link_TESTINIT-if00"
expect_contains "suffixed reflector path still resolves console to -if02" \
  "${FAKE_BY_ID}/usb-SEGGER_J-Link_TESTREFL-if02"

EMPTY_BY_ID="${TMP}/empty-by-id"
mkdir -p "${EMPTY_BY_ID}"
expect_status 1 "a missing device fails the run" \
  env SERIAL_BY_ID_DIR="${EMPTY_BY_ID}" "${HARNESS}" \
  --initiator NOSUCH --reflector TESTREFL --mode ras --duration 10 --dry-run
expect_contains "missing-device error names the resolved by-id path" \
  "usb-SEGGER_J-Link_NOSUCH-if00"

: >"${TMP}/fake-cobs"
: >"${TMP}/fake-init-console"
: >"${TMP}/fake-refl-console"
expect_status 0 "explicit port overrides bypass by-id resolution" \
  env SERIAL_BY_ID_DIR="${EMPTY_BY_ID}" "${HARNESS}" \
  --initiator UNUSED --reflector UNUSED2 --mode ras --duration 10 --dry-run \
  --initiator-cobs "${TMP}/fake-cobs" \
  --initiator-console "${TMP}/fake-init-console" \
  --reflector-console "${TMP}/fake-refl-console"
expect_contains "the initiator COBS override is used" "${TMP}/fake-cobs"
expect_contains "the reflector console override is used" "${TMP}/fake-refl-console"

# --- native USB port resolution and link assertions ------------------------
#
# The fake tree mirrors the real Linux layout, captured from the bench pair:
#
#   <by-id>/usb-Metirionic_Mars_CS_<Role>_<serial>-ifNN  ->  tty
#   <sysfs>/class/tty/<tty>/device
#       -> ../../../devices/<usb-dev>/<usb-dev>:1.<n>
#   <sysfs>/devices/<usb-dev>/<usb-dev>:1.<n>/bInterfaceNumber
#   <sysfs>/devices/<usb-dev>/speed, idVendor, idProduct, product
#
# The serials are opaque to the harness; the fixtures use short names.

USB_BY_ID_ROOT="${TMP}/usb-by-id"
USB_SYSFS_ROOT="${TMP}/usb-sysfs"
USB_TTY_FILES="${TMP}/usb-ttys"
mkdir -p "${USB_BY_ID_ROOT}" "${USB_SYSFS_ROOT}/class/tty" \
  "${USB_SYSFS_ROOT}/devices" "${USB_TTY_FILES}"

# usb_add_device <sysfs-name> <vendor> <pid> <product> <speed>
usb_add_device() {
  local dir="${USB_SYSFS_ROOT}/devices/$1"
  mkdir -p "${dir}"
  printf '%s\n' "$2" >"${dir}/idVendor"
  printf '%s\n' "$3" >"${dir}/idProduct"
  printf '%s\n' "$4" >"${dir}/product"
  printf '%s\n' "$5" >"${dir}/speed"
}

# usb_add_port <sysfs-name> <interface-number> <tty-name> <by-id-name>
usb_add_port() {
  local dev="$1" num="$2" tty="$3" name="$4"
  local iface_dir="${USB_SYSFS_ROOT}/devices/${dev}/${dev}:1.${num#0}"
  mkdir -p "${iface_dir}"
  printf '%s\n' "${num}" >"${iface_dir}/bInterfaceNumber"
  : >"${USB_TTY_FILES}/${tty}"
  ln -sfn "${USB_TTY_FILES}/${tty}" "${USB_BY_ID_ROOT}/${name}"
  mkdir -p "${USB_SYSFS_ROOT}/class/tty/${tty}"
  ln -sfn "../../../devices/${dev}/${dev}:1.${num#0}" \
    "${USB_SYSFS_ROOT}/class/tty/${tty}/device"
}

usb_dry_run() {
  env SERIAL_BY_ID_DIR="${USB_BY_ID_ROOT}" USB_SYSFS_ROOT="${USB_SYSFS_ROOT}" \
    "${HARNESS}" --transport usb "$@"
}

# USB overrides bypass serial resolution but keep the link assertion.
usb_override_run() {
  env SERIAL_BY_ID_DIR="${EMPTY_BY_ID}" USB_SYSFS_ROOT="${USB_SYSFS_ROOT}" \
    "${HARNESS}" --transport usb --initiator UNUSED --reflector UNUSED2 \
    --mode ras --duration 10 "$@" \
    --initiator-cobs "${USB_BY_ID_ROOT}/usb-Metirionic_Mars_CS_Initiator_USBINIT-if00" \
    --initiator-console "${USB_BY_ID_ROOT}/usb-Metirionic_Mars_CS_Initiator_USBINIT-if02" \
    --reflector-console "${USB_BY_ID_ROOT}/usb-Metirionic_Mars_CS_Reflector_USBREF-if00"
}

usb_add_device init 1915 0001 "Mars CS Initiator" 480
usb_add_device refl 1915 0002 "Mars CS Reflector" 480
usb_add_port init 00 init-data \
  usb-Metirionic_Mars_CS_Initiator_USBINIT-if00
usb_add_port init 02 init-console \
  usb-Metirionic_Mars_CS_Initiator_USBINIT-if02
usb_add_port refl 00 refl-console \
  usb-Metirionic_Mars_CS_Reflector_USBREF-if00

expect_status 0 "USB dry-run resolves the SoC-derived serial pair" \
  usb_dry_run --initiator USBINIT --reflector USBREF --mode ras --duration 10 \
  --dry-run
expect_contains "USB dry-run reports the transport" "transport: usb"
expect_contains "initiator USB data resolves to -if00" \
  "${USB_BY_ID_ROOT}/usb-Metirionic_Mars_CS_Initiator_USBINIT-if00"
expect_contains "initiator USB console resolves to -if02" \
  "${USB_BY_ID_ROOT}/usb-Metirionic_Mars_CS_Initiator_USBINIT-if02"
expect_contains "reflector USB console resolves to -if00" \
  "${USB_BY_ID_ROOT}/usb-Metirionic_Mars_CS_Reflector_USBREF-if00"
expect_contains "USB dry-run reports the 480 Mbit/s link" "480 Mbit/s"
expect_lacks "USB dry-run does not print a VCOM baud" "VCOM0"

expect_status 0 "transport names are case-insensitive" \
  env SERIAL_BY_ID_DIR="${USB_BY_ID_ROOT}" USB_SYSFS_ROOT="${USB_SYSFS_ROOT}" \
  "${HARNESS}" --transport USB --initiator USBINIT --reflector USBREF \
  --mode ipt --duration 10 --dry-run

# The assertions are exercised by breaking one property at a time and
# restoring it afterwards.
USB_INIT_SPEED="${USB_SYSFS_ROOT}/devices/init/speed"
printf '12\n' >"${USB_INIT_SPEED}"
expect_status 1 "USB dry-run rejects a full-speed link" \
  usb_dry_run --initiator USBINIT --reflector USBREF --mode ras --duration 10 \
  --dry-run
expect_contains "full-speed error names the expected 480 Mbit/s" \
  "expected 480 Mbit/s"
printf '480\n' >"${USB_INIT_SPEED}"

USB_INIT_CONSOLE_IFACE="${USB_SYSFS_ROOT}/devices/init/init:1.2/bInterfaceNumber"
printf '01\n' >"${USB_INIT_CONSOLE_IFACE}"
expect_status 1 "USB dry-run rejects a mismatched interface mapping" \
  usb_dry_run --initiator USBINIT --reflector USBREF --mode ras --duration 10 \
  --dry-run
expect_contains "mismatched-interface error names the expected interface" \
  "expected 02"
printf '02\n' >"${USB_INIT_CONSOLE_IFACE}"

USB_INIT_PID="${USB_SYSFS_ROOT}/devices/init/idProduct"
printf '0002\n' >"${USB_INIT_PID}"
expect_status 1 "USB dry-run rejects the wrong role identity" \
  usb_dry_run --initiator USBINIT --reflector USBREF --mode ras --duration 10 \
  --dry-run
expect_contains "wrong-identity error names the expected product ID" "0001"
printf '0001\n' >"${USB_INIT_PID}"

expect_status 1 "USB dry-run rejects a reflector by-id as the initiator" \
  usb_dry_run --initiator \
  "${USB_BY_ID_ROOT}/usb-Metirionic_Mars_CS_Reflector_USBREF-if00" \
  --reflector USBREF --mode ras --duration 10 --dry-run
expect_contains "role-mismatch error names the initiator identity" \
  "Mars CS Initiator"

expect_status 1 "USB dry-run fails on an unknown SoC serial" \
  usb_dry_run --initiator NOSUCH --reflector USBREF --mode ras --duration 10 \
  --dry-run
expect_contains "USB missing-device error names the resolved by-id path" \
  "usb-Metirionic_Mars_CS_Initiator_NOSUCH-if00"

# A second initiator-identity device exposes a split data/console mapping.
usb_add_device init2 1915 0001 "Mars CS Initiator" 480
usb_add_port init2 02 init2-console \
  usb-Metirionic_Mars_CS_Initiator_USBINIT-if02
expect_status 1 "USB dry-run rejects split data and console devices" \
  usb_dry_run --initiator USBINIT --reflector USBREF --mode ras --duration 10 \
  --dry-run
expect_contains "split-device error names the two USB devices" \
  "different USB devices"
usb_add_port init 02 init-console \
  usb-Metirionic_Mars_CS_Initiator_USBINIT-if02

expect_status 0 "USB overrides bypass role resolution" \
  usb_override_run --dry-run

printf '12\n' >"${USB_INIT_SPEED}"
expect_status 1 "USB overrides still assert the link speed" \
  usb_override_run --dry-run
printf '480\n' >"${USB_INIT_SPEED}"

# --- offline replay: --analyze-dir -----------------------------------------

GOOD_CAPTURE="${TMP}/capture-good"

# Hand-computed COBS body for the fixture's SubeventResultEvent, including its
# trailing 0x00 delimiter. The decoded payload is:
#   00 | 600-byte zero-free run (1..255 twice, then 1..90)
#      | 00 | 01..39 | 00 | 40..79
# The run spans three blocks (0xFF + 254 bytes, 0xFF + 254 bytes,
# 0x5D + 92 bytes); the remaining blocks are 0x28 + 39 bytes and
# 0x29 + 40 bytes. Pinning the bytes
# here keeps the fixture independent of any encoder, so a symmetric
# encode/decode bug cannot pass both sides.
PINNED_EVENT_FRAME_HEX="01ff0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a"
PINNED_EVENT_FRAME_HEX+="8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeffff0102030405060708090a0b0c0d0e0f10111213141516"
PINNED_EVENT_FRAME_HEX+="1718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2"
PINNED_EVENT_FRAME_HEX+="a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfd5dfeff0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e"
PINNED_EVENT_FRAME_HEX+="2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a280102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20212223242526272928292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f00"

# make_good_capture <dir>
# Writes a synthetic clean capture: both consoles carry benign log lines, and
# the COBS file holds one event frame and one log frame, bracketed by partial
# frames as a real mid-stream capture would be.
make_good_capture() {
  local dir="$1"
  mkdir -p "${dir}"
  cat >"${dir}/initiator-console.log" <<'EOF'
*** Booting nRF Connect SDK v3.4.0 ***
Starting Mars Channel Sounding Initiator
Run serialization for procedure 1
Sending 26700 bytes
Run serialization for procedure 2
Sending 26700 bytes
EOF
  cat >"${dir}/reflector-console.log" <<'EOF'
*** Booting nRF Connect SDK v3.4.0 ***
Starting Mars Channel Sounding Reflector
Connected to 12:34:56:78:9A:BC (err 0x00)
CS capability exchange completed. (peer antennas: 1)
EOF
  python3 - "${dir}/initiator-cobs.bin" "${PINNED_EVENT_FRAME_HEX}" <<'PY'
import sys

pinned_event_frame = bytes.fromhex(sys.argv[2])
# Hand-computed COBS frame for a LogMessage envelope: decoded =
# 01 13 "Processing finished" (tag 1, varint byte length 19), so the
# zero-free 21-byte payload becomes 16 <payload>, and 0x00 ends the frame.
fixed_log_frame = b"\x16\x01\x13Processing finished\x00"
stream = (
    b"\x07\xaa\xbb\x00"  # leading partial: capture began mid-frame
    + pinned_event_frame
    + fixed_log_frame
    + b"\x03\xcc"  # trailing partial: capture ended mid-frame
)
with open(sys.argv[1], "wb") as fh:
    fh.write(stream)
PY
}

make_good_capture "${GOOD_CAPTURE}"

expect_status 0 "replay accepts a clean capture" \
  "${HARNESS}" --mode ras --analyze-dir "${GOOD_CAPTURE}"
expect_contains "replay reports PASS and is marked as replay" \
  "RESULT: PASS (replay; not live evidence)"
expect_contains "replay counts both COBS frames" "frames_valid=2"
expect_contains "replay counts the event frame" "frames_event=1"
expect_contains "replay counts the log frame" "frames_log=1"
expect_contains "replay ignores the leading partial" "frames_invalid=0"
expect_contains "replay reports leading partial bytes" "leading_partial_bytes=3"
expect_contains "replay reports trailing partial bytes" "trailing_partial_bytes=2"
expect_contains "replay counts zero empty-procedure warnings" "empty_procedure_warnings=0"
expect_contains "replay counts zero reflector aborts" "reflector_aborts=0"
expect_contains "replay counts zero initiator watchdog recoveries" \
  "initiator_watchdog_recoveries=0"
expect_contains "replay counts zero reflector watchdog recoveries" \
  "reflector_watchdog_recoveries=0"
expect_contains "replay counts serialized procedures" "serialization_events=2"
expect_contains "replay reports the captured file locations" "initiator-cobs.bin"

expect_status 0 "replay accepts the ipt mode label" \
  "${HARNESS}" --mode ipt --analyze-dir "${GOOD_CAPTURE}"

# A USB capture additionally carries the transport's own drop signature.
expect_status 0 "replay accepts a clean USB capture" \
  "${HARNESS}" --transport usb --mode ras --analyze-dir "${GOOD_CAPTURE}"
expect_contains "USB replay reports the transport" "transport=usb"
expect_contains "USB replay counts zero transport drops" "usb_dropped_runs=0"
expect_contains "USB replay applies the transport drop assertion" \
  "initiator USB dropped runs == 0"

expect_status 0 "replay reports the wire rate when a window is given" \
  "${HARNESS}" --mode ras --analyze-dir "${GOOD_CAPTURE}" --duration 10
expect_contains "the wire-rate window is reported" "data_window_s=10"
expect_contains "the wire rate is reported in bytes per second" \
  "wire_rate_bytes_per_s="
expect_contains "the wire rate is reported in Mbit per second" \
  "wire_rate_mbit_per_s="
expect_lacks "a known wire rate is not reported as unknown" \
  "wire_rate_mbit_per_s=unknown"

USB_DROP_CAPTURE="${TMP}/capture-usb-drop"
rm -rf "${USB_DROP_CAPTURE}"
cp -R "${GOOD_CAPTURE}" "${USB_DROP_CAPTURE}"
printf '%s\n' "COBS USB: dropped run (transport busy), 3 dropped" \
  >>"${USB_DROP_CAPTURE}/initiator-console.log"
expect_status 1 "USB replay fails on a transport drop" \
  "${HARNESS}" --transport usb --mode ras --analyze-dir "${USB_DROP_CAPTURE}"
expect_contains "the USB drop count is reported" "usb_dropped_runs=3"
expect_contains "the USB drop failure names the assertion" \
  "initiator USB dropped runs == 0"

# capture-info.txt supplies transport and window to a bare replay.
INFO_CAPTURE="${TMP}/capture-info-usb"
rm -rf "${INFO_CAPTURE}"
cp -R "${GOOD_CAPTURE}" "${INFO_CAPTURE}"
cat >"${INFO_CAPTURE}/capture-info.txt" <<'EOF'
transport=usb
data_window=20
stall_after=0
attach_after=0
EOF
expect_status 0 "replay reads transport and window from capture-info.txt" \
  "${HARNESS}" --mode ras --analyze-dir "${INFO_CAPTURE}"
expect_contains "capture-info transport is applied" "transport=usb"
expect_contains "capture-info window is applied" "data_window_s=20"
expect_contains "capture-info yields a wire rate" "wire_rate_bytes_per_s="

# An older/hand-written info file may carry only the soak duration, which is
# the wire-rate window fallback.
DURATION_INFO="${TMP}/capture-info-duration"
rm -rf "${DURATION_INFO}"
cp -R "${GOOD_CAPTURE}" "${DURATION_INFO}"
cat >"${DURATION_INFO}/capture-info.txt" <<'EOF'
transport=usb
duration=25
EOF
expect_status 0 "capture-info duration is the window fallback" \
  "${HARNESS}" --mode ras --analyze-dir "${DURATION_INFO}"
expect_contains "the duration fallback sets the window" "data_window_s=25"

expect_status 1 "replay rejects a transport that contradicts capture-info.txt" \
  "${HARNESS}" --transport vcom --mode ras --analyze-dir "${INFO_CAPTURE}"
expect_contains "the transport mismatch is explained" \
  "capture-info.txt says transport=usb"

empty_fail() {
  local dir="${TMP}/capture-negative"
  rm -rf "${dir}"
  cp -R "${GOOD_CAPTURE}" "${dir}"
  printf '%s\n' "$1" >>"${dir}/$2"
  expect_status 1 "replay fails on: $1" \
    "${HARNESS}" --mode ras --analyze-dir "${dir}"
  expect_contains "replay reports FAIL for: $1" "RESULT: FAIL (replay)"
  expect_contains "replay names the failing assertion for: $1" "$3"
}

empty_fail "IPT procedure produced no step data" \
  initiator-console.log "empty-procedure signatures"
expect_contains "the empty-procedure count is reported" "empty_procedure_warnings=1"

empty_fail "All subevents in ranging counter 3 were aborted" \
  initiator-console.log "empty-procedure signatures"
expect_contains "the RAS empty-procedure count is reported" "empty_procedure_warnings=1"

empty_fail "CS subevent aborted: proc=7 sub_abort_reason=1 proc_abort_reason=0" \
  reflector-console.log "reflector aborts"
expect_contains "the reflector abort count is reported" "reflector_aborts=1"

empty_fail "CS liveness watchdog: no completed procedure with step data for 5000 ms" \
  initiator-console.log "initiator watchdog recoveries"
expect_contains "the initiator watchdog count is reported" \
  "initiator_watchdog_recoveries=1"

empty_fail "CS liveness watchdog: no completed subevent with step data for 5000 ms" \
  reflector-console.log "reflector watchdog recoveries"
expect_contains "the reflector watchdog count is reported" \
  "reflector_watchdog_recoveries=1"

empty_fail "Serialize backlog: dropped 1 procedures (transport slower than cadence)" \
  initiator-console.log "serialize backlog reports"
expect_contains "the serialize backlog count is reported" "serialize_backlog_reports=1"

empty_fail "Diagnostic backlog: dropped 1 COBS log frames (transport slower than cadence)" \
  initiator-console.log "diagnostic backlog reports"
expect_contains "the diagnostic backlog count is reported" "diagnostic_backlog_reports=1"

# A log-only stream is well-formed but carries no ranging event.
LOG_ONLY="${TMP}/capture-log-only"
rm -rf "${LOG_ONLY}"
cp -R "${GOOD_CAPTURE}" "${LOG_ONLY}"
python3 - "${LOG_ONLY}/initiator-cobs.bin" <<'PY'
import sys

# Hand-computed LogMessage frame, the same independent literal as the clean
# capture fixture.
fixed_log_frame = b"\x16\x01\x13Processing finished\x00"
with open(sys.argv[1], "wb") as fh:
    # The leading delimiter marks a frame boundary; without it the body would
    # be the partial frame a mid-stream capture starts in.
    fh.write(b"\x00" + fixed_log_frame)
PY
expect_status 1 "replay fails when no event frame is captured" \
  "${HARNESS}" --mode ras --analyze-dir "${LOG_ONLY}"
expect_contains "the log-only failure names the event-frame assertion" "event frame"
expect_contains "the log-only summary counts the log frame" "frames_log=1"
expect_contains "the log-only summary counts no event frame" "frames_event=0"
expect_contains "the log-only failure is marked as replay" "RESULT: FAIL (replay)"

# A truncated COBS body is not a valid record.
TRUNCATED="${TMP}/capture-truncated"
rm -rf "${TRUNCATED}"
cp -R "${GOOD_CAPTURE}" "${TRUNCATED}"
printf '\x05\x01\x02' >"${TRUNCATED}/initiator-cobs.bin"
expect_status 1 "replay fails on a truncated COBS body" \
  "${HARNESS}" --mode ras --analyze-dir "${TRUNCATED}"
expect_contains "the truncated summary counts no valid frames" "frames_valid=0"

# An empty console is not a gate failure: an idle IPT reflector can be silent
# for the whole soak, and a valid COBS event frame is the liveness evidence.
EMPTY_CONSOLE="${TMP}/capture-empty-reflector"
rm -rf "${EMPTY_CONSOLE}"
cp -R "${GOOD_CAPTURE}" "${EMPTY_CONSOLE}"
: >"${EMPTY_CONSOLE}/reflector-console.log"
expect_status 0 "replay passes with an empty reflector console" \
  "${HARNESS}" --mode ras --analyze-dir "${EMPTY_CONSOLE}"
expect_contains "empty-reflector replay still reports PASS" \
  "RESULT: PASS (replay; not live evidence)"
expect_contains "the empty reflector console size is reported" \
  "reflector_console_bytes=0"
expect_contains "the empty reflector console is warned about" \
  "warning: reflector console capture is empty"

BOTH_EMPTY="${TMP}/capture-empty-both"
rm -rf "${BOTH_EMPTY}"
cp -R "${GOOD_CAPTURE}" "${BOTH_EMPTY}"
: >"${BOTH_EMPTY}/initiator-console.log"
: >"${BOTH_EMPTY}/reflector-console.log"
expect_status 0 "replay passes with both consoles empty and valid COBS data" \
  "${HARNESS}" --mode ras --analyze-dir "${BOTH_EMPTY}"
expect_contains "the empty initiator console size is reported" \
  "initiator_console_bytes=0"
expect_contains "the empty reflector console is reported in the both-empty case" \
  "reflector_console_bytes=0"
expect_contains "the empty initiator console is warned about" \
  "warning: initiator console capture is empty"

MISSING_DIR="${TMP}/capture-missing"
mkdir -p "${MISSING_DIR}"
expect_status 1 "replay fails when capture files are missing" \
  "${HARNESS}" --mode ras --analyze-dir "${MISSING_DIR}"
expect_contains "the missing-file error names the expected file" "initiator-console.log"

expect_status 2 "replay still requires a valid mode" \
  "${HARNESS}" --mode fsk --analyze-dir "${GOOD_CAPTURE}"

# --- capture path over pseudo-terminals ------------------------------------
#
# Exercises the real stty/cat/timeout capture path without a DK: three ptys
# stand in for the ports, the harness opens them through the explicit
# overrides, and a Python fixture writes synthetic console lines and COBS
# frames after the capture has started.

PTY_OUT="${TMP}/capture-pty"
cat >"${TMP}/pty-capture.py" <<'PY'
import os
import shutil
import subprocess
import sys
import time

harness, out_dir, frame_hex = sys.argv[1], sys.argv[2], sys.argv[3]
scenario = sys.argv[4] if len(sys.argv) > 4 else ""
pinned_event_frame = bytes.fromhex(frame_hex)
usb = scenario.startswith("usb-")
attach = scenario == "usb-attach"
stall = scenario == "usb-stall"
empty_initiator = scenario == "empty-initiator"

masters = []
slave_paths = []
for _ in range(3):
    master, slave = os.openpty()
    masters.append(master)
    slave_paths.append(os.ttyname(slave))

env = os.environ.copy()
args = [harness, "--mode", "ras", "--duration", "3", "--out-dir", out_dir]

if usb:
    # Fake the native USB resolution surface around the three ptys: the
    # by-id names point at the pty slaves, and a fake sysfs tree reports the
    # 480 Mbit/s link plus the role identity and interface mapping.
    by_id = out_dir + "-by-id"
    sysfs = out_dir + "-sysfs"
    shutil.rmtree(by_id, ignore_errors=True)
    shutil.rmtree(sysfs, ignore_errors=True)
    os.makedirs(by_id)

    def add_device(name, pid, product):
        devdir = os.path.join(sysfs, "devices", name)
        os.makedirs(devdir)
        for key, value in (("speed", "480"), ("idVendor", "1915"),
                           ("idProduct", pid), ("product", product)):
            with open(os.path.join(devdir, key), "w") as fh:
                fh.write(value + "\n")

    def add_port(tty_path, dev, number, by_id_name):
        tty = os.path.basename(tty_path)
        iface_dir = os.path.join(sysfs, "devices", dev,
                                 "%s:1.%d" % (dev, int(number)))
        os.makedirs(iface_dir)
        with open(os.path.join(iface_dir, "bInterfaceNumber"), "w") as fh:
            fh.write(number + "\n")
        class_dir = os.path.join(sysfs, "class", "tty", tty)
        os.makedirs(class_dir)
        os.symlink(os.path.relpath(iface_dir, class_dir),
                   os.path.join(class_dir, "device"))
        os.symlink(tty_path, os.path.join(by_id, by_id_name))

    add_device("u-init", "0001", "Mars CS Initiator")
    add_device("u-refl", "0002", "Mars CS Reflector")
    add_port(slave_paths[0], "u-init", "00",
             "usb-Metirionic_Mars_CS_Initiator_USBPTY-if00")
    add_port(slave_paths[1], "u-init", "02",
             "usb-Metirionic_Mars_CS_Initiator_USBPTY-if02")
    add_port(slave_paths[2], "u-refl", "00",
             "usb-Metirionic_Mars_CS_Reflector_USBREFPTY-if00")

    env["SERIAL_BY_ID_DIR"] = by_id
    env["USB_SYSFS_ROOT"] = sysfs
    args += ["--transport", "usb", "--initiator", "USBPTY",
             "--reflector", "USBREFPTY"]
    if attach:
        args += ["--attach-after", "1"]
    if stall:
        args += ["--stall-after", "1"]
else:
    args += [
        "--initiator", "UNUSED",
        "--reflector", "UNUSED2",
        "--initiator-cobs", slave_paths[0],
        "--initiator-console", slave_paths[1],
        "--reflector-console", slave_paths[2],
    ]

process = subprocess.Popen(
    args,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    text=True,
    env=env,
)

# Give stty and the console readers time to start before writing.
time.sleep(0.5)

# Hand-computed LogMessage frame, independent of the event literal.
fixed_log_frame = b"\x16\x01\x13Processing finished\x00"
if not empty_initiator:
    os.write(masters[1],
             b"Starting Mars Channel Sounding Initiator\n"
             b"Run serialization for procedure 1\n")
os.write(masters[2], b"Starting Mars Channel Sounding Reflector\n")

if attach:
    # The harness opens the data port at t=1 s; write afterwards so the
    # frames are waiting for the late reader.
    time.sleep(1.0)

# The leading delimiter marks a frame boundary; a real capture starts
# mid-stream, and bytes before the first delimiter are a partial frame.
os.write(masters[0], b"\x00" + pinned_event_frame + fixed_log_frame)

if stall:
    # The harness stops reading the data port at t=1 s while keeping it open
    # and the console capture running. The first-drop report after that
    # boundary is the stall evidence; the handoff-backlog line that follows is
    # expected in a fault procedure and must not fail the gate.
    time.sleep(1.0)
    os.write(masters[1],
             b"COBS USB: dropped run (transport busy), 1 dropped\n"
             b"Serialize backlog: dropped 1 procedures (transport slower than cadence)\n")

stdout, _ = process.communicate(timeout=30)
print(stdout, end="")
sys.exit(process.returncode)
PY

expect_status 0 "capture run passes over a pty trio" \
  python3 -I "${TMP}/pty-capture.py" "${HARNESS}" "${PTY_OUT}" \
  "${PINNED_EVENT_FRAME_HEX}"
expect_contains "capture run reports three full-soak windows" "124,124,124"
expect_contains "capture run reports PASS" "RESULT: PASS"
expect_contains "capture run counts the event frame" "frames_event=1"
expect_lacks "live capture output is not marked as replay" "not live evidence"
for capture_file in initiator-console.log reflector-console.log initiator-cobs.bin; do
  if [[ -f "${PTY_OUT}/${capture_file}" ]]; then
    pass "capture run wrote ${capture_file}"
  else
    fail "capture run wrote ${capture_file}"
  fi
done

# A live capture with a dead initiator console must fail: otherwise the
# zero-warning assertions would be vacuous.
EMPTY_INIT_OUT="${TMP}/capture-pty-empty-initiator"
expect_status 1 "live capture fails on an empty initiator console" \
  python3 -I "${TMP}/pty-capture.py" "${HARNESS}" "${EMPTY_INIT_OUT}" \
  "${PINNED_EVENT_FRAME_HEX}" "empty-initiator"
expect_contains "the live empty-initiator failure names the assertion" \
  "[FAIL] initiator console capture non-empty"
expect_contains "the live empty-initiator failure reports FAIL" "RESULT: FAIL"
expect_lacks "the live empty-initiator failure is not marked as replay" \
  "not live evidence"

# Boot-with-no-host: the data port is opened after the soak starts. The
# fixture writes frames once the late reader is attached.
USB_ATTACH_OUT="${TMP}/capture-pty-usb-attach"
expect_status 0 "USB capture passes when the data port opens late" \
  python3 -I "${TMP}/pty-capture.py" "${HARNESS}" "${USB_ATTACH_OUT}" \
  "${PINNED_EVENT_FRAME_HEX}" "usb-attach"
expect_contains "the late-attach capture reports the attach point" \
  "data_attach_after_s=1"
expect_contains "the late-attach capture reports the shortened window" \
  "data_window_s=2"
expect_contains "the late-attach capture still sees the event frame" \
  "frames_event=1"
expect_contains "the late-attach capture does not gate pre-attach drops" \
  "pre-attach drops are expected and not gated; post-attach drops are gated"
expect_contains "the late-attach capture gates post-attach drops" \
  "[PASS] initiator USB dropped runs after attach == 0"
expect_contains "the late-attach capture passes" "RESULT: PASS"

expect_status 0 "replay of the late-attach USB capture passes" \
  "${HARNESS}" --mode ras --analyze-dir "${USB_ATTACH_OUT}"
expect_contains "the late-attach replay applies the recorded procedure" \
  "procedure: boot-with-no-host, data port opened at 1 s"

# A drop report after the attach boundary is a post-attach drop: the same
# capture must then fail.
ATTACH_DROP="${TMP}/capture-pty-usb-attach-drop"
rm -rf "${ATTACH_DROP}"
cp -R "${USB_ATTACH_OUT}" "${ATTACH_DROP}"
printf '%s\n' "COBS USB: dropped run (transport busy), 1 dropped" \
  >>"${ATTACH_DROP}/initiator-console.log"
expect_status 1 "late-attach replay fails on a post-attach drop" \
  "${HARNESS}" --mode ras --analyze-dir "${ATTACH_DROP}"
expect_contains "the post-attach failure names the assertion" \
  "initiator USB dropped runs after attach == 0"

# Host stall: the data port stops being read mid-soak while it stays open and
# the consoles keep capturing. The fixture writes the firmware's first-drop
# report and the expected handoff backlog afterwards.
USB_STALL_OUT="${TMP}/capture-pty-usb-stall"
expect_status 0 "USB capture passes through a host stall" \
  python3 -I "${TMP}/pty-capture.py" "${HARNESS}" "${USB_STALL_OUT}" \
  "${PINNED_EVENT_FRAME_HEX}" "usb-stall"
expect_contains "the stall capture reports the stall point" \
  "data_stall_after_s=1"
expect_contains "the stall capture reports the shortened window" \
  "data_window_s=1"
expect_contains "the stall capture counts the transport drop after the stall" \
  "usb_dropped_runs_after_stall=1"
expect_contains "the stall capture applies the inverted drop assertion" \
  "[PASS] initiator USB dropped runs after the stall >= 1"
expect_contains "the stall capture reports the handoff backlog" \
  "serialize_backlog_reports=1"
expect_contains "the stall capture does not gate the fault backlog" \
  "handoff/diagnostic backlog counts are reported, not gated"
expect_contains "the stall capture passes" "RESULT: PASS"

expect_status 0 "replay of the stalled USB capture passes" \
  "${HARNESS}" --mode ras --analyze-dir "${USB_STALL_OUT}"
expect_contains "the stalled replay applies the recorded procedure" \
  "procedure: host stall at 1 s"
expect_contains "the stalled replay reports the recorded window" \
  "data_window_s=1"

expect_status 2 "the fault procedures are rejected with --analyze-dir" \
  "${HARNESS}" --mode ras --analyze-dir "${USB_STALL_OUT}" --stall-after 1

# --- report -----------------------------------------------------------------

printf '\n%d passed, %d failed\n' "${PASSED}" "${FAILED}"
if ((FAILED > 0)); then
  exit 1
fi
