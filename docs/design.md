# OpenClaw + Kali Installer: Design

Oct 28, 2026 · revised Nov 2 and Nov 17, 2026 (converted from the original `.docx`; see [Changes from the original](#changes-from-the-original))

## Overview

`install.sh` is a non-interactive Bash installer for a pinned OpenClaw version plus Kali Linux tooling. It runs as root on a Linux server, started by a person at a prompt or by any provisioning tool over SSH (Marscape's provisioner uses PyInfra). It does not depend on any cloud provider, on cloud-init or on a callback endpoint: it prints its progress and errors on stdout, and its exit code is the result.

The repository describes itself to provisioners with [`marscape.yaml`](../marscape.yaml): script path, parameters, supported OS, machine size, ports, expected duration and retry and reboot settings. [`example-marscape.yaml`](../example-marscape.yaml) documents every field for authors of other install repositories.

## Goals and non-goals

**Goals**

- Install a pinned OpenClaw version non-interactively on the common server distros, on any provider or none.
- Make Kali Linux tooling available to the OpenClaw agent through Docker, wired into OpenClaw's own sandbox configuration.
- Accept every variable input as a parameter: no hardcoded secrets or server-specific values.
- Fail loudly and safely, and support safe retries.
- Report progress in 20% steps on stdout, with the exit code as the result, so a person and a provisioning tool read the same thing.

**Non-goals**

- Day-2 configuration management or drift correction.
- Provisioning the server itself.
- Reporting status to anything: the caller reads stdout and the exit code.
- Any interactive or GUI mode.

## Supported platforms

Six distros, in two package-manager families (the standard images of the common clouds). openSUSE is not supported.

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

Every input is a parameter: an environment variable, or an option that takes precedence over it. The installer has no secret parameters; the contract in `example-marscape.yaml` says how others' secrets travel (environment only, never printed).

| Parameter | Required | Description |
| --- | --- | --- |
| `OPENCLAW_VERSION` | Yes | Version, dist-tag or spec, passed to OpenClaw's official installer |
| `KALI_IMAGE` | Yes | Full image reference with a tag or digest, e.g. `kalilinux/kali-rolling@sha256:1ff4a2be3849333687b3ed2b31bb5af0cd1b7c0a11ec7713feb5abe5a6b2795c`; Kali publishes only rolling tags (`latest`, per-arch), so pin a digest for repeatable installs |
| `KALI_PACKAGES` | No (default `kali-linux-headless`) | Packages built into a local image on top of `KALI_IMAGE`; empty means use `KALI_IMAGE` as-is |
| `PUBLIC_HOST` | No (default: the IPv4 of the default route) | Host name or IPv4 the Control UI is reached at; set it behind NAT or for a DNS name |
| `DRY_RUN` | No (default `false`) | Validate parameters and detect the distro only; change nothing |

`KALI_IMAGE` is a full reference rather than a bare tag, so a caller can point at a private registry or another Kali variant without a script change.

Through a provisioner, the client sends the parameters in its request; the provisioner checks them against `marscape.yaml` and passes them as the environment of the install command. The old `CALLBACK_URL`, `CALLBACK_TOKEN` and `JOB_ID` variables are ignored if still set.

## Output contract

| Output | Meaning |
| --- | --- |
| `::progress <percent> <phase>` | Printed after each phase (20, 40, 60, 80, 100), also for phases skipped on a rerun |
| `::error <message>` | Printed once when the run fails, with the phase, exit code and reason. Not printed for a dry run or for a run refused by the lock (the other run owns the install) |
| Exit code `0` | Installed and verified |
| Any other exit code | Failed; the log and the `::error` line say why. `194`, the manifest's `reboot_exit_code`, would ask the caller to reboot and rerun, but this installer never needs it |

Markers start at the beginning of a line on stdout. Everything else is the log.

## Phases

| % | Phase | Milestone |
| --- | --- | --- |
| 20 | `preflight` | Missing tools installed (`curl`, `git`, `jq`, `iptables`, `ip`, `gpg` on apt) |
| 40 | `docker` | Docker Engine from Docker's repository, running; metadata service blocked for containers and non-root users |
| 60 | `openclaw` | OpenClaw installed by its official installer at the pinned version and onboarded as root (OpenClaw's default), with no model provider; gateway running as a system service with the Control UI on the public IPv4 |
| 80 | `kali` | Kali image pulled, local image built with `KALI_PACKAGES`, sandbox config written and validated, gateway restarted |
| 100 | `verify` | Version matches, gateway healthy on `/healthz`, sandbox image starts, metadata unreachable from containers and non-root users |

Before the phases, the script validates the parameters, detects the distro and takes the lock. After each phase it records it in the state file and prints its `::progress` line. If anything fails, the `EXIT` trap prints one `::error` line, then exits with the original code.

## OpenClaw setup

- **Install.** `https://openclaw.ai/install.sh` is downloaded over HTTPS (TLS 1.2+) to a file, not piped, and run as root with `--version "$OPENCLAW_VERSION" --no-prompt --no-onboard`. It installs Node.js from NodeSource and OpenClaw globally, so the binary is root-owned and the agent cannot modify it. An exact version already installed is not reinstalled; a dist-tag always re-runs the installer.
- **Onboarding.** As root, the way OpenClaw is installed by default: `openclaw onboard --non-interactive --accept-risk --mode local --auth-choice skip --gateway-bind lan --gateway-port 18789 --skip-daemon --skip-skills --skip-health`. With no auth flags OpenClaw generates the gateway token and stores it in its own config (`/root/.openclaw/openclaw.json`, `gateway.auth.token`, token mode), so OpenClaw's standard commands work on the server as documented: `openclaw gateway auth-token --show`, `openclaw devices approve`, `openclaw dashboard`. No model provider is configured: users add one in the Control UI (**Models → Connect provider**). Onboarding is skipped once root has an OpenClaw config.
- **Control UI origin.** Every run sets `gateway.controlUi.allowedOrigins` to `["http://<host>:18789"]`, which OpenClaw requires for a non-loopback Control UI. The host is `PUBLIC_HOST`, or else the IPv4 address of the default route (`ip -4 route get`), which is the public address on a typical cloud server; no cloud metadata service is asked. IPv6 and TLS are not configured.
- **Gateway service.** The script writes its own system unit, `openclaw-gateway.service`: `User=root`, `HOME=/root`, `ExecStart=openclaw gateway run --port 18789 --bind lan` (all interfaces; OpenClaw refuses a non-loopback bind without gateway auth), restart on failure except exit code 78 (invalid config). OpenClaw's own daemon install creates a per-user unit, which needs D-Bus and lingering and fails silently on headless servers.

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

- `set -Eeuo pipefail` throughout. The `ERR` trap records the failing command and line; the `EXIT` trap prints exactly one `::error` line when the exit code is not 0, and nothing on success. Its message carries the reason given to `die`. `INT` and `TERM` become exits 130 and 143 and go through the same path; `tee` ignores those signals, so a signal sent to the whole process group (as `timeout` and SSH-driven tools do) still produces the line.
- Invalid parameters, an unsupported distro or a missing root are reported the same way, so the caller sees the reason. A dry run never prints `::error`.
- **Lock:** `/run/openclaw-install.lock`, a directory created atomically, holding the owner's pid. A second run is refused without `::error` (the first run owns the install, and a caller must not end it). A lock whose pid is gone is taken over.
- **State:** `/var/lib/openclaw-install/` (`0700`) records each completed phase with a hash of that phase's own inputs: `OPENCLAW_VERSION` for openclaw, and `KALI_IMAGE` and `KALI_PACKAGES` for kali. A re-run skips completed phases whose inputs are unchanged, so a corrected `KALI_IMAGE` redoes only kali. Skipped phases still print their `::progress` line. Verify always runs.
- **Idempotence:** every phase is safe to repeat: packages are installed only if missing, Docker only if absent or stopped, OpenClaw only if not at the pin, the Kali image only if its tag is missing, and the metadata rules only if absent.

## Security

- OpenClaw runs as root (its default), under a system-level systemd unit. The servers are for professionals who administer them as root; OpenClaw's own documentation and commands apply unchanged.
- `OPENCLAW_VERSION` pins the install; the official installer is fetched over HTTPS only.
- **Secrets.** The installer takes none. The gateway token is OpenClaw's own, in root's OpenClaw config. The Control UI is exposed on the public IP over plain HTTP with token auth plus OpenClaw's per-browser device pairing; the server firewall should allow port `18789` only from the user's IP.
- **Metadata service.** On many clouds `169.254.169.254` serves the server's user data and credentials for its whole life. `openclaw-metadata-block.service` drops that traffic from Docker containers (`DOCKER-USER` chain) and from every non-root user (`OUTPUT` with `--uid-owner`), at every boot and Docker restart. Verify fails if either can still reach it. Root, and so OpenClaw itself, can still read it. The block is kept as hardening: no secrets reach this installer through user data any more.
- **Sandbox.** OpenClaw starts its Kali sandbox containers through Docker; the containers get no Docker socket and no host directories.
- **Abuse reports.** Kali ships offensive-security tools, and scans from a cloud server's IP can trigger abuse reports. Operators should only scan targets they are authorised to test.

## Logging

All output goes to standard output and to `/var/log/openclaw-install.log` (`0600`), so a failure can be diagnosed on the server as well as from the caller's captured output.

## Running under a provisioner

A provisioner clones the repository at a pinned commit, reads `marscape.yaml`, and runs `install.script` as root over SSH with the parameters as the command's environment. It relays `::progress` lines as the deployment's progress, uses the `::error` line and the end of the output as the failure reason, and decides retries and reboots from the exit code and `marscape.yaml` (`max_retries`, `reboot_exit_code`). The script must stay safe to rerun, because retries run it again on the same server.

## Testing

- **Unit tests** (`tests/unit`, bats) run every phase against command shims and a fake filesystem root (`OCI_ROOT`), covering parameters, distro detection, the output markers, the traps, resume and locking. `manifest.bats` keeps `marscape.yaml` in step with `install.sh --help`, the supported distros and `example-marscape.yaml`, and checks the manifests name no provider.
- **Real servers** (`tests/hetzner/run-matrix.sh`): one Hetzner server per supported distro. It clones the repository over SSH, runs `install.sh` the way a provisioning tool would, and checks the exit code and markers, that the gateway runs and that the metadata service is blocked; it also runs the failure, resume and lock cases. Every server is deleted at the end.

## Changes from the original

- **2026-11-17 (provider-agnostic installer).** The installer no longer depends on cloud-init, a callback endpoint or Hetzner. Removed: `lib/report.sh`, the `CALLBACK_URL`, `CALLBACK_TOKEN` and `JOB_ID` parameters (ignored if still set), the event sequence, and the cloud-init example. Progress and errors are `::progress` and `::error` lines on stdout, and the exit code is the result. The Control UI origin comes from the new `PUBLIC_HOST` parameter or the default route's IPv4 instead of Hetzner's metadata service. Added `marscape.yaml` and `example-marscape.yaml`. The Hetzner matrix runs the installer over SSH. Callers pinned to commit `a8b0f70` or earlier keep the old behaviour, because they pin the commit.

- `API_KEY` sent as `x-api-key` is replaced by the per-deployment `CALLBACK_TOKEN` sent as a bearer token; the shared platform key never reaches a server.
- Event names follow the provisioner's events route: `event` with `succeeded` and `failed`, instead of `status` with `success` and `failure`.
- OpenClaw runs as root (2026-11-15), its default, instead of a dedicated `openclaw` user; `INSTALL_USER` was removed, so OpenClaw's standard commands work on the server unchanged.
- Added `KALI_PACKAGES` (tools built into the image). `LLM_AUTH_CHOICE` and `LLM_API_KEY` were added and later removed (2026-11-15): the Control UI is exposed on the public IP with token auth, and users connect model providers there.
- Distro detection uses `ID` only, not `ID_LIKE`.
- The state file moved from `/var/run` (wiped at reboot) to `/var/lib/openclaw-install/`; the lock is in `/run`.
- The `EXIT` trap posts a failure only for a non-zero exit, once.
- The sandbox settings were corrected against OpenClaw's documentation: `mode` was missing (sandboxing is off by default), "per-agent" means `scope: agent`, and "open network" is `network: bridge`.
- The gateway runs from the script's own system unit instead of OpenClaw's per-user unit.
- Added the metadata-service block, required because user_data carries secrets.
- The install repository is any public HTTPS Git URL (GitLab now, Forgejo later).
