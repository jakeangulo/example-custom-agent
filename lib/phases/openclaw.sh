# shellcheck shell=bash
# 60%: OpenClaw at the pinned version, onboarded for the install user with no
# model provider (users connect one in the Control UI), and its gateway as a
# system service serving the Control UI on the server's public IPv4.

OPENCLAW_INSTALLER_URL="https://openclaw.ai/install.sh"
GATEWAY_PORT=18789
OPENCLAW_ENV_FILE="/etc/openclaw/openclaw.env"
PUBLIC_IPV4_URL="http://169.254.169.254/hetzner/v1/metadata/public-ipv4"

phase_openclaw() {
  install_openclaw
  write_openclaw_env
  onboard_openclaw
  allow_control_ui_origin
  install_gateway_service
  install_cli_helper
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

# as_install_user CMD...: runs CMD as the install user, with its home.
as_install_user() {
  (
    export HOME="/home/$INSTALL_USER"
    cd /
    runuser -u "$INSTALL_USER" -- "$@"
  )
}

# The gateway token lives only in this root-only file, which systemd reads
# before dropping to the install user; OpenClaw's config holds a reference. It
# is generated once and kept on re-runs, so paired browsers stay paired.
write_openclaw_env() {
  local file="$OCI_ROOT$OPENCLAW_ENV_FILE"
  GATEWAY_TOKEN="$(sed -n 's/^OPENCLAW_GATEWAY_TOKEN="\(.*\)"$/\1/p' "$file" 2>/dev/null || true)"
  [[ -n "$GATEWAY_TOKEN" ]] || GATEWAY_TOKEN="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  mkdir -p "$(dirname "$file")"
  chmod 700 "$(dirname "$file")"
  (umask 077 && printf 'OPENCLAW_GATEWAY_TOKEN="%s"\n' "$GATEWAY_TOKEN" > "$file")
  chmod 600 "$file"
}

onboard_openclaw() {
  local home="/home/$INSTALL_USER"
  if [[ -f "$OCI_ROOT$home/.openclaw/openclaw.json" ]]; then
    log "OpenClaw already onboarded for $INSTALL_USER"
    return 0
  fi
  log "onboarding OpenClaw for $INSTALL_USER, no model provider, gateway on the LAN bind with token auth"
  # A subshell keeps the token out of this script's environment; it reaches
  # onboarding through the environment only, never the command line.
  (
    export OPENCLAW_GATEWAY_TOKEN="$GATEWAY_TOKEN"
    as_install_user "$OPENCLAW_BIN" onboard --non-interactive --accept-risk \
      --mode local --auth-choice skip --secret-input-mode ref \
      --gateway-auth token --gateway-token-ref-env OPENCLAW_GATEWAY_TOKEN \
      --gateway-bind lan --gateway-port "$GATEWAY_PORT" \
      --skip-daemon --skip-skills --skip-health
  )
}

# The Control UI only accepts browsers from listed origins; a LAN bind needs
# the address users type. Runs every time, so a re-run fixes a changed IP.
# shortcut: IPv4 only, plain HTTP; add the IPv6 origin or a TLS front when needed.
allow_control_ui_origin() {
  local ip
  ip="$(curl -fsS --max-time 5 "$PUBLIC_IPV4_URL")" || die "could not read the public IPv4 from $PUBLIC_IPV4_URL"
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "the metadata service returned no IPv4 address"
  CONTROL_UI_URL="http://$ip:$GATEWAY_PORT"
  as_install_user "$OPENCLAW_BIN" config set gateway.controlUi.allowedOrigins "[\"$CONTROL_UI_URL\"]" --strict-json
  log "Control UI: $CONTROL_UI_URL"
}

install_gateway_service() {
  local unit="$OCI_ROOT/etc/systemd/system/openclaw-gateway.service"
  mkdir -p "$(dirname "$unit")"
  sed -e "s|@USER@|$INSTALL_USER|g" -e "s|@HOME@|/home/$INSTALL_USER|g" \
    -e "s|@OPENCLAW_BIN@|$OPENCLAW_BIN|g" -e "s|@PORT@|$GATEWAY_PORT|g" \
    "$SCRIPT_DIR/files/openclaw-gateway.service" > "$unit"
  chmod 644 "$unit"
  systemctl daemon-reload
  systemctl enable openclaw-gateway.service
  systemctl restart openclaw-gateway.service
}

# openclaw-cli runs OpenClaw as the gateway does, and `openclaw-cli login`
# prints the one-time Control UI link with the public address.
install_cli_helper() {
  local helper="$OCI_ROOT/usr/local/sbin/openclaw-cli"
  mkdir -p "$(dirname "$helper")"
  sed -e "s|@USER@|$INSTALL_USER|g" -e "s|@HOME@|/home/$INSTALL_USER|g" \
    -e "s|@OPENCLAW_BIN@|$OPENCLAW_BIN|g" -e "s|@PORT@|$GATEWAY_PORT|g" \
    -e "s|@ENV_FILE@|$OCI_ROOT$OPENCLAW_ENV_FILE|g" -e "s|@PUBLIC_URL@|$CONTROL_UI_URL|g" \
    "$SCRIPT_DIR/files/openclaw-cli" > "$helper"
  chmod 755 "$helper"
  log "Control UI login: run 'openclaw-cli login' as root on this server"
}
