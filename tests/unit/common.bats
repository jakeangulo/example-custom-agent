#!/usr/bin/env bats

load helpers

setup() {
  common_setup
  # shellcheck source=../../lib/common.sh
  source "$REPO_ROOT/lib/common.sh"
}

# --- parameters -------------------------------------------------------------

@test "valid environment passes validation and applies defaults" {
  parse_args
  run validate_params
  [ "$status" -eq 0 ]
  parse_args
  validate_params
  [ "$KALI_PACKAGES" = "kali-linux-headless" ]
  [ "$DRY_RUN" = "false" ]
}

@test "a flag overrides the environment for non-secret parameters" {
  parse_args --openclaw-version 2026.11.0 --kali-packages nmap --public-host 198.51.100.7 --dry-run
  [ "$PUBLIC_HOST" = "198.51.100.7" ]
  [ "$OPENCLAW_VERSION" = "2026.11.0" ]
  [ "$KALI_PACKAGES" = "nmap" ]
  [ "$DRY_RUN" = "true" ]
}

@test "--callback-url and --job-id are unknown options" {
  local opt
  for opt in --callback-url --job-id --callback-token; do
    run parse_args "$opt" x
    [ "$status" -ne 0 ] || { echo "accepted: $opt"; return 1; }
    [[ "$output" == *"unknown option"* ]]
  done
}

@test "unknown flags are refused" {
  run parse_args --bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"--bogus"* ]]
}

@test "every missing required parameter is reported at once" {
  unset OPENCLAW_VERSION KALI_IMAGE
  parse_args
  run validate_params
  [ "$status" -ne 0 ]
  for p in OPENCLAW_VERSION KALI_IMAGE; do
    [[ "$output" == *"$p"* ]]
  done
}

@test "malformed values are rejected" {
  local cases=(
    "OPENCLAW_VERSION=1.0; rm -rf /"
    "KALI_IMAGE=kalilinux/kali-rolling"
    "KALI_IMAGE=Kali/Rolling:latest"
    "KALI_PACKAGES=nmap; curl evil"
    "PUBLIC_HOST=http://x.example"
    "PUBLIC_HOST=a b"
    "DRY_RUN=yes"
  )
  local c
  for c in "${cases[@]}"; do
    set_valid_env
    export "${c%%=*}=${c#*=}"
    parse_args
    run validate_params
    [ "$status" -ne 0 ] || { echo "accepted: $c"; return 1; }
    [[ "$output" == *"${c%%=*}"* ]]
  done
}

@test "KALI_IMAGE accepts registry, port and digest forms" {
  local img
  for img in kalilinux/kali-rolling:2025.4 registry.example.com:5000/sec/kali:1 \
             kalilinux/kali-rolling@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef; do
    export KALI_IMAGE="$img"
    parse_args
    run validate_params
    [ "$status" -eq 0 ] || { echo "rejected: $img"; return 1; }
  done
}

@test "an empty KALI_PACKAGES is allowed" {
  export KALI_PACKAGES=""
  parse_args
  validate_params
  [ "$KALI_PACKAGES" = "" ]
}

# --- OS detection -----------------------------------------------------------

@test "each supported distro maps to its package family" {
  local f expected
  for f in debian-12:apt ubuntu-24.04:apt rocky-9:dnf almalinux-9:dnf centos-stream-9:dnf fedora-42:dnf; do
    cp "$FIXTURES/os-release/${f%%:*}" "$OCI_ROOT/etc/os-release"
    expected="${f#*:}"
    detect_os
    [ "$OS_FAMILY" = "$expected" ] || { echo "$f -> $OS_FAMILY"; return 1; }
  done
}

@test "detect_os records the distro id and codename" {
  cp "$FIXTURES/os-release/ubuntu-24.04" "$OCI_ROOT/etc/os-release"
  detect_os
  [ "$OS_ID" = "ubuntu" ]
  [ "$OS_CODENAME" = "noble" ]
}

@test "unsupported distros are refused, including look-alikes" {
  local f
  for f in opensuse-leap linuxmint; do
    cp "$FIXTURES/os-release/$f" "$OCI_ROOT/etc/os-release"
    run detect_os
    [ "$status" -ne 0 ] || { echo "accepted: $f"; return 1; }
    [[ "$output" == *"nsupported"* ]]
  done
}

# --- state ------------------------------------------------------------------

@test "completed phases are remembered across runs" {
  parse_args; validate_params
  state_init
  state_mark_done preflight
  state_mark_done docker
  state_init
  state_is_done preflight
  state_is_done docker
  ! state_is_done openclaw || false
}

@test "changing a phase's input redoes only that phase" {
  parse_args; validate_params
  state_init
  local p; for p in preflight docker openclaw kali; do state_mark_done "$p"; done
  export KALI_IMAGE="kalilinux/kali-rolling:2026.1"
  parse_args; validate_params
  state_init
  state_is_done preflight
  state_is_done docker
  state_is_done openclaw
  ! state_is_done kali || false
  export OPENCLAW_VERSION="2026.11.0"
  parse_args; validate_params
  ! state_is_done openclaw || false
  state_is_done docker
}

@test "changing PUBLIC_HOST redoes the openclaw phase" {
  parse_args; validate_params
  state_init
  state_mark_done openclaw
  export PUBLIC_HOST="agent.example.com"
  parse_args; validate_params
  ! state_is_done openclaw || false
}

@test "the state directory is private" {
  parse_args; validate_params
  state_init
  [ "$(stat -c %a "$OCI_ROOT/var/lib/openclaw-install" 2>/dev/null || stat -f %Lp "$OCI_ROOT/var/lib/openclaw-install")" = "700" ]
}

@test "validation reports missing parameters cleanly under set -u" {
  unset KALI_IMAGE
  run bash -c 'set -euo pipefail; source "$1"; parse_args; validate_params' _ "$REPO_ROOT/lib/common.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"KALI_IMAGE is required"* ]]
  [[ "$output" != *"unbound variable"* ]]
}
