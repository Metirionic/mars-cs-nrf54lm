#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Two-DK bench harness for the nRF54LM20-DK Channel Sounding pair.
#
# Captures, for a full soak window:
#   - the initiator console (VCOM1/uart20 at 115200, or the USB console
#     function);
#   - the reflector console (VCOM1/uart20 at 115200, or the USB console
#     function);
#   - the initiator COBS ranging stream (VCOM0/uart30 at 1,000,000 8N1, or
#     the USB data function).
#
# and asserts the release-gate conditions:
#   - zero empty-procedure signatures on the initiator (both the IPT
#     "IPT procedure produced no step data" and the RAS "All subevents in
#     ranging counter" warnings);
#   - zero "Serialize backlog" drop reports on the initiator console (no
#     procedure was dropped at the RX-thread -> consumer handoff gate);
#   - zero "Diagnostic backlog" drop reports on the initiator console (the
#     diagnostic queue never overflowed);
#   - zero "COBS USB: dropped run" reports on a normal USB run (the
#     host-stall procedure asserts the first drop instead, from a freshly
#     reset initiator; boot-with-no-host reports its pre-attach drops
#     without gating them);
#   - zero "CS subevent aborted" warnings (reflector);
#   - zero "CS liveness watchdog" recoveries (both consoles);
#   - at least one structurally valid COBS event frame on the initiator stream.
#
# The summary reports the drop counters and the measured wire rate (captured
# bytes per second and Mbit/s over the data-port window). --analyze-dir
# replays a capture, applying the transport and procedure recorded in its
# capture-info.txt, so the analysis logic is testable without hardware.
#
# Ports are resolved through /dev/serial/by-id so ttyACM renumbering does not
# affect a run. Two transports are supported.
#
# VCOM (default), through the onboard J-Link:
#
#   usb-SEGGER_J-Link_<SN>-if00 = VCOM0 = COBS ranging stream @ 1,000,000 baud
#   usb-SEGGER_J-Link_<SN>-if02 = VCOM1 = console              @ 115,200 baud
#
# That is the reverse of the nRF54L15 DK mapping used by the sibling
# repository's harness: on the LM20 the COBS stream is on VCOM0 and the
# console on VCOM1.
#
# Native USB (--transport usb), through the nRF54LM20 USBHS controller. The
# serial passed to --initiator/--reflector is the SoC-derived USB serial:
#
#   usb-Metirionic_Mars_CS_Initiator_<serial>-if00 = data    (COBS stream)
#   usb-Metirionic_Mars_CS_Initiator_<serial>-if02 = console
#   usb-Metirionic_Mars_CS_Reflector_<serial>-if00 = console
#
# A USB run asserts the negotiated link speed (480 Mbit/s high speed), the
# data/console interface mapping, and the role's USB identity (vendor,
# product ID, product string) through sysfs before any capture starts.
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
#   scripts/two-dk-bench.sh --transport usb --initiator <soc-serial> \
#       --reflector <soc-serial> --mode ras --duration 600
#   scripts/two-dk-bench.sh --transport usb --initiator <soc-serial> \
#       --reflector <soc-serial> --mode ras --duration 60 --stall-after 30
#
# Exit status: 0 = all assertions passed, 1 = capture/assertion failure,
# 2 = command-line usage error.

# No `set -e`: the harness inspects the capture and analysis statuses
# explicitly, and `set -e` would abort before it could print a summary.
set -uo pipefail

PROG="$(basename "$0")"
SERIAL_BY_ID_DIR="${SERIAL_BY_ID_DIR:-/dev/serial/by-id}"
USB_SYSFS_ROOT="${USB_SYSFS_ROOT:-/sys}"
COBS_BAUD=1000000
CONSOLE_BAUD=115200
MAX_DURATION=86400

# Native USB identity and mapping from common/mars_usb.c and the role
# overlays. The by-id name is usb-<manufacturer>_<product>_<serial>-if<NN>
# with spaces replaced by underscores.
USB_VENDOR_ID=1915
USB_INITIATOR_PID=0001
USB_REFLECTOR_PID=0002
USB_INITIATOR_PRODUCT="Mars CS Initiator"
USB_REFLECTOR_PRODUCT="Mars CS Reflector"
USB_REQUIRED_SPEED=480

INITIATOR=""
REFLECTOR=""
MODE=""
TRANSPORT="vcom"
TRANSPORT_EXPLICIT=0
DURATION=""
OUT_DIR=""
INITIATOR_COBS_OVERRIDE=""
INITIATOR_CONSOLE_OVERRIDE=""
REFLECTOR_CONSOLE_OVERRIDE=""
ANALYZE_DIR=""
DRY_RUN=0
ATTACH_AFTER=""
STALL_AFTER=""
INITIATOR_COBS_PORT=""
INITIATOR_CONSOLE_PORT=""
REFLECTOR_CONSOLE_PORT=""
INFO_TRANSPORT=""
INFO_WINDOW=""
INFO_STALL=""
INFO_ATTACH=""
PARSED_SECONDS=""
USB_ROLE_PID=""
USB_ROLE_PRODUCT=""

