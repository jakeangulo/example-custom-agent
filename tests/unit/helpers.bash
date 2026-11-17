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
  unset KALI_PACKAGES DRY_RUN PUBLIC_HOST CALLBACK_URL CALLBACK_TOKEN JOB_ID
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

# markers: the ::progress and ::error lines of the last `run`, in order.
markers() { grep -E '^::(progress|error) ' <<< "$output" || true; }

# load_phases: sources the libraries and every phase with valid parameters.
load_phases() {
  SCRIPT_DIR="$REPO_ROOT"  # set by install.sh in production
  source "$REPO_ROOT/lib/common.sh"
  local f
  for f in "$REPO_ROOT"/lib/phases/*.sh; do source "$f"; done
  parse_args
  validate_params
  detect_os
}

# use_os FIXTURE: switch the fake os-release and re-detect.
use_os() {
  cp "$FIXTURES/os-release/$1" "$OCI_ROOT/etc/os-release"
  detect_os
}

# download_shim: a fake curl that creates the file named by -o.
download_shim() {
  shim_script curl <<'EOF2'
prev=""; for a in "$@"; do [[ "$prev" == -o ]] && echo "downloaded $*" > "$a"; prev="$a"; done
exit 0
EOF2
}
