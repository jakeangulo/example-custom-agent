# Plan: OpenClaw + Kali installer (`appyfic/example-custom-agent`)

## Context

The repo holds only a default README and the design doc `OpenClaw + Kali Installer — Design Document.docx`. We are building the
install script that cloud-init runs on first boot of a Hetzner Cloud server. It installs a pinned OpenClaw version natively,
plus Kali tooling in a Docker container wired in as OpenClaw's sandbox, and reports progress over HTTP.

It is the "install repository" of the provisioner described in `../marscape-hetzner-provisioner/docs/design.md`, so it must
follow that design's **install-script contract**:
- runs as root with its parameters as environment variables;
- is safe to re-run;
- exits 0 only when the install is healthy;
- never prints secrets;
- finishes within the 30-minute deadline.

### Decisions from this session

These override the design doc where they differ.

| Topic | Decision |
|---|---|
| Install repo | Public GitLab repo for now; repo URL and pinned ref are cloud-init params (Forgejo later = config change). User sets visibility manually. |
| Callback auth | **No shared x-api-key on the server, anywhere.** The installer receives only the provisioner's per-deployment `CALLBACK_TOKEN` (hash-stored, scoped to one deployment, expires at the deadline, rejected after a final event). It is sent as `Authorization: Bearer`. |
| State / lock / log | Lock `/run/openclaw-install.lock` (`flock`). State `/var/lib/openclaw-install/state`. Log `/var/log/openclaw-install.log`. |
| Traps | ERR records context only. EXIT posts a failure once when rc≠0. INT/TERM are routed to exit. Traps run with `set +e` and `|| true` on posts. |
| Gateway service | Our own **system-level** unit `openclaw-gateway.service`, `User=$INSTALL_USER`. Avoids OpenClaw's user-level unit (needs D-Bus and linger, and fails silently headless). |
| LLM credentials | `LLM_AUTH_CHOICE` + `LLM_API_KEY` params. The key lives in a root-owned 0600 env file, and config holds an env ref. Mitigations are below. |
| Kali tools | Build a local image `FROM $KALI_IMAGE` that installs `KALI_PACKAGES` (default `kali-linux-headless`). Empty `KALI_PACKAGES` means use the image as-is. |
| Testing | Real Hetzner servers, one per supported distro. OpenClaw is native and only Kali is in a container. |

## Parameters

Non-secret parameters accept an env var or a `--flag`; the flag wins. Secret parameters are **env only**, and passing them as a flag fails.

| Param | Req | Notes |
|---|---|---|
| `OPENCLAW_VERSION` | yes | Passed to `install.sh --version` |
| `KALI_IMAGE` | yes | Full ref `registry/repo:tag` |
| `CALLBACK_URL` | yes | HTTPS only |
| `CALLBACK_TOKEN` | yes, secret | Replaces the doc's `API_KEY` |
| `JOB_ID` | yes | |
| `LLM_AUTH_CHOICE` | yes | Validated against a mapping table, e.g. `apiKey` → `--anthropic-api-key` / `ANTHROPIC_API_KEY`, `gemini-api-key`, `openai-api-key`, … |
| `LLM_API_KEY` | yes, secret | |
| `INSTALL_USER` | no | Default `openclaw` |
| `KALI_PACKAGES` | no | Default `kali-linux-headless` |
| `DRY_RUN` | no | Default `false`; runs phase 0 and preflight detection only, with no changes and no posts |

Parameters only the cloud-init stub uses: `INSTALL_REPO_URL`, `INSTALL_REPO_REF` (pinned commit SHA), `INSTALL_SCRIPT` (default `install.sh`).

## Repo layout (new files)

```
install.sh                  entry: parse params, lock, traps, run phases with resume
lib/common.sh               log(), die(), param parsing/validation, state read/write, os detection
lib/report.sh               post_status(): JSON via jq, header passed to curl on stdin (keeps token out of ps), 5s timeout, 3 retries with backoff, never fails the caller
lib/phases/preflight.sh     20%
lib/phases/docker.sh        40%
lib/phases/openclaw.sh      60%
lib/phases/kali.sh          80%
lib/phases/verify.sh        100%
files/openclaw-gateway.service       system unit template
files/openclaw-metadata-block.service  re-applies iptables rules on boot
cloud-init/user-data.example.yaml    stub: env params → git clone INSTALL_REPO_URL @ INSTALL_REPO_REF → run INSTALL_SCRIPT
tests/unit/*.bats + tests/fixtures/os-release/*   local tests
tests/hetzner/run-matrix.sh + receiver.py         real-server matrix (see Verification)
docs/design.md              docx converted to Markdown, updated with this session's decisions; the .docx is removed from the repo
README.md                   replaces the GitLab template: what it does, params, cloud-init usage, abuse-report note for scans from Hetzner IPs
.gitlab-ci.yml              shellcheck + bats
```

## Phases

Each phase is idempotent. After a phase succeeds the script records it in the state file and posts its percent. The state file
also stores a hash of the non-secret params; if the params change, completed phases are re-run instead of skipped. Verify
always runs.

- **0 started:** validate all params. Take the `flock` (exit non-zero if another run holds it). Send all output to the log and
  stdout with `tee`. Post `started`.
- **20 preflight:**
  - Detect the family from `ID`/`ID_LIKE` in `/etc/os-release`: apt for debian/ubuntu, dnf for rocky/almalinux/centos/fedora.
    Anything else fails.
  - Wait (bounded) for apt/dnf locks held by cloud-init's own package step.
  - Install `curl ca-certificates git jq iptables gnupg`.
  - Create `INSTALL_USER` as a system user with a home directory.
