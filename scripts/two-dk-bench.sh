#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Two-DK bench harness for the nRF54LM20-DK Channel Sounding pair.
#
# Captures, for a full soak window:
#   - the initiator console (VCOM1, uart20, 115200 8N1);
#   - the reflector console (VCOM1, uart20, 115200 8N1);
#   - the initiator COBS ranging stream (VCOM0, uart30, 1,000,000 8N1).
#
# and asserts the release-gate conditions:
#   - zero empty-procedure signatures on the initiator (both the IPT
#     "IPT procedure produced no step data" and the RAS "All subevents in
#     ranging counter" warnings);
#   - zero "Serialize backlog" drop reports on the initiator console (no
#     procedure was dropped at the RX-thread -> consumer handoff gate);
#   - zero "Diagnostic backlog" drop reports on the initiator console (the
#     diagnostic queue never overflowed);
#   - zero "CS subevent aborted" warnings (reflector);
#   - zero "CS liveness watchdog" recoveries (both consoles);
#   - at least one structurally valid COBS event frame on the initiator stream.
#
# Ports are resolved through /dev/serial/by-id so ttyACM renumbering does not
# affect a run. On the nRF54LM20-DK the J-Link VCOM mapping is:
#
#   usb-SEGGER_J-Link_<SN>-if00 = VCOM0 = COBS ranging stream @ 1,000,000 baud
#   usb-SEGGER_J-Link_<SN>-if02 = VCOM1 = console              @ 115,200 baud
#
# That is the reverse of the nRF54L15 DK mapping used by the sibling
# repository's harness: on the LM20 the COBS stream is on VCOM0 and the
# console on VCOM1.
#
# COBS validation is framing/length based: each 0x00-delimited body must
# COBS-decode cleanly, re-encode to the same bytes, be within the sane frame
# size, and carry a known envelope variant tag (0 = SubeventResultEvent,
# 1 = LogMessage). This is not a semantic postcard decode; mars-bluetooth-hci
# is encode-only for the UART path, so no host-side decoder is available.
#
# Usage examples (the serials are passed by the operator, never hard-coded;
# the release-gate soak in ticket #5 is ten minutes):
#   scripts/two-dk-bench.sh --initiator <serial> --reflector <serial> \
#       --mode ras --duration 600
#   scripts/two-dk-bench.sh --initiator <serial> --reflector <serial> \
#       --mode ipt --duration 600
#
# Exit status: 0 = all assertions passed, 1 = capture/assertion failure,
# 2 = command-line usage error.

# No `set -e`: the harness inspects the capture and analysis statuses
# explicitly, and `set -e` would abort before it could print a summary.
set -uo pipefail

PROG="$(basename "$0")"
SERIAL_BY_ID_DIR="${SERIAL_BY_ID_DIR:-/dev/serial/by-id}"
COBS_BAUD=1000000
CONSOLE_BAUD=115200
MAX_DURATION=86400

INITIATOR=""
REFLECTOR=""
MODE=""
DURATION=""
OUT_DIR=""
INITIATOR_COBS_OVERRIDE=""
INITIATOR_CONSOLE_OVERRIDE=""
REFLECTOR_CONSOLE_OVERRIDE=""
ANALYZE_DIR=""
DRY_RUN=0
INITIATOR_COBS_PORT=""
INITIATOR_CONSOLE_PORT=""
REFLECTOR_CONSOLE_PORT=""

