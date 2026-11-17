#!/usr/bin/env bash
# OpenClaw + Kali installer. Runs as root, standalone or from any provisioning
# tool. Prints ::progress and ::error lines; the exit code is the result.
# See README.md and marscape.yaml. Safe to re-run: finished phases are skipped.
set -Eeuo pipefail
umask 022

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_VERSION="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo dev)"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/phases/preflight.sh
source "$SCRIPT_DIR/lib/phases/preflight.sh"
# shellcheck source=lib/phases/docker.sh
source "$SCRIPT_DIR/lib/phases/docker.sh"
# shellcheck source=lib/phases/openclaw.sh
source "$SCRIPT_DIR/lib/phases/openclaw.sh"
# shellcheck source=lib/phases/kali.sh
source "$SCRIPT_DIR/lib/phases/kali.sh"
# shellcheck source=lib/phases/verify.sh
source "$SCRIPT_DIR/lib/phases/verify.sh"

LOCK_DIR="$OCI_ROOT/run/openclaw-install.lock"
LOG_FILE="$OCI_ROOT/var/log/openclaw-install.log"
PHASES=(preflight:20 docker:40 openclaw:60 kali:80 verify:100)

ERROR_REPORTED=false # true once ::error is printed, or when it must not be
LOCK_HELD=false
CURRENT_PHASE=started
FAILED_CMD=""
FAILED_LINE=""

# The lock is a directory (mkdir is atomic) holding the owner's pid. A lock
# whose pid is gone was left by a crash and is taken over.
acquire_lock() {
  mkdir -p "$(dirname "$LOCK_DIR")"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    local pid
    pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      die "another install is already running (pid $pid)"
    fi
    log "taking over a stale lock left by pid ${pid:-unknown}"
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" || die "could not take the lock at $LOCK_DIR"
  fi
  echo $$ > "$LOCK_DIR/pid"
  LOCK_HELD=true
}

release_lock() {
  if $LOCK_HELD; then
    rm -rf "$LOCK_DIR"
    LOCK_HELD=false
  fi
}

on_err() {
  FAILED_CMD="$BASH_COMMAND"
  FAILED_LINE="${BASH_LINENO[0]}"
}

on_exit() {
  local rc=$?
  set +e
  trap - ERR
  trap '' PIPE # a dead log pipe must not stop the failure report
  if ((rc != 0)) && ! $ERROR_REPORTED; then
    ERROR_REPORTED=true
    local message="phase '$CURRENT_PHASE' failed with exit code $rc"
    if [[ -n "$DIE_MESSAGE" ]]; then
      message+=": $DIE_MESSAGE"
    elif [[ -n "$FAILED_CMD" ]]; then
      message+=" at line $FAILED_LINE: $FAILED_CMD"
    fi
    printf '::error %s\n' "${message//$'\n'/ }"
    log "ERROR: $message"
  fi
  release_lock
  exit "$rc"
}

start_logging() {
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  # tee ignores the signals that timeout or a provisioner send to the whole
  # process group, so it is still there when on_exit reports the failure.
  exec > >(trap '' INT TERM HUP; exec tee -a "$LOG_FILE") 2>&1
}

# progress PERCENT PHASE: the progress line a provisioner relays.
progress() {
  printf '::progress %s %s\n' "$1" "$2"
}

run_phases() {
  local entry name percent
  for entry in "${PHASES[@]}"; do
    name="${entry%%:*}"
    percent="${entry##*:}"
    CURRENT_PHASE="$name"
    if [[ "$name" != verify ]] && state_is_done "$name"; then
      log "phase $name: already done, skipping"
    else
      log "phase $name: starting"
      "phase_$name"
      state_mark_done "$name"
      log "phase $name: done"
    fi
    progress "$percent" "$name"
  done
  log "OpenClaw $OPENCLAW_VERSION with Kali sandbox installed and verified"
}

main() {
  parse_args "$@"
  trap on_err ERR
  trap on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  # A dry run only checks; it never prints ::error.
  [[ "${DRY_RUN:-false}" == true ]] && ERROR_REPORTED=true
  validate_params
  [[ $EUID -eq 0 || -n "$OCI_ROOT" ]] || die "must run as root"
  detect_os

  if [[ "$DRY_RUN" == true ]]; then
    log "dry run: parameters valid; distro $OS_ID uses $OS_FAMILY"
    log "dry run: would run phases ${PHASES[*]%%:*}"
    exit 0
  fi

  # A run refused by the lock prints no ::error: the other run owns the install.
  ERROR_REPORTED=true
  acquire_lock
  start_logging
  ERROR_REPORTED=false
  state_init
  log "installer $SCRIPT_VERSION starting on $OS_ID ($OS_FAMILY)"
  run_phases
  log "install complete"
}

main "$@"
