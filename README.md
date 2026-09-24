# EVO-T1 Coder Stack

One `docker compose up` turns a GMKtec EVO-T1 laptop into a self-hosted dev-workspace server: Coder workspaces that open a **Grok Build** terminal by default (with Cline and Kilo Code pre-wired to local models), Kasm Workspaces for full desktop streaming, IPEX-LLM Ollama running Qwen Coder on the Intel Arc 140T, and a LiteLLM proxy that unifies the local iGPU with one or more NVIDIA Spark boxes behind a single OpenAI-compatible endpoint.

## Hardware

Target machine: **GMKtec EVO-T1**

| | |
|---|---|
| CPU | Intel Core Ultra 9 285H (Arrow Lake-H) |
| GPU | Intel Arc 140T iGPU (`/dev/dri`) |
| RAM | 96 GB DDR5 (CPU + iGPU unified) |

Everything in this stack is sized for that machine: local LLMs run on the iGPU via IPEX-LLM, and the 96 GB of unified memory is what makes a 32B MoE coder model comfortable.

## Architecture

```text
LAN clients (laptops, phones, the EVO-T1 itself)
  |
  +-- :3001 ----> Coder UI (control plane, Postgres-backed)
  |                   | provisions workspaces via /var/run/docker.sock
  |                   v
  |              Coder workspaces (Docker containers)
  |                * Grok Build terminal (default; tmux session
  |                  grok-build-<folder>-<hash>, then `grok --cwd <folder>`)
  |                * Cline / Kilo Code ---> host.docker.internal:4000
  |
  +-- :4000 ----> LiteLLM proxy (master key, model aliases)
  |                   +-- local:  http://ollama:11434 (compose network only)
  |                   +-- remote: SPARK1_OLLAMA_URL / SPARK2_OLLAMA_URL
  |
  +-- (no host port) IPEX-LLM Ollama on the Arc 140T (/dev/dri)
  |
  +-- :3000 ----> Kasm install wizard (first boot only)
  +-- :4443 ----> Kasm Workspaces UI (privileged DinD desktop streaming)
```

Key properties:

- **Ollama is never published to the host.** It listens on 11434 inside the compose network; LiteLLM is the only gateway to the models, and it sits behind a master key.
- **Workspaces reach models through the host.** The Coder access URL is the LAN IP; workspaces reach LiteLLM via `host.docker.internal:4000` (host-gateway).
- **Kasm owns :3000 / :4443**, so the Coder UI lives on :3001.

## Quick start

```sh
git clone https://github.com/toxicoder/evo-t1-coder-stack.git
cd evo-t1-coder-stack
cp .env.sample .env
./scripts/bootstrap.sh    # generates local secrets, fills CODER_ACCESS_URL
docker compose up -d
./scripts/pull-models.sh  # pulls OLLAMA_MODELS (first run is a big download)
```

Then:

1. Open `http://<host>:3001` and sign in with `CODER_ADMIN_USERNAME` / `CODER_ADMIN_PASSWORD` from `.env` (bootstrap generates them; if admin-bootstrap did not apply in your build, create the admin on the first-run screen).
2. Push the workspace template (section below).
3. Kasm: on first boot open `http://<host>:3000`, run the install wizard once, then use `http://<host>:4443` for the Kasm UI.

## Ports

| Host port | Service | Purpose |
|---:|---|---|
| 3001 | Coder | Web UI + control plane (`CODER_HTTP_PORT`) |
| 3000 | Kasm | First-boot install wizard (`KASM_WIZARD_PORT`) |
| 4443 | Kasm | Workspaces UI after install (`KASM_UI_PORT`) |
| 4000 | LiteLLM | OpenAI-compatible proxy (`LITELLM_PORT`) |
| — | Ollama | `11434` on the compose network only — deliberately not published |

## LiteLLM model aliases

Workspaces and desktops always talk to one base URL — `http://host.docker.internal:4000/v1` with `LITELLM_MASTER_KEY` — and pick a model alias:

| Alias | Model | Backend |
|---|---|---|
| `coder` | `qwen2.5-coder:32b` | local IPEX-LLM Ollama (Arc 140T) |
| `coder-fast` | `qwen2.5-coder:14b` | local IPEX-LLM Ollama |
| `chat` | `qwen2.5:7b` | local IPEX-LLM Ollama |
| `spark-coder` | `qwen2.5-coder:32b` | `SPARK1_OLLAMA_URL` (NVIDIA Spark, optional) |
| `spark-chat` | `qwen2.5:7b` | `SPARK2_OLLAMA_URL` (NVIDIA Spark, optional) |

Edit aliases in `litellm/config.yaml`, then `docker compose restart litellm`.

## Coder workspace template

```sh
coder login http://<host>:3001
coder template push ./templates/docker-dev
```

The template (`templates/docker-dev/`) creates one Docker container per workspace:

- `codercom/example-base:ubuntu` image (override with the `image` variable)
- persistent per-workspace home volume
- `host.docker.internal` → host-gateway, so workspaces reach the Coder server and LiteLLM
- a startup script that installs **tmux** + the **Grok Build CLI**, puts `~/.grok/bin` on PATH, and writes the VS Code settings (below)

