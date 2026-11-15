# OpenClaw + Kali installer

Installs a pinned version of [OpenClaw](https://docs.openclaw.ai) on a fresh Hetzner Cloud server, with Kali Linux tools in a Docker container wired in as OpenClaw's sandbox. cloud-init runs it on first boot, and it reports its progress over HTTP, so nobody has to log in to see what happened.

It is the install repository for the [Hetzner provisioning service](https://gitlab.com/appyfic/marscape-hetzner-provisioner): a client asks the provisioner for a server with this repository, and the provisioner passes the parameters below through cloud-init. Design: [docs/design.md](docs/design.md).

Supported images: Debian, Ubuntu, Rocky Linux, AlmaLinux, CentOS Stream and Fedora. First verified on a real server on 2026-11-15 through the provisioning service: Ubuntu 26.04 on a Hetzner `cpx22`, about 13 minutes in total, most of it the Kali phase with the default `KALI_PACKAGES`. On a `cpx02` the same install did not finish within 25 minutes, so give small servers a smaller `KALI_PACKAGES` or a longer deadline.

## What it does

| % | Phase | Result |
| --- | --- | --- |
| 0 | started | Parameters checked, distro detected |
| 20 | preflight | Base tools installed |
| 40 | docker | Docker Engine running, cloud metadata service blocked for containers and non-root users |
| 60 | openclaw | OpenClaw at the pinned version, run as root (its default), onboarded with no model provider, gateway running as `openclaw-gateway.service` with the Control UI on `http://<public IPv4>:18789` |
| 80 | kali | Kali image (plus `KALI_PACKAGES`) configured as OpenClaw's sandbox |
| 100 | verify | Everything checked; success reported |

A failure at any point reports the phase, exit code and the end of the log. Running it again resumes at the failed phase.

## Parameters

Set them as environment variables; non-secret ones can also be given as options (`--kali-image …`), which win. Secrets are refused as options. Run `./install.sh --help` for the list.

| Variable | Required | Meaning |
| --- | --- | --- |
| `OPENCLAW_VERSION` | Yes | OpenClaw version or dist-tag, e.g. `2026.10.2` |
| `KALI_IMAGE` | Yes | Kali image with tag or digest, e.g. `kalilinux/kali-rolling@sha256:1ff4a2be3849333687b3ed2b31bb5af0cd1b7c0a11ec7713feb5abe5a6b2795c` (Kali publishes only rolling tags such as `latest`, so pin a digest) |
| `KALI_PACKAGES` | No | Packages to add to the image; default `kali-linux-headless` (several GB, ~10 min). Empty uses the image as-is |
| `CALLBACK_URL` | Yes | HTTPS URL that receives progress events |
| `CALLBACK_TOKEN` | Yes, secret | Bearer token for `CALLBACK_URL` |
| `JOB_ID` | Yes | ID echoed in every event |
| `DRY_RUN` | No | `true` checks parameters and the distro without changing anything |

With the provisioner, `CALLBACK_URL`, `CALLBACK_TOKEN` and `JOB_ID` are set for you; send the rest in the request's `install.params`. Model provider credentials are not parameters: users add them in the Control UI (see below).

## Running it

Through the provisioner, point `install.git_url` at this repository and `install.git_ref` at a commit.

Standalone, edit [`cloud-init/user-data.example.yaml`](cloud-init/user-data.example.yaml) and pass it as the server's user data, for example:

```bash
hcloud server create --name kali-agent --type cpx31 --image ubuntu-24.04 --location fsn1 \
  --ssh-key my-key --user-data-from-file user-data.yaml
```

On an existing server, as root:

```bash
export OPENCLAW_VERSION=2026.10.2 KALI_IMAGE=kalilinux/kali-rolling@sha256:1ff4a2be3849333687b3ed2b31bb5af0cd1b7c0a11ec7713feb5abe5a6b2795c \
       CALLBACK_URL=https://… JOB_ID=manual-1
read -rs CALLBACK_TOKEN && export CALLBACK_TOKEN
./install.sh
```

Logs are in `/var/log/openclaw-install.log`.

## Using the Control UI

OpenClaw runs as root, its default, so OpenClaw's own documentation and commands apply on the server unchanged. The gateway serves the Control UI on `http://<server public IPv4>:18789`, on all interfaces with token auth. Open port `18789` only to your own IP in the server's firewall (with the provisioner, add a `tcp` rule for port `18789` next to the SSH rule).

To log in the first time, as root on the server:

1. `openclaw gateway auth-token --show` prints the gateway token; paste it into the Control UI's **Gateway secret** field.
2. The browser then waits for approval: `openclaw devices list`, then `openclaw devices approve <requestId>`. The browser is remembered after that.
3. Add a model provider in **Models → Connect provider**.

Alternatively, `openclaw dashboard --json` prints a one-time `browserUrl` that pairs a browser without a token; for this LAN bind it points at `127.0.0.1`, so replace that with the server's public IPv4 in the address and in the `gatewayUrl` value, as OpenClaw's docs describe.

The UI is plain HTTP, so traffic crosses the network unencrypted; keep the firewall rule limited to your IP, or put the UI behind TLS (for example Tailscale Serve).

## Events

Each event is a `POST` to `CALLBACK_URL` with `Authorization: Bearer $CALLBACK_TOKEN`:

```json
{
  "event": "in_progress",
  "job_id": "d-01JBX7Q8M4N2R5T6V7W8X9Y0Z1",
  "hostname": "kali-agent",
  "percent": 40,
  "phase": "docker",
  "message": "phase docker done",
  "timestamp": "2026-11-02T10:09:41Z",
  "script_version": "f80e24f",
  "sequence": 3
}
```

`event` is `started`, `in_progress`, `succeeded` or `failed`; a `failed` event adds `exit_code` and `log_tail`. Posting is best effort and never stops the install.

## Security notes

- `CALLBACK_TOKEN` is never logged or passed as a command-line argument. The gateway token and any provider credentials added in the Control UI are stored by OpenClaw in root's config.
- user_data stays readable from the cloud metadata service for the server's whole life, so the installer blocks that service for containers and non-root users, and checks the block works. Root, and so OpenClaw, can still read it.
- OpenClaw runs as root, so anything the agent does on the host runs as root; only its Kali sandbox containers are isolated.
- **Kali tools can trigger abuse reports.** Scans launched from a Hetzner IP are traced back to the server's owner. Only scan systems you are authorised to test.

## Development

Requirements: `bash` 4+, `bats-core`, `shellcheck`, `jq` (macOS: `brew install bash bats-core shellcheck jq`).

```bash
shellcheck -x install.sh files/openclaw-metadata-block
bats tests/unit
```

The unit tests run each phase against command shims and a fake filesystem root, so they need neither root nor a Linux machine. `tests/hetzner/run-matrix.sh` runs the installer on a real Hetzner server for every supported distro; see the script's header.
