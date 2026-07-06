#!/usr/bin/env bash
# InitBox module registry for Radxa Cubie A5E. Source this file.

module_label() {
  case "$1" in
    a5e) printf '%s\n' 'A5E base user/headless setup' ;;
    hotspot) printf '%s\n' 'Hotspot and captive DNS' ;;
    dashboard) printf '%s\n' 'React dashboard and web terminal' ;;
    isi) printf '%s\n' 'ISI simulator' ;;
    fms) printf '%s\n' 'FMS/CAN simulator' ;;
    ws-br0) printf '%s\n' 'br0 capture and log prep' ;;
    rtc) printf '%s\n' 'RTC sync' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

module_script() {
  local id="$1"
  : "${INITBOX_REPO_ROOT:?INITBOX_REPO_ROOT is not set}"

  case "$id" in
    a5e) printf '%s\n' "${INITBOX_REPO_ROOT}/module-a5e.sh" ;;
    hotspot) printf '%s\n' "${INITBOX_REPO_ROOT}/module-hotspot.sh" ;;
    dashboard) printf '%s\n' "${INITBOX_REPO_ROOT}/scripts/radxa-cubie-a5e/module-dashboard.sh" ;;
    isi) printf '%s\n' "${INITBOX_REPO_ROOT}/module-isi.sh" ;;
    fms) printf '%s\n' "${INITBOX_REPO_ROOT}/module-fms.sh" ;;
    ws-br0) printf '%s\n' "${INITBOX_REPO_ROOT}/module-ws-br0.sh" ;;
    rtc) printf '%s\n' "${INITBOX_REPO_ROOT}/module-rtc.sh" ;;
    *) return 1 ;;
  esac
}

module_is_available() {
  local script
  script="$(module_script "$1" 2>/dev/null || true)"
  [[ -n "$script" && -f "$script" ]]
}

supported_modules() {
  local id
  for id in $DEFAULT_MODULES; do
    if module_is_available "$id"; then
      printf '%s\n' "$id"
    fi
  done
}
