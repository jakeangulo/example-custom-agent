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
  for p in INSTALL_REPO_URL INSTALL_REPO_REF OPENCLAW_VERSION KALI_IMAGE CALLBACK_URL CALLBACK_TOKEN JOB_ID LLM_AUTH_CHOICE LLM_API_KEY; do
    grep -q "^      $p=" "$EXAMPLE" || { echo "missing $p"; return 1; }
  done
  grep -q 'permissions: "0600"' "$EXAMPLE"
}

@test "the example removes its secrets after the run" {
  grep -q 'shred -u /root/openclaw-install.env' "$EXAMPLE"
  grep -q '/var/lib/cloud/instances/\*/user-data.txt' "$EXAMPLE"
}
