#!/bin/bash
# module-a5e.sh - Cubie A5E base (headless + initbox)
#
# - Force headless (no GUI) boot
# - Change hostname to cubie-a5e
# - Remove GUI components + LibreOffice if installed
# - Create initbox user (with password prompt if locked/empty)
# - Migrate installer directory into /home/initbox/cubie-installer/<...>
# - Ask whether to logout or reboot after Phase 1
# - Heal dpkg/apt; optionally repair malformed dpkg status stanza(s)

set -uo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Error: run as root (sudo ./module-a5e.sh)" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

log() { echo ">>> $*"; }

set_mod_flag() {
  local key="$1" val="$2" file="/etc/initbox-mods.conf"
  touch "$file" 2>/dev/null || true
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i "s/^${key}=.*/${key}=${val}/" "$file" 2>/dev/null || true
  else
    echo "${key}=${val}" >> "$file"
  fi
}

# APT options for legacy/archived repos and smooth automation.
APT_OPTS=(
  -o Acquire::Check-Valid-Until=false
  -o Acquire::AllowInsecureRepositories=true
  -o Acquire::AllowDowngradeToInsecureRepositories=true
)

apt_run() {
  # usage: apt_run <apt-get args...>
  apt-get "${APT_OPTS[@]}" "$@"
}

installed_pkgs_from_globs() {
  # usage: installed_pkgs_from_globs <glob1> <glob2> ...
  # Prints installed package names, one per line.
  local g
  for g in "$@"; do
    dpkg-query -W -f='${binary:Package}\n' "$g" 2>/dev/null || true
  done | sort -u
}

user_password_needs_set() {
  # returns 0 if user has no usable password (locked/empty), 1 otherwise
  local u="$1" st
  st="$(passwd -S "$u" 2>/dev/null | awk '{print $2}')"
  case "$st" in
    L|NP|"") return 0 ;;
    *) return 1 ;;
  esac
}

prompt_set_user_password() {
  local u="$1" p1 p2
  while true; do
    read -r -s -p "Set password for '$u': " p1 < /dev/tty
    echo
    read -r -s -p "Confirm password: " p2 < /dev/tty
    echo
    if [[ -n "$p1" && "$p1" == "$p2" ]]; then
      echo "$u:$p1" | chpasswd
      return 0
    fi
    echo "Passwords do not match or are empty. Try again." >&2
  done
}

repair_dpkg_status_if_needed() {
  # One-time dpkg status fix:
  # Remove malformed stanza(s) where Package ends with ".deb" AND there is no "Description:" field.
  # This avoids awk extensions so it works with mawk/busybox awk.
  local status_file="/var/lib/dpkg/status"
  [[ -f "$status_file" ]] || return 0

  # Quick check - only run paragraph parser if any Package: ... .deb exists
  if ! grep -qE '^Package: .*\.deb$' "$status_file" 2>/dev/null; then
    return 0
  fi

  local tmp bak
  tmp="$(mktemp)"

  # Paragraph mode: RS="" gives full stanzas separated by blank lines.
  # Keep everything except paragraphs matching (pkg ends with .deb) AND (no Description: line).
  awk 'BEGIN{RS=""; ORS="\n\n"}
    function get_pkg(p,   n,i,l){
      n=split(p,l,"\n");
      for(i=1;i<=n;i++){
        if(l[i] ~ /^Package: /){
          sub(/^Package: /,"",l[i]);
          return l[i];
        }
      }
      return "";
    }
    function has_desc(p,   n,i,l){
      n=split(p,l,"\n");
      for(i=1;i<=n;i++) if(l[i] ~ /^Description:/) return 1;
      return 0;
    }
    {
      pkg=get_pkg($0);
      if (pkg ~ /\.deb$/ && !has_desc($0)) { dropped++; next; }
      print $0;
    }
    END{ if (dropped>0) exit 3; }
  ' "$status_file" > "$tmp"

  local rc=$?
  if [[ $rc -eq 3 ]]; then
    bak="${status_file}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$status_file" "$bak" 2>/dev/null || true
    cp -a "$tmp" "$status_file" 2>/dev/null || true
    log "Repaired dpkg status (removed malformed .deb stanza). Backup: $bak"
  fi

  rm -f "$tmp"
  return 0
}

