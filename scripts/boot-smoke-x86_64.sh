#!/usr/bin/env zsh
set -eu

iso="${1:-zernel-x86_64.iso}"
marker="__ZERNEL_BOOT_REPORT__"
timeout_seconds="${ZERNEL_BOOT_SMOKE_TIMEOUT_SECONDS:-15}"
log_file="${TMPDIR:-/tmp}/zernel-boot-smoke-x86_64.$$.log"

cleanup() {
  if [[ -n "${qemu_pid:-}" ]]; then
    kill "${qemu_pid}" >/dev/null 2>&1 || true
    wait "${qemu_pid}" >/dev/null 2>&1 || true
  fi
  rm -f "${log_file}"
}
trap cleanup EXIT INT TERM

validate_boot_report() {
  local report_json="$1"

  if ! jq -e \
    '.version == 1
     and .arch == "x86_64"
     and .build == "ReleaseSafe"
     and (.commit | type == "string")
     and (.commit | length >= 7)
     and .objects == 4
     and .caps == 2
     and .cells == 1
     and .routes == 1
     and .provenance >= 11' \
    >/dev/null <<<"${report_json}"; then
    echo "boot smoke: boot report did not match expected fields" >&2
    echo "${report_json}" >&2
    exit 1
  fi
}

if [[ ! -f "${iso}" ]]; then
  echo "boot smoke: missing ISO: ${iso}" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "boot smoke: jq is required for boot report validation" >&2
  exit 2
fi

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
  if [[ -f "${log_file}" ]] && grep -q "${marker}" "${log_file}"; then
    report_line="$(grep "${marker}" "${log_file}" | tail -n 1)"
    report_json="${report_line#*${marker} }"
    validate_boot_report "${report_json}"
    echo "${report_line}"
    exit 0
  fi

  if ! kill -0 "${qemu_pid}" >/dev/null 2>&1; then
    echo "boot smoke: QEMU exited before boot report" >&2
    [[ -f "${log_file}" ]] && tail -n 80 "${log_file}" >&2
    exit 1
  fi

  sleep 0.2
done

echo "boot smoke: timed out waiting for ${marker}" >&2
[[ -f "${log_file}" ]] && tail -n 80 "${log_file}" >&2
exit 1
