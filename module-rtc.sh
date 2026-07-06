#!/usr/bin/env bash
set -euo pipefail

: "${OWNER:=initbox}"
: "${LOGFILE:=/home/${OWNER}/pi_logs/initbox-install.log}"

ts(){ date +"%Y-%m-%d %H:%M:%S"; }
log(){  echo "[RTC $(ts)] ""$*""" | tee -a """$LOGFILE"""; }
ok(){   echo "[RTC $(ts)] [OK] ""$*""" | tee -a """$LOGFILE"""; }
warn(){ echo "[RTC $(ts)] [WARN] ""$*""" | tee -a """$LOGFILE""" >&2; }
err(){  echo "[RTC $(ts)] [ERR] ""$*""" | tee -a """$LOGFILE""" >&2; }

apt_safe(){
  apt-get -o Dpkg::Use-Pty=0 -o Acquire::Retries=5 "$@" 2>&1 | tee -a "$LOGFILE"
}

log "Installing RTC helpers …"
apt_safe update -y
apt_safe install -y i2c-tools util-linux python3-smbus || true

# --- Cubie-specific sanity checks (no overlays/boot config edits here) ---
# i2c-tools live in /usr/sbin on Debian; non-root shells may not have that in PATH.
export PATH="/usr/sbin:/sbin:$PATH"

# Ensure timezone is correct for this image (expected: Asia/Dubai, GMT+4)
ensure_timezone(){
  local target_tz="Asia/Dubai" cur_tz=""

  if command -v timedatectl >/dev/null 2>&1; then
    cur_tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  fi
  if [[ -z "${cur_tz}" ]] && [[ -f /etc/timezone ]]; then
    cur_tz="$(tr -d '\n\r' </etc/timezone 2>/dev/null || true)"
  fi

  if [[ "${cur_tz}" != "${target_tz}" ]]; then
    warn "Timezone is '${cur_tz:-unknown}'. Setting timezone to ${target_tz}…"
    if command -v timedatectl >/dev/null 2>&1; then
      timedatectl set-timezone "${target_tz}" >/dev/null 2>&1 || true
    fi
    # Fallback in case timedatectl is unavailable or fails
    if [[ -e "/usr/share/zoneinfo/${target_tz}" ]]; then
      ln -sf "/usr/share/zoneinfo/${target_tz}" /etc/localtime 2>/dev/null || true
      echo "${target_tz}" >/etc/timezone 2>/dev/null || true
    fi
    ok "Timezone set to ${target_tz}."
  else
    ok "Timezone already set to ${target_tz}."
  fi
}

ensure_timezone

detect_ds3231_on_bus(){
  local bus="$1"
  [[ -e "/dev/i2c-${bus}" ]] || return 1

  # Prefer read-probing: on some SUNXI kernels, default "quick write" probing reports an empty bus.
  if command -v i2cdetect >/dev/null 2>&1; then
    if i2cdetect -y -r "$bus" 2>/dev/null | grep -qE '(^|[[:space:]])68([[:space:]]|$)'; then
      return 0
    fi
  fi

  # Fallback: direct register read (works even when i2cdetect probing is quirky)
  if command -v i2cget >/dev/null 2>&1; then
    i2cget -y "$bus" 0x68 0x00 >/dev/null 2>&1 && return 0
  fi

  return 1
}

bind_ds3231(){
  local bus="$1"
  modprobe rtc-ds1307 2>/dev/null || true
  # Idempotent bind
  if [[ ! -e "/sys/bus/i2c/devices/${bus}-0068" ]]; then
    echo ds3231 0x68 >"/sys/bus/i2c/devices/i2c-${bus}/new_device" 2>/dev/null || true
  fi
}

if [[ -e /dev/rtc0 ]]; then
  name="$(cat /sys/class/rtc/rtc0/name 2>/dev/null || echo "unknown")"
  ok "Found /dev/rtc0 (${name}). RTC already configured."
else
  if detect_ds3231_on_bus 1; then
    warn "DS3231 responds at 0x68 on i2c-1, but /dev/rtc0 is missing. Attempting to bind rtc-ds1307 (DS3231)…"
    sudo -n true 2>/dev/null || true
    bind_ds3231 1
    # udev may take a moment; but we won't sleep here—just re-check.
    if [[ -e /dev/rtc0 ]]; then
      name="$(cat /sys/class/rtc/rtc0/name 2>/dev/null || echo "unknown")"
      ok "Bound DS3231; /dev/rtc0 is now present (${name})."
    else
      warn "DS3231 is present on i2c-1 but /dev/rtc0 still did not appear. You may need a reboot or a DT node (rtc@68) for persistence."
    fi
  else
    warn "No /dev/rtc0 and DS3231 not detected on i2c-1."
    warn "Notes: On this kernel, use 'sudo i2cdetect -y -r 1' (default probing may show an empty bus)."
    warn "Check: wiring (3.3V/GND/SDA/SCL), and that the TWI1 overlay is enabled."
  fi
