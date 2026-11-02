#!/usr/bin/env bats

load helpers

setup() {
  common_setup
  for c in apt-get dnf useradd; do shim "$c"; done
  shim id 1   # the install user does not exist yet
  load_phases
  # Pretend every tool is installed unless a test says otherwise.
  MISSING=""
  have() { [[ " $MISSING " != *" $1 "* ]]; }
}

@test "apt: only missing tools are installed, after one update" {
  MISSING="jq gpg"
  phase_preflight
  grep -q '^apt-get .*update' "$SHIM_LOG"
  grep -qE '^apt-get .*install .*ca-certificates jq gnupg$' "$SHIM_LOG"
  [ "$(grep -c '^apt-get .*update' "$SHIM_LOG")" = 1 ]
}

@test "apt waits for the package lock instead of failing" {
  MISSING="jq"
  phase_preflight
  grep -q '^apt-get .*DPkg::Lock::Timeout=600' "$SHIM_LOG"
}

@test "dnf: iptables comes from iptables-nft and gpg is not needed" {
  use_os rocky-9
  MISSING="iptables gpg git"
  phase_preflight
  grep -qE '^dnf -y install ca-certificates git iptables-nft$' "$SHIM_LOG"
  ! grep -q '^apt-get' "$SHIM_LOG" || false
}

@test "nothing is installed when every tool is present on dnf" {
  use_os fedora-42
  phase_preflight
  ! grep -q '^dnf' "$SHIM_LOG" || false
}

@test "the install user is created as a system user with a home" {
  phase_preflight
  grep -qE '^useradd --system --create-home --home-dir /home/openclaw --shell /usr/sbin/nologin openclaw$' "$SHIM_LOG"
}

@test "an existing install user is left alone" {
  shim id 0
  phase_preflight
  ! grep -q '^useradd' "$SHIM_LOG" || false
}
