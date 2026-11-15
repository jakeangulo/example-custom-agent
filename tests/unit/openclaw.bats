#!/usr/bin/env bats

load helpers

setup() {
  common_setup
  shim systemctl
  # Fake openclaw: logs, answers --version, and records whether the gateway
  # token reached its environment during onboarding.
  export OPENCLAW_SHIM_VERSION="2026.10.2"
  write_openclaw_shim() {
    shim_script openclaw <<'EOF'
[[ "$1" == --version ]] && { echo "OpenClaw $OPENCLAW_SHIM_VERSION"; exit 0; }
if [[ "$1" == onboard ]]; then
  echo "${OPENCLAW_GATEWAY_TOKEN:-unset} HOME=$HOME" > "$BATS_TEST_TMPDIR/onboard.env"
fi
if [[ "$1" == dashboard ]]; then
  echo "${OPENCLAW_GATEWAY_TOKEN:-unset}" > "$BATS_TEST_TMPDIR/dashboard.token"
  echo '{"ok":true,"url":"http://127.0.0.1:18789/","browserUrl":"http://127.0.0.1:18789/#bootstrapToken=one-time&bootstrapProfile=p&gatewayUrl=ws%3A%2F%2F127.0.0.1%3A18789"}'
fi
exit 0
EOF
  }
  # Fake download: the metadata service answers with PUBLIC_IPV4; the upstream
  # installer, when fetched, is a script that logs its arguments and
  # "installs" the openclaw shim.
  export PUBLIC_IPV4="203.0.113.10"
  shim_script curl <<'EOF'
if [[ "${*: -1}" == *169.254.169.254* ]]; then [[ -n "$PUBLIC_IPV4" ]] || exit 22; echo "$PUBLIC_IPV4"; exit 0; fi
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
  ! grep -q '^upstream-installer' "$SHIM_LOG" || false
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

@test "a gateway token is generated into a root-only env file" {
  phase_openclaw
  [ "$(stat -c %a "$ENV_FILE" 2>/dev/null || stat -f %Lp "$ENV_FILE")" = 600 ]
  grep -qE '^OPENCLAW_GATEWAY_TOKEN="[0-9a-f]{64}"$' "$ENV_FILE"
}

@test "a re-run keeps the existing gateway token" {
  mkdir -p "$(dirname "$ENV_FILE")"
  echo 'OPENCLAW_GATEWAY_TOKEN="kept-token-0123456789"' > "$ENV_FILE"
  phase_openclaw
  grep -qx 'OPENCLAW_GATEWAY_TOKEN="kept-token-0123456789"' "$ENV_FILE"
}

@test "onboarding configures no provider and token auth on the LAN bind, with the token only in its environment" {
  phase_openclaw
  grep -q "^runuser -u openclaw -- .*openclaw onboard --non-interactive --accept-risk --mode local --auth-choice skip --secret-input-mode ref --gateway-auth token --gateway-token-ref-env OPENCLAW_GATEWAY_TOKEN --gateway-bind lan --gateway-port 18789 --skip-daemon --skip-skills --skip-health$" "$SHIM_LOG"
  local token; token="$(sed -n 's/^OPENCLAW_GATEWAY_TOKEN="\(.*\)"$/\1/p' "$ENV_FILE")"
  ! grep -q -e "$token" "$SHIM_LOG" || false
  [ "$(cut -d' ' -f1 "$BATS_TEST_TMPDIR/onboard.env")" = "$token" ]
  grep -q 'HOME=/home/openclaw' "$BATS_TEST_TMPDIR/onboard.env"
}

@test "the token does not leak into the installer's own environment" {
  phase_openclaw
  [ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]
}

@test "the Control UI accepts the server's public IPv4 origin" {
  phase_openclaw
  grep -q '^runuser -u openclaw -- .*openclaw config set gateway.controlUi.allowedOrigins \["http://203.0.113.10:18789"\] --strict-json$' "$SHIM_LOG"
}

@test "no public IPv4 from the metadata service fails the phase" {
  export PUBLIC_IPV4=""
  run phase_openclaw
  [ "$status" -ne 0 ]
  [[ "$output" == *"public IPv4"* ]]
}

@test "onboarding is skipped once the user has a config" {
  mkdir -p "$OCI_ROOT/home/openclaw/.openclaw"
  echo '{}' > "$OCI_ROOT/home/openclaw/.openclaw/openclaw.json"
  phase_openclaw
  ! grep -q 'openclaw onboard' "$SHIM_LOG" || false
}

@test "the gateway runs as a system service under the install user" {
  phase_openclaw
  grep -qx 'User=openclaw' "$UNIT"
  grep -qx 'SupplementaryGroups=docker' "$UNIT"
  grep -qx 'EnvironmentFile=/etc/openclaw/openclaw.env' "$UNIT"
  grep -qx 'Environment=HOME=/home/openclaw' "$UNIT"
  grep -qE "^ExecStart=/.+/openclaw gateway run --port 18789 --bind lan$" "$UNIT"
  grep -qx 'RestartPreventExitStatus=78' "$UNIT"
  grep -qx 'systemctl daemon-reload' "$SHIM_LOG"
  grep -qx 'systemctl enable openclaw-gateway.service' "$SHIM_LOG"
  grep -qx 'systemctl restart openclaw-gateway.service' "$SHIM_LOG"
}

@test "openclaw-cli is installed with this server's user, env file and public URL" {
  phase_openclaw
  local helper="$OCI_ROOT/usr/local/sbin/openclaw-cli"
  [ "$(stat -c %a "$helper" 2>/dev/null || stat -f %Lp "$helper")" = 755 ]
  ! grep -q '@[A-Z_]*@' "$helper" || false
  grep -qx 'PUBLIC_URL="http://203.0.113.10:18789"' "$helper"
}

@test "openclaw-cli login prints the one-time link with the public address" {
  phase_openclaw
  run "$OCI_ROOT/usr/local/sbin/openclaw-cli" login
  [ "$status" -eq 0 ]
  [[ "$output" == *"http://203.0.113.10:18789/#bootstrapToken=one-time&bootstrapProfile=p&gatewayUrl=ws%3A%2F%2F203.0.113.10%3A18789"* ]]
  [[ "$output" != *"127.0.0.1"* ]]
  local token; token="$(sed -n 's/^OPENCLAW_GATEWAY_TOKEN="\(.*\)"$/\1/p' "$ENV_FILE")"
  [[ "$output" != *"$token"* ]]
  [ "$(cat "$BATS_TEST_TMPDIR/dashboard.token")" = "$token" ]
  grep -q '^runuser -u openclaw -- env HOME=/home/openclaw /.*openclaw dashboard --json$' "$SHIM_LOG"
  ! grep -qF -- "$token" "$SHIM_LOG" || false
}

@test "openclaw-cli passes other commands to OpenClaw as the install user with the token" {
  phase_openclaw
  run "$OCI_ROOT/usr/local/sbin/openclaw-cli" devices list
  [ "$status" -eq 0 ]
  grep -q '^runuser -u openclaw -- env HOME=/home/openclaw /.*openclaw devices list$' "$SHIM_LOG"
}

@test "openclaw-cli refuses to run without the env file" {
  phase_openclaw
  chmod 000 "$ENV_FILE"
  run "$OCI_ROOT/usr/local/sbin/openclaw-cli" login
  chmod 600 "$ENV_FILE"
  [[ "$(id -u)" == 0 ]] && skip "root can read any file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"run it as root"* ]]
}
