#!/usr/bin/env bash
# Runs the installer on real Hetzner Cloud servers, one per supported distro,
# and checks the result from the outside. The installer is run over SSH exactly
# as a person or a provisioning tool would: clone, then sudo ./install.sh with
# parameters in the environment. Costs a few euro cents per run: every server is
# deleted at the end, even on failure or Ctrl-C.
#
# Requirements: hcloud CLI, jq, ssh, ssh-keygen.
# The repository must be publicly cloneable at GIT_REF (pushed).
#
# Environment:
#   HCLOUD_TOKEN       Hetzner API token (read-write), for example
#                      HCLOUD_TOKEN=$(security find-generic-password -s <service> -w)
#   GIT_REF            commit to test (default: HEAD of this checkout)
#   GIT_URL            default https://gitlab.com/appyfic/example-custom-agent.git
#   OPENCLAW_VERSION   default latest
#   KALI_IMAGE         default kalilinux/kali-rolling:latest
#   KALI_PACKAGES      default "nmap" (faster than kali-linux-headless)
#   SERVER_TYPE        default cpx31
#   LOCATION           default fsn1
#   INSTALL_TIMEOUT    seconds per install, default 2400
#
# Usage: tests/hetzner/run-matrix.sh [distro ...]
#   distro: debian ubuntu rocky alma centos-stream fedora (default: all)
#   Negative cases (bad image, resume, lock) run on the first distro.
#
# "check && pass || fail" is safe here because pass always returns 0.
# shellcheck disable=SC2015
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
: "${HCLOUD_TOKEN:?set HCLOUD_TOKEN}"
export HCLOUD_TOKEN
GIT_REF="${GIT_REF:-$(git -C "$REPO" rev-parse HEAD)}"
GIT_URL="${GIT_URL:-https://gitlab.com/appyfic/example-custom-agent.git}"
OPENCLAW_VERSION="${OPENCLAW_VERSION:-latest}"
KALI_IMAGE="${KALI_IMAGE:-kalilinux/kali-rolling:latest}"
KALI_PACKAGES="${KALI_PACKAGES-nmap}"
SERVER_TYPE="${SERVER_TYPE:-cpx31}"
LOCATION="${LOCATION:-fsn1}"
INSTALL_TIMEOUT="${INSTALL_TIMEOUT:-2400}"

RUN="oci-test-$(date +%Y%m%d%H%M%S)"
WORK="$(mktemp -d)"
FAILURES=0

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { log "FAIL: $*"; FAILURES=$((FAILURES + 1)); }
pass() { log "PASS: $*"; }

cleanup() {
  log "deleting every resource labelled run=$RUN"
  local id
  for id in $(hcloud server list -l "run=$RUN" -o noheader -o columns=id 2>/dev/null); do
    hcloud server delete "$id" >/dev/null || log "WARN: could not delete server $id"
  done
  hcloud ssh-key delete "$RUN" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

ssh_to() { # ssh_to IP CMD...
  ssh -i "$WORK/id" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -o ConnectTimeout=10 "root@$1" "${@:2}"
}

# latest_image PREFIX: newest Hetzner system image whose name starts with PREFIX.
latest_image() {
  hcloud image list --type system -o noheader -o columns=name | grep "^$1-" | sort -V | tail -1
}

image_for() {
  case "$1" in
    debian) latest_image debian ;;
    ubuntu) latest_image ubuntu ;;
    rocky) latest_image rocky ;;
    alma) latest_image alma ;;
    centos-stream) latest_image centos-stream ;;
    fedora) latest_image fedora ;;
    *) echo "unknown distro $1" >&2; return 1 ;;
  esac
}

create_server() { # create_server NAME IMAGE -> prints IPv4
  hcloud server create --name "$1" --type "$SERVER_TYPE" --image "$2" --location "$LOCATION" \
    --ssh-key "$RUN" --label "run=$RUN" -o json |
    jq -r '.server.public_net.ipv4.ip'
}

wait_ssh() { # wait_ssh IP: until SSH answers and the image's own first boot is done
  for _ in $(seq 1 60); do
    ssh_to "$1" true 2>/dev/null && break
    sleep 5
  done
  ssh_to "$1" 'command -v cloud-init >/dev/null && cloud-init status --wait >/dev/null; true'
}

# fetch IP: clones the repository at GIT_REF to /opt/openclaw-installer.
fetch() {
  ssh_to "$1" bash -s <<EOF
set -e
command -v git >/dev/null || { command -v apt-get >/dev/null && apt-get -qq update && apt-get -qq install -y git; } || dnf -q -y install git
rm -rf /opt/openclaw-installer
git clone -q "$GIT_URL" /opt/openclaw-installer
git -C /opt/openclaw-installer checkout -q "$GIT_REF"
EOF
}

# run_install IP KALI_IMAGE OUT: runs the installer, keeps its output in OUT and
# its exit code in OUT.rc.
run_install() {
  local rc=0
  ssh_to "$1" "timeout $INSTALL_TIMEOUT env OPENCLAW_VERSION=$(printf %q "$OPENCLAW_VERSION") KALI_IMAGE=$(printf %q "$2") KALI_PACKAGES=$(printf %q "$KALI_PACKAGES") bash /opt/openclaw-installer/install.sh" \
    > "$3" 2>&1 || rc=$?
  echo "$rc" > "$3.rc"
}

