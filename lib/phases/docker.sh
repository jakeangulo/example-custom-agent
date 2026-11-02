# shellcheck shell=bash
# 40%: Docker Engine from Docker's own repositories, plus the metadata block.

DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin)

phase_docker() {
  if have docker && systemctl is-active --quiet docker; then
    log "docker already installed and running"
  else
    add_docker_repo
    pkg_install "${DOCKER_PACKAGES[@]}"
    systemctl enable --now docker
  fi
  # The gateway starts sandbox containers, so its user needs the Docker socket.
  usermod -aG docker "$INSTALL_USER"
  install_metadata_block
}

add_docker_repo() {
  if [[ "$OS_FAMILY" == apt ]]; then
    local keyring="$OCI_ROOT/etc/apt/keyrings/docker.asc"
    mkdir -p "$(dirname "$keyring")" "$OCI_ROOT/etc/apt/sources.list.d"
    download "https://download.docker.com/linux/$OS_ID/gpg" "$keyring"
    chmod a+r "$keyring"
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
      "$(dpkg --print-architecture)" "$OS_ID" "$OS_CODENAME" > "$OCI_ROOT/etc/apt/sources.list.d/docker.list"
    pkg_update
  else
    # Docker publishes no Rocky or Alma repository; its CentOS one serves all
    # three RHEL 9 rebuilds.
    local repo=centos
    [[ "$OS_ID" == fedora ]] && repo=fedora
    mkdir -p "$OCI_ROOT/etc/yum.repos.d"
    download "https://download.docker.com/linux/$repo/docker-ce.repo" "$OCI_ROOT/etc/yum.repos.d/docker-ce.repo"
  fi
}

# Blocks the cloud metadata service (which serves user_data, including the
# secrets) for containers and non-root users, and keeps it blocked across
# reboots and Docker restarts.
install_metadata_block() {
  mkdir -p "$OCI_ROOT/usr/local/sbin" "$OCI_ROOT/etc/systemd/system"
  install -m 0755 "$SCRIPT_DIR/files/openclaw-metadata-block" "$OCI_ROOT/usr/local/sbin/openclaw-metadata-block"
  install -m 0644 "$SCRIPT_DIR/files/openclaw-metadata-block.service" "$OCI_ROOT/etc/systemd/system/openclaw-metadata-block.service"
  systemctl daemon-reload
  systemctl enable openclaw-metadata-block.service
  systemctl restart openclaw-metadata-block.service
}
