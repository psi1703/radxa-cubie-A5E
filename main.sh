#!/usr/bin/env bash
set -uo pipefail

# ------------ Constants & Globals ------------
OWNER="initbox"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# IMPORTANT:
# main.sh must be runnable on a fresh image *before* the A5E base module is
# installed. That means we cannot assume /home/initbox exists, and we should
# not create the initbox user here.
#
# Until module-a5e.sh creates initbox (and migrates the installer), we log to a
# root-owned location.
LOG_DIR="/var/log/initbox"
mkdir -p "$LOG_DIR"
chmod 0755 "$LOG_DIR" 2>/dev/null || true
LOGFILE="${LOG_DIR}/initbox-install.log"

export DEBIAN_FRONTEND=noninteractive LC_ALL=C
export OWNER SCRIPT_DIR LOGFILE

# ------------ Logging helpers ------------
ts(){ date +"%Y-%m-%d %H:%M:%S"; }
log(){  echo "[INFO  $(ts)] $*"  | tee -a "$LOGFILE"; }
ok(){   echo "[OK    $(ts)] $*"  | tee -a "$LOGFILE"; }
warn(){ echo "[WARN  $(ts)] $*"  | tee -a "$LOGFILE"; }
err(){  echo "[ERROR $(ts)] $*" | tee -a "$LOGFILE"; }

apt_safe(){
  apt-get -o Dpkg::Use-Pty=0 -o Acquire::Retries=5 "$@" >>"$LOGFILE" 2>&1
}

# ------------ Owner / baseline setup ------------
# NOTE: initbox is created by module-a5e.sh, not by main.sh.
# This helper can be used by modules *after* initbox exists to ensure
# groups/sudoers are set, but it will never create the user.
ensure_owner(){
  if ! id -u "$OWNER" >/dev/null 2>&1; then
    warn "User $OWNER does not exist yet. Run '0) A5E base' first."
    return 0
  fi

  for g in wireshark netdev spi i2c gpio; do
    getent group "$g" >/dev/null 2>&1 || groupadd -r "$g" || true
    usermod -aG "$g" "$OWNER" || true
  done

  local sudo_file="/etc/sudoers.d/010-initbox-nopasswd"
  if [[ ! -f "$sudo_file" ]]; then
    log "Granting passwordless sudo to $OWNER …"
    echo "$OWNER ALL=(ALL) NOPASSWD:ALL" > "$sudo_file"
    chmod 0440 "$sudo_file"
  fi
}

disable_ipv6_early(){
  for f in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
    [[ -f "$f" ]] || continue
    if ! grep -q 'ipv6.disable=1' "$f"; then
      sed -i '1s/$/ ipv6.disable=1/' "$f"
      log "IPv6 disabled in $f (requires reboot)."
    fi
    return 0
  done
}

baseline(){
  disable_ipv6_early

  log "Running baseline APT maintenance …"
  apt_safe update -y
  apt_safe -y --with-new-pkgs upgrade || true
  apt_safe -y full-upgrade || true

  ok "Baseline ready."
}

# ------------ Module presence detection ------------
# Generic helper: “is there a marker line in the install log?”
module_done() {
  local pattern="$1"
  [[ -f "$LOGFILE" ]] && grep -Fq -- "$pattern" "$LOGFILE"
}

# 0) A5E base (Cubie-only headless/base setup)
# Prefer an explicit marker written by module-a5e.sh; fall back to a conservative
# heuristic to support older installations.
has_a5e() {
  if [[ -f "$MODULES_FILE" ]] && grep -q '^A5E=1' "$MODULES_FILE" 2>/dev/null; then
    return 0
  fi

  # Fallback heuristic (legacy): headless default target and no stock users.
  if id radxa >/dev/null 2>&1 || id rock >/dev/null 2>&1; then
    return 1
  fi
  systemctl get-default 2>/dev/null | grep -q '^multi-user.target'
}

# 1) Hotspot    (wlan0 AP for SSH)
# Make sure module-hotspot.sh logs: "Hotspot module installed."
has_hotspot() {
  module_done "Hotspot module installed."
}

# 2) Dashboard  (Node-RED + ttyd portal)
# e.g. module-dashboard.sh logs: "Dashboard module installed."
has_dashboard() {
  module_done "Dashboard module installed."
}

# 3) ISI    (br0, 3ns + 3 ISI clients, time-sync via COPILOTpc)
# module-isi.sh already logs this:
#   "ISI simulator module installed. Check 'journalctl -u isirunall.service' for logs."
has_isi() {
  module_done "ISI simulator module installed."
}

