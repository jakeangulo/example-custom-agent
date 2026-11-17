#!/usr/bin/env bats
# Orchestration tests: install.sh runs against stub phases, so these cover the
# lock, log, traps, resume and dry run without touching a real system.

load helpers

setup() {
  common_setup
  shim curl
  shim sleep
  # A copy of the installer whose phases are stubs. FAIL_PHASE=<name> makes
  # that phase fail with exit code FAIL_RC (default 3); HANG_PHASE=<name>
  # makes it wait to be signalled.
  export APP="$BATS_TEST_TMPDIR/app"
  mkdir -p "$APP/lib/phases"
  cp "$REPO_ROOT/install.sh" "$APP/"
  cp "$REPO_ROOT/lib/common.sh" "$APP/lib/"
  local p
  for p in preflight docker openclaw kali verify; do
    cat > "$APP/lib/phases/$p.sh" <<EOF
phase_$p() {
  echo "running $p"
  printf 'phase %s\n' "$p" >> "\$SHIM_LOG"
  if [[ "\${HANG_PHASE:-}" == $p ]]; then touch "\$BATS_TEST_TMPDIR/hanging"; sleep_real 5; fi
  if [[ "\${FAIL_PHASE:-}" == $p ]]; then echo "something broke in $p"; return "\${FAIL_RC:-3}"; fi
  if [[ "\${DIE_PHASE:-}" == $p ]]; then die "custom reason in $p"; fi
  env > "\$BATS_TEST_TMPDIR/env-$p"
}
EOF
  done
  # The phase stubs need a real sleep; the shimmed one only records backoff.
  printf 'sleep_real() { command -p sleep "$@"; }\n' >> "$APP/lib/phases/preflight.sh"
  export LOG="$OCI_ROOT/var/log/openclaw-install.log"
}

phases_run() { grep '^phase ' "$SHIM_LOG" | cut -d' ' -f2 | tr '\n' ' '; }

@test "a clean run prints progress for every phase and exits 0" {
  run bash "$APP/install.sh"
  [ "$status" -eq 0 ]
  [ "$(phases_run)" = "preflight docker openclaw kali verify " ]
  [ "$(markers | tr '\n' '|')" = "::progress 20 preflight|::progress 40 docker|::progress 60 openclaw|::progress 80 kali|::progress 100 verify|" ]
}

@test "a failing phase prints exactly one ::error and keeps its exit code" {
  FAIL_PHASE=docker FAIL_RC=7 run bash "$APP/install.sh"
  [ "$status" -eq 7 ]
  [ "$(phases_run)" = "preflight docker " ]
  [ "$(markers | grep -c '^::error ')" = 1 ]
  [[ "$(markers | tail -1)" == "::error phase 'docker' failed with exit code 7"* ]]
  [ "$(markers | grep -c '^::progress ')" = 1 ]
}

@test "the log keeps the failing phase's output" {
  FAIL_PHASE=openclaw run bash "$APP/install.sh"
  grep -q "something broke in openclaw" "$LOG"
}

@test "a re-run after a failure resumes at the failed phase" {
  FAIL_PHASE=kali run bash "$APP/install.sh"
  : > "$SHIM_LOG"
  run bash "$APP/install.sh"
  [ "$status" -eq 0 ]
  [ "$(phases_run)" = "kali verify " ]
  [ "$(markers | grep -c '^::progress ')" = 5 ]
  [ "$(markers | tail -1)" = "::progress 100 verify" ]
  ! markers | grep -q '^::error ' || false
}

@test "verify runs again even when every phase is done" {
  bash "$APP/install.sh"
  : > "$SHIM_LOG"
  run bash "$APP/install.sh"
  [ "$status" -eq 0 ]
  [ "$(phases_run)" = "verify " ]
}

