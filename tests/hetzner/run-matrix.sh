#!/usr/bin/env bash
# Runs the installer on real Hetzner Cloud servers, one per supported distro,
# and checks the result from the outside. Costs a few euro cents per run: every
# server is deleted at the end, even on failure or Ctrl-C.
#
# Requirements: hcloud CLI, jq, ssh, ssh-keygen, openssl, curl.
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
TOKEN="$(openssl rand -hex 24)"
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

create_server() { # create_server NAME IMAGE USER_DATA_FILE -> prints IPv4
  hcloud server create --name "$1" --type "$SERVER_TYPE" --image "$2" --location "$LOCATION" \
    --ssh-key "$RUN" --label "run=$RUN" --user-data-from-file "$3" -o json |
    jq -r '.server.public_net.ipv4.ip'
}

start_receiver() {
  local recv="$WORK/receiver.yaml" script
  script="$(sed 's/^/      /' "$HERE/receiver.py")"
  cat > "$recv" <<EOF
#cloud-config
packages: [caddy, python3]
write_files:
  - path: /opt/receiver.py
    permissions: "0755"
    content: |
$script
runcmd:
  - [bash, -c, 'nohup python3 /opt/receiver.py 8080 $TOKEN >/var/log/receiver.log 2>&1 &']
  - [bash, -c, 'ip=\$(curl -s http://169.254.169.254/hetzner/v1/metadata/public-ipv4); printf "%s.sslip.io {\n  reverse_proxy 127.0.0.1:8080\n}\n" "\$ip" > /etc/caddy/Caddyfile; systemctl restart caddy']
EOF
  log "creating the receiver"
  RECEIVER_IP="$(create_server "$RUN-recv" "$(latest_image ubuntu)" "$recv")"
  RECEIVER="https://$RECEIVER_IP.sslip.io"
  for _ in $(seq 1 60); do
    curl -fsS --max-time 5 "$RECEIVER/health" >/dev/null 2>&1 && { log "receiver ready at $RECEIVER"; return 0; }
    sleep 10
  done
  log "receiver never became ready"; exit 1
}

events() { # events JOB -> JSON list
  curl -fsS --max-time 10 -H "Authorization: Bearer $TOKEN" "$RECEIVER/events/$1"
}

user_data() { # user_data JOB KALI_IMAGE -> file
  # The env block is regenerated with printf %q, so any character in a value
  # (including the API key) survives being sourced; awk's ENVIRON avoids the
  # escaping rules of sed and awk -v.
  local f="$WORK/$1.yaml" block
  block="$(
    printf '      %s=%q\n' INSTALL_REPO_URL "$GIT_URL" INSTALL_REPO_REF "$GIT_REF" INSTALL_SCRIPT install.sh \
      OPENCLAW_VERSION "$OPENCLAW_VERSION" KALI_IMAGE "$2" KALI_PACKAGES "$KALI_PACKAGES" \
      CALLBACK_URL "$RECEIVER/events/$1" CALLBACK_TOKEN "$TOKEN" JOB_ID "$1"
  )"
  BLOCK="$block" awk '/^      [A-Z_]+=/ { if (!done) { print ENVIRON["BLOCK"]; done = 1 } next } { print }' \
    "$REPO/cloud-init/user-data.example.yaml" > "$f"
  echo "$f"
}

# wait_scrubbed IP: the stub deletes its env file after install.sh exits, which
# is after the final event; wait for that before looking for leaked secrets.
wait_scrubbed() {
  for _ in $(seq 1 30); do
    ssh_to "$1" test ! -e /root/openclaw-install.env && return 0
    sleep 5
  done
  return 1
}

wait_final() { # wait_final JOB -> prints the final event name, or "timeout"
  local deadline=$((SECONDS + INSTALL_TIMEOUT)) final
  while ((SECONDS < deadline)); do
    final="$(events "$1" 2>/dev/null | jq -r '[.[] | select(.event == "succeeded" or .event == "failed")][0].event // empty')"
    [[ -n "$final" ]] && { echo "$final"; return 0; }
    sleep 30
  done
  echo timeout
}