# 4) FMS    (CAN/FMS replay using MCP2515)
# Make sure module-fms.sh logs: "FMS module installed."
has_fms() {
  module_done "FMS module installed."
}

# 5) Wireshark + Bridge (capture on br0)
# e.g. module-wireshark.sh logs: "Wireshark + Bridge + log-prep module installed."
has_wireshark() {
  [[ -x /usr/local/bin/wireshark.sh ]] && [[ -f /etc/systemd/system/wireshark-autostart.service ]]
}

# 6) RTCsync    (rtc-sync timer + service)
# module-rtc.sh already logs this:
#   "RTC module installed. Check 'journalctl -u rtc-sync.service' for logs."
has_rtcsync() {
  module_done "RTC module installed."
}

status_flag() {
  # usage: status_flag has_isi
  if "$1"; then
    printf '[INSTALLED]'
  else
    printf '[missing ]'
  fi
}

MODULES_FILE="/etc/initbox-mods.conf"

set_module_flag() {
  local key="$1" val="$2"
  touch "$MODULES_FILE"
  if grep -q "^${key}=" "$MODULES_FILE" 2>/dev/null; then
    sed -i "s/^${key}=.*/${key}=${val}/" "$MODULES_FILE"
  else
    echo "${key}=${val}" >> "$MODULES_FILE"
  fi
}

refresh_module_flags() {
  has_a5e       && set_module_flag A5E 1
  has_isi       && set_module_flag ISI 1
  has_fms       && set_module_flag FMS 1
  has_hotspot   && set_module_flag HOTSPOT 1
  has_dashboard && set_module_flag DASHBOARD 1
  has_wireshark && set_module_flag WSBR0 1
  has_rtcsync   && set_module_flag RTCSYNC 1
}

# ------------ Module dispatcher ------------
run_module() {
  # usage: run_module module-isi.sh "ISI"
  local script="$1"
  local name="$2"

  if [[ -x "$SCRIPT_DIR/$script" ]]; then
    echo
    echo "=== Running module: $name ($script) ==="
    "$SCRIPT_DIR/$script"
    local rc=$?
    echo "=== Module $name finished with exit code $rc ==="
  else
    echo
    echo "ERROR: $SCRIPT_DIR/$script not found or not executable."
    echo "Please check the file name and permissions."
  fi

  echo
  read -rp "Press ENTER to return to menu..." _
}

# ------------ Logging header & sanity ------------
{
  echo "================================================================================"
  echo "Started : $(date -Is)"
  echo "Host    : $(hostname)"
  echo "User    : ${SUDO_USER:-$USER}"
  echo "Script  : $(basename "$0")"
  echo "Dir     : $SCRIPT_DIR"
  echo "--------------------------------------------------------------------------------"
} >> "$LOGFILE"

if [[ $EUID -ne 0 ]]; then
  err "Run as root (sudo)."
  exit 1
fi

# ------------ Uninstall helpers ------------
uninstall_isi() {
  log "Uninstalling ISI module (service and helper scripts) …"
  systemctl stop isirunall.service 2>/dev/null || true
  systemctl disable isirunall.service 2>/dev/null || true
  rm -f /etc/systemd/system/isirunall.service
  systemctl daemon-reload

  rm -f /usr/local/bin/isirunall.sh \
        /usr/local/bin/isi1.txt \
        /usr/local/bin/isi2.txt \
        /usr/local/bin/isi3.txt

  log "ISI module uninstall complete. Any leftover network namespaces will vanish after a reboot."
  set_module_flag ISI 0
}

uninstall_fms() {
  log "Uninstalling FMS module (service and helper scripts) …"
  systemctl stop fms.service 2>/dev/null || true
  systemctl disable fms.service 2>/dev/null || true
  rm -f /etc/systemd/system/fms.service
  systemctl daemon-reload

  rm -f /usr/local/bin/fms.py \
        /usr/local/bin/CAN.trc

  log "FMS module uninstall complete. MCP2515 overlay in config.txt is left in place."
  set_module_flag FMS 0
}

uninstall_wsbr0() {
  log "Uninstalling Wireshark capture + log-prep (bridge left in place) …"
    systemctl stop wireshark-autostart.service 2>/dev/null || true
    systemctl disable wireshark-autostart.service 2>/dev/null || true
    rm -f /etc/systemd/system/wireshark-autostart.service
    systemctl daemon-reload
    rm -f /usr/local/bin/wireshark.sh \
        /usr/local/bin/log-prep.sh
  
  log "Wireshark capture + log-prep uninstall complete. bridge-check.service and br0 are left in place."
  set_module_flag WSBR0 0
}