@test "a run refused by the lock prints no ::error" {
  mkdir -p "$OCI_ROOT/run/openclaw-install.lock"
  command -p sleep 60 & local holder=$!  # the real sleep: the shimmed one exits at once
  echo "$holder" > "$OCI_ROOT/run/openclaw-install.lock/pid"
  run bash "$APP/install.sh"
  kill "$holder"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already running"* ]]
  [ -z "$(markers)" ]
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

@test "invalid parameters print one ::error naming them and exit 1" {
  export KALI_IMAGE="no-tag"
  run bash "$APP/install.sh"
  [ "$status" -eq 1 ]
  [ "$(markers | wc -l | tr -d ' ')" = 1 ]
  [[ "$(markers)" == "::error "*"KALI_IMAGE"* ]]
  [ -z "$(phases_run)" ]
}

@test "a dry run with invalid parameters prints no markers" {
  export KALI_IMAGE="no-tag"
  run bash "$APP/install.sh" --dry-run
  [ "$status" -eq 1 ]
  [ -z "$(markers)" ]
}

@test "a die inside a phase puts its reason in the ::error line" {
  DIE_PHASE=docker run bash "$APP/install.sh"
  [ "$status" -eq 1 ]
  [[ "$(markers | tail -1)" == "::error "*"custom reason in docker"* ]]
}

@test "the old callback variables are ignored" {
  export CALLBACK_URL="https://x.example.test/events" CALLBACK_TOKEN="tok_0123456789abcdef" JOB_ID="d-1"
  run bash "$APP/install.sh"
  [ "$status" -eq 0 ]
  [ "$(markers | tail -1)" = "::progress 100 verify" ]
}

@test "no command makes an HTTP call to a status endpoint" {
  FAIL_PHASE=kali run bash "$APP/install.sh"
  run bash "$APP/install.sh"
  ! grep -q '^curl ' "$SHIM_LOG" || false
}

@test "a dry run validates and detects, changes nothing and prints no markers" {
  run bash "$APP/install.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"apt"* ]]
  [ -z "$(phases_run)" ]
  [ -z "$(markers)" ]
  [ ! -e "$OCI_ROOT/var/lib/openclaw-install" ]
  [ ! -e "$LOG" ]
}

@test "an unsupported distro prints one ::error" {
  cp "$FIXTURES/os-release/opensuse-leap" "$OCI_ROOT/etc/os-release"
  run bash "$APP/install.sh"
  [ "$status" -ne 0 ]
  [ "$(markers | wc -l | tr -d ' ')" = 1 ]
  [[ "$(markers)" == "::error "*"unsupported distro"* ]]
}

@test "the log file is private and records phase output" {
  bash "$APP/install.sh"
  [ "$(stat -c %a "$LOG" 2>/dev/null || stat -f %Lp "$LOG")" = 600 ]
  grep -q "running kali" "$LOG"
}

@test "SIGTERM during a phase prints one ::error" {
  HANG_PHASE=openclaw bash "$APP/install.sh" > "$BATS_TEST_TMPDIR/out" 2>&1 &
  local pid=$!
  local i
  for i in $(seq 1 50); do [[ -e "$BATS_TEST_TMPDIR/hanging" ]] && break; command -p sleep 0.1; done
  kill -TERM "$pid"
  local rc=0; wait "$pid" || rc=$?
  [ "$rc" -eq 143 ]
  output="$(cat "$BATS_TEST_TMPDIR/out")"
  [[ "$(markers | tail -1)" == "::error phase 'openclaw' failed with exit code 143"* ]]
  [ "$(markers | grep -c '^::error ')" = 1 ]
}

@test "--help prints usage without needing parameters" {
  unset OPENCLAW_VERSION
  run bash "$APP/install.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "SIGTERM to the whole process group still prints the ::error" {
  command -v perl >/dev/null || skip "perl not installed"
  # perl puts the installer in its own process group, as timeout and systemd do.
  HANG_PHASE=openclaw perl -e 'setpgrp(0, 0); exec @ARGV' bash "$APP/install.sh" > "$BATS_TEST_TMPDIR/out" 2>&1 &
  local pid=$! i rc=0
  for i in $(seq 1 50); do [[ -e "$BATS_TEST_TMPDIR/hanging" ]] && break; command -p sleep 0.1; done
  kill -TERM -- "-$pid"
  wait "$pid" || rc=$?
  [ "$rc" -eq 143 ]
  output="$(cat "$BATS_TEST_TMPDIR/out")"
  [[ "$(markers | tail -1)" == "::error phase 'openclaw' failed"* ]]
}
