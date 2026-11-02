#!/usr/bin/env bats

load helpers

setup() {
  common_setup
  source "$REPO_ROOT/lib/common.sh"
  source "$REPO_ROOT/lib/report.sh"
  parse_args
  validate_params
  state_init
  SCRIPT_VERSION=test-1
  # curl shim: saves stdin (the -K config) and the --data-binary body for each
  # call, then answers with the next code from HTTP_CODES (default 204).
  export CALL_DIR="$BATS_TEST_TMPDIR/curl"; mkdir -p "$CALL_DIR"
  export HTTP_CODES="${HTTP_CODES:-204}"
  shim_script curl <<'EOF2'
n=$(( $(ls "$CALL_DIR" | wc -l) / 2 + 1 ))
cat > "$CALL_DIR/$n.config"
prev=""; for a in "$@"; do [[ "$prev" == --data-binary ]] && cp "${a#@}" "$CALL_DIR/$n.body"; prev="$a"; done
codes=($HTTP_CODES); code="${codes[$((n-1))]:-${codes[-1]}}"
[[ "$code" == fail ]] && exit 28
printf '%s' "$code"
EOF2
  shim sleep
}

body() { cat "$CALL_DIR/$1.body"; }

@test "an event is posted as JSON with the contract's fields" {
  post_event in_progress 40 docker "Docker installed"
  [ "$(body 1 | jq -r .event)" = in_progress ]
  [ "$(body 1 | jq -r .percent)" = 40 ]
  [ "$(body 1 | jq -r .phase)" = docker ]
  [ "$(body 1 | jq -r .message)" = "Docker installed" ]
  [ "$(body 1 | jq -r .job_id)" = "$JOB_ID" ]
  [ "$(body 1 | jq -r .script_version)" = test-1 ]
  [ "$(body 1 | jq -r .sequence)" = 1 ]
  [ "$(body 1 | jq -r .hostname)" != "" ]
  [[ "$(body 1 | jq -r .timestamp)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]]
  [ "$(body 1 | jq -r 'has("exit_code")')" = false ]
  grep -q "curl.*$CALLBACK_URL" "$SHIM_LOG"
}

@test "the bearer token goes through stdin, never the command line" {
  post_event started 0 started "Installer started"
  grep -q "Authorization: Bearer $CALLBACK_TOKEN" "$CALL_DIR/1.config"
  ! grep -q "$CALLBACK_TOKEN" "$SHIM_LOG"
}

@test "a failed event carries the exit code and a redacted log tail" {
  post_event failed 60 openclaw "install failed" 7 $'line one\nkey='"$LLM_API_KEY"$'\ntoken '"$CALLBACK_TOKEN"
  [ "$(body 1 | jq -r .event)" = failed ]
  [ "$(body 1 | jq -r .exit_code)" = 7 ]
  [[ "$(body 1 | jq -r .log_tail)" == *"line one"* ]]
  ! body 1 | grep -q -e "$LLM_API_KEY" -e "$CALLBACK_TOKEN"
  [[ "$(body 1 | jq -r .log_tail)" == *"[REDACTED]"* ]]
}

@test "sequence numbers increase with each event" {
  post_event started 0 started a
  post_event in_progress 20 preflight b
  [ "$(body 2 | jq -r .sequence)" = 2 ]
}

@test "a server error is retried until it succeeds" {
  HTTP_CODES="500 502 204"
  post_event in_progress 20 preflight ok
  [ "$(ls "$CALL_DIR"/*.body | wc -l | tr -d ' ')" = 3 ]
}

@test "a dead endpoint is tried 4 times and never fails the caller" {
  HTTP_CODES="fail"
  run post_event in_progress 20 preflight ok
  [ "$status" -eq 0 ]
  [ "$(grep -c '^curl ' "$SHIM_LOG")" = 4 ]
  [[ "$output" == *"WARN"* ]]
}

@test "retries back off 1, 2 and 4 seconds" {
  HTTP_CODES="fail"
  post_event in_progress 20 preflight ok
  [ "$(grep '^sleep' "$SHIM_LOG" | tr '\n' ' ')" = "sleep 1 sleep 2 sleep 4 " ]
}

@test "a dry run posts nothing" {
  DRY_RUN=true
  post_event started 0 started a
  ! grep -q '^curl' "$SHIM_LOG"
}

@test "each attempt has a 5 second timeout" {
  post_event started 0 started a
  grep -q -- '--max-time 5' "$SHIM_LOG"
}