usage() {
  cat <<EOF
Usage: ${PROG} --initiator <serial|by-id-path> --reflector <serial|by-id-path>
                  --mode <ras|ipt> --duration <seconds> [options]
       ${PROG} --mode <ras|ipt> --analyze-dir <dir>

Required for a capture run:
  -i, --initiator ID        Initiator DK serial or /dev/serial/by-id path
                            (VCOM: J-Link serial; USB: SoC-derived USB serial)
  -r, --reflector ID        Reflector DK serial or /dev/serial/by-id path
                            (VCOM: J-Link serial; USB: SoC-derived USB serial)
  -m, --mode MODE           Ranging mode: ras or ipt
  -d, --duration SECONDS    Soak duration, positive integer seconds
                            (max ${MAX_DURATION} = 24 h); with --analyze-dir,
                            optional and used only for the wire-rate window

Options:
  -t, --transport NAME      Port transport: vcom (default) or usb
  -o, --out-dir DIR         Capture directory (default: a fresh mktemp -d)
      --initiator-cobs PATH     Override the initiator COBS/data port
      --initiator-console PATH  Override the initiator console port
      --reflector-console PATH  Override the reflector console port
      --attach-after SECONDS    Boot-with-no-host procedure: start the data
                                capture SECONDS into the soak, leaving the
                                initiator data port unopened while the board
                                boots, then confirm streaming starts
      --stall-after SECONDS     Host-stall procedure: stop reading the
                                initiator data port SECONDS into the soak
                                while keeping it open and the consoles
                                capturing, then confirm the firmware stays
                                alive and reports the USB transport drop.
                                Reset the initiator just before the run (see
                                the fresh-boot note below) so the report is
                                visible from a zero drop counter
      --analyze-dir DIR         Re-run the assertions on a previous capture
                                (DIR must hold initiator-console.log,
                                reflector-console.log, initiator-cobs.bin; an
                                optional capture-info.txt supplies transport,
                                window, and procedure metadata); no hardware
                                is touched
      --dry-run                 Resolve and print the ports, then exit
  -h, --help                Show this help

VCOM port resolution: a bare serial number expands to
${SERIAL_BY_ID_DIR}/usb-SEGGER_J-Link_<serial>; a by-id path may be
given with or without its -if00/-if02 suffix. The explicit overrides accept any
tty path and are the escape hatch for non-J-Link wiring.

USB port resolution: a bare SoC-derived serial expands to
${SERIAL_BY_ID_DIR}/usb-Metirionic_Mars_CS_Initiator_<serial> for the
initiator and ..._Reflector_<serial> for the reflector; a by-id path may be
given with or without its interface suffix. The initiator data port is -if00
and its console -if02; the reflector console is -if00. A USB run asserts the
480 Mbit/s high-speed link, the interface mapping, and the role identity
through USB_SYSFS_ROOT (default: /sys). SERIAL_BY_ID_DIR overrides the by-id
root (default: /dev/serial/by-id).

Start a USB release run from a freshly reset initiator: reset or reflash,
wait for the native-USB device to re-enumerate, then start the harness. The
USB transport gate sees only the drop reports the firmware emits (the first
drop and every 128th), so a stale counter can hide up to 127 new drops and
let a dirty run pass.

The harness does not flash the DKs. Flash a matched mode pair first:
  VCOM RAS: nrf54lm20dk_cent_a1_4 + nrf54lm20dk_peri_a1_4
  VCOM IPT: nrf54lm20dk_cent_a1_4_ipt + nrf54lm20dk_peri_a1_4_ipt
  USB RAS:  nrf54lm20dk_usb_cent_a1_4 + nrf54lm20dk_usb_peri_a1_4
  USB IPT:  nrf54lm20dk_usb_cent_a1_4_ipt + nrf54lm20dk_usb_peri_a1_4_ipt
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
      -t | --transport)
        (($# >= 2)) || die_usage "missing value for $1"
        TRANSPORT="$2"
        TRANSPORT_EXPLICIT=1
        shift 2
        ;;
      --attach-after)
        (($# >= 2)) || die_usage "missing value for $1"
        ATTACH_AFTER="$2"
        shift 2
        ;;
      --stall-after)
        (($# >= 2)) || die_usage "missing value for $1"
        STALL_AFTER="$2"
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

# expand_by_id_path <ident> <bare-prefix>
#
# Expands a bare serial number or usb-* basename under SERIAL_BY_ID_DIR. A
# /dev tty path is rejected: the explicit port overrides are that escape
# hatch. The caller owns any -ifNN suffix handling.
expand_by_id_path() {
  local ident="$1" prefix="$2"

  case "${ident}" in
    /dev/serial/by-id/* | "${SERIAL_BY_ID_DIR}"/*) printf '%s\n' "${ident}" ;;
    /dev/*)
      printf "error: '%s' is a raw tty path; pass a serial number or a /dev/serial/by-id path, or use --initiator-cobs/--initiator-console/--reflector-console\n" \
        "${ident}" >&2
      return 1
      ;;
    usb-*) printf '%s/%s\n' "${SERIAL_BY_ID_DIR}" "${ident}" ;;
    *) printf '%s/%s%s\n' "${SERIAL_BY_ID_DIR}" "${prefix}" "${ident}" ;;
  esac
}

# resolve_vcom_port <ident> <cobs|console>
#
# Expands a bare J-Link serial number or a by-id path to the requested VCOM
# interface. J-Link exposes VCOM0 as -if00 and VCOM1 as -if02; on this DK the
# COBS stream is VCOM0 and the console is VCOM1. An input path may carry
# either suffix already (for example when copied from `ls by-id`).
resolve_vcom_port() {
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

  base="$(expand_by_id_path "${base}" "usb-SEGGER_J-Link_")" || return 1

  printf '%s%s\n' "${base}" "${suffix}"
}

# usb_role_word <initiator|reflector>
usb_role_word() {
  case "$1" in
    initiator) printf 'Initiator' ;;
    reflector) printf 'Reflector' ;;
    *)
      printf 'internal error: unknown USB role %s\n' "$1" >&2
      return 1
      ;;
  esac
}

# usb_role_identity <initiator|reflector>
#
# Sets USB_ROLE_PID and USB_ROLE_PRODUCT for the role.
usb_role_identity() {
  case "$1" in
    initiator)
      USB_ROLE_PID="${USB_INITIATOR_PID}"
      USB_ROLE_PRODUCT="${USB_INITIATOR_PRODUCT}"
      ;;
    reflector)
      USB_ROLE_PID="${USB_REFLECTOR_PID}"
      USB_ROLE_PRODUCT="${USB_REFLECTOR_PRODUCT}"
      ;;
    *)
      printf 'internal error: unknown USB role %s\n' "$1" >&2
      return 1
      ;;
  esac
}

# usb_iface_suffix <role> <cobs|console>
#
# The initiator's two CDC ACM functions occupy host interfaces 00 (data) and
# 02 (console); the reflector has a single console function at 00.
usb_iface_suffix() {
  case "$1:$2" in
    initiator:cobs) printf '%s' "-if00" ;;
    initiator:console) printf '%s' "-if02" ;;
    reflector:console) printf '%s' "-if00" ;;
    *)
      printf 'internal error: no USB interface for role %s and function %s\n' "$1" "$2" >&2
      return 1
      ;;
  esac
}

# resolve_usb_port <ident> <initiator|reflector> <cobs|console>
#
# Expands a bare SoC-derived USB serial or a by-id path to the requested
# native-USB interface. A by-id path may carry any -ifNN suffix; the role and
# function decide the real interface. A path naming the other role is rejected
# rather than silently rewritten.
resolve_usb_port() {
  local ident="$1" role="$2" iface="$3"
  local word suffix prefix base name product

  word="$(usb_role_word "${role}")" || return 1
  suffix="$(usb_iface_suffix "${role}" "${iface}")" || return 1
  usb_role_identity "${role}" || return 1
  prefix="usb-Metirionic_Mars_CS_${word}_"
  product="${USB_ROLE_PRODUCT}"

  base="${ident}"
  case "${base}" in
    *-if[0-9][0-9]) base="${base%-if[0-9][0-9]}" ;;
    *-if??)
      printf "error: unsupported USB interface suffix in '%s' (expected none or -ifNN)\n" \
        "${ident}" >&2
      return 1
      ;;
  esac

  base="$(expand_by_id_path "${base}" "${prefix}")" || return 1

  name="$(basename "${base}")"
  if [[ "${name}" != "${prefix}"* ]]; then
    printf "error: %s USB port must be a '%s' by-id name ('%s...'), got '%s'; check --initiator/--reflector and the transport\n" \
      "${word}" "${product}" "${prefix}" "${name}" >&2
    return 1
  fi

  printf '%s%s\n' "${base}" "${suffix}"
}

# resolve_port <ident> <initiator|reflector> <cobs|console>
resolve_port() {
  local ident="$1" role="$2" iface="$3"

  if [[ "${TRANSPORT}" == "usb" ]]; then
    resolve_usb_port "${ident}" "${role}" "${iface}"
  else
    resolve_vcom_port "${ident}" "${iface}"
  fi
}

# resolve_or_override <override> <ident> <role> <cobs|console>
resolve_or_override() {
  local override="$1" ident="$2" role="$3" iface="$4"

  if [[ -n "${override}" ]]; then
    printf '%s\n' "${override}"
    return 0
  fi
  resolve_port "${ident}" "${role}" "${iface}"
}

# usb_tty_name <path>
usb_tty_name() {
  basename "$(readlink -f "$1")"
}

# usb_interface_dir <path>
usb_interface_dir() {
  printf '%s/class/tty/%s/device\n' "${USB_SYSFS_ROOT}" "$(usb_tty_name "$1")"
}

# usb_device_dir <path>
#
# The tty's sysfs device node is the USB interface; its parent directory is
# the USB device that carries speed, idVendor, idProduct, and product.
usb_device_dir() {
  dirname "$(readlink -f "$(usb_interface_dir "$1")")"
}

# assert_usb_port <label> <path> <role> <cobs|console> <check-identity>
#
# A USB port must be a CDC ACM tty on a 480 Mbit/s high-speed link. Ports
# resolved from a serial additionally prove the by-id interface mapping
# (bInterfaceNumber) and the role identity (vendor, product ID, product
# string). An explicit override is the escape hatch for non-standard wiring,
# so it keeps the link check but skips the role/interface checks.
assert_usb_port() {
  local label="$1" path="$2" role="$3" iface="$4" check_identity="$5"
  local tty iface_dir iface_num expected_num dev_dir speed vendor pid product
  local expected_pid expected_product

  tty="$(usb_tty_name "${path}")"
  if [[ -z "${tty}" || "${tty}" == "/" ]]; then
    die_run "could not resolve ${label} port ${path} to a tty"
  fi

  iface_dir="$(usb_interface_dir "${path}")"
  if [[ ! -e "${iface_dir}" ]]; then
    die_run "${label} port ${path} (${tty}) is not a USB CDC ACM tty: no sysfs interface at ${iface_dir} (USB_SYSFS_ROOT=${USB_SYSFS_ROOT})"
  fi

  dev_dir="$(dirname "$(readlink -f "${iface_dir}")")"
  if [[ ! -r "${dev_dir}/speed" ]]; then
    die_run "${label} port ${path} (${tty}) has no readable USB link speed in ${dev_dir}"
  fi
  speed="$(tr -d '[:space:]' <"${dev_dir}/speed")"
  case "${speed}" in
    480 | 480.0 | 480.00 | 480.000) ;;
    *)
      die_run "${label} port ${path} (${tty}) negotiated ${speed} Mbit/s, expected ${USB_REQUIRED_SPEED} Mbit/s (high speed); a full-speed fallback cannot pass the USB gate"
      ;;
  esac

  if ((check_identity == 0)); then
    return 0
  fi

  expected_num="$(usb_iface_suffix "${role}" "${iface}")" || return 1
  expected_num="${expected_num#-if}"
  if [[ ! -r "${iface_dir}/bInterfaceNumber" ]]; then
    die_run "${label} port ${path} (${tty}) has no readable bInterfaceNumber in ${iface_dir}"
  fi
  iface_num="$(tr -d '[:space:]' <"${iface_dir}/bInterfaceNumber" | tr 'A-F' 'a-f')"
  if [[ "${iface_num}" != "${expected_num}" ]]; then
    die_run "${label} port ${path} (${tty}) is interface ${iface_num}, expected ${expected_num} for the ${role} ${iface}; wrong port or by-id interface"
  fi

  usb_role_identity "${role}" || return 1
  expected_pid="${USB_ROLE_PID}"
  expected_product="${USB_ROLE_PRODUCT}"

  vendor="$(tr -d '[:space:]' <"${dev_dir}/idVendor" 2>/dev/null)"
  pid="$(tr -d '[:space:]' <"${dev_dir}/idProduct" 2>/dev/null)"
  product="$(tr -d '\r\n' <"${dev_dir}/product" 2>/dev/null)"

  if [[ "${vendor}" != "${USB_VENDOR_ID}" ]]; then
    die_run "${label} port ${path} (${tty}) has USB vendor ID '${vendor}', expected ${USB_VENDOR_ID}"
  fi
  if [[ "${pid}" != "${expected_pid}" ]]; then
    die_run "${label} port ${path} (${tty}) has USB product ID '${pid}', expected ${expected_pid} (${expected_product})"
  fi
  if [[ -n "${product}" && "${product}" != "${expected_product}" ]]; then
    die_run "${label} port ${path} (${tty}) has USB product string '${product}', expected '${expected_product}'"
  fi
}

# require_port <label> <path>
require_port() {
  local label="$1" path="$2"

  if [[ ! -e "${path}" ]]; then
    die_run "${label} port not found: ${path} (check the DK serial and 'ls ${SERIAL_BY_ID_DIR}')"
  fi
}

print_ports() {
  printf 'transport: %s\n' "${TRANSPORT}"
  printf 'mode: %s\n' "${MODE}"
  if [[ "${TRANSPORT}" == "usb" ]]; then
    printf 'initiator data    (USB CDC ACM -if00, 480 Mbit/s): %s\n' "${INITIATOR_COBS_PORT}"
    printf 'initiator console (USB CDC ACM -if02, 480 Mbit/s): %s\n' "${INITIATOR_CONSOLE_PORT}"
    printf 'reflector console (USB CDC ACM -if00, 480 Mbit/s): %s\n' "${REFLECTOR_CONSOLE_PORT}"
  else
    printf 'initiator COBS    (VCOM0, %d baud): %s\n' "${COBS_BAUD}" "${INITIATOR_COBS_PORT}"
    printf 'initiator console (VCOM1, %d baud): %s\n' "${CONSOLE_BAUD}" "${INITIATOR_CONSOLE_PORT}"
    printf 'reflector console (VCOM1, %d baud): %s\n' "${CONSOLE_BAUD}" "${REFLECTOR_CONSOLE_PORT}"
  fi
}

# load_capture_info <dir>
#
# Reads the optional capture-info.txt written by a live run. Every key is
# best-effort: a capture without the file (including the offline fixtures)
# falls back to the CLI transport and window.
load_capture_info() {
  local dir="$1"
  local file="${dir}/capture-info.txt"
  local key value

  INFO_TRANSPORT=""
  INFO_WINDOW=""
  INFO_STALL=""
  INFO_ATTACH=""
  [[ -f "${file}" ]] || return 0

  while IFS='=' read -r key value; do
    case "${key}" in
      transport) INFO_TRANSPORT="${value}" ;;
      data_window) INFO_WINDOW="${value}" ;;
      duration)
        [[ -n "${INFO_WINDOW}" ]] || INFO_WINDOW="${value}"
        ;;
      stall_after) INFO_STALL="${value}" ;;
      attach_after) INFO_ATTACH="${value}" ;;
    esac
  done <"${file}"
}

# analyze_capture <initiator-console> <reflector-console> <cobs-binary>
#                 <capture-status> <transport> <window-seconds>
#                 <stall-after> <attach-after>
#
# capture-status is "replay" for --analyze-dir, otherwise the three `timeout`
# exit statuses as "a,b,c" (124 = the soak window expired as expected).
# window-seconds is the data-port capture window used for the wire rate; empty
# or 0 means unknown.
analyze_capture() {
  local init_log="$1" refl_log="$2" cobs_bin="$3" capture_status="$4"
  local transport="$5" window="$6" stall_after="$7" attach_after="$8"
  local missing=0 file analysis_status

  for file in "${init_log}" "${refl_log}" "${cobs_bin}"; do
    if [[ ! -f "${file}" ]]; then
      printf 'error: missing capture file: %s\n' "${file}" >&2
      missing=1
    fi
  done
  ((missing == 0)) || return 1

  python3 - "${init_log}" "${refl_log}" "${cobs_bin}" "${MODE}" \
    "${transport}" "${capture_status}" "${window}" "${stall_after}" \
    "${attach_after}" <<'PY'
import os
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


(init_path, refl_path, cobs_path, mode, transport, capture_status,
 window_raw, stall_raw, attach_raw) = sys.argv[1:10]


def positive_int(value):
    """Parse an optional positive-integer metadata value; 0 means unknown."""
    return int(value) if value.isdigit() and int(value) > 0 else 0


def drop_count(text):
    """Largest cumulative USB drop count reported in text, or report count."""
    values = [int(value) for value in re.findall(
        r"COBS USB: dropped run \([^)]*\), (\d+) dropped", text)]
    # A report line is itself evidence of at least one drop, even if a future
    # message format stops carrying the cumulative count.
    return max(values + [text.count("COBS USB: dropped run")])


def read_console_offset(name):
    """Read a console-log byte boundary written by a fault procedure."""
    path = os.path.join(os.path.dirname(os.path.abspath(cobs_path)), name)
    try:
        with open(path, "r", encoding="ascii") as fh:
            return max(0, int(fh.read().strip() or "0"))
    except (OSError, ValueError):
        return None


window_s = positive_int(window_raw)
stall_after_s = positive_int(stall_raw)
attach_after_s = positive_int(attach_raw)

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
# The USB backend logs the first drop and every 128th, carrying the cumulative
# count in the message; the largest seen value is the transport drop count.
usb_drop_reports = init_text.count("COBS USB: dropped run")
usb_dropped_runs = drop_count(init_text)
# The fault procedures record the console-log size at their boundary, so the
# analysis can tell a pre-procedure drop from the drop the procedure caused.
stall_offset = read_console_offset("stall-console-offset") if stall_after_s > 0 else None
attach_offset = read_console_offset("attach-console-offset") if attach_after_s > 0 else None
usb_after_stall = (drop_count(init_text[stall_offset:])
                   if stall_offset is not None else usb_dropped_runs)
usb_after_attach = (drop_count(init_text[attach_offset:])
                    if attach_offset is not None else None)
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
    if stall_after_s > 0:
        completed = (statuses[0] == 124 and statuses[1] == 124 and
                     statuses[2] == 0)
        detail = (f"console statuses {statuses[:2]}, data reader status "
                  f"{statuses[2]} (0 = controlled stall, 124 = window expired)")
    else:
        completed = all(status == 124 for status in statuses)
        detail = f"timeout exit statuses {statuses} (124 = window expired)"
    assertions.append(("captures completed for the full soak", completed, detail))
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

# A USB fault procedure deliberately blocks the transport, so the handoff and
# diagnostic backlog counters are expected to move; they are reported, not
# gated. A normal run keeps the zero-backlog gate in both transports.
usb_fault_procedure = (transport == "usb" and
                       (stall_after_s > 0 or attach_after_s > 0))
if not usb_fault_procedure:
    assertions.extend([
        ("initiator serialize backlog reports == 0",
         backlog_reports == 0, f"found {backlog_reports}"),
        ("initiator diagnostic backlog reports == 0",
         diagnostic_backlog_reports == 0,
         f"found {diagnostic_backlog_reports}"),
    ])

# The USB transport gate: a normal run must not drop a run at the transport.
# The host-stall procedure deliberately stops reading, so a drop report after
# its console boundary is the expected evidence instead. Boot-with-no-host
# withholds the reader only until the attach boundary: pre-attach drops are
# expected, post-attach drops are not.
if transport == "usb":
    if stall_after_s > 0:
        assertions.append((
            "initiator USB dropped runs after the stall >= 1",
            usb_after_stall >= 1,
            f"found {usb_after_stall} after the {stall_after_s} s boundary",
        ))
    elif attach_after_s > 0:
        if usb_after_attach is not None:
            assertions.append((
                "initiator USB dropped runs after attach == 0",
                usb_after_attach == 0,
                f"found {usb_after_attach} after the {attach_after_s} s boundary",
            ))
    else:
        assertions.append((
            "initiator USB dropped runs == 0",
            usb_dropped_runs == 0,
            f"found {usb_dropped_runs}",
        ))

if window_s > 0:
    wire_rate_bytes = len(cobs_bytes) / window_s
    wire_rate_bytes_s = f"{wire_rate_bytes:.1f}"
    wire_rate_mbit_s = f"{wire_rate_bytes * 8 / 1000000:.3f}"
else:
    wire_rate_bytes_s = "unknown"
    wire_rate_mbit_s = "unknown"

print(f"two-DK bench summary: transport={transport} mode={mode}")
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
    ("usb_dropped_runs", usb_dropped_runs),
    ("usb_drop_reports", usb_drop_reports),
    ("usb_dropped_runs_after_stall", usb_after_stall),
    ("usb_dropped_runs_after_attach",
     usb_after_attach if usb_after_attach is not None else "unknown"),
    ("data_window_s", window_s),
    ("data_attach_after_s", attach_after_s),
    ("data_stall_after_s", stall_after_s),
    ("wire_rate_bytes_per_s", wire_rate_bytes_s),
    ("wire_rate_mbit_per_s", wire_rate_mbit_s),
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
if window_s <= 0:
    print("note: wire rate is unknown without a capture window "
          "(pass --duration with --analyze-dir)")
if usb_fault_procedure:
    print("note: USB fault procedure: handoff/diagnostic backlog counts are "
          "reported, not gated")
if stall_after_s > 0:
    print(f"procedure: host stall at {stall_after_s} s "
          "(data port kept open, reader stopped)")
if attach_after_s > 0:
    print(f"procedure: boot-with-no-host, data port opened at {attach_after_s} s")
    if transport == "usb":
        print("note: boot-with-no-host: pre-attach drops are expected and "
              "not gated; post-attach drops are gated")
        if usb_after_attach is None:
            print("note: no attach console offset recorded; post-attach drops "
                  "are not gated")
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

# configure_serial <path> <baud|empty> <label>
#
# An empty baud means a native USB CDC ACM port: line coding is irrelevant, so
# only raw mode is forced. Setting a custom 1 Mbaud rate on a CDC ACM tty is a
# needless failure mode.
configure_serial() {
  local path="$1" baud="$2" label="$3"

  if [[ -z "${baud}" ]]; then
    if ! stty -F "${path}" raw -echo -crtscts; then
      die_run "could not configure ${label} port ${path} for native USB"
    fi
  elif ! stty -F "${path}" "${baud}" raw -echo -crtscts; then
    die_run "could not configure ${label} port ${path} at ${baud} baud"
  fi
}

run_capture() {
  local out_dir="${OUT_DIR}"
  local init_log refl_log cobs_bin
  local init_status refl_status cobs_status
  local data_window="${DURATION}" data_label="initiator COBS"
  local data_baud="${COBS_BAUD}"

  if [[ "${TRANSPORT}" == "usb" ]]; then
    data_label="initiator data"
    data_baud=""
  fi
  if [[ -n "${ATTACH_AFTER}" ]]; then
    data_window=$((DURATION - ATTACH_AFTER))
  fi
  if [[ -n "${STALL_AFTER}" ]]; then
    data_window="${STALL_AFTER}"
  fi

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

  # Record what the capture was, so a later --analyze-dir replay applies the
  # same transport, window, and procedure without the operator re-stating them.
  cat >"${out_dir}/capture-info.txt" <<EOF
transport=${TRANSPORT}
mode=${MODE}
duration=${DURATION}
data_window=${data_window}
attach_after=${ATTACH_AFTER:-0}
stall_after=${STALL_AFTER:-0}
initiator_data=${INITIATOR_COBS_PORT}
initiator_console=${INITIATOR_CONSOLE_PORT}
reflector_console=${REFLECTOR_CONSOLE_PORT}
EOF

  # The USB console functions are output-only and only parsed as text, so they
  # need no line-discipline setup. Skipping it also avoids a hang: tcsetattr
  # blocks when the unread console buffer of a long-running USB image is full,
  # which is exactly the state a bench capture starts in.
  if [[ "${TRANSPORT}" == "vcom" ]]; then
    configure_serial "${INITIATOR_CONSOLE_PORT}" "${CONSOLE_BAUD}" "initiator console"
    configure_serial "${REFLECTOR_CONSOLE_PORT}" "${CONSOLE_BAUD}" "reflector console"
  fi

  # The consoles capture for the whole soak. The data stream may start late
  # (boot-with-no-host) or stop being read early (host stall). In the normal
  # and attach procedures its `timeout` window is expected to expire with
  # status 124; anything else (notably 0, a tty hangup before the window
  # ended) is reported and fails the gate.
  timeout "${DURATION}" cat "${INITIATOR_CONSOLE_PORT}" >"${init_log}" &
  local init_pid=$!
  timeout "${DURATION}" cat "${REFLECTOR_CONSOLE_PORT}" >"${refl_log}" &
  local refl_pid=$!

  if [[ -n "${ATTACH_AFTER}" ]]; then
    printf 'boot-with-no-host: leaving the %s port unopened for %s s\n' \
      "${data_label}" "${ATTACH_AFTER}"
    sleep "${ATTACH_AFTER}"
    # Console-log boundary for the attached phase: a drop report after this
    # offset is a post-attach drop and is gated.
    wc -c <"${init_log}" | tr -d '[:space:]' >"${out_dir}/attach-console-offset"
  fi
  # Configure the data port only when the capture is about to attach it, so
  # the boot-with-no-host procedure leaves it untouched while the board boots.
  configure_serial "${INITIATOR_COBS_PORT}" "${data_baud}" "${data_label}"

  if [[ -n "${STALL_AFTER}" ]]; then
    printf 'host stall: stop reading the %s port after %s s (port kept open)\n' \
      "${data_label}" "${STALL_AFTER}"
    # A stopped reader is the designed host-stall case: the port stays open
    # (DTR asserted), the host simply stops consuming, the kernel and device
    # buffers fill, and the firmware's bounded wait drops whole runs. Closing
    # the tty instead deasserts DTR and is a different condition.
    python3 - "${INITIATOR_COBS_PORT}" "${cobs_bin}" "${init_log}" \
      "${out_dir}/stall-console-offset" "${STALL_AFTER}" "${DURATION}" <<'PY' &
import os
import select
import sys
import time

(port, out_path, console_path, offset_path,
 stall_after_raw, duration_raw) = sys.argv[1:7]
stall_after = int(stall_after_raw)
duration = int(duration_raw)

fd = os.open(port, os.O_RDONLY | os.O_NONBLOCK)
deadline = time.time() + stall_after
with open(out_path, "wb") as out:
    while time.time() < deadline:
        ready, _, _ = select.select(
            [fd], [], [], min(0.2, max(0.0, deadline - time.time())))
        if not ready:
            continue
        try:
            data = os.read(fd, 65536)
        except BlockingIOError:
            continue
        if not data:
            break
        out.write(data)
    out.flush()
    # Console-log boundary for the stalled phase: a drop report after this
    # offset is the evidence the host-stall procedure asserts.
    try:
        offset = os.path.getsize(console_path)
    except OSError:
        offset = 0
    with open(offset_path, "w") as fh:
        fh.write(str(offset))
    # Keep the port open but unread until the soak window ends.
    time.sleep(max(0.0, duration - stall_after))
os.close(fd)
PY
    local cobs_pid=$!
  else
    timeout "${data_window}" cat "${INITIATOR_COBS_PORT}" >"${cobs_bin}" &
    local cobs_pid=$!
  fi

  wait "${cobs_pid}"
  cobs_status=$?
  wait "${init_pid}"
  init_status=$?
  wait "${refl_pid}"
  refl_status=$?

  # In the host-stall procedure the controlled reader exits 0 after keeping
  # the port open and unread for the rest of the soak; the consoles still end
  # by expiring their timeout window.
  local expected_cobs_status=124
  if [[ -n "${STALL_AFTER}" ]]; then
    expected_cobs_status=0
  fi
  if [[ "${cobs_status}" -ne "${expected_cobs_status}" ]]; then
    printf 'warning: %s capture exited %s (expected %s)\n' \
      "${data_label}" "${cobs_status}" "${expected_cobs_status}" >&2
  fi
  for status in "initiator console:${init_status}" \
    "reflector console:${refl_status}"; do
    if [[ "${status##*:}" -ne 124 ]]; then
      printf 'warning: %s capture exited %s (expected 124 = soak window expired)\n' \
        "${status%%:*}" "${status##*:}" >&2
    fi
  done

  analyze_capture "${init_log}" "${refl_log}" "${cobs_bin}" \
    "${init_status},${refl_status},${cobs_status}" "${TRANSPORT}" \
    "${data_window}" "${STALL_AFTER:-0}" "${ATTACH_AFTER:-0}"
}

# normalize_seconds <value>
#
# Prints a positive integer number of seconds with leading zeros removed, or
# returns 1 when the value is not a decimal integer of a sane width. Capping
# the width keeps bash's 64-bit arithmetic from wrapping (2^64 + 1 becomes 1).
normalize_seconds() {
  local value="$1" trimmed

  [[ "${value}" =~ ^[0-9]+$ ]] || return 1
  trimmed="${value#"${value%%[!0]*}"}"
  [[ -n "${trimmed}" && "${#trimmed}" -le 6 ]] || return 1
  printf '%s' "$((10#${trimmed}))"
}

# validate_duration
#
# Parses DURATION as a positive integer number of seconds up to MAX_DURATION.
validate_duration() {
  local raw="${DURATION}" normalized

  normalized="$(normalize_seconds "${raw}")" ||
    die_usage "--duration must be a positive integer number of seconds, at most ${MAX_DURATION} (got '${raw}')"
  DURATION="${normalized}"
  ((DURATION >= 1 && DURATION <= MAX_DURATION)) ||
    die_usage "--duration must be a positive integer number of seconds, at most ${MAX_DURATION} (got '${raw}')"
}

# validate_offset <option> <value>
#
# Parses a fault-procedure offset into PARSED_SECONDS and requires it to fall
# strictly inside the soak window, so the console capture still observes the
# board after the data-port change.
validate_offset() {
  local name="$1" value="$2" normalized

  normalized="$(normalize_seconds "${value}")" ||
    die_usage "${name} must be a positive integer number of seconds, less than --duration (got '${value}')"
  PARSED_SECONDS="${normalized}"
  ((PARSED_SECONDS >= 1 && PARSED_SECONDS < DURATION)) ||
    die_usage "${name} must be a positive integer number of seconds, less than --duration ${DURATION} (got '${value}')"
}

validate_args() {
  TRANSPORT="${TRANSPORT,,}"
  case "${TRANSPORT}" in
    vcom | usb) ;;
    *) die_usage "--transport must be 'vcom' or 'usb' (got '${TRANSPORT}')" ;;
  esac

  if [[ -n "${ANALYZE_DIR}" ]]; then
    [[ -d "${ANALYZE_DIR}" ]] || die_run "analyze directory not found: ${ANALYZE_DIR}"
    [[ -z "${ATTACH_AFTER}" && -z "${STALL_AFTER}" ]] ||
      die_usage "--attach-after/--stall-after describe a live capture; replay reads them from capture-info.txt"
    if [[ -n "${DURATION}" ]]; then
      validate_duration
    fi
  else
    [[ -n "${INITIATOR}" ]] || die_usage "--initiator is required"
    [[ -n "${REFLECTOR}" ]] || die_usage "--reflector is required"
    [[ -n "${DURATION}" ]] || die_usage "--duration is required"
    validate_duration
    [[ -z "${ATTACH_AFTER}" || -z "${STALL_AFTER}" ]] ||
      die_usage "--attach-after and --stall-after are separate procedures; pass only one"
    if [[ -n "${ATTACH_AFTER}" ]]; then
      validate_offset "--attach-after" "${ATTACH_AFTER}"
      ATTACH_AFTER="${PARSED_SECONDS}"
    fi
    if [[ -n "${STALL_AFTER}" ]]; then
      validate_offset "--stall-after" "${STALL_AFTER}"
      STALL_AFTER="${PARSED_SECONDS}"
    fi
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
    load_capture_info "${ANALYZE_DIR}"

    if [[ -n "${INFO_TRANSPORT}" ]]; then
      INFO_TRANSPORT="${INFO_TRANSPORT,,}"
      case "${INFO_TRANSPORT}" in
        vcom | usb) ;;
        *) die_run "capture-info.txt has invalid transport '${INFO_TRANSPORT}'" ;;
      esac
      if ((TRANSPORT_EXPLICIT == 0)); then
        TRANSPORT="${INFO_TRANSPORT}"
      elif [[ "${TRANSPORT}" != "${INFO_TRANSPORT}" ]]; then
        die_run "capture-info.txt says transport=${INFO_TRANSPORT}, but --transport ${TRANSPORT} was given"
      fi
    fi

    local replay_window="${INFO_WINDOW}"
    if [[ -n "${DURATION}" ]]; then
      replay_window="${DURATION}"
    fi
    local info_value
    for info_value in "${replay_window}" "${INFO_STALL}" "${INFO_ATTACH}"; do
      [[ -z "${info_value}" || "${info_value}" =~ ^[0-9]+$ ]] ||
        die_run "capture-info.txt has an invalid numeric value: '${info_value}'"
    done

    analyze_capture "${ANALYZE_DIR}/initiator-console.log" \
      "${ANALYZE_DIR}/reflector-console.log" \
      "${ANALYZE_DIR}/initiator-cobs.bin" "replay" "${TRANSPORT}" \
      "${replay_window}" "${INFO_STALL}" "${INFO_ATTACH}"
    return $?
  fi

  require_command stty
  require_command timeout
  require_command cat
  require_command mktemp

  INITIATOR_COBS_PORT="$(resolve_or_override "${INITIATOR_COBS_OVERRIDE}" "${INITIATOR}" initiator cobs)" || exit 1
  INITIATOR_CONSOLE_PORT="$(resolve_or_override "${INITIATOR_CONSOLE_OVERRIDE}" "${INITIATOR}" initiator console)" || exit 1
  REFLECTOR_CONSOLE_PORT="$(resolve_or_override "${REFLECTOR_CONSOLE_OVERRIDE}" "${REFLECTOR}" reflector console)" || exit 1

  if [[ "${TRANSPORT}" == "usb" ]]; then
    require_port "initiator data" "${INITIATOR_COBS_PORT}"
    require_port "initiator console" "${INITIATOR_CONSOLE_PORT}"
    require_port "reflector console" "${REFLECTOR_CONSOLE_PORT}"

    local init_data_identity=1 init_console_identity=1 refl_console_identity=1
    [[ -n "${INITIATOR_COBS_OVERRIDE}" ]] && init_data_identity=0
    [[ -n "${INITIATOR_CONSOLE_OVERRIDE}" ]] && init_console_identity=0
    [[ -n "${REFLECTOR_CONSOLE_OVERRIDE}" ]] && refl_console_identity=0

    assert_usb_port "initiator data" "${INITIATOR_COBS_PORT}" initiator cobs "${init_data_identity}"
    assert_usb_port "initiator console" "${INITIATOR_CONSOLE_PORT}" initiator console "${init_console_identity}"
    assert_usb_port "reflector console" "${REFLECTOR_CONSOLE_PORT}" reflector console "${refl_console_identity}"

    local init_data_dev init_console_dev refl_console_dev
    init_data_dev="$(usb_device_dir "${INITIATOR_COBS_PORT}")"
    init_console_dev="$(usb_device_dir "${INITIATOR_CONSOLE_PORT}")"
    refl_console_dev="$(usb_device_dir "${REFLECTOR_CONSOLE_PORT}")"

    if [[ "${init_data_dev}" != "${init_console_dev}" ]]; then
      die_run "initiator data and console resolve to different USB devices (${init_data_dev} vs ${init_console_dev}); check the SoC serial and interface mapping"
    fi
    if [[ "${init_data_dev}" == "${refl_console_dev}" ]]; then
      die_run "initiator and reflector resolve to the same USB device (${init_data_dev}); check the two SoC serials"
    fi
  else
    require_port "initiator COBS" "${INITIATOR_COBS_PORT}"
    require_port "initiator console" "${INITIATOR_CONSOLE_PORT}"
    require_port "reflector console" "${REFLECTOR_CONSOLE_PORT}"
  fi

  print_ports

  if ((DRY_RUN)); then
    printf 'dry-run: ports resolved, no capture performed\n'
    return 0
  fi

  run_capture
}

main "$@"