- **40 docker:**
  - Add Docker's official repo (debian, ubuntu, centos for the RHEL clones, fedora).
  - Install `docker-ce docker-ce-cli containerd.io docker-buildx-plugin`, then `systemctl enable --now docker`.
  - Add `INSTALL_USER` to the `docker` group. The gateway must create sandbox containers; this is inherent to OpenClaw's design
    and gets documented.
  - Install and start `openclaw-metadata-block.service`, which applies two rules:
    - `DOCKER-USER -d 169.254.169.254 -j DROP`
    - `OUTPUT -d 169.254.169.254 -m owner ! --uid-owner 0 -j DROP`
- **60 openclaw:**
  - Download `https://openclaw.ai/install.sh` with `--proto '=https' --tlsv1.2` to a temp file (not a pipe), then run
    `bash <file> --version "$OPENCLAW_VERSION" --no-prompt --no-onboard` as root.
  - Write `/etc/openclaw/openclaw.env` (root 0600) with the provider's key env var.
  - As `INSTALL_USER`, with that env loaded, run
    `openclaw onboard --non-interactive --accept-risk --mode local --auth-choice "$LLM_AUTH_CHOICE" --secret-input-mode ref --gateway-bind loopback --skip-daemon --skip-skills`.
  - Install `openclaw-gateway.service` (`User=`, `EnvironmentFile=`, `SupplementaryGroups=docker`, `Restart=on-failure`) and
    enable it.
- **80 kali:**
  - `docker pull "$KALI_IMAGE"`.
  - If `KALI_PACKAGES` is set, build `openclaw-kali:<sha of image digest + packages>` from a Dockerfile on stdin:
    `FROM $KALI_IMAGE`, then `apt-get install -y $KALI_PACKAGES` and a cleanup. If that tag already exists, skip the build.
  - Write `agents.defaults.sandbox`:
    - `mode: non-main`, `backend: docker`, `scope: agent`, `workspaceAccess: none`
    - `docker.image: <built or given image>`, `docker.network: bridge`
    - no binds and no socket mount
    - container user root with `capDrop ALL` and NET_RAW/NET_ADMIN kept (so nmap raw scans work)
  - Restart the gateway.
- **100 verify:**
  - `openclaw --version` matches when the pin is a semver.
  - `systemctl is-active openclaw-gateway`, plus the gateway health check on loopback.
  - The sandbox image runs `nmap --version`.
  - From inside a bridge container, a request to `169.254.169.254` fails.
  - Clean up: delete the installer's own temp files and `unset` the secrets.
  - Post `success` with percent 100.

**Failure path:** the EXIT trap posts `failure` with the phase, exit code and `tail -n 50` of the log (secrets never reach the
log), then exits with the original code.

## Things to confirm on the first Hetzner server

The docs don't settle these; the code keeps each one in a single function so it's easy to change.
1. The gateway's foreground command for `ExecStart` (`openclaw gateway --help`).
2. How to write config: `openclaw config set` if it exists, otherwise a JSON5-aware edit of `~/.openclaw/openclaw.json`.
3. Whether ref mode reads the expected env var name for each auth choice.
4. Whether the sandbox config supports `capAdd` and a root user, or only `capDrop` (fall back to a narrower `capDrop` list).
5. Real phase timings against the 30-minute deadline, especially the `kali-linux-headless` build.

## Changes needed in `marscape-hetzner-provisioner` (recorded in its design docs on branch `docs/design-hcloud-sdk`; code still to do)

- The Callback route must accept `in_progress` events with `percent`, `phase` and `sequence`. The current contract has only
  started/succeeded/failed.
- The design's line "user_data holds no application secrets" must be updated for `LLM_API_KEY`.
- The wrapper should scrub cloud-init's cached user_data (`/var/lib/cloud/instance*/user-data.txt*`) after its final event. It
  already deletes the callback token.

## Verification

1. **Local:**
   - `shellcheck` on all scripts.
   - `bats tests/unit`, covering:
     - param validation, including secret-as-flag rejection;
     - os detection against fixture os-release files for all 6 distros;
     - payload shape and sequence numbering;
     - trap behaviour: forced failure in each phase gives exactly one failure post with the right phase and exit code, and
       success gives no failure post;
     - a dead callback endpoint doesn't abort the install;
     - the token and LLM key never appear in the log.
     - These tests use PATH shims for curl, apt, dnf, docker and openclaw.
   - `DRY_RUN=true` makes no changes.
2. **Hetzner matrix** (`tests/hetzner/run-matrix.sh`):
   - Uses the `hcloud` CLI with a token from Keychain. You add it yourself with `security add-generic-password`; I'll ask for
     the service name.
   - Creates one receiver server (`receiver.py` logs POSTs) and one server per distro: Debian, Ubuntu, Rocky, Alma,
     CentOS Stream, Fedora. Image names are picked from `hcloud image list --type system` at run time.
   - All servers are labelled, and a trap always tears them down.
   - Asserts for each distro:
     - the receiver got 0→20→40→60→80→100 + `success` in sequence order;
     - over SSH, the gateway service is active and the sandbox config is present;
     - `sudo -u openclaw curl 169.254.169.254` fails;
     - a bridge container can't reach the metadata service;
     - the token and LLM key appear only in `/etc/openclaw/openclaw.env`.
   - Negative runs:
     - a bad `KALI_IMAGE` gives a `failure` post with phase `kali` and a log tail;
     - re-running with the image fixed resumes at kali;
     - a concurrent second run is refused by the lock.
   - Cost: about 7 servers for under an hour.
