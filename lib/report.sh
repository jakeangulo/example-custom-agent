# shellcheck shell=bash
# Progress events for the provisioner's events route (see the provisioner's
# docs/api.md). Posting is best effort: a dead endpoint never fails the install.

SCRIPT_VERSION="${SCRIPT_VERSION:-dev}"

# redact TEXT: replaces every secret value in TEXT with [REDACTED].
redact() {
  local text="$1" secret
  for secret in "${CALLBACK_TOKEN:-}" "${LLM_API_KEY:-}"; do
    [[ -n "$secret" ]] && text="${text//"$secret"/[REDACTED]}"
  done
  printf '%s' "$text"
}

# post_event EVENT PERCENT PHASE MESSAGE [EXIT_CODE LOG_TAIL]
# EVENT is started | in_progress | succeeded | failed.
post_event() {
  local event="$1" percent="$2" phase="$3" message="$4" exit_code="${5:-}" log_tail="${6:-}"
  [[ "${DRY_RUN:-false}" == true ]] && return 0

  local body
  body="$(mktemp)"
  jq -n \
    --arg event "$event" --argjson percent "$percent" --arg phase "$phase" \
    --arg message "$(redact "$message")" --arg job_id "$JOB_ID" \
    --arg hostname "$(hostname)" --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg script_version "$SCRIPT_VERSION" --argjson sequence "$(next_sequence)" \
    --arg exit_code "$exit_code" --arg log_tail "$(redact "$log_tail")" \
    '{event: $event, job_id: $job_id, hostname: $hostname, percent: $percent, phase: $phase,
      message: $message, timestamp: $timestamp, script_version: $script_version, sequence: $sequence}
     + (if $exit_code == "" then {} else {exit_code: ($exit_code | tonumber), log_tail: $log_tail} end)' \
    > "$body"

  local attempt code delay=1
  for attempt in 1 2 3 4; do
    # The token is passed as curl config on stdin so it never shows up in ps.
    code="$(printf 'header = "Authorization: Bearer %s"\n' "$CALLBACK_TOKEN" |
      curl -sS -o /dev/null -w '%{http_code}' --max-time 5 -K - \
        -H 'Content-Type: application/json' --data-binary "@$body" "$CALLBACK_URL" 2>/dev/null)" || code=000
    if [[ "$code" == 2?? ]]; then
      rm -f "$body"
      return 0
    fi
    if ((attempt < 4)); then
      sleep "$delay"
      delay=$((delay * 2))
    fi
  done
  rm -f "$body"
  log "WARN: could not post '$event' event (last HTTP status $code); continuing"
  return 0
}
