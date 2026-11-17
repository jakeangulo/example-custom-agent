#!/usr/bin/env bats
# The marscape.yaml manifest describes this repository to any provisioner.
# These tests keep it in step with install.sh and with example-marscape.yaml.

load helpers

setup() {
  common_setup
}

# yq FILE FILTER: jq FILTER applied to the YAML FILE.
yq() {
  ruby -ryaml -rjson -e 'puts JSON.dump(YAML.safe_load(File.read(ARGV[0])))' "$1" | jq -c "$2"
}

# key_paths FILE: every key path in FILE, list items merged, one per line.
key_paths() {
  yq "$1" '[paths(scalars) | map(if type == "number" then "[]" else . end) | join(".")] | unique | .[]' | tr -d '"'
}

M="$BATS_TEST_DIRNAME/../../marscape.yaml"
X="$BATS_TEST_DIRNAME/../../example-marscape.yaml"

@test "marscape.yaml has every required key with the values for this repo" {
  [ "$(yq "$M" .schema_version)" = 1 ]
  [ "$(yq "$M" '.name | length > 0')" = true ]
  [ "$(yq "$M" '.description | length > 0')" = true ]
  [ "$(yq "$M" .install.script)" = '"install.sh"' ]
  [ -f "$REPO_ROOT/$(yq "$M" .install.script | jq -r .)" ]
  [ "$(yq "$M" .install.expected_duration_minutes)" = 20 ]
  [ "$(yq "$M" .install.reboot_exit_code)" = 194 ]
  [ "$(yq "$M" .install.max_retries)" = 3 ]
  [ "$(yq "$M" .machine.minimum)" = '{"vcpus":2,"memory_gb":4,"disk_gb":40}' ]
  [ "$(yq "$M" .machine.default)" = '{"vcpus":3,"memory_gb":4,"disk_gb":80}' ]
  [ "$(yq "$M" '[.ports[] | {port, protocol}]')" = '[{"port":18789,"protocol":"tcp"}]' ]
}

@test "marscape.yaml lists exactly the parameters install.sh accepts" {
  local from_help
  from_help="$(bash "$REPO_ROOT/install.sh" --help | grep -oE '^  --[a-z-]+' | grep -vE -- '--(dry-run|help)$' |
    sed 's/^  --//' | tr 'a-z-' 'A-Z_' | sort | jq -R . | jq -sc .)"
  [ "$(yq "$M" '[.params[].name] | sort')" = "$from_help" ]
  [ "$from_help" = '["KALI_IMAGE","KALI_PACKAGES","OPENCLAW_VERSION","PUBLIC_HOST"]' ]
  [ "$(yq "$M" '[.params[] | select(.required) | .name] | sort')" = '["KALI_IMAGE","OPENCLAW_VERSION"]' ]
  [ "$(yq "$M" '.params[] | select(.name == "KALI_PACKAGES") | .default')" = '"kali-linux-headless"' ]
}

@test "marscape.yaml parameter patterns accept the values the unit tests use" {
  local name value pattern
  for name in OPENCLAW_VERSION KALI_IMAGE; do
    value="${!name}"
    pattern="$(yq "$M" ".params[] | select(.name == \"$name\") | .pattern" | jq -r .)"
    [[ "$value" =~ $pattern ]] || { echo "$name=$value does not match $pattern"; return 1; }
  done
}

@test "marscape.yaml os entries match the distros install.sh supports" {
  source "$REPO_ROOT/lib/common.sh"
  local entry distro
  for entry in $(yq "$M" '.os[]' | tr -d '"'); do
    distro="${entry%-*}"
    [[ "$distro" == centos-stream ]] && distro=centos
    [[ " $SUPPORTED_OS_IDS " == *" $distro "* ]] || { echo "unsupported: $entry"; return 1; }
  done
  [ "$(yq "$M" '.os | length')" -ge 6 ]
}

@test "no parameter is secret" {
  [ "$(yq "$M" '[.params[] | select(.secret == true)] | length')" = 0 ]
}

@test "example-marscape.yaml parses and documents every key marscape.yaml uses" {
  [ -f "$X" ]
  [ -f "$M" ]
  local missing
  missing="$(comm -23 <(key_paths "$M" | sort) <(key_paths "$X" | sort))"
  [ -z "$missing" ] || { echo "missing from the example: $missing"; return 1; }
}

@test "example-marscape.yaml shows a secret parameter and a pattern" {
  [ "$(yq "$X" '[.params[] | select(.secret == true)] | length > 0')" = true ]
  [ "$(yq "$X" '[.params[] | select(.pattern)] | length > 0')" = true ]
}

@test "the manifests name no provider" {
  [ -f "$X" ]
  [ -f "$M" ]
  ! grep -i -n -E 'hetzner|aws|gcp|oci|cloud-init|cpx[0-9]' "$M" "$X" || false
}
