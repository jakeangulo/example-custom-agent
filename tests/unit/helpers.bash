# Shared setup for the unit tests. Every test gets its own fake filesystem root
# (OCI_ROOT) and a bin directory of command shims that record their calls.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
FIXTURES="$REPO_ROOT/tests/fixtures"

common_setup() {
  export OCI_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$OCI_ROOT/etc" "$OCI_ROOT/run" "$OCI_ROOT/var/lib" "$OCI_ROOT/var/log"
  cp "$FIXTURES/os-release/debian-12" "$OCI_ROOT/etc/os-release"
  export SHIM_DIR="$BATS_TEST_TMPDIR/bin"
  export SHIM_LOG="$BATS_TEST_TMPDIR/calls.log"
  mkdir -p "$SHIM_DIR"
  : > "$SHIM_LOG"
  export PATH="$SHIM_DIR:$PATH"
  set_valid_env
}

set_valid_env() {
  export OPENCLAW_VERSION="2026.10.2"
  export KALI_IMAGE="kalilinux/kali-rolling:2025.4"
  export CALLBACK_URL="https://api.example.test/deployments/d-1/events"
  export CALLBACK_TOKEN="tok_0123456789abcdefABCDEF"
  export JOB_ID="d-01JBX7Q8M4N2R5T6V7W8X9Y0Z1"
  export LLM_AUTH_CHOICE="apiKey"
  export LLM_API_KEY="sk-ant-test-secret-value"
  unset INSTALL_USER KALI_PACKAGES DRY_RUN
}

# shim NAME [EXIT_CODE] [STDOUT]: a fake command that logs "NAME args" and
# exits with EXIT_CODE (default 0) after printing STDOUT.
shim() {
  local name="$1" rc="${2:-0}" out="${3:-}"
  cat > "$SHIM_DIR/$name" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$name \$*" >> "\$SHIM_LOG"
${out:+printf '%s\n' "$out"}
exit $rc
EOF
  chmod +x "$SHIM_DIR/$name"
}

# shim_script NAME: a fake command whose body is read from stdin; it still logs.
shim_script() {
  local name="$1"
  { printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s $*" >> "$SHIM_LOG"\n' "$name"; cat; } > "$SHIM_DIR/$name"
  chmod +x "$SHIM_DIR/$name"
}