usage() {
  cat <<EOF
Usage: ${PROG} --initiator <serial|by-id-path> --reflector <serial|by-id-path>
                  --mode <ras|ipt> --duration <seconds> [options]
       ${PROG} --mode <ras|ipt> --analyze-dir <dir>

Required for a capture run:
  -i, --initiator ID        Initiator DK serial number or /dev/serial/by-id path
  -r, --reflector ID        Reflector DK serial number or /dev/serial/by-id path
  -m, --mode MODE           Ranging mode: ras or ipt
  -d, --duration SECONDS    Soak duration, positive integer seconds
                            (max ${MAX_DURATION} = 24 h)

Options:
  -o, --out-dir DIR         Capture directory (default: a fresh mktemp -d)
      --initiator-cobs PATH     Override the initiator COBS port (VCOM0)
      --initiator-console PATH  Override the initiator console port (VCOM1)
      --reflector-console PATH  Override the reflector console port (VCOM1)
      --analyze-dir DIR         Re-run the assertions on a previous capture
                                (DIR must hold initiator-console.log,
                                reflector-console.log, initiator-cobs.bin);
                                no hardware is touched, --duration is unused
      --dry-run                 Resolve and print the ports, then exit
  -h, --help                Show this help

Port resolution: a bare serial number expands to
${SERIAL_BY_ID_DIR}/usb-SEGGER_J-Link_<serial>; a by-id path may be
given with or without its -if00/-if02 suffix. SERIAL_BY_ID_DIR overrides the
by-id root (default: /dev/serial/by-id). The explicit overrides accept any tty
path and are the escape hatch for non-J-Link wiring.

The harness does not flash the DKs. Flash a matched mode pair first:
  RAS: nrf54lm20dk_cent_a1_1 + nrf54lm20dk_peri_a1_1
  IPT: nrf54lm20dk_cent_a1_1_ipt + nrf54lm20dk_peri_a1_1_ipt
EOF
}

die_usage() {
  printf 'error: %s\n\n' "$1" >&2
  usage >&2
  exit 2
}

die_run() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

