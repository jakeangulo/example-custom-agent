# Provider-Agnostic Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make example-custom-agent a standalone installer: no callbacks, no cloud-init, progress as stdout markers, plus the `marscape.yaml` manifest and a fully commented `example-marscape.yaml`.

**Architecture:** `install.sh` keeps its phases, lock, resume state, traps and log. Everything that talks to the provisioner (`lib/report.sh`, the callback parameters, the event sequence) is deleted. Progress and the failure reason become plain stdout lines (`::progress`, `::error`), which a person at a prompt can read and the provisioner's PyInfra runner relays. The exit code is the result. The manifest describes the repo to any provisioner in provider-neutral terms.

**Tech Stack:** bash, bats (unit tests), shellcheck, ruby's YAML parser (already in the CI image) for manifest tests, hcloud CLI + ssh for the real-server matrix.

**Spec:** `/Users/jake/Documents/gitlab/handoff/Design Change Overview.md` (step 1 of 2; the provisioner is a separate plan).

## Global Constraints

- The script must run standalone (`sudo ./install.sh`, parameters as environment variables or flags) and under PyInfra, with identical behaviour. Nothing in the repo may mention or depend on cloud-init, Hetzner, AWS or the provisioner.
- No callbacks: the script makes no HTTP call to any status endpoint.
- Exit codes: `0` = success; any other code = failure, except the manifest's `reboot_exit_code` (`194`), which means "reboot and rerun me". This installer never needs a reboot, so it never exits `194`.
- Progress lines: `::progress <percent> <phase>` on stdout, on a line of their own, after each phase. Percent is an integer 0–100.
- Failure line: exactly one `::error <message>` on stdout when the run fails after the lock is taken, or fails validation/detection. Never printed on success or on a dry run. Secrets are never printed (this repo has none left after the change, but the rule stays in the contract).
- Reruns stay safe: completed phases are skipped, `verify` always runs (unchanged behaviour).
- The manifest must not name provider-specific things: OS as `<distro>-<version>` (for example `ubuntu-24.04`), machine size as `vcpus`, `memory_gb`, `disk_gb`. The provisioner maps these to Hetzner images and server types. (This refines the design's "default or minimum machine type" so repos stay provider-agnostic; see Review Focus.)
- `marscape.yaml` field values for this repo: `schema_version: 1`, `install.script: install.sh`, `install.expected_duration_minutes: 20`, `install.reboot_exit_code: 194`, `install.max_retries: 3`, `machine.minimum: {vcpus: 2, memory_gb: 4, disk_gb: 40}`, `machine.default: {vcpus: 3, memory_gb: 4, disk_gb: 80}`, `ports: [{port: 18789, protocol: tcp, description: OpenClaw Control UI}]`, `os` = the six supported distros.

## Review Focus

1. **A provisioner (or person) passing the old `CALLBACK_URL`/`CALLBACK_TOKEN`/`JOB_ID` env vars** — they must be silently ignored, not refused, so existing callers don't break. Test in Task 1.
2. **`::progress` lines mixed with phase output** — a phase printing text that starts with `::progress` would fake progress. Phases' output goes through the same stdout; accept this, but the markers must be the only lines the script itself emits with that prefix and must start at column 0. Test in Task 1 (exact marker list on a clean run).
3. **A failure after a partial run, rerun later** — the rerun must print fresh markers from the resumed phase on and exactly one `::error` per failed run. Test in Task 1.
4. **Manifest drift** — a parameter added to `install.sh --help` but not to `marscape.yaml` (or the reverse). Test in Task 3 compares both.
5. **`example-marscape.yaml` going stale against `marscape.yaml`** — every key used in `marscape.yaml` must exist in the example. Test in Task 3.

---

### Task 1: Remove callbacks; progress and errors as stdout markers

**Files:**
- Delete: `lib/report.sh`, `tests/unit/report.bats`
- Modify: `install.sh` (header comment, sourcing, `on_exit`, `run_phases`, `main`), `lib/common.sh` (`usage`, `parse_args`, `validate_params`; delete `callback_params_valid`, `next_sequence`, `SEQ_FILE`)
- Modify: `tests/unit/helpers.bash` (drop `curl_capture_shim`, `event`, `events`, the callback vars in `set_valid_env`; stop sourcing `report.sh` in `load_phases`), `tests/unit/install.bats`, `tests/unit/common.bats`

**Interfaces:**
- Produces: `progress PERCENT PHASE` (in `install.sh`) prints `::progress PERCENT PHASE`; `install.sh` options are exactly `--openclaw-version`, `--kali-image`, `--kali-packages`, `--dry-run`, `--help` (Task 3 checks this list against the manifest).

- [ ] **Step 1: Rewrite the tests**

In `helpers.bash` add `markers() { grep -E '^::(progress|error) ' <<< "$output"; }` and remove the curl/event helpers. In `install.bats` replace every `events`/`event` assertion with marker assertions, and keep every lock, resume, trap, log and signal test. Required tests (rename existing ones where they match):

```bash
@test "a clean run prints progress for every phase and exits 0" {
  run bash "$APP/install.sh"
  [ "$status" -eq 0 ]
  [ "$(markers | tr '\n' '|')" = "::progress 20 preflight|::progress 40 docker|::progress 60 openclaw|::progress 80 kali|::progress 100 verify|" ]
}
@test "a failing phase prints exactly one ::error and keeps its exit code" {
  FAIL_PHASE=docker FAIL_RC=7 run bash "$APP/install.sh"
  [ "$status" -eq 7 ]
  [ "$(markers | grep -c '^::error ')" = 1 ]
  [[ "$(markers | tail -1)" == "::error phase 'docker' failed with exit code 7"* ]]
}
@test "a die inside a phase puts its reason in the ::error line"     # contains "custom reason in docker"
@test "invalid parameters print one ::error naming them and exit 1"  # KALI_IMAGE=no-tag; no phase ran
@test "an unsupported distro prints one ::error"                     # contains "unsupported distro"
@test "a run refused by the lock prints no ::error"                  # status 1, no markers at all
@test "a dry run prints no markers"
@test "a rerun after a failure resumes and prints markers from the failed phase on"
#   FAIL_PHASE=openclaw run; then rerun clean: markers = preflight..verify skipped phases still print their ::progress (state says done), exactly 5 progress lines, no ::error
@test "the old callback variables are ignored"
#   export CALLBACK_URL=https://x.test CALLBACK_TOKEN=tok_0123456789abcdef JOB_ID=d-1; run: status 0, and the curl shim log is empty
@test "no command makes an HTTP call to a status endpoint"           # shim curl; clean run; curl never called by install.sh itself
```

In `common.bats`: delete the callback-specific cases (secret-as-flag refusal, token validation, job-ID/URL state tests, sequence numbers, "missing secrets under set -u"); keep "every missing required parameter is reported at once" with the list `OPENCLAW_VERSION KALI_IMAGE`; add `@test "--callback-url and --job-id are unknown options"` (exit 1, "unknown option").

- [ ] **Step 2: Run the tests to see them fail**

Run: `bats tests/unit/install.bats tests/unit/common.bats`
Expected: FAIL (markers missing; old options still accepted).

- [ ] **Step 3: Implement**

- `install.sh`: delete the `report.sh` source, `REPORTING`, `FINAL_POSTED` and the `export -n CALLBACK_TOKEN` line. Add `progress() { printf '::progress %s %s\n' "$1" "$2"; }` and call it after every phase in `run_phases` (verify included, replacing the `succeeded` post). In `on_exit`, on `rc != 0` and `ERROR_REPORTED == false`, build the same message as today and print `::error $message` once (set `ERROR_REPORTED=true`). Keep the stdout marker *before* the existing `log "ERROR: ..."`. A lock refusal must not print it: set `ERROR_REPORTED=true` before `acquire_lock` and back to `false` once it is held (same trick as today's `REPORTING`). Validation and `detect_os` failures do print it. Dry runs exit before anything prints it. The "starting" log line drops `for job $JOB_ID`.
- `lib/common.sh`: remove `--callback-url`, `--job-id`, `--callback-token` (and the secrets block) from `usage` and `parse_args`; required list becomes `OPENCLAW_VERSION KALI_IMAGE`; delete the CALLBACK/JOB_ID checks, `callback_params_valid`, `next_sequence` and `SEQ_FILE`. Update the header comment of `install.sh` to: "OpenClaw + Kali installer. Runs as root, standalone or from any provisioning tool. Prints ::progress and ::error lines; the exit code is the result. Safe to re-run: finished phases are skipped."

- [ ] **Step 4: Run all unit tests and shellcheck**

Run: `bats tests/unit && shellcheck -x install.sh files/openclaw-metadata-block`
Expected: all pass, no warnings (`cloud_init.bats` may fail until Task 2; run it with the rest only after Task 2).

- [ ] **Step 5: Commit**

```bash
git add -A install.sh lib tests/unit
git commit -m "Installer: drop callbacks; report progress and errors as stdout markers"
```

### Task 2: Remove cloud-init; rework the real-server matrix to run over SSH

**Files:**
- Delete: `cloud-init/user-data.example.yaml`, `tests/unit/cloud_init.bats`, `tests/hetzner/receiver.py`
- Modify: `tests/hetzner/run-matrix.sh`, `.gitlab-ci.yml` (only if a deleted path is listed)

**Interfaces:**
- Consumes: Task 1's markers and exit codes.

- [ ] **Step 1: Rework `run-matrix.sh`**

Keep: the environment variables (minus `INSTALL_TIMEOUT`'s callback use), the `run=$RUN` labels, the cleanup trap, `image_for`, the per-distro loop and the pass/fail counter. Replace user-data creation, the receiver and `wait_final` with: create the server with a throwaway SSH key (no user data), wait for SSH, `git clone $GIT_URL` and `git checkout $GIT_REF` on the server, then run `timeout $INSTALL_TIMEOUT sudo env OPENCLAW_VERSION=… KALI_IMAGE=… KALI_PACKAGES=… ./install.sh` over SSH, capturing stdout. Checks per distro: exit code 0; the five `::progress` lines in order; no `::error`; the existing outside checks of `check_success` that don't involve the callback token (drop the "callback token removed" check). Negative cases keep their meaning: bad image → non-zero exit and one `::error` naming `KALI_IMAGE`'s pull; rerun with the fixed image → exit 0 and earlier phases logged as skipped; a second concurrent run → refused by the lock, no `::error`.

- [ ] **Step 2: Verify**

Run: `shellcheck -x tests/hetzner/run-matrix.sh && bash -n tests/hetzner/run-matrix.sh && bats tests/unit`
Expected: no warnings; all unit tests pass. (The matrix itself costs money and needs `HCLOUD_TOKEN`; it is not run in this task.)

- [ ] **Step 3: Commit**

```bash
git add -A cloud-init tests .gitlab-ci.yml
git commit -m "Remove the cloud-init stub; the Hetzner matrix runs install.sh over SSH"
```

### Task 3: `marscape.yaml` and `example-marscape.yaml`

**Files:**
- Create: `marscape.yaml`, `example-marscape.yaml`, `tests/unit/manifest.bats`

**Interfaces:**
- Consumes: the option list from Task 1.
- Produces (the manifest contract the provisioner plan will validate, schema version 1):

| Key | Type | Required | Meaning |
| --- | --- | --- | --- |
| `schema_version` | int | yes | `1` |
| `name`, `description` | string | yes | Shown to users |
| `install.script` | path | yes | Relative to the repo root, run as root |
| `install.expected_duration_minutes` | int | yes | Deadline = 2 × this, capped by the platform |
| `install.reboot_exit_code` | int 1–255 | no (default 194) | Exit code meaning "reboot and rerun me" |
| `install.max_retries` | int ≥ 0 | no | May only lower the platform's retry count |
| `params[]` | list | no | `name` (UPPER_SNAKE), `description`, `required` (bool), `default` (string), `secret` (bool, default false), `pattern` (regex, optional) |
| `os[]` | list of `<distro>-<version>` | yes | Supported images |
| `machine.minimum`, `machine.default` | `{vcpus, memory_gb, disk_gb}` | minimum yes | Size floor; default used when the request names none |
| `ports[]` | list | no | `port` (1–65535), `protocol` (`tcp`/`udp`), `description` — the ports a request may open; SSH 22 is always allowed |

- [ ] **Step 1: Write `tests/unit/manifest.bats`**

Load YAML with `ruby -ryaml -rjson -e 'puts JSON.dump(YAML.safe_load(File.read(ARGV[0])))' FILE | jq …`. Tests:

```bash
@test "marscape.yaml has every required key with the values for this repo"
#   schema_version 1; install.script == install.sh and the file exists and is executable or bash-runnable;
#   expected_duration_minutes 20; reboot_exit_code 194; max_retries 3; machine.minimum == {vcpus:2,memory_gb:4,disk_gb:40};
#   ports == [{port:18789,protocol:"tcp",...}]
@test "marscape.yaml lists exactly the parameters install.sh accepts"
#   jq '[.params[].name] | sort' == the UPPER_SNAKE form of the --options in `install.sh --help`, minus --dry-run/--help:
#   ["KALI_IMAGE","KALI_PACKAGES","OPENCLAW_VERSION"]; required flags match (KALI_PACKAGES not required, default "kali-linux-headless")
@test "marscape.yaml os entries match the distros install.sh supports"
#   distro part of each os entry ∈ SUPPORTED_OS_IDS from lib/common.sh (centos-stream maps to centos, almalinux to almalinux)
@test "no parameter is secret"   # this repo has none since the callback token went
@test "example-marscape.yaml parses and documents every key marscape.yaml uses"
#   every key path in marscape.yaml (recursively, list items merged) exists in example-marscape.yaml
@test "example-marscape.yaml shows a secret parameter and a pattern"
@test "the manifests name no provider"  # grep -i -E 'hetzner|aws|gcp|oci|cloud-init|cpx[0-9]' finds nothing in either file
```

- [ ] **Step 2: Run to see them fail**

Run: `bats tests/unit/manifest.bats` — Expected: FAIL (files missing).

- [ ] **Step 3: Write the two files**

`marscape.yaml` with the values from Global Constraints, the three parameters (descriptions taken from `install.sh --help`, `OPENCLAW_VERSION` and `KALI_IMAGE` required, their validation regexes from `validate_params` as `pattern`), and `os: [debian-12, ubuntu-24.04, ubuntu-26.04, rocky-9, almalinux-9, centos-stream-9, fedora-42]` (check each against `tests/fixtures/os-release` and the supported IDs).
`example-marscape.yaml`: every key in the table above, a one-line comment per key, two example parameters (one `secret: true` with a comment that secrets arrive only as environment variables and must never be printed), and a header comment stating the script contract: run as root; parameters as environment variables; exit 0 = success; `reboot_exit_code` = reboot and rerun; must be safe to rerun; may print `::progress <percent> <phase>` and one `::error <message>` on stdout.

- [ ] **Step 4: Run all tests**

Run: `bats tests/unit` — Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add marscape.yaml example-marscape.yaml tests/unit/manifest.bats
git commit -m "Add marscape.yaml and a commented example-marscape.yaml"
```

### Task 4: Docs

**Files:**
- Modify: `README.md`, `docs/design.md` (sections on status reporting, cloud-init, parameters, secrets; add a dated changelog entry), `docs/plan.md` (a short "Superseded by" note at the top pointing to this plan)

- [ ] **Step 1: Update**

README: usage is `sudo ./install.sh` with the parameter table from `marscape.yaml`; the output contract (`::progress`, `::error`, exit codes); a pointer to `marscape.yaml` and `example-marscape.yaml` for repo authors; remove cloud-init and callback text. design.md: replace the status-reporting and cloud-init sections with the marker contract; note the metadata-service block stays as hardening (no secrets are delivered through user data any more); changelog entry `2026-11-17 (provider-agnostic installer)` summarising Tasks 1–3 and that callers pinned to `a8b0f70` keep working because they pin the commit.

- [ ] **Step 2: Verify**

Run: `grep -rn -i -E 'callback|cloud-init|JOB_ID|report\.sh' README.md docs/design.md install.sh lib marscape.yaml example-marscape.yaml` — Expected: matches only in the changelog and the "removed" notes.

- [ ] **Step 3: Commit**

```bash
git add README.md docs
git commit -m "Docs: standalone installer contract and manifest"
```
