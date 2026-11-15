# shellcheck shell=bash
# Progress events for the provisioner's events route (see the provisioner's
# docs/api.md). Posting is best effort: a dead endpoint never fails the install.

SCRIPT_VERSION="${SCRIPT_VERSION:-dev}"

# redact TEXT: replaces every secret value in TEXT with [REDACTED].
redact() {
  local text="$1" secret
  for secret in "${CALLBACK_TOKEN:-}" "${GATEWAY_TOKEN:-}"; do
    [[ -n "$secret" ]] && text="${text//"$secret"/[REDACTED]}"
  done
  printf '%s' "$text"
}

LOG_TAIL_MAX_BYTES=12000

# json_string TEXT: TEXT as a JSON string, built without jq (which a fresh
# server may not have yet). Control characters other than tab, CR and LF, and
# all non-ASCII bytes, are dropped so the result is always valid JSON.
json_string() {
  local s
  s="$(printf '%s' "$1" | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177-\377')"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  printf '"%s"' "$s"
}

# cap_tail TEXT: the last LOG_TAIL_MAX_BYTES bytes of TEXT, from a line start.
cap_tail() {
  local text="$1"
  if ((${#text} > LOG_TAIL_MAX_BYTES)); then
    text="$(printf '%s' "$text" | tail -c "$LOG_TAIL_MAX_BYTES")"
    text="${text#*$'\n'}"
  fi
  printf '%s' "$text"
}

# post_event EVENT PERCENT PHASE MESSAGE [EXIT_CODE LOG_TAIL]
# EVENT is started | in_progress | succeeded | failed.
post_event() {
  local event="$1" percent="$2" phase="$3" message="$4" exit_code="${5:-}" log_tail="${6:-}"
  [[ "${DRY_RUN:-false}" == true ]] && return 0

  local body json
  json="{\"event\":$(json_string "$event"),\"job_id\":$(json_string "$JOB_ID")"
  json+=",\"hostname\":$(json_string "$(hostname)"),\"percent\":$((percent))"
  json+=",\"phase\":$(json_string "$phase"),\"message\":$(json_string "$(redact "$message")")"
  json+=",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"script_version\":$(json_string "$SCRIPT_VERSION")"
  json+=",\"sequence\":$(($(next_sequence)))"
  if [[ -n "$exit_code" ]]; then
    json+=",\"exit_code\":$((exit_code)),\"log_tail\":$(json_string "$(cap_tail "$(redact "$log_tail")")")"
  fi
  json+="}"
  if ! body="$(mktemp 2>/dev/null)" || ! printf '%s\n' "$json" > "$body"; then
    log "WARN: could not write the '$event' event body; not posted"
    [[ -n "${body:-}" ]] && rm -f "$body"
    return 0
  fi

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
