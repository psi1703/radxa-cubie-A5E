#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INITBOX_REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export INITBOX_REPO_ROOT

# shellcheck source=scripts/lib/profile.sh
. "${SCRIPT_DIR}/lib/profile.sh"
# shellcheck source=scripts/lib/state.sh
. "${SCRIPT_DIR}/lib/state.sh"
# shellcheck source=scripts/lib/modules.sh
. "${SCRIPT_DIR}/lib/modules.sh"
# shellcheck source=scripts/lib/packages.sh
. "${SCRIPT_DIR}/lib/packages.sh"

PROFILE_ARG="${INITBOX_PROFILE:-${1:-}}"
load_profile "$PROFILE_ARG"

LOG_DIR="/var/log/initbox"
if id -u "$OWNER" >/dev/null 2>&1; then
  LOG_DIR="/home/${OWNER}/pi_logs"
fi
install -d -m 0755 "$LOG_DIR"
LOGFILE="${LOG_DIR}/initbox-install.log"
export LOGFILE OWNER

INITBOX_STATE_FILE="/etc/initbox/install-state.env"
INITBOX_MODS_FILE="/etc/initbox-mods.conf"
export INITBOX_STATE_FILE INITBOX_MODS_FILE
ensure_state_files

export DEBIAN_FRONTEND=noninteractive LC_ALL=C

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root: sudo ./scripts/initbox-installer.sh" >&2
  exit 1
fi

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[INSTALL $(ts)] $*" | tee -a "$LOGFILE"; }
warn() { echo "[INSTALL $(ts)] [WARN] $*" | tee -a "$LOGFILE" >&2; }

pause() {
  echo
  read -r -p "Press ENTER to continue..." _ </dev/tty || true
}

status_text() {
  local id="$1"
  if module_state_is_installed "$id"; then
    printf '[INSTALLED]'
  else
    printf '[missing ]'
  fi
}

run_module() {
  local id="$1" action="${2:-install}" script label rc
  script="$(module_script "$id")"
  label="$(module_label "$id")"

  if [[ ! -f "$script" ]]; then
    warn "Module script missing for ${id}: ${script}"
    pause
    return 0
  fi

  chmod +x "$script" 2>/dev/null || true
  log "Running module ${id}: ${label} (${action})"
  if "$script" "$action"; then
    rc=0
    if [[ "$action" == "install" ]]; then
      set_module_state "$id" 1
    elif [[ "$action" == "uninstall" ]]; then
      set_module_state "$id" 0
    fi
  else
    rc=$?
    warn "Module ${id} failed with exit code ${rc}"
  fi
  pause
  return "$rc"
}

run_default_install() {
  local id
  for id in $DEFAULT_MODULES; do
    if module_is_available "$id"; then
      run_module "$id" install || return $?
    else
      warn "Skipping unavailable module: $id"
    fi
  done
}

show_state() {
  echo "Profile: ${PROFILE_NAME} (${PROFILE_ID})"
  echo "Profile file: ${PROFILE_PATH}"
  echo "Log file: ${LOGFILE}"
  echo
  echo "Module state:"
  if [[ -s "$INITBOX_STATE_FILE" ]]; then
    sort "$INITBOX_STATE_FILE"
  else
    echo "  no state recorded yet"
  fi
  echo
  echo "Compatibility flags:"
  if [[ -s "$INITBOX_MODS_FILE" ]]; then
    sort "$INITBOX_MODS_FILE"
  else
    echo "  no flags recorded yet"
  fi
  pause
}

show_logs() {
  if [[ -f "$LOGFILE" ]]; then
    tail -n 120 "$LOGFILE"
  else
    echo "No log file yet: $LOGFILE"
  fi
  pause
}

module_menu() {
  local title="$1" action="$2" choice idx id modules=()
  mapfile -t modules < <(supported_modules)

  while true; do
    clear
    echo "======================================================"
    echo " InitBox ${title}"
    echo " Profile: ${PROFILE_NAME}"
    echo "======================================================"
    idx=1
    for id in "${modules[@]}"; do
      printf ' %d) %-10s %-36s %s\n' "$idx" "$id" "$(module_label "$id")" "$(status_text "$id")"
      idx=$((idx + 1))
    done
    echo " a) Run default module order"
    echo " b) Back"
    echo "------------------------------------------------------"
    read -r -p "Select: " choice </dev/tty || choice="b"

    case "$choice" in
      a|A)
        if [[ "$action" == "install" ]]; then
          run_default_install
        else
          warn "Default uninstall is intentionally disabled. Remove modules one at a time."
          pause
        fi
        ;;
      b|B|q|Q) break ;;
      ''|*[!0-9]*)
        echo "Invalid choice."
        pause
        ;;
      *)
        if (( choice >= 1 && choice <= ${#modules[@]} )); then
          run_module "${modules[$((choice - 1))]}" "$action"
        else
          echo "Invalid choice."
          pause
        fi
        ;;
    esac
  done
}

sanity_checks() {
  echo "Profile: ${PROFILE_NAME}"
  echo "Repo root: ${INITBOX_REPO_ROOT}"
  echo "Owner: ${OWNER}"
  echo
  echo "Available modules:"
  local id script
  for id in $DEFAULT_MODULES; do
    script="$(module_script "$id" 2>/dev/null || true)"
    if [[ -n "$script" && -f "$script" ]]; then
      printf '  [OK]      %-10s %s\n' "$id" "$script"
    else
      printf '  [missing] %-10s %s\n' "$id" "${script:-unknown}"
    fi
  done
  pause
}

{
  echo "================================================================================"
  echo "Started : $(date -Is)"
  echo "Host    : $(hostname)"
  echo "User    : ${SUDO_USER:-${USER:-root}}"
  echo "Script  : scripts/initbox-installer.sh"
  echo "Profile : ${PROFILE_NAME}"
  echo "--------------------------------------------------------------------------------"
} >> "$LOGFILE"

while true; do
  clear
  echo "======================================================"
  echo " InitBox Radxa Cubie A5E Installer"
  echo "======================================================"
  echo " 1) Install modules"
  echo " 2) Uninstall modules"
  echo " 3) Sanity checks"
  echo " 4) Package cache status"
  echo " 5) Show state"
  echo " 6) Show logs"
  echo " 7) Quit"
  echo "------------------------------------------------------"
  read -r -p "Select [1-7]: " choice </dev/tty || choice="7"

  case "$choice" in
    1) module_menu "Install Menu" install ;;
    2) module_menu "Uninstall Menu" uninstall ;;
    3) sanity_checks ;;
    4) show_package_cache_status; pause ;;
    5) show_state ;;
    6) show_logs ;;
    7|q|Q)
      echo "Log file: $LOGFILE"
      exit 0
      ;;
    *)
      echo "Invalid choice."
      pause
      ;;
  esac
done
