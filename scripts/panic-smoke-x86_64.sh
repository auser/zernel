#!/usr/bin/env zsh
set -eu

iso="${1:-zernel-x86_64-panic-smoke.iso}"
timeout_seconds="${ZERNEL_PANIC_SMOKE_TIMEOUT_SECONDS:-15}"
log_file="${TMPDIR:-/tmp}/zernel-panic-smoke-x86_64.$$.log"

cleanup() {
  if [[ -n "${qemu_pid:-}" ]]; then
    kill "${qemu_pid}" >/dev/null 2>&1 || true
    wait "${qemu_pid}" >/dev/null 2>&1 || true
  fi
  rm -f "${log_file}"
}
trap cleanup EXIT INT TERM

if [[ ! -f "${iso}" ]]; then
  echo "panic smoke: missing ISO: ${iso}" >&2
  exit 2
fi

panic_output_seen() {
  [[ -f "${log_file}" ]] || return 1
  grep -q "PANIC" "${log_file}" &&
    grep -q "panic smoke test" "${log_file}" &&
    grep -q "system halted" "${log_file}"
}

qemu-system-x86_64 \
  -M q35 \
  -m 128M \
  -cdrom "${iso}" \
  -boot d \
  -display none \
  -serial "file:${log_file}" \
  -no-reboot \
  -no-shutdown &
qemu_pid=$!

deadline=$((SECONDS + timeout_seconds))
while (( SECONDS < deadline )); do
  if panic_output_seen; then
    grep -E "PANIC|panic smoke test|system halted" "${log_file}"
    exit 0
  fi

  if ! kill -0 "${qemu_pid}" >/dev/null 2>&1; then
    echo "panic smoke: QEMU exited before panic markers" >&2
    [[ -f "${log_file}" ]] && tail -n 80 "${log_file}" >&2
    exit 1
  fi

  sleep 0.2
done

echo "panic smoke: timed out waiting for panic markers" >&2
[[ -f "${log_file}" ]] && tail -n 80 "${log_file}" >&2
exit 1