# require_command <name>
require_command() {
  command -v "$1" >/dev/null 2>&1 || die_run "required command not found: $1"
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      -i | --initiator)
        (($# >= 2)) || die_usage "missing value for $1"
        INITIATOR="$2"
        shift 2
        ;;
      -r | --reflector)
        (($# >= 2)) || die_usage "missing value for $1"
        REFLECTOR="$2"
        shift 2
        ;;
      -m | --mode)
        (($# >= 2)) || die_usage "missing value for $1"
        MODE="$2"
        shift 2
        ;;
      -d | --duration)
        (($# >= 2)) || die_usage "missing value for $1"
        DURATION="$2"
        shift 2
        ;;
      -o | --out-dir)
        (($# >= 2)) || die_usage "missing value for $1"
        OUT_DIR="$2"
        shift 2
        ;;
      --initiator-cobs)
        (($# >= 2)) || die_usage "missing value for $1"
        INITIATOR_COBS_OVERRIDE="$2"
        shift 2
        ;;
      --initiator-console)
        (($# >= 2)) || die_usage "missing value for $1"
        INITIATOR_CONSOLE_OVERRIDE="$2"
        shift 2
        ;;
      --reflector-console)
        (($# >= 2)) || die_usage "missing value for $1"
        REFLECTOR_CONSOLE_OVERRIDE="$2"
        shift 2
        ;;
      --analyze-dir)
        (($# >= 2)) || die_usage "missing value for $1"
        ANALYZE_DIR="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        die_usage "unknown option: $1"
        ;;
      *)
        die_usage "unexpected argument: $1"
        ;;
    esac
  done
  (($# == 0)) || die_usage "unexpected argument: $1"
}

# resolve_port <ident> <cobs|console>
#
# Expands a bare J-Link serial number or a by-id path to the requested VCOM
# interface. J-Link exposes VCOM0 as -if00 and VCOM1 as -if02; on this DK the
# COBS stream is VCOM0 and the console is VCOM1. An input path may carry
# either suffix already (for example when copied from `ls by-id`).
resolve_port() {
  local ident="$1" iface="$2" base suffix

  case "${iface}" in
    cobs) suffix="-if00" ;;
    console) suffix="-if02" ;;
    *)
      printf 'internal error: unknown interface %s\n' "${iface}" >&2
      return 1
      ;;
  esac

  base="${ident}"
  case "${base}" in
    *-if00 | *-if02) base="${base%-if??}" ;;
    *-if??)
      printf "error: unsupported J-Link interface suffix in '%s' (expected none, -if00, or -if02)\n" \
        "${ident}" >&2
      return 1
      ;;
  esac

  case "${base}" in
    /dev/serial/by-id/* | "${SERIAL_BY_ID_DIR}"/*) ;;
    /dev/*)
      printf "error: '%s' is a raw tty path; pass a serial number or a /dev/serial/by-id path, or use --initiator-cobs/--initiator-console/--reflector-console\n" \
        "${ident}" >&2
      return 1
      ;;
    usb-*) base="${SERIAL_BY_ID_DIR}/${base}" ;;
    *) base="${SERIAL_BY_ID_DIR}/usb-SEGGER_J-Link_${base}" ;;
  esac

  printf '%s%s\n' "${base}" "${suffix}"
}

# resolve_or_override <override> <ident> <cobs|console>
resolve_or_override() {
  local override="$1" ident="$2" iface="$3"

  if [[ -n "${override}" ]]; then
    printf '%s\n' "${override}"
    return 0
  fi
  resolve_port "${ident}" "${iface}"
}

# require_port <label> <path>
require_port() {
  local label="$1" path="$2"

  if [[ ! -e "${path}" ]]; then
    die_run "${label} port not found: ${path} (check the DK serial and 'ls ${SERIAL_BY_ID_DIR}')"
  fi
}

print_ports() {
  printf 'mode: %s\n' "${MODE}"
  printf 'initiator COBS    (VCOM0, %d baud): %s\n' "${COBS_BAUD}" "${INITIATOR_COBS_PORT}"
  printf 'initiator console (VCOM1, %d baud): %s\n' "${CONSOLE_BAUD}" "${INITIATOR_CONSOLE_PORT}"
  printf 'reflector console (VCOM1, %d baud): %s\n' "${CONSOLE_BAUD}" "${REFLECTOR_CONSOLE_PORT}"
}

# analyze_capture <initiator-console> <reflector-console> <cobs-binary> <capture-status>
#
# capture-status is "replay" for --analyze-dir, otherwise the three `timeout`
# exit statuses as "a,b,c" (124 = the soak window expired as expected).
analyze_capture() {
  local init_log="$1" refl_log="$2" cobs_bin="$3" capture_status="$4"
  local missing=0 file analysis_status

  for file in "${init_log}" "${refl_log}" "${cobs_bin}"; do
    if [[ ! -f "${file}" ]]; then
      printf 'error: missing capture file: %s\n' "${file}" >&2
      missing=1
    fi
  done
  ((missing == 0)) || return 1

  python3 - "${init_log}" "${refl_log}" "${cobs_bin}" "${MODE}" "${capture_status}" <<'PY'
import re
import sys

# A COBS body larger than this cannot come from the firmware's 29,000-byte
# serialization buffer; treat it as line noise rather than a frame.
MAX_FRAME_BYTES = 65536


def cobs_decode(body):
    """Decode one 0x00-free COBS body; raises ValueError if it is malformed."""
    out = bytearray()
    i = 0
    n = len(body)
    while i < n:
        code = body[i]
        if code == 0:
            raise ValueError("zero byte inside COBS body")
        i += 1
        run = code - 1
        if i + run > n:
            raise ValueError("truncated COBS block")
        out += body[i:i + run]
        i += run
        # A 0xFF code consumes a full 254-byte run and carries no implicit
        # zero. Every other code (except the final block) terminated on a zero.
        if code != 0xFF and i < n:
            out.append(0)
    return bytes(out)


def cobs_encode(data):
    """Re-encode a decoded frame for the canonical-encoding round trip."""
    out = bytearray()
    i = 0
    n = len(data)
    while i <= n:
        zero = data.find(b"\x00", i)
        if zero < 0:
            zero = n
        block = data[i:zero]
        while len(block) > 254:
            out.append(0xFF)
            out.extend(block[:254])
            block = block[254:]
        out.append(len(block) + 1)
        out.extend(block)
        if zero == n:
            break
        i = zero + 1
    return bytes(out)


def read_bytes(path):
    with open(path, "rb") as fh:
        return fh.read()


def split_frames(raw):
    """Split a captured stream into complete COBS bodies.

    A capture starts and ends at an arbitrary point in the stream, so the
    bytes before the first 0x00 and after the last 0x00 are partial frames,
    not malformed records. They are reported separately and ignored.
    """
    leading = b""
    trailing = b""
    if not raw:
        return leading, [], trailing

    parts = raw.split(b"\x00")
    if parts and parts[0]:
        leading = parts.pop(0)
    if parts and parts[-1]:
        trailing = parts.pop()
    frames = [part for part in parts if part]
    return leading, frames, trailing


init_path, refl_path, cobs_path, mode, capture_status = sys.argv[1:6]

init_bytes = read_bytes(init_path)
refl_bytes = read_bytes(refl_path)
cobs_bytes = read_bytes(cobs_path)
init_text = init_bytes.decode("utf-8", "replace")
refl_text = refl_bytes.decode("utf-8", "replace")

# Console signatures (exact literals from the firmware).
empty_procedures = (init_text.count("IPT procedure produced no step data") +
                    init_text.count("All subevents in ranging counter"))
reflector_aborts = refl_text.count("CS subevent aborted")
init_watchdog = init_text.count("CS liveness watchdog")
refl_watchdog = refl_text.count("CS liveness watchdog")

# Evidence that the pair actually serialized procedures.
procedures = [int(value) for value in
              re.findall(r"Run serialization for procedure (\d+)", init_text)]
serialization_events = len(procedures)
last_procedure = procedures[-1] if procedures else -1
backlog_reports = len(re.findall(r"Serialize backlog: dropped", init_text))
diagnostic_backlog_reports = init_text.count("Diagnostic backlog")
initiator_banner = int("Starting Mars Channel Sounding Initiator" in init_text)
reflector_banner = int("Starting Mars Channel Sounding Reflector" in refl_text)

leading_partial, frames, trailing_partial = split_frames(cobs_bytes)
frames_valid = 0
frames_event = 0
frames_log = 0
invalid_reasons = []

for frame in frames:
    try:
        if len(frame) > MAX_FRAME_BYTES:
            raise ValueError(
                f"body {len(frame)} bytes exceeds sane maximum {MAX_FRAME_BYTES}")
        decoded = cobs_decode(frame)
        if not decoded:
            raise ValueError("empty decoded frame")
        if cobs_encode(decoded) != frame:
            raise ValueError("non-canonical COBS encoding")
        tag = decoded[0]
        if tag not in (0, 1):
            raise ValueError(f"unknown envelope variant tag 0x{tag:02x}")
    except ValueError as exc:
        invalid_reasons.append(str(exc))
        continue

    frames_valid += 1
    if tag == 0:
        frames_event += 1
    else:
        frames_log += 1

assertions = []
if capture_status != "replay":
    statuses = [int(value) for value in capture_status.split(",")]
    assertions.append((
        "captures completed for the full soak",
        all(status == 124 for status in statuses),
        f"timeout exit statuses {statuses} (124 = window expired)",
    ))
    # A live capture must show console evidence on the initiator: with no
    # output at all, the zero-warning assertions would be vacuous. The
    # reflector console may legitimately stay silent on an idle IPT pair.
    assertions.append((
        "initiator console capture non-empty",
        len(init_bytes) > 0,
        f"{len(init_bytes)} bytes (wrong port or dead console?)",
    ))
assertions.extend([
    ("initiator empty-procedure signatures == 0",
     empty_procedures == 0, f"found {empty_procedures}"),
    ("initiator serialize backlog reports == 0",
     backlog_reports == 0, f"found {backlog_reports}"),
    ("initiator diagnostic backlog reports == 0",
     diagnostic_backlog_reports == 0, f"found {diagnostic_backlog_reports}"),
    ("reflector aborts == 0",
     reflector_aborts == 0, f"found {reflector_aborts}"),
    ("initiator watchdog recoveries == 0",
     init_watchdog == 0, f"found {init_watchdog}"),
    ("reflector watchdog recoveries == 0",
     refl_watchdog == 0, f"found {refl_watchdog}"),
    ("at least one structurally valid COBS event frame",
     frames_event >= 1,
     f"found {frames_event} event frame(s) among {frames_valid} valid frame(s)"),
])

print(f"two-DK bench summary: mode={mode}")
print("captured files:")
print(f"  initiator console: {init_path} ({len(init_bytes)} bytes)")
print(f"  reflector console: {refl_path} ({len(refl_bytes)} bytes)")
print(f"  initiator COBS:    {cobs_path} ({len(cobs_bytes)} bytes)")
if capture_status == "replay":
    print("  capture status:    replay (no capture performed)")
else:
    print(f"  capture status:    timeout exit statuses {capture_status}")
print("counts:")
counts = [
    ("empty_procedure_warnings", empty_procedures),
    ("reflector_aborts", reflector_aborts),
    ("initiator_watchdog_recoveries", init_watchdog),
    ("reflector_watchdog_recoveries", refl_watchdog),
    ("serialization_events", serialization_events),
    ("last_procedure_counter", last_procedure),
    ("serialize_backlog_reports", backlog_reports),
    ("diagnostic_backlog_reports", diagnostic_backlog_reports),
    ("initiator_banner", initiator_banner),
    ("reflector_banner", reflector_banner),
    ("initiator_console_bytes", len(init_bytes)),
    ("reflector_console_bytes", len(refl_bytes)),
    ("cobs_bytes", len(cobs_bytes)),
    ("frames_valid", frames_valid),
    ("frames_event", frames_event),
    ("frames_log", frames_log),
    ("frames_invalid", len(invalid_reasons)),
    ("leading_partial_bytes", len(leading_partial)),
    ("trailing_partial_bytes", len(trailing_partial)),
]
for key, value in counts:
    print(f"  {key}={value}")
if invalid_reasons:
    print("first invalid COBS frame reasons:")
    for reason in invalid_reasons[:3]:
        print(f"  - {reason}")
# An empty console is evidence of a dead/late capture, not a gate failure:
# a healthy IPT reflector logs only at boot/connect and can be silent for the
# whole soak, so the zero-count assertions stay meaningful via the COBS frames.
if not init_bytes:
    print("warning: initiator console capture is empty (dead port or late start?)",
          file=sys.stderr)
if not refl_bytes:
    print("warning: reflector console capture is empty "
          "(normal for an idle IPT reflector, or a dead port)",
          file=sys.stderr)
print("assertions:")
for name, ok, detail in assertions:
    print(f"  [{'PASS' if ok else 'FAIL'}] {name} ({detail})")

failed = [name for name, ok, _ in assertions if not ok]
if failed:
    if capture_status == "replay":
        print("RESULT: FAIL (replay)")
    else:
        print("RESULT: FAIL")
    sys.exit(1)
if capture_status == "replay":
    print("RESULT: PASS (replay; not live evidence)")
else:
    print("RESULT: PASS")
PY

  # Python exits 1 for a failed assertion. Map every other non-zero status
  # (interpreter crash, syntax error, signal) to the documented failure code
  # 1 so the CLI contract keeps only 0/1/2.
  analysis_status=$?
  if ((analysis_status != 0)); then
    ((analysis_status == 1)) ||
      printf 'error: analysis engine exited with status %d\n' "${analysis_status}" >&2
    return 1
  fi
  return 0
}

# configure_serial <path> <baud> <label>
configure_serial() {
  local path="$1" baud="$2" label="$3"

  if ! stty -F "${path}" "${baud}" raw -echo -crtscts; then
    die_run "could not configure ${label} port ${path} at ${baud} baud"
  fi
}

run_capture() {
  local out_dir="${OUT_DIR}"
  local init_log refl_log cobs_bin
  local init_status refl_status cobs_status

  if [[ -z "${out_dir}" ]]; then
    out_dir="$(mktemp -d "${TMPDIR:-/tmp}/two-dk-bench.XXXXXX")" ||
      die_run "could not create a capture directory"
  else
    mkdir -p "${out_dir}" || die_run "could not create capture directory: ${out_dir}"
  fi

  init_log="${out_dir}/initiator-console.log"
  refl_log="${out_dir}/reflector-console.log"
  cobs_bin="${out_dir}/initiator-cobs.bin"

  printf 'capture dir: %s\n' "${out_dir}"

  configure_serial "${INITIATOR_COBS_PORT}" "${COBS_BAUD}" "initiator COBS"
  configure_serial "${INITIATOR_CONSOLE_PORT}" "${CONSOLE_BAUD}" "initiator console"
  configure_serial "${REFLECTOR_CONSOLE_PORT}" "${CONSOLE_BAUD}" "reflector console"

  # Three independent captures, one soak window. `timeout` exits 124 when the
  # window expires, which is the only expected status; anything else (notably
  # 0, a tty hangup before the window ended) is reported and fails the gate.
  timeout "${DURATION}" cat "${INITIATOR_COBS_PORT}" >"${cobs_bin}" &
  local cobs_pid=$!
  timeout "${DURATION}" cat "${INITIATOR_CONSOLE_PORT}" >"${init_log}" &
  local init_pid=$!
  timeout "${DURATION}" cat "${REFLECTOR_CONSOLE_PORT}" >"${refl_log}" &
  local refl_pid=$!

  wait "${cobs_pid}"
  cobs_status=$?
  wait "${init_pid}"
  init_status=$?
  wait "${refl_pid}"
  refl_status=$?

  for status in "initiator COBS:${cobs_status}" \
    "initiator console:${init_status}" \
    "reflector console:${refl_status}"; do
    if [[ "${status##*:}" -ne 124 ]]; then
      printf 'warning: %s capture exited %s (expected 124 = soak window expired)\n' \
        "${status%%:*}" "${status##*:}" >&2
    fi
  done

  analyze_capture "${init_log}" "${refl_log}" "${cobs_bin}" \
    "${init_status},${refl_status},${cobs_status}"
}

validate_args() {
  if [[ -n "${ANALYZE_DIR}" ]]; then
    [[ -d "${ANALYZE_DIR}" ]] || die_run "analyze directory not found: ${ANALYZE_DIR}"
  else
    [[ -n "${INITIATOR}" ]] || die_usage "--initiator is required"
    [[ -n "${REFLECTOR}" ]] || die_usage "--reflector is required"
    [[ -n "${DURATION}" ]] || die_usage "--duration is required"
    local duration_raw="${DURATION}"
    local duration_trimmed
    [[ "${DURATION}" =~ ^[0-9]+$ ]] ||
      die_usage "--duration must be a positive integer number of seconds, at most ${MAX_DURATION} (got '${duration_raw}')"
    # Strip leading zeros, then cap the remaining digits before any arithmetic:
    # a 20-digit value would otherwise wrap through bash's 64-bit integers
    # (2^64 + 1 becomes 1).
    duration_trimmed="${DURATION#"${DURATION%%[!0]*}"}"
    if [[ -z "${duration_trimmed}" || "${#duration_trimmed}" -gt 6 ]]; then
      die_usage "--duration must be a positive integer number of seconds, at most ${MAX_DURATION} (got '${duration_raw}')"
    fi
    DURATION=$((10#${duration_trimmed}))
    ((DURATION >= 1 && DURATION <= MAX_DURATION)) ||
      die_usage "--duration must be a positive integer number of seconds, at most ${MAX_DURATION} (got '${duration_raw}')"
  fi

  [[ -n "${MODE}" ]] || die_usage "--mode is required"
  MODE="${MODE,,}"
  case "${MODE}" in
    ras | ipt) ;;
    *) die_usage "--mode must be 'ras' or 'ipt' (got '${MODE}')" ;;
  esac
}

main() {
  parse_args "$@"
  validate_args

  require_command python3

  if [[ -n "${ANALYZE_DIR}" ]]; then
    analyze_capture "${ANALYZE_DIR}/initiator-console.log" \
      "${ANALYZE_DIR}/reflector-console.log" \
      "${ANALYZE_DIR}/initiator-cobs.bin" "replay"
    return $?
  fi

  require_command stty
  require_command timeout
  require_command cat
  require_command mktemp

  INITIATOR_COBS_PORT="$(resolve_or_override "${INITIATOR_COBS_OVERRIDE}" "${INITIATOR}" cobs)" || exit 1
  INITIATOR_CONSOLE_PORT="$(resolve_or_override "${INITIATOR_CONSOLE_OVERRIDE}" "${INITIATOR}" console)" || exit 1
  REFLECTOR_CONSOLE_PORT="$(resolve_or_override "${REFLECTOR_CONSOLE_OVERRIDE}" "${REFLECTOR}" console)" || exit 1

  require_port "initiator COBS" "${INITIATOR_COBS_PORT}"
  require_port "initiator console" "${INITIATOR_CONSOLE_PORT}"
  require_port "reflector console" "${REFLECTOR_CONSOLE_PORT}"

  print_ports

  if ((DRY_RUN)); then
    printf 'dry-run: ports resolved, no capture performed\n'
    return 0
  fi

  run_capture
}

main "$@"
