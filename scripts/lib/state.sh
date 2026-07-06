#!/usr/bin/env bash
# InitBox module state helper. Source this file.

: "${INITBOX_STATE_FILE:=/etc/initbox/install-state.env}"
: "${INITBOX_MODS_FILE:=/etc/initbox-mods.conf}"

ensure_state_files() {
  install -d -m 0755 /etc/initbox
  touch "$INITBOX_STATE_FILE" "$INITBOX_MODS_FILE"
  chmod 0644 "$INITBOX_STATE_FILE" "$INITBOX_MODS_FILE"
}

set_state_key() {
  local file="$1" key="$2" value="$3"
  ensure_state_files
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i "s/^${key}=.*/${key}=${value}/" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

get_state_key() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1 == k {print $2; found=1} END {if (!found) exit 1}' "$file" 2>/dev/null
}

set_module_state() {
  local module_id="$1" value="$2" key
  key="$(printf '%s' "$module_id" | tr '[:lower:]-' '[:upper:]_')"
  set_state_key "$INITBOX_STATE_FILE" "$key" "$value"
  set_state_key "$INITBOX_MODS_FILE" "$key" "$value"
}

module_state_is_installed() {
  local module_id="$1" key value
  key="$(printf '%s' "$module_id" | tr '[:lower:]-' '[:upper:]_')"
  value="$(get_state_key "$INITBOX_STATE_FILE" "$key" 2>/dev/null || get_state_key "$INITBOX_MODS_FILE" "$key" 2>/dev/null || true)"
  [[ "$value" == "1" ]]
}
