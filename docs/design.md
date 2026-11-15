# OpenClaw + Kali Installer: Design

Oct 28, 2026 · revised Nov 2, 2026 (converted from the original `.docx`; see [Changes from the original](#changes-from-the-original))

## Overview

`install.sh` is a non-interactive Bash installer for a pinned OpenClaw version plus Kali Linux tooling. cloud-init runs it on first boot of a freshly provisioned Hetzner Cloud server.

It is the install step of the Hetzner provisioning service ([marscape-hetzner-provisioner](https://gitlab.com/appyfic/marscape-hetzner-provisioner)): the provisioner creates the server and passes parameters through cloud-init user data, and this script performs the install and reports its own progress to the provisioner's events route, so nothing ever needs to SSH in to know what happened.

## Goals and non-goals

**Goals**

- Install a pinned OpenClaw version non-interactively on every Linux distro Hetzner Cloud offers as a standard image.
- Make Kali Linux tooling available to the OpenClaw agent through Docker, wired into OpenClaw's own sandbox configuration.
- Accept every variable input as a parameter: no hardcoded secrets or server-specific values.
- Fail loudly and safely, and support safe retries.
- Report progress in 20% steps plus a final success or failure, over HTTP.

**Non-goals**

- Day-2 configuration management or drift correction.
- Provisioning the server itself.
- The events endpoint's own storage and authentication; the script only calls it.
- Any interactive or GUI mode.

## Supported platforms

Exactly the Hetzner Cloud standard images, in two package-manager families. openSUSE is excluded: it is a Hetzner Robot (dedicated server) image, not a Cloud one.

| Distro | `ID` | Family | Docker repository |
| --- | --- | --- | --- |
| Debian | `debian` | apt | `download.docker.com/linux/debian` |
| Ubuntu | `ubuntu` | apt | `download.docker.com/linux/ubuntu` |
| Rocky Linux | `rocky` | dnf | `download.docker.com/linux/centos` |
| AlmaLinux | `almalinux` | dnf | `download.docker.com/linux/centos` |
| CentOS Stream | `centos` | dnf | `download.docker.com/linux/centos` |
| Fedora | `fedora` | dnf | `download.docker.com/linux/fedora` |

The script reads `ID` from `/etc/os-release` and accepts only these six values. It does not fall back to `ID_LIKE`, because the Docker repository depends on the exact distro. The families differ only in prerequisite packages and the Docker install. Everything after that is identical: OpenClaw's installer brings Node.js, and Kali runs in Docker rather than as native packages.

## Parameters

Every input is a parameter: an environment variable, or an option that takes precedence over it. Secrets are read from the environment only and refused as options, to keep them out of `ps` and shell history.

| Parameter | Required | Description |
| --- | --- | --- |
| `OPENCLAW_VERSION` | Yes | Version, dist-tag or spec, passed to OpenClaw's official installer |
| `KALI_IMAGE` | Yes | Full image reference with a tag or digest, e.g. `kalilinux/kali-rolling@sha256:1ff4a2be3849333687b3ed2b31bb5af0cd1b7c0a11ec7713feb5abe5a6b2795c`; Kali publishes only rolling tags (`latest`, per-arch), so pin a digest for repeatable installs |
| `KALI_PACKAGES` | No (default `kali-linux-headless`) | Packages built into a local image on top of `KALI_IMAGE`; empty means use `KALI_IMAGE` as-is |
| `CALLBACK_URL` | Yes | HTTPS events route; set by the provisioner |
| `CALLBACK_TOKEN` | Yes, secret | Per-deployment bearer token for the events route; set by the provisioner |
| `JOB_ID` | Yes | Deployment ID echoed in every event; set by the provisioner |
| `LLM_AUTH_CHOICE` | Yes | `apiKey` (Anthropic), `openai-api-key`, `gemini-api-key` or `mistral-api-key` |
| `LLM_API_KEY` | Yes, secret | The provider's API key |
| `INSTALL_USER` | No (default `openclaw`) | Dedicated non-root system user OpenClaw runs as |
| `DRY_RUN` | No (default `false`) | Validate parameters and detect the distro only; change nothing |

`KALI_IMAGE` is a full reference rather than a bare tag, so a caller can point at a private registry or another Kali variant without a script change.

Through the provisioner, the client sends the non-secret parameters in `install.params` and the secrets in `install.secrets`; the provisioner adds `CALLBACK_URL`, `CALLBACK_TOKEN` and `JOB_ID`.

## Status reporting

Each event is a `POST` to `CALLBACK_URL` with `Authorization: Bearer <CALLBACK_TOKEN>` and a JSON body, following the provisioner's events contract. The token is handed to `curl` as config on standard input, never as an argument. Posting is best effort: each attempt has a 5-second timeout, and a failed attempt is retried 3 times after 1, 2 and 4 seconds. A dead endpoint never stops the install.

| Field | Description |
| --- | --- |
| `event` | `started`, `in_progress`, `succeeded` or `failed` |
| `job_id` | From `JOB_ID` |
| `hostname` | The server's hostname |
| `percent` | 0, 20, 40, 60, 80 or 100 |
| `phase` | The current phase |
| `message` | Human-readable detail |
| `timestamp` | ISO 8601, UTC |
| `script_version` | The installer's commit |
| `sequence` | Monotonic across runs, so the receiver can order and de-duplicate |
| `exit_code`, `log_tail` | On `failed` only: the exit code and the end of the log (at most 50 lines and 12,000 bytes), with secret values replaced by `[REDACTED]` and control and non-ASCII characters removed |

## Phases

| % | Phase | Milestone |
| --- | --- | --- |
| 0 | `started` | Parameters validated, distro detected, lock taken |
| 20 | `preflight` | Missing tools installed (`curl`, `git`, `jq`, `iptables`, `gpg` on apt), install user created |
| 40 | `docker` | Docker Engine from Docker's repository, running; install user in the `docker` group; metadata service blocked |
| 60 | `openclaw` | OpenClaw installed by its official installer at the pinned version, onboarded for the install user, gateway running as a system service |
| 80 | `kali` | Kali image pulled, local image built with `KALI_PACKAGES`, sandbox config written and validated, gateway restarted |
| 100 | `verify` | Version matches, gateway healthy on `/healthz`, sandbox image starts, metadata unreachable from containers and the install user; `succeeded` posted |

After each phase the script records it in the state file and posts its percentage. If anything fails, the `EXIT` trap posts one `failed` event with the phase, exit code and log tail, then exits with the original code.

## OpenClaw setup

- **Install.** `https://openclaw.ai/install.sh` is downloaded over HTTPS (TLS 1.2+) to a file, not piped, and run as root with `--version "$OPENCLAW_VERSION" --no-prompt --no-onboard`. It installs Node.js from NodeSource and OpenClaw globally, so the binary is root-owned and the agent cannot modify it. An exact version already installed is not reinstalled; a dist-tag always re-runs the installer.
- **Provider key.** The key is written to `/etc/openclaw/openclaw.env` (root, `0600`) under the provider's variable name, for example `ANTHROPIC_API_KEY`.
- **Onboarding.** As the install user, with the key in the environment only: `openclaw onboard --non-interactive --accept-risk --mode local --auth-choice "$LLM_AUTH_CHOICE" --secret-input-mode ref --gateway-bind loopback --gateway-port 18789 --skip-daemon --skip-skills --skip-health`. With `--secret-input-mode ref`, OpenClaw's config stores a reference to the variable, not the key. Onboarding is skipped once the user has a config; a rotated key only needs the env file, which every run rewrites.
- **Gateway service.** The script writes its own system unit, `openclaw-gateway.service`: `User=` the install user, `SupplementaryGroups=docker`, `EnvironmentFile=/etc/openclaw/openclaw.env`, `ExecStart=openclaw gateway run --port 18789 --bind loopback`, restart on failure except exit code 78 (invalid config). OpenClaw's own daemon install creates a per-user unit, which needs D-Bus and lingering and fails silently on headless servers.

## Kali sandbox configuration

The script writes the sandbox into OpenClaw's config, `agents.defaults.sandbox`, with `openclaw config patch` and checks it with `openclaw config validate`, instead of installing the community `prts-sandbox` skill, so the behaviour is owned by this script.

| Setting | Value | Why |
| --- | --- | --- |
| `mode` | `non-main` | Sandboxing is off by default in OpenClaw; this turns it on for non-main sessions |
| `backend` | `docker` | |
| `scope` | `agent` | One container per agent. Per-agent overrides (`agents.list[].sandbox`) can give a restricted agent no sandbox tools |
| `workspaceAccess` | `none` | Tools see only the sandbox workspace under `~/.openclaw/sandboxes`, not the agent's files |
| `docker.image` | The local image built from `KALI_IMAGE` + `KALI_PACKAGES`, or `KALI_IMAGE` itself | OpenClaw does not pull missing images, so the script provides it |
| `docker.network` | `bridge` | Outbound network for real targets and package mirrors. OpenClaw's default is `none`; `host` is always blocked |
| `docker.user` | `0:0` | Root inside the container, for tools that need raw sockets |
| `docker.capDrop` | Docker's default capabilities except `NET_RAW` | Root in the container keeps only `NET_RAW` (enough for nmap SYN scans) |
| `docker.readOnlyRoot` | `true` | OpenClaw's default |
| `docker.binds` | none | No Docker socket and no host directories |

The local image is tagged `openclaw-kali:<hash>`, where the hash covers the base image ID and the package list, so a re-run with the same inputs reuses it. `kali-linux-headless` is several GB and adds roughly 10 minutes to the install.

## Error handling and resilience

- `set -Eeuo pipefail` throughout. The `ERR` trap records the failing command and line; the `EXIT` trap posts exactly one `failed` event when the exit code is not 0, and nothing on success. Its message carries the reason given to `die`. `INT` and `TERM` become exits 130 and 143 and go through the same path; `tee` ignores those signals, so a signal sent to the whole process group (as `timeout` and systemd do) still produces the event.
- As soon as `CALLBACK_URL`, `CALLBACK_TOKEN` and `JOB_ID` are valid, any later failure is reported, including other invalid parameters, an unsupported distro or a missing root, so the client sees the reason instead of a timeout. A dry run never posts.
- Events are built in bash rather than with `jq`, so the first event works before preflight installs anything.
- **Lock:** `/run/openclaw-install.lock`, a directory created atomically, holding the owner's pid. A second run is refused and posts nothing (a `failed` event would end the deployment the first run is still installing). A lock whose pid is gone is taken over.
- **State:** `/var/lib/openclaw-install/` (`0700`) records each completed phase with a hash of that phase's own inputs: `INSTALL_USER` for all of them, plus `OPENCLAW_VERSION` and `LLM_AUTH_CHOICE` for openclaw, and `KALI_IMAGE` and `KALI_PACKAGES` for kali. A re-run skips completed phases whose inputs are unchanged, so a corrected `KALI_IMAGE` redoes only kali; a new `JOB_ID`, `CALLBACK_URL` or secret redoes nothing. Skipped phases still report their percentage. Verify always runs.
- **Idempotence:** every phase is safe to repeat: packages are installed only if missing, Docker only if absent or stopped, OpenClaw only if not at the pin, the Kali image only if its tag is missing, and the metadata rules only if absent.

## Security

- OpenClaw runs as `INSTALL_USER`, a dedicated non-root system user, under a system-level systemd unit.
- `OPENCLAW_VERSION` pins the install; the official installer is fetched over HTTPS only.
- **Secrets** (`CALLBACK_TOKEN`, `LLM_API_KEY`) come from the environment only, are unexported right after validation so no child process inherits them, are never passed as arguments or logged, are excluded from the state file, and are redacted from the log tail sent on failure. The provider key's only file on disk is `/etc/openclaw/openclaw.env` (root, `0600`).
- **No shared platform key on the server.** The events route accepts only the per-deployment `CALLBACK_TOKEN`, which expires at the deployment's deadline.
- **Metadata service.** user_data, which carries the secrets, stays readable from `169.254.169.254` for the server's life. `openclaw-metadata-block.service` drops that traffic from Docker containers (`DOCKER-USER` chain) and from every non-root user (`OUTPUT` with `--uid-owner`), at every boot and Docker restart. Verify fails if either can still reach it.
- **Docker group.** The gateway's user is in the `docker` group because OpenClaw starts sandbox containers, which makes that user root-equivalent on the host. This is inherent to OpenClaw's Docker backend. The sandbox containers themselves get no Docker socket and no host directories.
- **Abuse reports.** Kali ships offensive-security tools, and scans from a Hetzner IP can trigger abuse reports. Operators should only scan targets they are authorised to test.

## Logging

All output goes to standard output (captured in cloud-init's log) and to `/var/log/openclaw-install.log` (`0600`), so a failure can be diagnosed on the server even if no event reached the endpoint. The events are the main channel for the provisioner; the log file is the fallback.

## cloud-init delivery

Hetzner's user_data limit is 32 KiB, so user_data stays a small stub: it receives the parameters as environment variables, clones the install repository at a pinned commit, and runs `install.sh` from the checkout. The repository URL is a parameter: a public GitLab repository for now, the Forgejo server later. [`cloud-init/user-data.example.yaml`](../cloud-init/user-data.example.yaml) is a standalone example; the provisioner renders its own equivalent.

## Testing

- **Unit tests** (`tests/unit`, bats) run every phase against command shims and a fake filesystem root (`OCI_ROOT`), covering parameters, distro detection, events, the traps, resume and locking, and that secrets reach no log, file or argument list.
- **Real servers** (`tests/hetzner/run-matrix.sh`): one Hetzner server per supported distro, plus a receiver that records events. It checks the events arrive in order, the gateway runs, the metadata service is blocked and secrets stay in the env file; it also runs the failure, resume and lock cases. Every server is deleted at the end.

## Changes from the original

- `API_KEY` sent as `x-api-key` is replaced by the per-deployment `CALLBACK_TOKEN` sent as a bearer token; the shared platform key never reaches a server.
- Event names follow the provisioner's events route: `event` with `succeeded` and `failed`, instead of `status` with `success` and `failure`.
- Added `LLM_AUTH_CHOICE` and `LLM_API_KEY` (model credentials) and `KALI_PACKAGES` (tools built into the image).
- Distro detection uses `ID` only, not `ID_LIKE`.
- The state file moved from `/var/run` (wiped at reboot) to `/var/lib/openclaw-install/`; the lock is in `/run`.
- The `EXIT` trap posts a failure only for a non-zero exit, once.
- The sandbox settings were corrected against OpenClaw's documentation: `mode` was missing (sandboxing is off by default), "per-agent" means `scope: agent`, and "open network" is `network: bridge`.
- The gateway runs from the script's own system unit instead of OpenClaw's per-user unit.
- Added the metadata-service block, required because user_data carries secrets.
- The install repository is any public HTTPS Git URL (GitLab now, Forgejo later).