uninstall_menu() {
  while true; do
    clear
    echo "============================================"
    echo " Initbox Uninstall Menu"
    echo "============================================"
    echo " 1) Uninstall ISI module"
    echo " 2) Uninstall FMS module"
    echo " 3) Uninstall Wireshark capture module (keeps bridge)"
    echo " 4) Back to main menu"
    echo "--------------------------------------------"
    read -rp "Select a module to uninstall [1-5]: " choice
    case "$choice" in
      1) uninstall_isi ;;
      2) uninstall_fms ;;
      3) uninstall_wsbr0 ;;
      4|q|Q) break ;;
      *)
        echo "Invalid choice. Press ENTER and try again."
        read -r _
        ;;
    esac
    refresh_module_flags
  done
}

# ------------ Self-destruct helper ------------

arm_self_destruct() {
  local me="${SCRIPT_DIR}/$(basename "$0")"
  local delay=1200   # 20 minutes

  log "Arming self-destruct: installer script and log directory will be removed in $((delay/60)) minutes …"

  (
    sleep "$delay"
    rm -f "$me"
    rm -rf "$LOG_DIR"
  ) >/dev/null 2>&1 &
}

# ------------ Baseline once ------------
baseline
refresh_module_flags

# ------------ Interactive module selection ------------
while true; do
  clear
  echo "======================================================"
  echo " Initbox Module Installer / Manager"                  
  echo "======================================================"
  echo " 0) A5E base (Cubie headless + initbox)                $(status_flag has_a5e)"
  echo " 1) Hotspot                 (wlan0 AP for SSH)         $(status_flag has_hotspot)"
  echo " 2) Dashboard               (Node-RED + ttyd portal)   $(status_flag has_dashboard)"
  echo " 3) ISI                     (ISI simulator 3 clients)  $(status_flag has_isi)"
  echo " 4) FMS                     (CAN/FMS simulator)        $(status_flag has_fms)"
  echo " 5) Wshark + BR0 + Log-prep (capture on br0)           $(status_flag has_wireshark)"
  echo " 6) RTCsync                 (rtc-sync timer + service) $(status_flag has_rtcsync)"
  echo " 7) Uninstall module(s) (except Hotspot & Bridge)"
  echo " 8) Quit"
  echo "------------------------------------------------------"
  read -rp "Select a module to install/configure [1-8]: " choice

  case "$choice" in
    0)
      run_module "module-a5e.sh" "A5E base (Cubie headless)"
      refresh_module_flags
      ;;
    1)
      if ! has_a5e; then
        echo
        echo "A5E base is not installed yet. Please run: 0) A5E base first."
        read -rp "Press ENTER to return to menu..." _
        continue
      fi
      run_module "module-hotspot.sh" "Hotspot"
      refresh_module_flags
      ;;
    2)
      if ! has_a5e; then
        echo
        echo "A5E base is not installed yet. Please run: 0) A5E base first."
        read -rp "Press ENTER to return to menu..." _
        continue
      fi
      run_module "module-dashboard.sh" "Dashboard"
      refresh_module_flags
      ;;
    3)
      if ! has_a5e; then
        echo
        echo "A5E base is not installed yet. Please run: 0) A5E base first."
        read -rp "Press ENTER to return to menu..." _
        continue
      fi
      run_module "module-isi.sh" "ISI"
      refresh_module_flags
      ;;
    4)
      if ! has_a5e; then
        echo
        echo "A5E base is not installed yet. Please run: 0) A5E base first."
        read -rp "Press ENTER to return to menu..." _
        continue
      fi
      run_module "module-fms.sh" "FMS"
      refresh_module_flags
      ;;
    5)
      if ! has_a5e; then
        echo
        echo "A5E base is not installed yet. Please run: 0) A5E base first."
        read -rp "Press ENTER to return to menu..." _
        continue
      fi
      run_module "module-ws-br0.sh" "Wshark + BR0 + Log-prep"
      refresh_module_flags    
      ;;
    6)
      if ! has_a5e; then
        echo
        echo "A5E base is not installed yet. Please run: 0) A5E base first."
        read -rp "Press ENTER to return to menu..." _
        continue
      fi
      run_module "module-rtc.sh" "RTCsync"
      refresh_module_flags
      ;;
    7)
      uninstall_menu
      ;;
    8|q|Q)
      echo
      echo "Exiting Initbox Module Installer / Manager."
      echo "Install log is at:"
      echo "  $LOGFILE"
      echo
      echo "Installer and log directory will self-destruct in 20 minutes."
      arm_self_destruct
      break
      ;;
    *)
      echo "Invalid choice. Press ENTER and try again."
      read -r _
      ;;  
  esac
done