#!/usr/bin/env bats

load helpers

EXAMPLE="$BATS_TEST_DIRNAME/../../cloud-init/user-data.example.yaml"

@test "the cloud-init example is valid cloud-config YAML" {
  command -v ruby >/dev/null || skip "ruby not installed"
  head -1 "$EXAMPLE" | grep -qx '#cloud-config'
  ruby -ryaml -e 'd = YAML.safe_load(File.read(ARGV[0])); exit(d["runcmd"].is_a?(Array) && d["write_files"].is_a?(Array) ? 0 : 1)' "$EXAMPLE"
}

@test "the example's bootstrap script is valid bash" {
  command -v ruby >/dev/null || skip "ruby not installed"
  ruby -ryaml -e 'puts YAML.safe_load(File.read(ARGV[0]))["runcmd"].last.last' "$EXAMPLE" > "$BATS_TEST_TMPDIR/boot.sh"
  bash -n "$BATS_TEST_TMPDIR/boot.sh"
}

@test "the example passes every required parameter and keeps its env file private" {
  local p
  for p in INSTALL_REPO_URL INSTALL_REPO_REF OPENCLAW_VERSION KALI_IMAGE CALLBACK_URL CALLBACK_TOKEN JOB_ID; do
    grep -q "^      $p=" "$EXAMPLE" || { echo "missing $p"; return 1; }
  done
  grep -q 'permissions: "0600"' "$EXAMPLE"
}

@test "the example removes its secrets after the run" {
  grep -q 'shred -u /root/openclaw-install.env' "$EXAMPLE"
  grep -q '/var/lib/cloud/instances/\*/user-data.txt' "$EXAMPLE"
}

@test "the example also removes cloud-init's pickled and merged copies of user data" {
  grep -q '/var/lib/cloud/instances/\*/obj.pkl' "$EXAMPLE"
  grep -q '/var/lib/cloud/instances/\*/cloud-config.txt' "$EXAMPLE"
}

@test "the example's values survive being sourced: spaces and shell characters" {
  command -v ruby >/dev/null || skip "ruby not installed"
  ruby -ryaml -e 'puts YAML.safe_load(File.read(ARGV[0]))["write_files"][0]["content"]' "$EXAMPLE" > "$BATS_TEST_TMPDIR/env"
  # Values a real deployment may use, written the way the example writes them.
  sed -i.bak -e "s|^KALI_PACKAGES=.*|KALI_PACKAGES='kali-linux-headless nmap'|" \
    -e "s|^CALLBACK_TOKEN=.*|CALLBACK_TOKEN='tok-\$HOME;\`id\`'|" "$BATS_TEST_TMPDIR/env"
  run bash -c 'set -euo pipefail; set -a; . "$1"; set +a; printf "%s|%s" "$KALI_PACKAGES" "$CALLBACK_TOKEN"' _ "$BATS_TEST_TMPDIR/env"
  [ "$status" -eq 0 ]
  [ "$output" = 'kali-linux-headless nmap|tok-$HOME;`id`' ]
}

@test "every value in the example is single-quoted" {
  ! grep -E "^      [A-Z_]+=[^']" "$EXAMPLE" || false
}
