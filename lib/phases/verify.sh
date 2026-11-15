# shellcheck shell=bash
# 100%: checks that the install works, from the outside in. Runs on every run,
# including re-runs where every other phase is already done.

METADATA_PROBE='timeout 5 bash -c "</dev/tcp/169.254.169.254/80"'

phase_verify() {
  resolve_openclaw_bin

  if [[ "$OPENCLAW_VERSION" =~ ^[0-9]+\.[0-9]+ ]]; then
    local version
    version="$("$OPENCLAW_BIN" --version)"
    [[ "$version" == *"$OPENCLAW_VERSION"* ]] ||
      die "installed version '$version' does not match OPENCLAW_VERSION $OPENCLAW_VERSION"
  fi

  systemctl is-active --quiet openclaw-gateway.service || die "openclaw-gateway.service is not running"
  wait_for_gateway

  local image
  image="$("$OPENCLAW_BIN" config get agents.defaults.sandbox.docker.image --json | jq -r .)"
  [[ -n "$image" && "$image" != null ]] || die "no sandbox image in OpenClaw's config"
  docker run --rm --network none "$image" true || die "sandbox image $image does not start"

  if docker run --rm --network bridge "$image" bash -c "$METADATA_PROBE" 2>/dev/null; then
    die "the metadata service is reachable from a sandbox container"
  fi
  if runuser -u nobody -- bash -c "$METADATA_PROBE" 2>/dev/null; then
    die "the metadata service is reachable by non-root users"
  fi
  log "verified: OpenClaw $("$OPENCLAW_BIN" --version), gateway healthy, sandbox $image, metadata blocked"
}

# The gateway was just restarted; give it up to a minute to answer.
wait_for_gateway() {
  local i
  for i in $(seq 1 12); do
    curl -fsS --max-time 3 "http://127.0.0.1:$GATEWAY_PORT/healthz" >/dev/null 2>&1 && return 0
    ((i < 12)) && sleep 5
  done
  die "the gateway did not answer on http://127.0.0.1:$GATEWAY_PORT/healthz"
}