check_success() { # check_success JOB IP DISTRO
  local job="$1" ip="$2" name="$3" seq
  seq="$(events "$job" | jq -r '[.[] | "\(.event):\(.percent)"] | join(" ")')"
  [[ "$seq" == "started:0 in_progress:20 in_progress:40 in_progress:60 in_progress:80 succeeded:100" ]] &&
    pass "$name events in order" || fail "$name events: $seq"
  ssh_to "$ip" systemctl is-active --quiet openclaw-gateway.service &&
    pass "$name gateway active" || fail "$name gateway not active"
  ssh_to "$ip" "runuser -u openclaw -- env HOME=/home/openclaw openclaw config get agents.defaults.sandbox.mode" |
    grep -q non-main && pass "$name sandbox configured" || fail "$name sandbox config missing"
  ssh_to "$ip" "runuser -u openclaw -- timeout 5 bash -c '</dev/tcp/169.254.169.254/80'" 2>/dev/null &&
    fail "$name metadata reachable by openclaw" || pass "$name metadata blocked for openclaw"
  # The callback token must not survive the install anywhere on the server.
  wait_scrubbed "$ip" || fail "$name bootstrap env file was not removed"
  local leaks
  leaks="$(ssh_to "$ip" "grep -rlsF -e '$TOKEN' /etc /var/log /var/lib /home /root /opt /tmp 2>/dev/null" || true)"
  [[ -z "$leaks" ]] && pass "$name callback token removed" || fail "$name callback token found in: $leaks"
}

run_distro() { # run_distro DISTRO -> sets IP_<distro>
  local distro="$1" image job ip
  image="$(image_for "$distro")"
  job="$RUN-$distro"
  log "creating $job on $image"
  ip="$(create_server "$job" "$image" "$(user_data "$job" "$KALI_IMAGE")")"
  printf '%s %s %s\n' "$distro" "$job" "$ip" >> "$WORK/servers"
}

negative_cases() { # on one distro: bad image, resume after fixing it, lock
  local distro="$1" image job ip final
  image="$(image_for "$distro")"
  job="$RUN-$distro-bad"
  log "negative cases on $image"
  ip="$(create_server "$job" "$image" "$(user_data "$job" "kalilinux/does-not-exist:none")")"
  final="$(wait_final "$job")"
  if [[ "$final" == failed ]] && [[ "$(events "$job" | jq -r '.[-1].phase')" == kali ]] &&
    [[ -n "$(events "$job" | jq -r '.[-1].log_tail')" ]]; then
    pass "bad KALI_IMAGE fails in phase kali with a log tail"
  else
    fail "bad KALI_IMAGE: final=$final last=$(events "$job" | jq -c '.[-1]')"
  fi

  # Re-run by hand with the image fixed; secrets go over ssh stdin, not argv.
  local env="OPENCLAW_VERSION=$OPENCLAW_VERSION KALI_IMAGE=$KALI_IMAGE KALI_PACKAGES='$KALI_PACKAGES' CALLBACK_URL=$RECEIVER/events/$job-resume JOB_ID=$job-resume"
  printf 'export CALLBACK_TOKEN=%q\nexport %s\nbash /opt/openclaw-installer/install.sh\n' \
    "$TOKEN" "$env" > "$WORK/resume.sh"
  # Two runs at once: the second must be refused by the lock.
  ssh_to "$ip" bash -s < "$WORK/resume.sh" > "$WORK/resume.log" 2>&1 &
  local first=$!
  sleep 5
  if ssh_to "$ip" bash -s < "$WORK/resume.sh" 2>&1 | grep -q "already running"; then
    pass "a concurrent run is refused"
  else
    fail "a concurrent run was not refused"
  fi
  wait "$first" || true
  # Skipped phases still report their percentage, so check the log for what ran.
  local skipped
  skipped="$(ssh_to "$ip" "grep -o 'phase [a-z]*: already done' /var/log/openclaw-install.log | sort -u | cut -d' ' -f2 | tr -d : | tr '\\n' ' '")"
  [[ "$skipped" == "docker openclaw preflight " ]] && pass "re-run skips the finished phases" || fail "re-run skipped: '$skipped'"
  [[ "$(events "$job-resume" | jq -r '.[-1].event')" == succeeded ]] && pass "re-run succeeds" || fail "re-run did not succeed"
  # Runs in the background, so report through the exit code.
  ((FAILURES == 0))
}

main() {
  local distros=("$@")
  ((${#distros[@]})) || distros=(debian ubuntu rocky alma centos-stream fedora)
  ssh-keygen -q -t ed25519 -N '' -f "$WORK/id"
  hcloud ssh-key create --name "$RUN" --public-key-from-file "$WORK/id.pub" --label "run=$RUN" >/dev/null
  start_receiver
  : > "$WORK/servers"
  local d
  for d in "${distros[@]}"; do run_distro "$d"; done
  negative_cases "${distros[0]}" &
  local negative=$!

  local distro job ip final
  while read -r distro job ip; do
    final="$(wait_final "$job")"
    if [[ "$final" == succeeded ]]; then
      pass "$distro install succeeded"
      check_success "$job" "$ip" "$distro"
    else
      fail "$distro install ended with '$final'"
      events "$job" | jq -c '.[-1]' || true
    fi
  done < "$WORK/servers"
  wait "$negative" || FAILURES=$((FAILURES + 1))

  log "done: $FAILURES failure(s)"
  ((FAILURES == 0))
}

main "$@"