heal_apt() {
  log "Attempting to heal dpkg/apt state"
  repair_dpkg_status_if_needed
  dpkg --configure -a || true
  # Prevent a known-bad local .deb-named package from being (re)installed during -f install.
  # This has shown up as a malformed dpkg stanza and can get pulled back in by "Correcting dependencies".
  local badpkg="xserver-xorg-mesa-g57-1.21.1-2.deb"
  if dpkg -l "$badpkg" 2>/dev/null | awk 'NR>5{print $1}' | grep -q '^ii$'; then
    log "Purging bad package that should never be installed: $badpkg"
    apt_run -y purge "$badpkg" 2>/dev/null || dpkg --purge "$badpkg" 2>/dev/null || true
  fi
  mkdir -p /etc/apt/preferences.d 2>/dev/null || true
  cat > /etc/apt/preferences.d/99-initbox-block-badpkgs <<EOF
Package: $badpkg
Pin: version *
Pin-Priority: -1
EOF
  rm -f "/var/cache/apt/archives/${badpkg}"*.deb 2>/dev/null || true

  # Be conservative: avoid pulling in recommends (helps prevent GUI bits returning)
  apt_run -y -f install --no-install-recommends || true
}

stop_disable_mask() {
  # best-effort disable + mask a unit if it exists
  local unit="$1"
  systemctl stop "$unit" 2>/dev/null || true
  systemctl disable "$unit" 2>/dev/null || true
  systemctl mask "$unit" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Confirm
# -----------------------------------------------------------------------------
log "WARNING: This will harden the system, change hostname, and purge GUI components."
read -r -p "Continue? [y/N] " ans < /dev/tty
if [[ ! "$ans" =~ ^[yY]$ ]]; then
  echo "Aborting."
  exit 1
fi

NEW_HOSTNAME="cubie-a5e"
INIT_USER="initbox"
CURRENT_USER="${SUDO_USER:-${USER:-root}}"

# -----------------------------------------------------------------------------
# Phase 1: Bootstrap initbox user + migrate installer (only when started from legacy users)
# -----------------------------------------------------------------------------
if [[ "$CURRENT_USER" == "radxa" || "$CURRENT_USER" == "rock" ]]; then
  log "Phase 1: Preparing admin user '$INIT_USER'..."

  log "Updating hostname to $NEW_HOSTNAME..."
  echo "$NEW_HOSTNAME" > /etc/hostname
  if grep -q '^127\.0\.1\.1' /etc/hosts 2>/dev/null; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts || true
  else
    echo -e "127.0.1.1\t$NEW_HOSTNAME" >> /etc/hosts
  fi
  hostnamectl set-hostname "$NEW_HOSTNAME" 2>/dev/null || hostname "$NEW_HOSTNAME" || true

  if ! id "$INIT_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$INIT_USER"
  fi

  if user_password_needs_set "$INIT_USER"; then
    prompt_set_user_password "$INIT_USER"
  fi

  usermod -aG sudo,adm,netdev,audio,video,plugdev,gpio,i2c,spi "$INIT_USER" 2>/dev/null || true

  # Copy installer entrypoint + logs into initbox home (do NOT copy whole repo)
  SCRIPT_SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
  DEST_SCRIPT="/home/$INIT_USER/cubie-installer.sh"

  # Prefer a prebuilt cubie-installer.sh if present; otherwise copy the current running script
  SRC_INSTALLER=""
  if [[ -f "$SCRIPT_SRC_DIR/cubie-installer.sh" ]]; then
    SRC_INSTALLER="$SCRIPT_SRC_DIR/cubie-installer.sh"
  else
    SRC_INSTALLER="$0"
  fi

  log "Copying installer script to $DEST_SCRIPT..."
  install -m 0755 "$SRC_INSTALLER" "$DEST_SCRIPT" 2>/dev/null || cp -f "$SRC_INSTALLER" "$DEST_SCRIPT"
  chown "$INIT_USER:$INIT_USER" "$DEST_SCRIPT" 2>/dev/null || true

  # Ensure initbox log directory exists
  mkdir -p "/home/$INIT_USER/pi_logs"
  chown -R "$INIT_USER:$INIT_USER" "/home/$INIT_USER/pi_logs" 2>/dev/null || true

  # If main.sh logged to /var/log/initbox before initbox existed, copy logs over
  if [[ -d /var/log/initbox ]]; then
    mkdir -p "/home/$INIT_USER/pi_logs"
    cp -a /var/log/initbox/. "/home/$INIT_USER/pi_logs/" 2>/dev/null || true
    chown -R "$INIT_USER:$INIT_USER" "/home/$INIT_USER/pi_logs" 2>/dev/null || true
  fi

  echo "---------------------------------------------------------------"
  echo " PHASE 1 COMPLETE: HOSTNAME SET TO $NEW_HOSTNAME"
  echo "---------------------------------------------------------------"
  echo "To finish, you MUST:"
  echo " 1. Log out or reboot."
  echo " 2. Log back in as: $INIT_USER"
  echo " 3. Run this script again from: /home/$INIT_USER/cubie-installer.sh"
  echo "---------------------------------------------------------------"
  echo
  echo "Choose next step:"
  echo "  1) Logout now (recommended)"
  echo "  2) Reboot now"
  echo "  3) Do nothing (I'll do it manually)"
  echo

  while true; do
    read -r -p "Select [1-3]: " choice < /dev/tty
    case "$choice" in
      1)
        log "Logging out user '$CURRENT_USER'..."
        if command -v loginctl >/dev/null 2>&1; then
          loginctl terminate-user "$CURRENT_USER" 2>/dev/null || true
        fi
        # Fallback (works for SSH sessions)
        pkill -HUP -u "$CURRENT_USER" 2>/dev/null || true
        exit 0
        ;;
      2)
        log "Rebooting now..."
        reboot
        exit 0
        ;;
      3)
        log "OK. Please logout/reboot manually and re-run as $INIT_USER."
        exit 0
        ;;
      *) echo "Invalid choice." >&2 ;;
    esac
  done
