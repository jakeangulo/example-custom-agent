# OpenClaw + Kali installer

Installs a pinned version of [OpenClaw](https://docs.openclaw.ai) on a Linux server, with Kali Linux tools in a Docker container wired in as OpenClaw's sandbox. Run it as root on the server, by hand or from any provisioning tool: it needs no cloud provider, no cloud-init and no callback endpoint. Progress and errors are printed as `::progress` and `::error` lines, and the exit code is the result.

The repository is described to provisioners by [`marscape.yaml`](marscape.yaml). Authors of other install repositories can start from [`example-marscape.yaml`](example-marscape.yaml), which documents every field and the script contract. Design: [docs/design.md](docs/design.md).

Supported distros: Debian, Ubuntu, Rocky Linux, AlmaLinux, CentOS Stream and Fedora. First verified on a real server on 2026-11-15: Ubuntu 26.04 with 3 vCPUs and 4 GB, about 13 minutes in total, most of it the Kali phase with the default `KALI_PACKAGES`. On a 2 vCPU / 2 GB server the same install did not finish within 25 minutes, so give small servers a smaller `KALI_PACKAGES` or more time.

## What it does

| % | Phase | Result |
| --- | --- | --- |
| 20 | preflight | Base tools installed |
| 40 | docker | Docker Engine running, cloud metadata service blocked for containers and non-root users |
| 60 | openclaw | OpenClaw at the pinned version, run as root (its default), onboarded with no model provider, gateway running as `openclaw-gateway.service` with the Control UI on `http://<PUBLIC_HOST>:18789` |
| 80 | kali | Kali image (plus `KALI_PACKAGES`) configured as OpenClaw's sandbox |
| 100 | verify | Everything checked |

Running it again after a failure resumes at the failed phase; finished phases are skipped, and verify always runs.

## Parameters

Set them as environment variables, or as options (`--kali-image …`), which win. Run `./install.sh --help` for the list; [`marscape.yaml`](marscape.yaml) lists the same parameters with their validation patterns.

| Variable | Required | Meaning |
| --- | --- | --- |
| `OPENCLAW_VERSION` | Yes | OpenClaw version or dist-tag, e.g. `2026.10.2` |
| `KALI_IMAGE` | Yes | Kali image with tag or digest, e.g. `kalilinux/kali-rolling@sha256:1ff4a2be3849333687b3ed2b31bb5af0cd1b7c0a11ec7713feb5abe5a6b2795c` (Kali publishes only rolling tags such as `latest`, so pin a digest) |
| `KALI_PACKAGES` | No | Packages to add to the image; default `kali-linux-headless` (several GB, ~10 min). Empty uses the image as-is |
| `PUBLIC_HOST` | No | Host name or IPv4 the Control UI is reached at. Default: this machine's IPv4 on its default route, which is the public address on a typical cloud server. Set it behind NAT or for a DNS name |
| `DRY_RUN` | No | `true` checks parameters and the distro without changing anything |

Model provider credentials are not parameters: users add them in the Control UI (see below).

## Running it

As root on the server:

```bash
git clone https://github.com/jakeangulo/example-custom-agent.git && cd example-custom-agent
export OPENCLAW_VERSION=2026.10.2 \
       KALI_IMAGE=kalilinux/kali-rolling@sha256:1ff4a2be3849333687b3ed2b31bb5af0cd1b7c0a11ec7713feb5abe5a6b2795c
./install.sh
```

A provisioning tool does the same over SSH, with the parameters in the command's environment.

### Output and exit codes

- `::progress <percent> <phase>` after each phase, on a line of its own.
- One `::error <message>` when the run fails (not for a run refused because another is already running, and never for `--dry-run`).
- Exit code `0`: installed and verified. Anything else: failed. This installer never asks for a reboot (exit code `194` in `marscape.yaml`).

Everything else on stdout and stderr is the log, also kept in `/var/log/openclaw-install.log` (`0600`).

## Using the Control UI

OpenClaw runs as root, its default, so OpenClaw's own documentation and commands apply on the server unchanged. The gateway serves the Control UI on `http://<PUBLIC_HOST>:18789`, on all interfaces with token auth. Open port `18789` only to your own IP in the server's firewall (through a provisioner, add a `tcp` rule for port `18789` next to the SSH rule; `marscape.yaml` allows it).

To log in the first time, as root on the server:

1. `openclaw gateway auth-token --show` prints the gateway token; paste it into the Control UI's **Gateway secret** field.
2. The browser then waits for approval: `openclaw devices list`, then `openclaw devices approve <requestId>`. The browser is remembered after that.
3. Add a model provider in **Models → Connect provider**.

Alternatively, `openclaw dashboard --json` prints a one-time `browserUrl` that pairs a browser without a token; for this LAN bind it points at `127.0.0.1`, so replace that with the server's public address in the address and in the `gatewayUrl` value, as OpenClaw's docs describe.

The UI is plain HTTP, so traffic crosses the network unencrypted; keep the firewall rule limited to your IP, or put the UI behind TLS (for example Tailscale Serve).

## Security notes

- The installer takes no secrets. The gateway token and any provider credentials added in the Control UI are stored by OpenClaw in root's config.
- The installer blocks the cloud metadata service (`169.254.169.254`) for containers and non-root users, and checks the block works, because on many clouds it serves the server's user data and credentials. Root, and so OpenClaw, can still read it.
- OpenClaw runs as root, so anything the agent does on the host runs as root; only its Kali sandbox containers are isolated.
- **Kali tools can trigger abuse reports.** Scans launched from a cloud server's IP are traced back to the server's owner. Only scan systems you are authorised to test.

## Development

Requirements: `bash` 4+, `bats-core`, `shellcheck`, `jq`, `ruby` (for the manifest tests; macOS: `brew install bash bats-core shellcheck jq`).

```bash
shellcheck -x install.sh files/openclaw-metadata-block tests/hetzner/run-matrix.sh
bats tests/unit
```

The unit tests run each phase against command shims and a fake filesystem root, so they need neither root nor a Linux machine. `tests/unit/manifest.bats` keeps `marscape.yaml` in step with `install.sh --help` and with `example-marscape.yaml`. `tests/hetzner/run-matrix.sh` runs the installer over SSH on a real Hetzner server for every supported distro (it costs a few cents and has not been run yet); see the script's header.
