#!/usr/bin/env bash
# Shared profile loader for InitBox installers.
# Source this file; do not execute it directly.

initbox_repo_root() {
  local src_dir
  src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  printf '%s\n' "$src_dir"
}

load_profile() {
  local profile_path="${1:-}"

  INITBOX_REPO_ROOT="${INITBOX_REPO_ROOT:-$(initbox_repo_root)}"
  export INITBOX_REPO_ROOT

  if [[ -z "$profile_path" ]]; then
    profile_path="${INITBOX_REPO_ROOT}/profiles/radxa-cubie-a5e.conf"
  elif [[ "$profile_path" != /* ]]; then
    profile_path="${INITBOX_REPO_ROOT}/${profile_path}"
  fi

  if [[ ! -r "$profile_path" ]]; then
    echo "Profile not found or not readable: $profile_path" >&2
    return 1
  fi

  # shellcheck disable=SC1090
  . "$profile_path"

  : "${PROFILE_ID:?PROFILE_ID missing from profile}"
  : "${PROFILE_NAME:?PROFILE_NAME missing from profile}"
  : "${OWNER:=initbox}"
  : "${DEFAULT_MODULES:=a5e hotspot dashboard isi ws-br0 rtc}"
  : "${DASHBOARD_PORT:=8080}"
  : "${DASHBOARD_API_PORT:=8090}"
  : "${TERMINAL_PORT:=7681}"
  : "${TRACE_DIR:=/usr/tracefiles}"

  PROFILE_PATH="$profile_path"
  export PROFILE_ID PROFILE_NAME OWNER DEFAULT_MODULES PROFILE_PATH
  export DASHBOARD_PORT DASHBOARD_API_PORT TERMINAL_PORT TRACE_DIR
}