fi

# --- Install rtc-sync.sh (unchanged policy logic, board-agnostic) ---

cat > /usr/local/bin/rtc-sync.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Policy:
# --iso "YYYY-MM-DDTHH:MM:SSZ" or --datetime "DD.MM.YYYY-HH:MM:SS":
#   treat as COPILOT time. If drift > DRIFT_THRESHOLD (default 2s),
#   set system; if RTC present, also write RTC.
#
# No args:
#   If RTC present and system time is bogus -> restore from RTC.
#   If Internet available -> use net time; if drift > DRIFT_THRESHOLD, set system; write RTC if present.
#   Else stay quiet. Also keep RTC aligned to system if RTC drift > 1s.
#
# This script is intentionally generic: works on Cubie, Radxa, Pi, etc,
# as long as there is a kernel RTC (/dev/rtc0) and hwclock works.

DRIFT_THRESHOLD="${DRIFT_THRESHOLD:-2}"

now_epoch() {
  date +%s
}

abs() {
  local v="${1:-0}"
  if (( v < 0 )); then
    printf '%d\n' $((-v))
  else
    printf '%d\n' "$v"
  fi
}

to_epoch_iso() {
  # ISO-8601 like: 2025-11-19T14:23:00Z
  local ts="$1"
  date -u -d "$ts" +%s 2>/dev/null || echo 0
}

to_epoch_dt() {
  # DD.MM.YYYY-HH:MM:SS
  local dt="$1" dpart tpart DD MM YYYY
  dpart="${dt%%-*}"
  tpart="${dt#*-}"
  IFS='.' read -r DD MM YYYY <<<"$dpart"
  date -d "${YYYY}-${MM}-${DD} ${tpart}" +%s 2>/dev/null || echo 0
}

apply_epoch_to_system() {
  local ep="$1"
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-time "@${ep}" >/dev/null 2>&1 || date -u -s "@${ep}" >/dev/null 2>&1
  else
    date -u -s "@${ep}" >/dev/null 2>&1 || return 1
  fi
}

have_rtc(){
  # Must have the hwclock binary
  if ! command -v hwclock >/dev/null 2>&1; then
    return 1
  fi

  # Primary: kernel RTC device
  if [[ -e /dev/rtc0 ]]; then
    return 0
  fi

  # Optional: DS3231 probe on I2C (0x68) if i2c-tools are installed
  # NOTE: On some SUNXI kernels, default i2cdetect probing can miss devices.
  # Prefer read-probing (-r) and fall back to i2cget.
  if command -v i2cdetect >/dev/null 2>&1 || command -v i2cget >/dev/null 2>&1; then
    local dev bus
    for dev in /dev/i2c-*; do
      [[ -e "$dev" ]] || continue
      bus="${dev##*-}"
      if command -v i2cdetect >/dev/null 2>&1; then
        if i2cdetect -y -r "$bus" 2>/dev/null | grep -qE '(^|[[:space:]])68([[:space:]]|$)'; then
          return 0
        fi
      fi
      if command -v i2cget >/dev/null 2>&1; then
        i2cget -y "$bus" 0x68 0x00 >/dev/null 2>&1 && return 0
      fi
    done
  fi

  # If we reach here, we don't have a usable RTC
  return 1
}

write_rtc_if_present(){
  have_rtc || { echo "[RTC] no RTC present"; return 0; }
  hwclock -w && echo "[RTC] wrote RTC"
}

rtc_to_system_if_bogus(){
  have_rtc || return 0
  local sys_ep rtcline rtcep
  sys_ep="$(now_epoch)"
  # treat anything before 2017 as "bogus"
  if [[ "$sys_ep" -lt 1483228800 ]]; then
    rtcline="$(hwclock -r 2>/dev/null || true)"
    [[ -z "$rtcline" ]] && return 0
    rtcep="$(date -d "$rtcline" +%s 2>/dev/null || echo 0)"
    [[ "$rtcep" -gt 0 ]] && apply_epoch_to_system "$rtcep" && echo "[RTC] restored system time from RTC"
  fi
}

