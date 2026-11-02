#!/usr/bin/env bats

load helpers

setup() {
  common_setup
  shim systemctl
  # Fake openclaw: logs, answers --version, and records whether the provider
  # key reached its environment during onboarding.
  export OPENCLAW_SHIM_VERSION="2026.10.2"
  write_openclaw_shim() {
    shim_script openclaw <<'EOF'
[[ "$1" == --version ]] && { echo "OpenClaw $OPENCLAW_SHIM_VERSION"; exit 0; }
if [[ "$1" == onboard ]]; then
  echo "${ANTHROPIC_API_KEY:-unset} ${GEMINI_API_KEY:-unset} HOME=$HOME" > "$BATS_TEST_TMPDIR/onboard.env"
fi
exit 0
EOF
  }
  # Fake download: the upstream installer, when fetched, is a script that logs
  # its arguments and "installs" the openclaw shim.
  shim_script curl <<'EOF'
prev=""; for a in "$@"; do [[ "$prev" == -o ]] && out="$a"; prev="$a"; done
cat > "$out" <<'EOS'
printf 'upstream-installer %s\n' "$*" >> "$SHIM_LOG"
write_openclaw_shim_from_installer
EOS
EOF
  # runuser -u USER -- CMD...: logs, then runs CMD with the current environment.
  shim_script runuser <<'EOF'
shift 3
exec "$@"
EOF
  export -f write_openclaw_shim shim_script
  write_openclaw_shim_from_installer() { write_openclaw_shim; }
  export -f write_openclaw_shim_from_installer
  load_phases
  ENV_FILE="$OCI_ROOT/etc/openclaw/openclaw.env"
  UNIT="$OCI_ROOT/etc/systemd/system/openclaw-gateway.service"
}

@test "the upstream installer is downloaded over https and run with the pin" {
  phase_openclaw
  grep -q "^curl .*--proto =https --tlsv1.2 .*https://openclaw.ai/install.sh" "$SHIM_LOG"
  grep -qx "upstream-installer --version 2026.10.2 --no-prompt --no-onboard" "$SHIM_LOG"
}

@test "an install already at the pinned version is not reinstalled" {
  write_openclaw_shim
  phase_openclaw
  ! grep -q '^upstream-installer' "$SHIM_LOG"
}

@test "a different installed version is replaced" {
  write_openclaw_shim
  export OPENCLAW_SHIM_VERSION="2026.9.0"
  phase_openclaw
  grep -q '^upstream-installer' "$SHIM_LOG"
}

@test "a dist-tag pin always runs the installer" {
  write_openclaw_shim
  OPENCLAW_VERSION=latest
  phase_openclaw
  grep -q '^upstream-installer --version latest' "$SHIM_LOG"
}

@test "a missing openclaw binary after install fails the phase" {
  write_openclaw_shim_from_installer() { :; }
  export -f write_openclaw_shim_from_installer
  run phase_openclaw
  [ "$status" -ne 0 ]
  [[ "$output" == *"openclaw"*"not found"* ]]
}

@test "the provider key is written to a root-only env file" {
  phase_openclaw
  [ "$(stat -c %a "$ENV_FILE" 2>/dev/null || stat -f %Lp "$ENV_FILE")" = 600 ]
  grep -qx "ANTHROPIC_API_KEY=\"$LLM_API_KEY\"" "$ENV_FILE"
}

@test "the env file names the variable for the chosen provider" {
  LLM_AUTH_CHOICE=gemini-api-key
  phase_openclaw
  grep -q '^GEMINI_API_KEY=' "$ENV_FILE"
  ! grep -q '^ANTHROPIC_API_KEY=' "$ENV_FILE"
}

@test "onboarding runs as the install user with the key only in its environment" {
  phase_openclaw
  grep -q "^runuser -u openclaw -- .*openclaw onboard --non-interactive --accept-risk --mode local --auth-choice apiKey --secret-input-mode ref --gateway-bind loopback --gateway-port 18789 --skip-daemon --skip-skills --skip-health$" "$SHIM_LOG"
  ! grep -q -e "$LLM_API_KEY" "$SHIM_LOG"
  [ "$(cut -d' ' -f1 "$BATS_TEST_TMPDIR/onboard.env")" = "$LLM_API_KEY" ]
  grep -q 'HOME=/home/openclaw' "$BATS_TEST_TMPDIR/onboard.env"
}

@test "the key does not leak into the installer's own environment" {
  phase_openclaw
  [ -z "${ANTHROPIC_API_KEY:-}" ]
}

@test "onboarding is skipped once the user has a config" {
  mkdir -p "$OCI_ROOT/home/openclaw/.openclaw"
  echo '{}' > "$OCI_ROOT/home/openclaw/.openclaw/openclaw.json"
  phase_openclaw
  ! grep -q 'openclaw onboard' "$SHIM_LOG"
}

@test "the gateway runs as a system service under the install user" {
  phase_openclaw
  grep -qx 'User=openclaw' "$UNIT"
  grep -qx 'SupplementaryGroups=docker' "$UNIT"
  grep -qx 'EnvironmentFile=/etc/openclaw/openclaw.env' "$UNIT"
  grep -qx 'Environment=HOME=/home/openclaw' "$UNIT"
  grep -qE "^ExecStart=/.+/openclaw gateway run --port 18789 --bind loopback$" "$UNIT"
  grep -qx 'RestartPreventExitStatus=78' "$UNIT"
  grep -qx 'systemctl daemon-reload' "$SHIM_LOG"
  grep -qx 'systemctl enable openclaw-gateway.service' "$SHIM_LOG"
  grep -qx 'systemctl restart openclaw-gateway.service' "$SHIM_LOG"
}