fi

# -----------------------------------------------------------------------------
# Phase 2: System conversion (run as initbox via sudo)
# -----------------------------------------------------------------------------
log "Phase 2: System conversion for $NEW_HOSTNAME..."

log "Optimizing APT for legacy repositories..."
apt_run update || true

log "Forcing headless boot target..."
systemctl set-default multi-user.target 2>/dev/null || true

# Stop/disable/mask display managers so they don't come back
stop_disable_mask sddm
stop_disable_mask lightdm
stop_disable_mask gdm3

# Desktop + LibreOffice removal
GUI_GLOBS=(
  'kde-*' 'plasma-*' 'task-kde-desktop' 'kubuntu-desktop'
  'gnome-*' 'ubuntu-desktop*' 'task-gnome-desktop'
  'xfce4*' 'lxqt*' 'mate-*' 'cinnamon-*'
  'xorg' 'xserver-xorg*' 'x11-*' 'wayland-*' 'xwayland'
  'sddm' 'lightdm' 'gdm3'
  # Common GUI runtime libs that can linger and cause dependency conflicts once X11 bits are purged
  'libqt5*' 'qt5*' 'libxcb*' 'libx11*' 'libxext*' 'libxrender*' 'libxfixes*' 'libxi*'
  'libice6' 'libsm6' 'libgl1*' 'mesa-*'
  'libreoffice*'
)

log "Collecting installed GUI/LibreOffice packages..."
mapfile -t GUI_INSTALLED < <(installed_pkgs_from_globs "${GUI_GLOBS[@]}")

if ((${#GUI_INSTALLED[@]} > 0)); then
  log "Purging GUI/LibreOffice packages (${#GUI_INSTALLED[@]}): ${GUI_INSTALLED[*]}"
  apt_run -y purge "${GUI_INSTALLED[@]}" || true
  heal_apt
  apt_run -y autoremove --purge || true
else
  log "No GUI/LibreOffice packages from list are installed."
fi

# Verification sweep: if any denylist packages remain, purge again.
log "Verification sweep: ensuring no GUI/LibreOffice packages remain..."
VERIFY_GLOBS=(
  'ubuntu-desktop*' 'kubuntu-desktop' 'task-gnome-desktop' 'gnome-shell'
  'xorg' 'xserver-xorg*' 'x11-*' 'wayland-*' 'xwayland'
  'sddm' 'lightdm' 'gdm3'
  'plasma-*' 'kde-*'
  'libqt5*' 'qt5*' 'libxcb*' 'libx11*' 'libxext*' 'libxrender*' 'libxfixes*' 'libxi*'
  'libice6' 'libsm6' 'libgl1*' 'mesa-*'
  'libreoffice*'
)
mapfile -t REMAINING < <(installed_pkgs_from_globs "${VERIFY_GLOBS[@]}")
if ((${#REMAINING[@]} > 0)); then
  log "Verification found remaining GUI-related packages (${#REMAINING[@]}): ${REMAINING[*]}"
  apt_run -y purge "${REMAINING[@]}" || true
  heal_apt
  apt_run -y autoremove --purge || true
else
  log "Verification OK: no matching GUI/LibreOffice packages installed."
fi

# Legacy user removal (only if present)
for TARGET in rock radxa; do
  if id "$TARGET" >/dev/null 2>&1; then
    log "Removing legacy user '$TARGET'..."
    pkill -KILL -u "$TARGET" 2>/dev/null || true
    userdel -r "$TARGET" 2>/dev/null || userdel -f "$TARGET" 2>/dev/null || true
  fi
 done

set_mod_flag A5E 1

echo "==================================================================="
echo " ALL PHASES COMPLETE"
echo " Hostname: $(hostname)"
echo "==================================================================="
log "A5E base module installed."
