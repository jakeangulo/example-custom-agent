#!/usr/bin/env bats

load helpers

setup() {
  common_setup
  for c in apt-get dnf usermod iptables; do shim "$c"; done
  shim dpkg 0 amd64
  # systemctl: is-active answers DOCKER_ACTIVE_RC (default 3, not running).
  shim_script systemctl <<'EOF2'
[[ "$1" == is-active ]] && exit "${DOCKER_ACTIVE_RC:-3}"
exit 0
EOF2
  download_shim
  load_phases
  have() { [[ "$1" != docker ]]; }
}

@test "debian: Docker's signed apt repository is added for the release" {
  phase_docker
  grep -q 'https://download.docker.com/linux/debian/gpg' "$SHIM_LOG"
  [ -f "$OCI_ROOT/etc/apt/keyrings/docker.asc" ]
  grep -qx 'deb \[arch=amd64 signed-by=/etc/apt/keyrings/docker.asc\] https://download.docker.com/linux/debian bookworm stable' \
    "$OCI_ROOT/etc/apt/sources.list.d/docker.list"
  grep -qE '^apt-get .*install .*docker-ce docker-ce-cli containerd.io docker-buildx-plugin$' "$SHIM_LOG"
}

@test "ubuntu uses its own repository and codename" {
  use_os ubuntu-24.04
  phase_docker
  grep -q 'https://download.docker.com/linux/ubuntu noble stable' "$OCI_ROOT/etc/apt/sources.list.d/docker.list"
}

@test "fedora uses the fedora repository" {
  use_os fedora-42
  phase_docker
  grep -q 'https://download.docker.com/linux/fedora/docker-ce.repo' "$SHIM_LOG"
  [ -f "$OCI_ROOT/etc/yum.repos.d/docker-ce.repo" ]
  grep -qE '^dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin$' "$SHIM_LOG"
}

@test "rocky, alma and centos stream use the centos repository" {
  local os
  for os in rocky-9 almalinux-9 centos-stream-9; do
    : > "$SHIM_LOG"
    use_os "$os"
    phase_docker
    grep -q 'https://download.docker.com/linux/centos/docker-ce.repo' "$SHIM_LOG" || { echo "$os"; return 1; }
  done
}

@test "downloads are https-only" {
  phase_docker
  ! grep '^curl' "$SHIM_LOG" | grep -v -- "--proto =https --tlsv1.2"
}

@test "docker is enabled and started, and the install user joins the docker group" {
  phase_docker
  grep -qx 'systemctl enable --now docker' "$SHIM_LOG"
  grep -qx 'usermod -aG docker openclaw' "$SHIM_LOG"
}

@test "an installed, running docker is not reinstalled" {
  have() { true; }
  export DOCKER_ACTIVE_RC=0
  phase_docker
  ! grep -q 'docker-ce' "$SHIM_LOG"
  grep -qx 'usermod -aG docker openclaw' "$SHIM_LOG"
}

@test "the metadata block is installed as a boot-time service and applied" {
  phase_docker
  [ -x "$OCI_ROOT/usr/local/sbin/openclaw-metadata-block" ]
  grep -q 'ExecStart=/usr/local/sbin/openclaw-metadata-block' "$OCI_ROOT/etc/systemd/system/openclaw-metadata-block.service"
  grep -qx 'systemctl daemon-reload' "$SHIM_LOG"
  grep -qx 'systemctl enable openclaw-metadata-block.service' "$SHIM_LOG"
  grep -qx 'systemctl restart openclaw-metadata-block.service' "$SHIM_LOG"
}

@test "the metadata block drops container and non-root traffic to the metadata address" {
  shim_script iptables <<'EOF2'   # -C finds no rule yet; -I succeeds
[[ "$1" == -C ]] && exit 1
exit 0
EOF2
  bash "$REPO_ROOT/files/openclaw-metadata-block"
  grep -qx 'iptables -I DOCKER-USER -d 169.254.169.254/32 -j DROP' "$SHIM_LOG"
  grep -qx 'iptables -I OUTPUT -d 169.254.169.254/32 -m owner ! --uid-owner 0 -j DROP' "$SHIM_LOG"
}

@test "the metadata block adds nothing when the rules exist" {
  shim iptables 0   # -C finds the rules
  bash "$REPO_ROOT/files/openclaw-metadata-block"
  ! grep -q -- ' -I ' "$SHIM_LOG"
}
