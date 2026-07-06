#!/usr/bin/env bash
# Small APT/cache helper for InitBox modules. Source this file.

: "${LOGFILE:=/var/log/initbox/initbox-install.log}"
: "${PACKAGE_CACHE_DIR:=/opt/initbox-package-cache}"

apt_safe() {
  apt-get -o Dpkg::Use-Pty=0 -o Acquire::Retries=5 "$@" >>"$LOGFILE" 2>&1
}

have_internet() {
  getent hosts deb.debian.org >/dev/null 2>&1 || ping -c1 -W1 1.1.1.1 >/dev/null 2>&1
}

install_packages() {
  local packages=("$@")
  ((${#packages[@]} > 0)) || return 0

  if have_internet; then
    apt_safe update -y
    apt_safe install -y --no-install-recommends "${packages[@]}"
  else
    apt_safe install -y --no-download --no-install-recommends "${packages[@]}"
  fi
}

show_package_cache_status() {
  local packages_file="${INITBOX_REPO_ROOT:-.}/scripts/packages.txt"
  echo "Package cache directory: $PACKAGE_CACHE_DIR"
  if [[ -d "$PACKAGE_CACHE_DIR" ]]; then
    find "$PACKAGE_CACHE_DIR" -maxdepth 1 -type f -name '*.deb' | wc -l | awk '{print "Cached .deb files: "$1}'
  else
    echo "Cached .deb files: 0"
  fi
  if [[ -f "$packages_file" ]]; then
    echo "Package list: $packages_file"
  fi
}
