#!/usr/bin/env bats

load helpers

setup() {
  common_setup
  shim systemctl
  # Fake openclaw: logs and answers --version.
  export OPENCLAW_SHIM_VERSION="2026.10.2"
  write_openclaw_shim() {
    shim_script openclaw <<'EOF'
[[ "$1" == --version ]] && { echo "OpenClaw $OPENCLAW_SHIM_VERSION"; exit 0; }
exit 0
EOF
  }
  # Fake ip: the default route's source address is ROUTE_SRC (none if empty).
  export ROUTE_SRC="203.0.113.10"
  shim_script ip <<'EOF'
[[ -n "$ROUTE_SRC" ]] && echo "1.1.1.1 via 203.0.113.1 dev eth0 src $ROUTE_SRC uid 0"
exit 0
EOF
  # Fake download: the upstream installer, when fetched, is a script that logs
  # its arguments and "installs" the openclaw shim.
  shim_script curl <<'EOF'
prev=""; for a in "$@"; do [[ "$prev" == -o ]] && out="$a"; prev="$a"; done
cat > "$out" <<'EOS'
printf 'upstream-installer %s\n' "$*" >> "$SHIM_LOG"
write_openclaw_shim_from_installer
EOS
EOF
  export -f write_openclaw_shim shim_script
  write_openclaw_shim_from_installer() { write_openclaw_shim; }
  export -f write_openclaw_shim_from_installer
  load_phases
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

@test "onboarding as root configures no provider and lets OpenClaw generate the gateway token on the LAN bind" {
  phase_openclaw
  grep -q "^openclaw onboard --non-interactive --accept-risk --mode local --auth-choice skip --gateway-bind lan --gateway-port 18789 --skip-daemon --skip-skills --skip-health$" "$SHIM_LOG"
  ! grep -q -e '--gateway-token' -e '--secret-input-mode' -e '^runuser' "$SHIM_LOG" || false
}

@test "the Control UI origin is the IPv4 of the default route" {
  phase_openclaw
  grep -q '^openclaw config set gateway.controlUi.allowedOrigins \["http://203.0.113.10:18789"\] --strict-json$' "$SHIM_LOG"
}

@test "PUBLIC_HOST overrides the detected address" {
  export PUBLIC_HOST="agent.example.com"
  phase_openclaw
  grep -q '^openclaw config set gateway.controlUi.allowedOrigins \["http://agent.example.com:18789"\] --strict-json$' "$SHIM_LOG"
}

@test "no IPv4 on the default route and no PUBLIC_HOST fails the phase" {
  export ROUTE_SRC=""
  run phase_openclaw
  [ "$status" -ne 0 ]
  [[ "$output" == *"PUBLIC_HOST"* ]]
}

@test "the phase never asks a cloud metadata service" {
  phase_openclaw
  ! grep -q '169.254.169.254' "$SHIM_LOG" || false
}

@test "onboarding is skipped once root has an OpenClaw config" {
  mkdir -p "$OCI_ROOT/root/.openclaw"
  echo '{}' > "$OCI_ROOT/root/.openclaw/openclaw.json"
  phase_openclaw
  ! grep -q 'openclaw onboard' "$SHIM_LOG" || false
}

@test "the gateway runs as a root system service on the LAN bind" {
  phase_openclaw
  grep -qx 'User=root' "$UNIT"
  grep -qx 'Environment=HOME=/root' "$UNIT"
  ! grep -q -e '^EnvironmentFile=' -e '^SupplementaryGroups=' "$UNIT" || false
  grep -qE "^ExecStart=/.+/openclaw gateway run --port 18789 --bind lan$" "$UNIT"
  grep -qx 'RestartPreventExitStatus=78' "$UNIT"
  grep -qx 'systemctl daemon-reload' "$SHIM_LOG"
  grep -qx 'systemctl enable openclaw-gateway.service' "$SHIM_LOG"
  grep -qx 'systemctl restart openclaw-gateway.service' "$SHIM_LOG"
}
