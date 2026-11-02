# shellcheck shell=bash
# Shared helpers: logging, parameters, OS detection and the resume state.
#
# OCI_ROOT prefixes every system path so the unit tests can run against a fake
# filesystem; it is empty in production.

OCI_ROOT="${OCI_ROOT:-}"
STATE_DIR="$OCI_ROOT/var/lib/openclaw-install"
STATE_FILE="$STATE_DIR/state"
SEQ_FILE="$STATE_DIR/sequence"

NON_SECRET_PARAMS=(OPENCLAW_VERSION KALI_IMAGE CALLBACK_URL JOB_ID LLM_AUTH_CHOICE INSTALL_USER KALI_PACKAGES DRY_RUN)
SUPPORTED_OS_IDS="debian ubuntu rocky almalinux centos fedora"

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

DIE_MESSAGE=""

die() {
  DIE_MESSAGE="$*"
  printf '[%s] ERROR: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: install.sh [options]

Every option can also be given as an environment variable of the same name in
upper case (for example --kali-image or KALI_IMAGE); the option wins.

  --openclaw-version V   OpenClaw version, dist-tag or spec (required)
  --kali-image REF       Kali image, registry/repo:tag or @digest (required)
  --callback-url URL     HTTPS events endpoint (required)
  --job-id ID            Deployment ID echoed in every event (required)
  --llm-auth-choice C    apiKey | openai-api-key | gemini-api-key | mistral-api-key (required)
  --install-user U       User OpenClaw runs as (default: openclaw)
  --kali-packages "P"    Packages to add to the Kali image (default: kali-linux-headless; "" = none)
  --dry-run              Validate and detect only; change nothing

Secrets are read from the environment only and are refused as options:
  CALLBACK_TOKEN         Bearer token for the events endpoint (required)
  LLM_API_KEY            API key for the chosen model provider (required)
EOF
}