Template variables: `image`, `litellm_url` (default `http://host.docker.internal:4000/v1`), `litellm_key` (sensitive — pass the LiteLLM master key when creating a workspace), `docker_socket` (optional).

## Grok Build default terminal

New Coder workspaces open a **Grok Build** terminal by default:

- `terminal.integrated.defaultProfile.linux` is `"Grok Build"`; the automation profile stays `bash`, and plain `bash` and `tmux` remain available as extra profiles.
- The profile resumes (or starts) one tmux session per folder — `grok-build-<folder>-<hash>` — then runs `grok --cwd <folder>` inside it.
- The workspace startup script installs the Grok CLI from `https://x.ai/cli/install.sh` (once) and adds `~/.grok/bin` to PATH.
- First run may prompt you to `grok auth`; after that, sessions just resume.
- Cline and Kilo Code are pre-wired to the LiteLLM proxy (endpoint `http://host.docker.internal:4000/v1`, master key from the `litellm_key` template variable, model alias `coder`). If your extension build names its settings slightly differently, set the OpenAI-compatible endpoint + key in its settings UI — one field each.

## Kasm

- **First boot:** `http://<host>:3000` — run the install wizard once.
- **After install:** the Kasm UI is on `http://<host>:4443` (change with `KASM_UI_PORT`).
- The image ships default users (`admin@kasm.local` / `user@kasm.local`) — change them during the wizard.
- Kasm is a privileged Docker-in-Docker container; it is the only privileged service in this stack. Keep it LAN-only (see SECURITY.md).

## Memory budget (96 GB DDR5, CPU + iGPU unified)

| Item | Typical footprint |
|---|---|
| `qwen2.5-coder:32b` (Q4) | ~20 GB weights + 4–8 GB KV cache / activations |
| `qwen2.5-coder:14b` | ~10 GB |
| `qwen2.5:7b` | ~5 GB |
| Each Coder workspace | 2–8 GB depending on toolchain |
| Coder + Postgres + LiteLLM | ~2–3 GB |
| Kasm desktop session | 4–16 GB (more for GPU apps) |

Only models you actually load are resident; Ollama keeps them in RAM until they age out.

## What not to run here

- **Training / fine-tuning.** This is an inference + dev-workspace box, not a training rig.
- **Public internet exposure.** All services assume a trusted LAN / VPN; there is no reverse proxy, TLS termination, or SSO in the stack.
- **Heavy video encode/render.** The Arc 140T is strong for LLM inference; do not plan media pipelines around it.
- **Multi-tenant teams.** A handful of trusted users, not an org-wide SaaS.
- **CI that downloads models.** No pipeline in this repo pulls 40 GB of weights — model pulls are a manual `./scripts/pull-models.sh`.

## Why this shape

- **IPEX-LLM over vanilla Ollama (CPU/Vulkan):** the IPEX-LLM runtime is Intel's XPU path (oneAPI / Level Zero) for the Arc stack. With `OLLAMA_NUM_GPU=999` every layer offloads to the 140T and the iGPU pulls weights straight out of the 96 GB DDR5. Vanilla Ollama on an Intel iGPU is effectively CPU-bound, which is several times slower on a 32B coder model. Watch for `runners=[ipex_llm]` in `docker compose logs ollama` — that line is the GPU backend confirming itself.
- **MoE over dense:** `qwen2.5-coder:32b` is a Mixture-of-Experts model — 32B-class quality with far fewer active parameters per token. On a memory-rich but bandwidth/latency-constrained iGPU that is the sweet spot; an equivalent dense model would move all parameters per token and run much slower at the same footprint.
- **One LiteLLM front door:** workspaces see a stable OpenAI-compatible URL and alias names; you can flip `coder` from the local Arc to a Spark box (or add a new alias) without touching workspace settings.
- **Kasm on the same box:** the EVO-T1's 96 GB is enough to run a desktop (X11 + GPU) alongside local models, so "open a full desktop when the editor is not enough" is one Kasm click away.

## Repo layout

```text
.
├── docker-compose.yml
├── .env.sample            # canonical env template (.env.example is a copy)
├── litellm/config.yaml    # model aliases
├── scripts/
│   ├── bootstrap.sh       # .env + secrets + access URL + sanity checks
│   └── pull-models.sh     # pulls OLLAMA_MODELS into the IPEX-LLM container
└── templates/docker-dev   # Coder template (`coder template push`)
    ├── main.tf
    ├── coder.tf
    ├── startup.sh.tftpl
    └── settings.json.tftpl
```

## Troubleshooting

- `docker compose logs -f ollama` — IPEX-LLM startup; look for `runners=[ipex_llm]`.
- Workspace cannot reach LiteLLM → check `CODER_ACCESS_URL` is a LAN IP (not `localhost` / `127.0.0.1`) and that the workspace container can resolve `host.docker.internal`.
- Grok profile missing in a fresh workspace → the startup script runs before VS Code starts; check the workspace agent logs, then `ls ~/.grok/bin`.
- Kasm wizard gone after install → expected; use :4443. Reset Kasm by removing the `kasm-data` volume (destroys all Kasm config).
- Coder admin login fails → see the admin note in Quick start; the fallback is the first-run admin screen.
