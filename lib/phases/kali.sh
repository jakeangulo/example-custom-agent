# shellcheck shell=bash
# 80%: the Kali image (with KALI_PACKAGES added) wired in as OpenClaw's sandbox.

# Docker's default capabilities minus NET_RAW, which raw-socket tools such as
# nmap need. Everything else is dropped; nothing is added.
SANDBOX_CAP_DROP=(CHOWN DAC_OVERRIDE FOWNER FSETID KILL MKNOD NET_BIND_SERVICE SETFCAP SETGID SETPCAP SETUID SYS_CHROOT AUDIT_WRITE)

phase_kali() {
  resolve_openclaw_bin
  log "pulling $KALI_IMAGE"
  docker pull "$KALI_IMAGE"
  local image="$KALI_IMAGE"
  if [[ -n "$KALI_PACKAGES" ]]; then
    image="$(build_kali_image)"
  fi
  write_sandbox_config "$image"
  systemctl restart openclaw-gateway.service
}

# build_kali_image: prints the tag of a local image FROM $KALI_IMAGE with
# $KALI_PACKAGES installed. The tag hashes the base image ID and the package
# list, so a re-run with the same inputs reuses it.
build_kali_image() {
  local base_id tag
  base_id="$(docker image inspect --format '{{.Id}}' "$KALI_IMAGE")"
  tag="openclaw-kali:$(printf '%s\n%s\n' "$base_id" "$KALI_PACKAGES" | sha256 | cut -c1-12)"
  if docker image inspect "$tag" >/dev/null 2>&1; then
    log "sandbox image $tag already built" >&2
  else
    log "building $tag with: $KALI_PACKAGES" >&2
    docker build --pull=false -t "$tag" - >&2 <<DOCKERFILE
FROM $KALI_IMAGE
RUN apt-get update \\
 && DEBIAN_FRONTEND=noninteractive apt-get install -y $KALI_PACKAGES \\
 && rm -rf /var/lib/apt/lists/*
DOCKERFILE
  fi
  printf '%s\n' "$tag"
}

write_sandbox_config() {
  local image="$1" dir
  dir="$(mktemp -d)"
  chmod 755 "$dir"
  jq -n --arg image "$image" --args '{agents: {defaults: {sandbox: {
      mode: "non-main", backend: "docker", scope: "agent", workspaceAccess: "none",
      docker: {image: $image, network: "bridge", readOnlyRoot: true, user: "0:0",
               capDrop: $ARGS.positional, binds: []}}}}}' "${SANDBOX_CAP_DROP[@]}" > "$dir/sandbox.json"
  chmod 644 "$dir/sandbox.json"
  log "writing the sandbox config (image $image)"
  as_install_user "$OPENCLAW_BIN" config patch --file "$dir/sandbox.json"
  as_install_user "$OPENCLAW_BIN" config validate
  rm -rf "$dir"
}