# parse_args "$@": options override the environment of the same name.
parse_args() {
  while (($#)); do
    local opt="$1" val="" has_val=false
    if [[ "$opt" == --*=* ]]; then
      val="${opt#*=}"; opt="${opt%%=*}"; has_val=true
    fi
    case "$opt" in
      --callback-token | --llm-api-key)
        local name
        name="$(printf '%s' "${opt#--}" | tr 'a-z-' 'A-Z_')"
        die "$name is a secret: set it in the environment, not as an option"
        ;;
      --help | -h) usage; exit 0 ;;
      --dry-run) DRY_RUN=true; shift; continue ;;
      --openclaw-version | --kali-image | --callback-url | --job-id | --llm-auth-choice | \
        --install-user | --kali-packages)
        if ! $has_val; then
        (($# >= 2)) || die "$opt needs a value"
          val="$2"; shift
        fi
        printf -v "$(printf '%s' "${opt#--}" | tr 'a-z-' 'A-Z_')" '%s' "$val"
        shift
        ;;
      *) die "unknown option: $opt (see --help)" ;;
    esac
  done
}

# validate_params: applies defaults, then reports every problem at once.
# Messages name the parameter but never echo a secret's value.
validate_params() {
  INSTALL_USER="${INSTALL_USER:-openclaw}"
  KALI_PACKAGES="${KALI_PACKAGES-kali-linux-headless}"
  DRY_RUN="${DRY_RUN:-false}"

  local errors=() p
  for p in OPENCLAW_VERSION KALI_IMAGE CALLBACK_URL CALLBACK_TOKEN JOB_ID LLM_AUTH_CHOICE LLM_API_KEY; do
    [[ -n "${!p:-}" ]] || errors+=("$p is required")
  done

  check() { # check NAME REGEX MESSAGE
    [[ -z "${!1:-}" || "${!1}" =~ $2 ]] || errors+=("$1 $3")
  }
  check OPENCLAW_VERSION '^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$' 'must be a version, dist-tag or spec'
  check KALI_IMAGE '^[a-z0-9]([a-z0-9._/-]*[a-z0-9])?(:[0-9]+)?(/[a-z0-9._-]+)*(:[A-Za-z0-9_][A-Za-z0-9._-]{0,127}|@sha256:[a-f0-9]{64})$' \
    'must be a full image reference with a tag or digest'
  check CALLBACK_URL '^https://[^[:space:]]+$' 'must be an https:// URL'
  check CALLBACK_TOKEN '^[A-Za-z0-9._~+/=-]{16,}$' 'must be 16-512 URL-safe characters'
  local token="${CALLBACK_TOKEN:-}"; ((${#token} <= 512)) || errors+=("CALLBACK_TOKEN must be 16-512 URL-safe characters")
  check JOB_ID '^[A-Za-z0-9._:-]{1,128}$' 'must be 1-128 letters, digits or ._:-'
  check INSTALL_USER '^[a-z_][a-z0-9_-]{0,31}$' 'must be a lowercase user name'
  check KALI_PACKAGES '^[a-z0-9.+ -]*$' 'must be space-separated Debian package names'
  check DRY_RUN '^(true|false)$' 'must be true or false'
  [[ "$INSTALL_USER" != root ]] || errors+=("INSTALL_USER must not be root")
  if [[ -n "${LLM_AUTH_CHOICE:-}" ]] && ! llm_key_env_name "$LLM_AUTH_CHOICE" >/dev/null; then
    errors+=("LLM_AUTH_CHOICE must be one of: apiKey openai-api-key gemini-api-key mistral-api-key")
  fi
  [[ "${LLM_API_KEY:-}" != *$'\n'* ]] || errors+=("LLM_API_KEY must be a single line")
  unset -f check

  if ((${#errors[@]})); then
    DIE_MESSAGE="invalid parameters: $(printf '%s; ' "${errors[@]}")"
    printf 'Invalid parameters:\n' >&2
    printf '  - %s\n' "${errors[@]}" >&2
    exit 1
  fi
}

# callback_params_valid: true when the events endpoint can be reached, so even
# a failure in the remaining validation can be reported.
callback_params_valid() {
  [[ "${CALLBACK_URL:-}" =~ ^https://[^[:space:]]+$ ]] &&
    [[ "${CALLBACK_TOKEN:-}" =~ ^[A-Za-z0-9._~+/=-]{16,}$ ]] && ((${#CALLBACK_TOKEN} <= 512)) &&
    [[ "${JOB_ID:-}" =~ ^[A-Za-z0-9._:-]{1,128}$ ]]
}

# llm_key_env_name CHOICE: the environment variable OpenClaw reads the key from.
llm_key_env_name() {
  case "$1" in
    apiKey) echo ANTHROPIC_API_KEY ;;
    openai-api-key) echo OPENAI_API_KEY ;;
    gemini-api-key) echo GEMINI_API_KEY ;;
    mistral-api-key) echo MISTRAL_API_KEY ;;
    *) return 1 ;;
  esac
}

# detect_os: sets OS_ID, OS_CODENAME and OS_FAMILY (apt | dnf) from os-release.
# Only the exact supported IDs are accepted, because the Docker repository
# depends on the distro itself, not on what it is like.
detect_os() {
  local file="$OCI_ROOT/etc/os-release"
  [[ -r "$file" ]] || die "cannot read $file"
  # shellcheck source=/dev/null
  OS_ID="$(. "$file" && printf '%s' "${ID:-}")"
  # shellcheck source=/dev/null
  OS_CODENAME="$(. "$file" && printf '%s' "${VERSION_CODENAME:-}")"
  case " $SUPPORTED_OS_IDS " in
    *" $OS_ID "*) ;;
    *) die "unsupported distro '$OS_ID' (supported: $SUPPORTED_OS_IDS)" ;;
  esac
  case "$OS_ID" in
    debian | ubuntu) OS_FAMILY=apt ;;
    *) OS_FAMILY=dnf ;;
  esac
}

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi
}

# params_hash: identifies the non-secret inputs, so a re-run with different
# inputs redoes every phase while a rotated secret does not.
params_hash() {
  local p
  for p in "${NON_SECRET_PARAMS[@]}"; do printf '%s=%s\n' "$p" "${!p:-}"; done | sha256
}

state_init() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  local hash
  hash="$(params_hash)"
  if [[ ! -f "$STATE_FILE" ]] || [[ "$(head -n1 "$STATE_FILE")" != "params=$hash" ]]; then
    printf 'params=%s\n' "$hash" > "$STATE_FILE"
  fi
}

state_is_done() {
  grep -qx "done=$1" "$STATE_FILE"
}

state_mark_done() {
  state_is_done "$1" || printf 'done=%s\n' "$1" >> "$STATE_FILE"
}

next_sequence() {
  local n=0
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  [[ -f "$SEQ_FILE" ]] && n="$(cat "$SEQ_FILE")"
  n=$((n + 1))
  printf '%s\n' "$n" > "$SEQ_FILE"
  printf '%s\n' "$n"
}

# --- system helpers used by the phases ---------------------------------------

have() {
  command -v "$1" >/dev/null 2>&1
}

APT_UPDATED=false

apt_get() {
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 -y -q "$@"
}

# pkg_update: refreshes the apt index (forced after adding a repository).
pkg_update() {
  [[ "$OS_FAMILY" == apt ]] || return 0
  apt_get update
  APT_UPDATED=true
}

# pkg_install PACKAGE...: installs with the distro's package manager.
pkg_install() {
  if [[ "$OS_FAMILY" == apt ]]; then
    $APT_UPDATED || pkg_update
    apt_get install --no-install-recommends "$@"
  else
    dnf -y install "$@"
  fi
}

# download URL FILE: HTTPS-only fetch that fails on HTTP errors.
download() {
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 "$1" -o "$2"
}
