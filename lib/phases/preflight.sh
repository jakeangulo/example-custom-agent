# shellcheck shell=bash
# 20%: base tools and the install user.

phase_preflight() {
  # Each needed command and the package that provides it, per family.
  local tools=(curl:curl:curl git:git:git jq:jq:jq iptables:iptables:iptables-nft gpg:gnupg:)
  local packages=(ca-certificates) entry cmd apt_pkg dnf_pkg missing=false
  for entry in "${tools[@]}"; do
    IFS=: read -r cmd apt_pkg dnf_pkg <<< "$entry"
    have "$cmd" && continue
    if [[ "$OS_FAMILY" == apt ]]; then packages+=("$apt_pkg"); else [[ -n "$dnf_pkg" ]] && packages+=("$dnf_pkg"); fi
    missing=true
  done
  if $missing; then
    log "installing ${packages[*]}"
    pkg_install "${packages[@]}"
  fi

  if ! id -u "$INSTALL_USER" >/dev/null 2>&1; then
    log "creating system user $INSTALL_USER"
    useradd --system --create-home --home-dir "/home/$INSTALL_USER" --shell /usr/sbin/nologin "$INSTALL_USER"
  fi
}
