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
for flag in --initiator --reflector --mode --duration --analyze-dir --dry-run; do
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

for duration in 0 00 -1 abc 1.5 "" 86401 999999 18446744073709551617; do
  expect_status 2 "duration '${duration}' is a usage error" \
    "${HARNESS}" --initiator FAKE --reflector FAKE2 --mode ras --duration "${duration}"
done

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
import subprocess
import sys
import time

harness, out_dir = sys.argv[1], sys.argv[2]
pinned_event_frame = bytes.fromhex(sys.argv[3])
empty_initiator = len(sys.argv) > 4 and sys.argv[4] == "empty-initiator"

masters = []
slave_paths = []
for _ in range(3):
    master, slave = os.openpty()
    masters.append(master)
    slave_paths.append(os.ttyname(slave))

process = subprocess.Popen(
    [
        harness,
        "--initiator", "UNUSED",
        "--reflector", "UNUSED2",
        "--mode", "ras",
        "--duration", "2",
        "--out-dir", out_dir,
        "--initiator-cobs", slave_paths[0],
        "--initiator-console", slave_paths[1],
        "--reflector-console", slave_paths[2],
    ],
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    text=True,
)

# Give stty and the three `cat` readers time to start before writing.
time.sleep(1.0)

# Hand-computed LogMessage frame, independent of the event literal.
fixed_log_frame = b"\x16\x01\x13Processing finished\x00"
if not empty_initiator:
    os.write(masters[1],
             b"Starting Mars Channel Sounding Initiator\n"
             b"Run serialization for procedure 1\n")
os.write(masters[2], b"Starting Mars Channel Sounding Reflector\n")
# The leading delimiter marks a frame boundary; a real capture starts
# mid-stream, and bytes before the first delimiter are a partial frame.
os.write(masters[0], b"\x00" + pinned_event_frame + fixed_log_frame)

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

# --- report -----------------------------------------------------------------

printf '\n%d passed, %d failed\n' "${PASSED}" "${FAILED}"
if ((FAILED > 0)); then
  exit 1
fi
