# shellcheck shell=bash
# 60%: OpenClaw at the pinned version, onboarded for the install user, and its
# gateway as a system service.

OPENCLAW_INSTALLER_URL="https://openclaw.ai/install.sh"
GATEWAY_PORT=18789
OPENCLAW_ENV_FILE="/etc/openclaw/openclaw.env"

phase_openclaw() {
  install_openclaw
  write_openclaw_env
  onboard_openclaw
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

# as_install_user CMD...: runs CMD as the install user, with its home.
as_install_user() {
  (
    export HOME="/home/$INSTALL_USER"
    cd /
    runuser -u "$INSTALL_USER" -- "$@"
  )
}

# The provider key lives only in this root-only file, which systemd reads
# before dropping to the install user; OpenClaw's config holds a reference.
write_openclaw_env() {
  local file="$OCI_ROOT$OPENCLAW_ENV_FILE" name value
  name="$(llm_key_env_name "$LLM_AUTH_CHOICE")"
  value="${LLM_API_KEY//\\/\\\\}"
  value="${value//\"/\\\"}"
  mkdir -p "$(dirname "$file")"
  chmod 700 "$(dirname "$file")"
  (umask 077 && printf '%s="%s"\n' "$name" "$value" > "$file")
  chmod 600 "$file"
}

onboard_openclaw() {
  local home="/home/$INSTALL_USER"
  if [[ -f "$OCI_ROOT$home/.openclaw/openclaw.json" ]]; then
    log "OpenClaw already onboarded for $INSTALL_USER"
    return 0
  fi
  local name
  name="$(llm_key_env_name "$LLM_AUTH_CHOICE")"
  log "onboarding OpenClaw for $INSTALL_USER with $LLM_AUTH_CHOICE"
  # A subshell keeps the key out of this script's environment; it reaches
  # onboarding through the environment only, never the command line.
  (
    export "$name=$LLM_API_KEY"
    as_install_user "$OPENCLAW_BIN" onboard --non-interactive --accept-risk \
      --mode local --auth-choice "$LLM_AUTH_CHOICE" --secret-input-mode ref \
      --gateway-bind loopback --gateway-port "$GATEWAY_PORT" \
      --skip-daemon --skip-skills --skip-health
  )
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
