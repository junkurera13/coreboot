#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Firmware-only qemu-q35 S3 detect smoke test (no guest OS required).
#
# QEMU q35 S3 wake is pc_machine_wakeup() -> RESET_TYPE_WAKEUP (CPUs restart
# at the reset vector, RAM preserved) then acpi_notify_wakeup() sets
# PM1_STS.WAK_STS. This script:
#   1. Boots coreboot once (cold) and captures serial
#   2. Issues QMP system_suspend + system_wakeup
#   3. Confirms the second firmware pass prints s3resume=1
#
# Usage:
#   s3-verify.sh [coreboot.rom]
#   COREBOOT_ROM=build/coreboot.rom s3-verify.sh
#
# Requires: qemu-system-x86_64, python3
set -euo pipefail

ROM="${1:-${COREBOOT_ROM:-build/coreboot.rom}}"
QEMU="${QEMU:-qemu-system-x86_64}"
TIMEOUT_SEC="${TIMEOUT_SEC:-90}"
WORKDIR="${WORKDIR:-$(mktemp -d /tmp/q35-s3-XXXXXX)}"
QMP="${WORKDIR}/qmp.sock"
SERIAL="${WORKDIR}/serial.log"
PIDFILE="${WORKDIR}/qemu.pid"

cleanup() {
	if [[ -f "${PIDFILE}" ]]; then
		local pid
		pid="$(cat "${PIDFILE}" 2>/dev/null || true)"
		if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
			kill "${pid}" 2>/dev/null || true
			wait "${pid}" 2>/dev/null || true
		fi
	fi
}
trap cleanup EXIT

if [[ ! -f "${ROM}" ]]; then
	echo "error: ROM not found: ${ROM}" >&2
	echo "Build a qemu-q35 image first, e.g.:" >&2
	echo "  cp configs/config.emulation_qemu_x86_q35_s3_smoke .config" >&2
	echo "  make olddefconfig && make -j\$(nproc)" >&2
	exit 2
fi
if ! command -v "${QEMU}" >/dev/null; then
	echo "error: ${QEMU} not found" >&2
	exit 2
fi
if ! command -v python3 >/dev/null; then
	echo "error: python3 not found" >&2
	exit 2
fi

qmp_cmd() {
	python3 - "${QMP}" "$@" <<'PY'
import json, socket, sys, time

sock_path = sys.argv[1]
cmd = json.loads(sys.argv[2])
deadline = time.time() + 10
last_err = None
while time.time() < deadline:
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(15)
        s.connect(sock_path)
        break
    except OSError as exc:
        last_err = exc
        time.sleep(0.1)
else:
    raise SystemExit(f"qmp connect failed: {last_err}")

def recv_obj(sock):
    buf = b""
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError("qmp eof")
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            if not line.strip():
                continue
            return json.loads(line.decode())

greeting = recv_obj(s)
if "QMP" not in greeting:
    raise SystemExit(f"unexpected qmp greeting: {greeting}")
s.sendall(b'{"execute":"qmp_capabilities"}\n')
recv_obj(s)
s.sendall((json.dumps(cmd) + "\n").encode())
print(json.dumps(recv_obj(s)))
s.close()
PY
}

serial_plain() {
	# Strip coreboot ANSI so grep matches the Q35 S3 line reliably.
	sed 's/\x1b\[[0-9;]*m//g' "${SERIAL}" 2>/dev/null || true
}

wait_serial() {
	local pattern="$1"
	local seconds="$2"
	local deadline=$((SECONDS + seconds))
	while (( SECONDS < deadline )); do
		if [[ -f "${SERIAL}" ]] && serial_plain | grep -qE "${pattern}"; then
			return 0
		fi
		sleep 0.2
	done
	return 1
}

echo "ROM=${ROM}"
echo "WORKDIR=${WORKDIR}"

"${QEMU}" \
	-M q35 \
	-smp 1 \
	-m 1G \
	-bios "${ROM}" \
	-display none \
	-serial "file:${SERIAL}" \
	-qmp "unix:${QMP},server,nowait" \
	-pidfile "${PIDFILE}" \
	-daemonize

if ! wait_serial "Q35 S3:.*s3resume=" "${TIMEOUT_SEC}"; then
	echo "error: timed out waiting for cold-boot Q35 S3 line" >&2
	echo "----- serial -----" >&2
	serial_plain >&2 || true
	exit 1
fi

# Finish ramstage so PMBASE stays programmed before the PM1_CNT S3 write.
wait_serial "Payload not loaded|Jumping to|Boot failed" "${TIMEOUT_SEC}" || true

cold="$(serial_plain | grep -E "Q35 S3:.*s3resume=" | tail -n 1 || true)"
echo "COLD: ${cold}"
if echo "${cold}" | grep -q "s3resume=1"; then
	echo "error: cold boot was detected as S3 resume" >&2
	exit 1
fi

echo "STATUS before S3: $(qmp_cmd '{"execute":"query-status"}')"
# QEMU ACPI PM: byte write to PM1_CNT high byte (I/O 0x605) with
# SLP_TYP=1 | SLP_EN (0x24) is the guest S3 entry path (hw/acpi/core.c).
echo "HMP out PM1_CNT: $(qmp_cmd '{"execute":"human-monitor-command","arguments":{"command-line":"o 0x605 0x24"}}')"
sleep 1
echo "STATUS after S3 write: $(qmp_cmd '{"execute":"query-status"}')"
echo "WAKEUP: $(qmp_cmd '{"execute":"system_wakeup"}')"

if ! wait_serial "s3resume=1" "${TIMEOUT_SEC}"; then
	echo "error: timed out waiting for S3 resume detect" >&2
	echo "----- serial -----" >&2
	serial_plain >&2 || true
	exit 1
fi

resume="$(serial_plain | grep -E "Q35 S3:.*s3resume=1" | tail -n 1 || true)"
echo "WAKE: ${resume}"

# Detection alone is not enough: zero TSEG stage cache prints s3resume=1 then
# postcar_cache_invalid() -> board_reset(), which clears WAK_STS.
wait_serial "S3 Resume|postcar cache invalid|OS waking vector" "${TIMEOUT_SEC}" || true
# Let ramstage finish or reset so failure strings are in the log.
sleep 2

plain="$(serial_plain)"
if echo "${plain}" | grep -q "postcar cache invalid"; then
	echo "error: S3 detected but postcar stage cache was empty/invalid" >&2
	echo "${plain}" >&2
	exit 1
fi
if echo "${plain}" | grep -q "Can't find 57a9e002 metadata"; then
	echo "error: S3 detected but postcar was not in the TSEG stage cache" >&2
	echo "${plain}" >&2
	exit 1
fi
if ! echo "${plain}" | grep -q "S3 Resume"; then
	echo "error: missing romstage_handoff S3 Resume after s3resume=1" >&2
	echo "${plain}" >&2
	exit 1
fi
if echo "${plain}" | grep -q "board_reset"; then
	echo "error: S3 resume path reset the board (not a successful resume)" >&2
	echo "${plain}" >&2
	exit 1
fi

echo "PASS: QEMU q35 firmware distinguished cold boot vs S3 wake and resumed without reset"
echo "SERIAL=${SERIAL}"
# Keep logs for the caller; do not delete WORKDIR on success.
trap - EXIT
if [[ -f "${PIDFILE}" ]]; then
	pid="$(cat "${PIDFILE}")"
	kill "${pid}" 2>/dev/null || true
	wait "${pid}" 2>/dev/null || true
fi
echo "Full serial log:"
serial_plain