markers() { grep -E '^::(progress|error) ' "$1" || true; }

check_success() { # check_success OUT IP DISTRO
  local out="$1" ip="$2" name="$3" seq
  [[ "$(cat "$out.rc")" == 0 ]] && pass "$name install exited 0" || fail "$name install exited $(cat "$out.rc")"
  seq="$(markers "$out" | tr '\n' '|')"
  [[ "$seq" == "::progress 20 preflight|::progress 40 docker|::progress 60 openclaw|::progress 80 kali|::progress 100 verify|" ]] &&
    pass "$name progress in order, no ::error" || fail "$name markers: $seq"
  ssh_to "$ip" systemctl is-active --quiet openclaw-gateway.service &&
    pass "$name gateway active" || fail "$name gateway not active"
  ssh_to "$ip" "openclaw config get agents.defaults.sandbox.mode" |
    grep -q non-main && pass "$name sandbox configured" || fail "$name sandbox config missing"
  ssh_to "$ip" "runuser -u nobody -- timeout 5 bash -c '</dev/tcp/169.254.169.254/80'" 2>/dev/null &&
    fail "$name metadata reachable by non-root users" || pass "$name metadata blocked for non-root users"
}

run_distro() { # run_distro DISTRO: create, fetch and install; output in $WORK/DISTRO.out
  local distro="$1" image ip
  image="$(image_for "$distro")"
  log "creating $RUN-$distro on $image"
  ip="$(create_server "$RUN-$distro" "$image")"
  printf '%s %s\n' "$distro" "$ip" >> "$WORK/servers"
  wait_ssh "$ip" && fetch "$ip" && run_install "$ip" "$KALI_IMAGE" "$WORK/$distro.out"
}

negative_cases() { # on one distro: bad image, resume after fixing it, lock
  local distro="$1" image ip out="$WORK/bad.out"
  image="$(image_for "$distro")"
  log "negative cases on $image"
  ip="$(create_server "$RUN-$distro-bad" "$image")"
  wait_ssh "$ip" && fetch "$ip"
  run_install "$ip" "kalilinux/does-not-exist:none" "$out"
  if [[ "$(cat "$out.rc")" != 0 ]] && [[ "$(markers "$out" | grep -c '^::error ')" == 1 ]] &&
    markers "$out" | grep -q "^::error phase 'kali'"; then
    pass "bad KALI_IMAGE fails in phase kali with one ::error"
  else
    fail "bad KALI_IMAGE: rc=$(cat "$out.rc") markers=$(markers "$out" | tr '\n' '|')"
  fi

  # Two runs at once with the image fixed: the second must be refused by the lock.
  run_install "$ip" "$KALI_IMAGE" "$WORK/resume.out" &
  local first=$!
  sleep 5
  run_install "$ip" "$KALI_IMAGE" "$WORK/second.out"
  if grep -q "already running" "$WORK/second.out" && [[ -z "$(markers "$WORK/second.out")" ]]; then
    pass "a concurrent run is refused without ::error"
  else
    fail "a concurrent run was not refused cleanly"
  fi
  wait "$first" || true
  # Skipped phases still print their progress, so check the log for what ran.
  local skipped
  skipped="$(ssh_to "$ip" "grep -o 'phase [a-z]*: already done' /var/log/openclaw-install.log | sort -u | cut -d' ' -f2 | tr -d : | tr '\\n' ' '")"
  [[ "$skipped" == "docker openclaw preflight " ]] && pass "re-run skips the finished phases" || fail "re-run skipped: '$skipped'"
  [[ "$(cat "$WORK/resume.out.rc")" == 0 ]] && pass "re-run succeeds" || fail "re-run exited $(cat "$WORK/resume.out.rc")"
  # Runs in the background, so report through the exit code.
  ((FAILURES == 0))
}

main() {
  local distros=("$@")
  ((${#distros[@]})) || distros=(debian ubuntu rocky alma centos-stream fedora)
  ssh-keygen -q -t ed25519 -N '' -f "$WORK/id"
  hcloud ssh-key create --name "$RUN" --public-key-from-file "$WORK/id.pub" --label "run=$RUN" >/dev/null
  : > "$WORK/servers"
  local d pids=()
  for d in "${distros[@]}"; do run_distro "$d" & pids+=($!); sleep 2; done
  negative_cases "${distros[0]}" &
  local negative=$!
  wait "${pids[@]}" || true

  local distro ip
  while read -r distro ip; do
    if [[ -f "$WORK/$distro.out.rc" ]]; then
      check_success "$WORK/$distro.out" "$ip" "$distro"
    else
      fail "$distro never ran the installer (SSH or clone failed)"
    fi
  done < "$WORK/servers"
  wait "$negative" || FAILURES=$((FAILURES + 1))

  log "done: $FAILURES failure(s)"
  ((FAILURES == 0))
}

main "$@"
