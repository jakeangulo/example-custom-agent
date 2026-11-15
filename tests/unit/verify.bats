#!/usr/bin/env bats

load helpers

setup() {
  common_setup
  shim sleep
  export OPENCLAW_SHIM_VERSION="2026.10.2" GATEWAY_RC=0 HEALTH_FAILS=0 CONTAINER_METADATA_RC=1 HOST_METADATA_RC=1
  shim_script openclaw <<'EOF'
[[ "$1" == --version ]] && { echo "OpenClaw $OPENCLAW_SHIM_VERSION"; exit 0; }
[[ "$1 $2" == "config get" ]] && { echo '"openclaw-kali:abc123def456"'; exit 0; }
exit 0
EOF
  shim_script systemctl <<'EOF'
exit "$GATEWAY_RC"
EOF
  # curl: /healthz fails HEALTH_FAILS times, then answers.
  shim_script curl <<'EOF'
n=$(grep -c '^curl ' "$SHIM_LOG")
(( n <= HEALTH_FAILS )) && exit 7
echo ok
EOF
  # docker run: the metadata probe exits CONTAINER_METADATA_RC; anything else 0.
  shim_script docker <<'EOF'
[[ "$*" == *169.254.169.254* ]] && exit "$CONTAINER_METADATA_RC"
exit 0
EOF
  # runuser: the host metadata probe exits HOST_METADATA_RC; anything else runs.
  shim_script runuser <<'EOF'
[[ "$*" == *169.254.169.254* ]] && exit "$HOST_METADATA_RC"
shift 3
exec "$@"
EOF
  load_phases
}

@test "a healthy install passes every check" {
  run phase_verify
  [ "$status" -eq 0 ]
  grep -qx 'systemctl is-active --quiet openclaw-gateway.service' "$SHIM_LOG"
  grep -q '^curl .*http://127.0.0.1:18789/healthz' "$SHIM_LOG"
}

@test "the sandbox image named in OpenClaw's config is started" {
  phase_verify
  grep -q '^openclaw config get agents.defaults.sandbox.docker.image --json$' "$SHIM_LOG"
  grep -qx 'docker run --rm --network none openclaw-kali:abc123def456 true' "$SHIM_LOG"
}

@test "a different installed version fails verification" {
  export OPENCLAW_SHIM_VERSION="2026.9.0"
  run phase_verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"version"* ]]
}

@test "a dist-tag pin skips the version comparison" {
  OPENCLAW_VERSION=latest
  export OPENCLAW_SHIM_VERSION="2026.9.0"
  run phase_verify
  [ "$status" -eq 0 ]
}

@test "an inactive gateway service fails verification" {
  export GATEWAY_RC=3
  run phase_verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"openclaw-gateway"* ]]
}

@test "the health check waits for a gateway that is still starting" {
  export HEALTH_FAILS=3
  run phase_verify
  [ "$status" -eq 0 ]
}

@test "a gateway that never answers fails after about a minute" {
  export HEALTH_FAILS=999
  run phase_verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"healthz"* ]]
  [ "$(grep -c '^curl ' "$SHIM_LOG")" = 12 ]
}

@test "metadata reachable from a container fails verification" {
  export CONTAINER_METADATA_RC=0
  run phase_verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"metadata"*"container"* ]]
  grep -q '^docker run --rm --network bridge openclaw-kali:abc123def456 ' "$SHIM_LOG"
}

@test "metadata reachable by non-root users fails verification" {
  export HOST_METADATA_RC=0
  run phase_verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"metadata"*"non-root"* ]]
}
