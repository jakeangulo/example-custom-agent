#!/usr/bin/env bats

load helpers

setup() {
  common_setup
  shim systemctl
  # Fake docker: inspect of the base image gives its ID; inspect of a built tag
  # succeeds only if the tag is listed in BUILT_TAGS; build saves the Dockerfile.
  shim_script docker <<'EOF'
if [[ "$1 $2" == "image inspect" ]]; then
  [[ "$3" == --format ]] && { echo "sha256:base${KALI_IMAGE_ID_SUFFIX:-1}"; exit 0; }
  [[ " ${BUILT_TAGS:-} " == *" $3 "* ]] && exit 0 || exit 1
fi
[[ "$1" == build ]] && cat > "$BATS_TEST_TMPDIR/Dockerfile"
exit 0
EOF
  # Fake openclaw: keeps a copy of the config patch it is given.
  shim_script openclaw <<'EOF'
prev=""; for a in "$@"; do [[ "$prev" == --file ]] && cp "$a" "$BATS_TEST_TMPDIR/patch.json"; prev="$a"; done
exit 0
EOF
  shim_script runuser <<'EOF'
shift 3
exec "$@"
EOF
  load_phases
  OPENCLAW_BIN="$SHIM_DIR/openclaw"
}

sandbox() { jq -r ".agents.defaults.sandbox$1" "$BATS_TEST_TMPDIR/patch.json"; }
built_tag() { grep '^docker build' "$SHIM_LOG" | sed -E 's/.* -t ([^ ]+) .*/\1/'; }

@test "the Kali image is pulled" {
  phase_kali
  grep -qx "docker pull $KALI_IMAGE" "$SHIM_LOG"
}

@test "packages are added in a local image built from the Kali image" {
  phase_kali
  grep -q "^docker build --pull=false -t openclaw-kali:[0-9a-f]\{12\} -$" "$SHIM_LOG"
  grep -qx "FROM $KALI_IMAGE" "$BATS_TEST_TMPDIR/Dockerfile"
  grep -q "apt-get install -y kali-linux-headless" "$BATS_TEST_TMPDIR/Dockerfile"
  [ "$(sandbox .docker.image)" = "$(built_tag)" ]
}

@test "the build is skipped when the image for these inputs exists" {
  phase_kali
  local tag; tag="$(built_tag)"
  : > "$SHIM_LOG"
  BUILT_TAGS="$tag" phase_kali
  ! grep -q '^docker build' "$SHIM_LOG" || false
  [ "$(sandbox .docker.image)" = "$tag" ]
}

@test "different packages or a new base image give a different tag" {
  phase_kali; local a; a="$(built_tag)"
  : > "$SHIM_LOG"; KALI_PACKAGES="nmap"; phase_kali; local b; b="$(built_tag)"
  : > "$SHIM_LOG"; KALI_IMAGE_ID_SUFFIX=2 phase_kali; local c; c="$(built_tag)"
  [ "$a" != "$b" ] && [ "$b" != "$c" ]
}

@test "empty KALI_PACKAGES uses the Kali image as-is" {
  KALI_PACKAGES=""
  phase_kali
  ! grep -q '^docker build' "$SHIM_LOG" || false
  [ "$(sandbox .docker.image)" = "$KALI_IMAGE" ]
}

@test "the sandbox config follows the agreed policy" {
  phase_kali
  [ "$(sandbox .mode)" = non-main ]
  [ "$(sandbox .backend)" = docker ]
  [ "$(sandbox .scope)" = agent ]
  [ "$(sandbox .workspaceAccess)" = none ]
  [ "$(sandbox .docker.network)" = bridge ]
  [ "$(sandbox .docker.readOnlyRoot)" = true ]
  [ "$(sandbox '.docker.binds | length')" = 0 ]
}

@test "the sandbox keeps only NET_RAW of Docker's default capabilities" {
  phase_kali
  [ "$(sandbox '.docker.user')" = "0:0" ]
  [ "$(sandbox '.docker.capDrop | index("NET_RAW")')" = null ]
  local cap
  for cap in CHOWN DAC_OVERRIDE FOWNER FSETID KILL MKNOD NET_BIND_SERVICE SETFCAP SETGID SETPCAP SETUID SYS_CHROOT AUDIT_WRITE; do
    [ "$(sandbox ".docker.capDrop | index(\"$cap\")")" != null ] || { echo "kept $cap"; return 1; }
  done
}

@test "the config is applied and validated as the install user, then the gateway restarts" {
  phase_kali
  grep -q "^runuser -u openclaw -- .*openclaw config patch --file " "$SHIM_LOG"
  grep -q "^runuser -u openclaw -- .*openclaw config validate$" "$SHIM_LOG"
  [ "$(grep -n '^runuser.*config validate' "$SHIM_LOG" | cut -d: -f1)" -gt "$(grep -n '^runuser.*config patch' "$SHIM_LOG" | cut -d: -f1)" ]
  [ "$(grep -n 'restart openclaw-gateway' "$SHIM_LOG" | cut -d: -f1)" -gt "$(grep -n '^runuser.*config validate' "$SHIM_LOG" | cut -d: -f1)" ]
}

@test "on a resumed run the openclaw binary is found on PATH" {
  unset OPENCLAW_BIN
  phase_kali
  grep -q "^runuser -u openclaw -- $SHIM_DIR/openclaw config patch" "$SHIM_LOG"
}
