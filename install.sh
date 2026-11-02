#!/usr/bin/env bash
# OpenClaw + Kali installer. Runs as root from cloud-init on first boot of a
# Hetzner Cloud server, and reports progress to the provisioner's events route.
# See docs/plan.md and README.md. Safe to re-run: finished phases are skipped.
set -Eeuo pipefail
umask 022

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_VERSION="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo dev)"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/report.sh
source "$SCRIPT_DIR/lib/report.sh"
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

REPORTING=false # true once the lock is held, so failures are posted
FINAL_POSTED=false
LOCK_HELD=false
CURRENT_PHASE=started
LAST_PERCENT=0
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
  if ((rc != 0)) && $REPORTING && ! $FINAL_POSTED; then
    FINAL_POSTED=true
    local message="phase '$CURRENT_PHASE' failed with exit code $rc"
    [[ -n "$FAILED_CMD" ]] && message+=" at line $FAILED_LINE: $FAILED_CMD"
    log "ERROR: $message"
    post_event failed "$LAST_PERCENT" "$CURRENT_PHASE" "$message" "$rc" "$(tail -n 50 "$LOG_FILE" 2>/dev/null)"
  fi
  release_lock
  exit "$rc"
}

start_logging() {
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
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
    if [[ "$name" == verify ]]; then
      FINAL_POSTED=true
      post_event succeeded "$percent" "$name" "OpenClaw $OPENCLAW_VERSION with Kali sandbox installed and verified"
    else
      post_event in_progress "$percent" "$name" "phase $name done"
    fi
    LAST_PERCENT="$percent"
  done
}

main() {
  parse_args "$@"
  validate_params
  [[ $EUID -eq 0 || -n "$OCI_ROOT" ]] || die "must run as root"
  detect_os

  if [[ "$DRY_RUN" == true ]]; then
    log "dry run: parameters valid; distro $OS_ID uses $OS_FAMILY"
    log "dry run: would run phases ${PHASES[*]%%:*} as user $INSTALL_USER"
    exit 0
  fi

  trap on_err ERR
  trap on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  acquire_lock
  start_logging
  REPORTING=true
  state_init
  log "installer $SCRIPT_VERSION starting for job $JOB_ID on $OS_ID ($OS_FAMILY)"
  post_event started 0 started "installer $SCRIPT_VERSION started"
  run_phases
  log "install complete"
}

main "$@"
