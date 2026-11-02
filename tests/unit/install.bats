#!/usr/bin/env bats
# Orchestration tests: install.sh runs against stub phases, so these cover the
# lock, log, traps, resume and dry run without touching a real system.

load helpers

setup() {
  common_setup
  curl_capture_shim
  shim sleep
  # A copy of the installer whose phases are stubs. FAIL_PHASE=<name> makes
  # that phase fail with exit code FAIL_RC (default 3); HANG_PHASE=<name>
  # makes it wait to be signalled.
  export APP="$BATS_TEST_TMPDIR/app"
  mkdir -p "$APP/lib/phases"
  cp "$REPO_ROOT/install.sh" "$APP/"
  cp "$REPO_ROOT/lib/common.sh" "$REPO_ROOT/lib/report.sh" "$APP/lib/"
  local p
  for p in preflight docker openclaw kali verify; do
    cat > "$APP/lib/phases/$p.sh" <<EOF
phase_$p() {
  echo "running $p"
  printf 'phase %s\n' "$p" >> "\$SHIM_LOG"
  if [[ "\${HANG_PHASE:-}" == $p ]]; then touch "\$BATS_TEST_TMPDIR/hanging"; sleep_real 5; fi
  if [[ "\${FAIL_PHASE:-}" == $p ]]; then echo "something broke in $p"; return "\${FAIL_RC:-3}"; fi
}
EOF
  done
  # The phase stubs need a real sleep; the shimmed one only records backoff.
  printf 'sleep_real() { command -p sleep "$@"; }\n' >> "$APP/lib/phases/preflight.sh"
  export LOG="$OCI_ROOT/var/log/openclaw-install.log"
}

phases_run() { grep '^phase ' "$SHIM_LOG" | cut -d' ' -f2 | tr '\n' ' '; }

@test "a clean run reports 0 to 100 in order and exits 0" {
  run bash "$APP/install.sh"
  [ "$status" -eq 0 ]
  [ "$(phases_run)" = "preflight docker openclaw kali verify " ]
  [ "$(events | tr '\n' '|')" = "started 0 started|in_progress 20 preflight|in_progress 40 docker|in_progress 60 openclaw|in_progress 80 kali|succeeded 100 verify|" ]
}

@test "event sequence numbers increase" {
  bash "$APP/install.sh"
  [ "$(event 1 .sequence)" = 1 ]
  [ "$(event 6 .sequence)" = 6 ]
}

@test "a failing phase posts exactly one failed event and keeps its exit code" {
  FAIL_PHASE=docker FAIL_RC=7 run bash "$APP/install.sh"
  [ "$status" -eq 7 ]
  [ "$(phases_run)" = "preflight docker " ]
  [ "$(events | tail -1)" = "failed 20 docker" ]
  [ "$(events | grep -c '^failed')" = 1 ]
  ! events | grep -q '^succeeded'
  [ "$(event 3 .exit_code)" = 7 ]
}

@test "the failed event carries the tail of the log" {
  FAIL_PHASE=openclaw run bash "$APP/install.sh"
  [[ "$(event 4 .log_tail)" == *"something broke in openclaw"* ]]
  [[ "$(event 4 .message)" == *"openclaw"* ]]
}

@test "a re-run after a failure resumes at the failed phase" {
  FAIL_PHASE=kali run bash "$APP/install.sh"
  : > "$SHIM_LOG"
  run bash "$APP/install.sh"
  [ "$status" -eq 0 ]
  [ "$(phases_run)" = "kali verify " ]
  [ "$(events | tail -1)" = "succeeded 100 verify" ]
}

@test "verify runs again even when every phase is done" {
  bash "$APP/install.sh"
  : > "$SHIM_LOG"
  run bash "$APP/install.sh"
  [ "$status" -eq 0 ]
  [ "$(phases_run)" = "verify " ]
}

@test "a run is refused while another holds the lock, and posts nothing" {
  mkdir -p "$OCI_ROOT/run/openclaw-install.lock"
  sleep 60 & local holder=$!
  echo "$holder" > "$OCI_ROOT/run/openclaw-install.lock/pid"
  run bash "$APP/install.sh"
  kill "$holder"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already running"* ]]
  [ -z "$(events)" ]
  [ -z "$(phases_run)" ]
}

@test "a lock left by a dead process is taken over" {
  mkdir -p "$OCI_ROOT/run/openclaw-install.lock"
  echo 999999 > "$OCI_ROOT/run/openclaw-install.lock/pid"
  run bash "$APP/install.sh"
  [ "$status" -eq 0 ]
}

@test "the lock is released when the run ends" {
  bash "$APP/install.sh"
  [ ! -e "$OCI_ROOT/run/openclaw-install.lock" ]
  FAIL_PHASE=docker run bash "$APP/install.sh"
  [ ! -e "$OCI_ROOT/run/openclaw-install.lock" ]
}

@test "invalid parameters exit 1 and post nothing" {
  unset KALI_IMAGE
  run bash "$APP/install.sh"
  [ "$status" -eq 1 ]
  [ -z "$(events)" ]
}

@test "a dry run validates and detects but changes and posts nothing" {
  run bash "$APP/install.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"apt"* ]]
  [ -z "$(phases_run)" ]
  [ -z "$(events)" ]
  [ ! -e "$OCI_ROOT/var/lib/openclaw-install" ]
  [ ! -e "$LOG" ]
}

@test "an unsupported distro fails before any event" {
  cp "$FIXTURES/os-release/opensuse-leap" "$OCI_ROOT/etc/os-release"
  run bash "$APP/install.sh"
  [ "$status" -ne 0 ]
  [ -z "$(events)" ]
}

@test "the log file is private and records phase output" {
  bash "$APP/install.sh"
  [ "$(stat -c %a "$LOG" 2>/dev/null || stat -f %Lp "$LOG")" = 600 ]
  grep -q "running kali" "$LOG"
}

@test "secrets never reach the log" {
  FAIL_PHASE=docker run bash "$APP/install.sh"
  ! grep -q -e "$LLM_API_KEY" -e "$CALLBACK_TOKEN" "$LOG"
}

@test "SIGTERM during a phase posts a failed event" {
  HANG_PHASE=openclaw bash "$APP/install.sh" > /dev/null 2>&1 &
  local pid=$!
  local i
  for i in $(seq 1 50); do [[ -e "$BATS_TEST_TMPDIR/hanging" ]] && break; command -p sleep 0.1; done
  kill -TERM "$pid"
  local rc=0; wait "$pid" || rc=$?
  [ "$rc" -eq 143 ]
  [ "$(events | tail -1)" = "failed 40 openclaw" ]
  [ "$(events | grep -c '^failed')" = 1 ]
}

@test "--help prints usage without needing parameters" {
  unset OPENCLAW_VERSION
  run bash "$APP/install.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}
