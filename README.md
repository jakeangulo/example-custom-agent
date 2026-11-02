# OpenClaw + Kali installer

Installs a pinned version of [OpenClaw](https://docs.openclaw.ai) on a fresh Hetzner Cloud server, with Kali Linux tools in a Docker container wired in as OpenClaw's sandbox. cloud-init runs it on first boot, and it reports its progress over HTTP, so nobody has to log in to see what happened.

It is the install repository for the [Hetzner provisioning service](https://gitlab.com/appyfic/marscape-hetzner-provisioner): a client asks the provisioner for a server with this repository, and the provisioner passes the parameters below through cloud-init. Design: [docs/design.md](docs/design.md).

Supported images: Debian, Ubuntu, Rocky Linux, AlmaLinux, CentOS Stream and Fedora.

## What it does

| % | Phase | Result |
| --- | --- | --- |
| 0 | started | Parameters checked, distro detected |
| 20 | preflight | Base tools installed, `openclaw` user created |
| 40 | docker | Docker Engine running, cloud metadata service blocked for containers and non-root users |
| 60 | openclaw | OpenClaw at the pinned version, onboarded with your model provider, gateway running as `openclaw-gateway.service` |
| 80 | kali | Kali image (plus `KALI_PACKAGES`) configured as OpenClaw's sandbox |
| 100 | verify | Everything checked; success reported |

A failure at any point reports the phase, exit code and the end of the log. Running it again resumes at the failed phase.

## Parameters

Set them as environment variables; non-secret ones can also be given as options (`--kali-image …`), which win. Secrets are refused as options. Run `./install.sh --help` for the list.

| Variable | Required | Meaning |
| --- | --- | --- |
| `OPENCLAW_VERSION` | Yes | OpenClaw version or dist-tag, e.g. `2026.10.2` |
| `KALI_IMAGE` | Yes | Kali image with tag or digest, e.g. `kalilinux/kali-rolling:2025.4` |
| `KALI_PACKAGES` | No | Packages to add to the image; default `kali-linux-headless` (several GB, ~10 min). Empty uses the image as-is |
| `LLM_AUTH_CHOICE` | Yes | `apiKey` (Anthropic), `openai-api-key`, `gemini-api-key` or `mistral-api-key` |
| `LLM_API_KEY` | Yes, secret | The provider's API key |
| `CALLBACK_URL` | Yes | HTTPS URL that receives progress events |
| `CALLBACK_TOKEN` | Yes, secret | Bearer token for `CALLBACK_URL` |
| `JOB_ID` | Yes | ID echoed in every event |
| `INSTALL_USER` | No | User OpenClaw runs as; default `openclaw` |
| `DRY_RUN` | No | `true` checks parameters and the distro without changing anything |

With the provisioner, `CALLBACK_URL`, `CALLBACK_TOKEN` and `JOB_ID` are set for you; send the rest in the request's `install.params` and `install.secrets` (`LLM_API_KEY`).

## Running it

Through the provisioner, point `install.git_url` at this repository and `install.git_ref` at a commit.

Standalone, edit [`cloud-init/user-data.example.yaml`](cloud-init/user-data.example.yaml) and pass it as the server's user data, for example:

```bash
hcloud server create --name kali-agent --type cpx31 --image ubuntu-24.04 --location fsn1 \
  --ssh-key my-key --user-data-from-file user-data.yaml
```

On an existing server, as root:

```bash
export OPENCLAW_VERSION=2026.10.2 KALI_IMAGE=kalilinux/kali-rolling:2025.4 LLM_AUTH_CHOICE=apiKey \
       CALLBACK_URL=https://… JOB_ID=manual-1
read -rs LLM_API_KEY && export LLM_API_KEY
read -rs CALLBACK_TOKEN && export CALLBACK_TOKEN
./install.sh
```

Logs are in `/var/log/openclaw-install.log`.

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

- Secrets are never logged or passed as command-line arguments. The provider key is stored only in `/etc/openclaw/openclaw.env` (root, `0600`); OpenClaw's config refers to it by name.
- user_data stays readable from the cloud metadata service for the server's whole life, so the installer blocks that service for containers and non-root users, and checks the block works.
- The `openclaw` user is in the `docker` group so the gateway can start sandbox containers, which makes it root-equivalent on the host.
- **Kali tools can trigger abuse reports.** Scans launched from a Hetzner IP are traced back to the server's owner. Only scan systems you are authorised to test.

## Development

Requirements: `bash` 4+, `bats-core`, `shellcheck`, `jq` (macOS: `brew install bash bats-core shellcheck jq`).

```bash
shellcheck -x install.sh files/openclaw-metadata-block
bats tests/unit
```

The unit tests run each phase against command shims and a fake filesystem root, so they need neither root nor a Linux machine. `tests/hetzner/run-matrix.sh` runs the installer on a real Hetzner server for every supported distro; see the script's header.
