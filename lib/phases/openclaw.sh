# shellcheck shell=bash
# 60%: OpenClaw at the pinned version, run as root (OpenClaw's default), onboarded
# with no model provider (users connect one in the Control UI), and its gateway
# as a system service serving the Control UI on the server's public IPv4.

OPENCLAW_INSTALLER_URL="https://openclaw.ai/install.sh"
GATEWAY_PORT=18789

phase_openclaw() {
  install_openclaw
  onboard_openclaw
  allow_control_ui_origin
  install_gateway_service
}

install_openclaw() {
  local current=""
  if have openclaw; then
    current="$(openclaw --version 2>/dev/null || true)"
  fi
  # Only an exact version pin can be compared; a dist-tag always re-runs the
  # installer, which updates in place.
  if [[ "$OPENCLAW_VERSION" =~ ^[0-9]+\.[0-9]+ && "$current" == *"$OPENCLAW_VERSION"* ]]; then
    log "OpenClaw $OPENCLAW_VERSION already installed"
  else
    local dir
    dir="$(mktemp -d)"
    download "$OPENCLAW_INSTALLER_URL" "$dir/install.sh"
    log "running the OpenClaw installer for version $OPENCLAW_VERSION"
    OPENCLAW_NO_PROMPT=1 bash "$dir/install.sh" --version "$OPENCLAW_VERSION" --no-prompt --no-onboard
    rm -rf "$dir"
  fi
  resolve_openclaw_bin
}

# resolve_openclaw_bin: sets OPENCLAW_BIN, also on a resumed run where this
# phase was skipped.
resolve_openclaw_bin() {
  hash -r
  OPENCLAW_BIN="$(command -v openclaw)" || die "openclaw binary not found on PATH after install"
}

onboard_openclaw() {
  if [[ -f "$OCI_ROOT/root/.openclaw/openclaw.json" ]]; then
    log "OpenClaw already onboarded"
    return 0
  fi
  log "onboarding OpenClaw: no model provider, gateway on the LAN bind with token auth"
  # With no auth flags OpenClaw generates the gateway token into its own config
  # (token mode), so the standard CLI (gateway auth-token, devices, dashboard)
  # works as root.
  "$OPENCLAW_BIN" onboard --non-interactive --accept-risk \
    --mode local --auth-choice skip \
    --gateway-bind lan --gateway-port "$GATEWAY_PORT" \
    --skip-daemon --skip-skills --skip-health
}

# The Control UI only accepts browsers from listed origins; a LAN bind needs
# the address users type. A re-run with a new PUBLIC_HOST redoes the phase.
# shortcut: IPv4 only, plain HTTP; add the IPv6 origin or a TLS front when needed.
# allow_control_ui_origin: the Control UI is reached at PUBLIC_HOST, or else at
# the IPv4 address of the default route (the public address on a typical
# cloud server). Behind NAT, set PUBLIC_HOST.
allow_control_ui_origin() {
  local host="${PUBLIC_HOST:-}"
  if [[ -z "$host" ]]; then
    host="$(ip -4 -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')" || host=""
    [[ "$host" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] ||
      die "could not find this machine's IPv4 address on the default route; set PUBLIC_HOST"
  fi
  CONTROL_UI_URL="http://$host:$GATEWAY_PORT"
  "$OPENCLAW_BIN" config set gateway.controlUi.allowedOrigins "[\"$CONTROL_UI_URL\"]" --strict-json
  log "Control UI: $CONTROL_UI_URL"
}

install_gateway_service() {
  local unit="$OCI_ROOT/etc/systemd/system/openclaw-gateway.service"
  mkdir -p "$(dirname "$unit")"
  sed -e "s|@OPENCLAW_BIN@|$OPENCLAW_BIN|g" -e "s|@PORT@|$GATEWAY_PORT|g" \
    "$SCRIPT_DIR/files/openclaw-gateway.service" > "$unit"
  chmod 644 "$unit"
  systemctl daemon-reload
  systemctl enable openclaw-gateway.service
  systemctl restart openclaw-gateway.service
}
