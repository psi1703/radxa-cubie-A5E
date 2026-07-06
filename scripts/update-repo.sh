#!/usr/bin/env bash
# Hard-sync the local Radxa Cubie A5E repo from GitHub.
#
# Intended workflow:
#   - Edit files directly on GitHub.
#   - Run this script on the Radxa board.
#   - Local tracked changes are discarded.
#   - Untracked files inside the repo are removed.
#
# Default repo:
#   https://github.com/psi1703/radxa-cubie-A5E.git
#
# Optional overrides:
#   INITBOX_REPO_URL="https://github.com/psi1703/radxa-cubie-A5E.git"
#   INITBOX_REPO_BRANCH="main"
#   INITBOX_REPO_DIR="/home/radxa/radxa-cubie-A5E"

set -euo pipefail

REPO_URL="${INITBOX_REPO_URL:-https://github.com/psi1703/radxa-cubie-A5E.git}"
REPO_BRANCH="${INITBOX_REPO_BRANCH:-main}"
SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

if [ -n "${INITBOX_REPO_DIR:-}" ]; then
  REPO_DIR="$INITBOX_REPO_DIR"
else
  REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

log() {
  printf '[UPDATE-REPO] %s\n' "$*"
}

fail() {
  printf '[UPDATE-REPO][ERR] %s\n' "$*" >&2
  exit 1
}

need_command() {
  command -v "$1" >/dev/null 2>&1
}

install_git_if_missing() {
  if need_command git; then
    return 0
  fi

  log "git is missing. Installing git with apt-get."
  if [ "$(id -u)" -eq 0 ]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y git ca-certificates
  else
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y git ca-certificates
  fi
}

ensure_repo_exists() {
  if [ -d "$REPO_DIR/.git" ]; then
    return 0
  fi

  if [ -e "$REPO_DIR" ]; then
    fail "Directory exists but is not a git repo: $REPO_DIR. Clone the repo with git first, or set INITBOX_REPO_DIR to the real git checkout."
  fi

  log "Repo directory does not exist. Cloning $REPO_URL branch $REPO_BRANCH into $REPO_DIR."
  mkdir -p "$(dirname "$REPO_DIR")"
  git clone --branch "$REPO_BRANCH" "$REPO_URL" "$REPO_DIR"
}

ensure_origin() {
  local current_origin

  current_origin="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)"

  if [ -z "$current_origin" ]; then
    log "No origin remote found. Adding origin: $REPO_URL"
    git -C "$REPO_DIR" remote add origin "$REPO_URL"
    return 0
  fi

  if [ "$current_origin" != "$REPO_URL" ]; then
    log "Updating origin remote."
    log "Old origin: $current_origin"
    log "New origin: $REPO_URL"
    git -C "$REPO_DIR" remote set-url origin "$REPO_URL"
  fi
}

mark_safe_directory() {
  git config --global --add safe.directory "$REPO_DIR" >/dev/null 2>&1 || true
}

hard_sync_repo() {
  log "Repository: $REPO_DIR"
  log "Remote:     $REPO_URL"
  log "Branch:     $REPO_BRANCH"

  mark_safe_directory
  ensure_origin

  log "Fetching latest GitHub state."
  git -C "$REPO_DIR" fetch --prune origin "$REPO_BRANCH"

  log "Checking out branch $REPO_BRANCH."
  git -C "$REPO_DIR" checkout -B "$REPO_BRANCH" "origin/$REPO_BRANCH"

  log "Discarding local tracked changes."
  git -C "$REPO_DIR" reset --hard "origin/$REPO_BRANCH"

  log "Removing untracked files and folders inside repo."
  git -C "$REPO_DIR" clean -fdx

  log "Final commit:"
  git -C "$REPO_DIR" --no-pager log -1 --oneline

  log "Repo hard-sync complete."
}

main() {
  install_git_if_missing
  ensure_repo_exists
  hard_sync_repo
}

main "$@"