sync_rtc_to_system_if_needed(){
  have_rtc || return 0
  local now_ep rtcline rtcep diff
  now_ep="$(now_epoch)"
  rtcline="$(hwclock -r 2>/dev/null || true)"
  [[ -z "$rtcline" ]] && return 0
  rtcep="$(date -d "$rtcline" +%s 2>/dev/null || echo 0)"
  [[ "$rtcep" -gt 0 ]] || return 0
  diff="$(abs $((now_ep - rtcep)))"
  if [[ "$diff" -gt 1 ]]; then
    hwclock -w && echo "[RTC] wrote RTC (drift=${diff}s)"
  fi
}

net_epoch(){
  # Quietly try to obtain a network time; return 0 if not available.
  local ep=0 hdr now off
  if command -v ntpdate >/dev/null 2>&1; then
    off="$(ntpdate -q time.google.com 2>/dev/null | awk '/offset/ {print $10; exit}')"
    if [[ -n "${off:-}" ]]; then
      now="$(now_epoch)"
      ep="$(awk -v n="$now" -v o="$off" 'BEGIN{printf "%.0f", n+o}')"
      [[ "$ep" -gt 0 ]] && echo "$ep" && return 0
    fi
  fi
  if command -v curl >/dev/null 2>&1; then
    for url in https://www.google.com https://www.cloudflare.com; do
      hdr="$(curl -sI --max-time 4 "$url" | awk -F': ' '/^Date: /{print $2; exit}')"
      if [[ -n "${hdr:-}" ]]; then
        ep="$(date -u -d "$hdr" +%s 2>/dev/null || echo 0)"
        [[ "$ep" -gt 0 ]] && echo "$ep" && return 0
      fi
    done
  fi
  echo 0
}

maybe_apply(){
  local candidate_ep="$1" source="$2" sys_ep diff
  [[ "$candidate_ep" -gt 0 ]] || { echo "[RTC] $source time unavailable"; return 0; }
  sys_ep="$(now_epoch)"
  diff="$(abs $((candidate_ep - sys_ep)))"
  if [[ "$diff" -gt "$DRIFT_THRESHOLD" ]]; then
    apply_epoch_to_system "$candidate_ep" || return 1
    write_rtc_if_present
    echo "[RTC] applied from $source (drift=${diff}s)"
  else
    echo "[RTC] drift ${diff}s (<=${DRIFT_THRESHOLD}s); no update"
  fi
}

case "${1:-}" in
  --iso)
    shift; ts="${1:-}"; [[ -n "$ts" ]] || { echo "[RTC] --iso needs a timestamp"; exit 2; }
    ep="$(to_epoch_iso "$ts")"; [[ "$ep" -gt 0 ]] || { echo "[RTC] bad ISO timestamp"; exit 2; }
    maybe_apply "$ep" "COPILOT/ISO"
    ;;
  --datetime)
    shift; dt="${1:-}"; [[ -n "$dt" ]] || { echo "[RTC] --datetime needs a timestamp"; exit 2; }
    ep="$(to_epoch_dt "$dt")"; [[ "$ep" -gt 0 ]] || { echo "[RTC] bad DateTime"; exit 2; }
    maybe_apply "$ep" "COPILOT/DateTime"
    ;;
  *)
    rtc_to_system_if_bogus
    ep="$(net_epoch)"
    if [[ "$ep" -gt 0 ]]; then
      maybe_apply "$ep" "Internet"
    else
      sync_rtc_to_system_if_needed
    fi
    ;;
esac
EOF

sudo chmod 755 /usr/local/bin/rtc-sync.sh
chown "$OWNER:$OWNER" /usr/local/bin/rtc-sync.sh || true

log "Installing rtc-sync.service and rtc-sync.timer …"

cat > /etc/systemd/system/rtc-sync.service <<EOF
[Unit]
Description=Unified RTC/system clock sync (handles ISI + sniffer mode)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=initbox
Group=initbox
ExecStart=/usr/local/bin/rtc-sync.sh
AmbientCapabilities=CAP_SYS_TIME
CapabilityBoundingSet=CAP_SYS_TIME
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/rtc-sync.timer <<EOF
[Unit]
Description=Auto-run rtc-sync

[Timer]
OnBootSec=120
OnUnitActiveSec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable rtc-sync.service rtc-sync.timer
systemctl start rtc-sync.timer
systemctl start rtc-sync.service || true

ok "RTC module installed. Check 'journalctl -u rtc-sync.service' for logs."