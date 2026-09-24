# Contributing

## Issues

- For bugs, include `docker compose ps`, the relevant
  `docker compose logs <service>` excerpt, and the non-secret parts of your
  `.env`.
- For hardware questions, state the machine: this stack targets the GMKtec
  EVO-T1 (Ultra 9 285H / Arc 140T / 96 GB DDR5). IPEX-LLM behavior varies
  between Intel iGPUs.

## Pull requests

- Keep diffs small and focused; keep the architecture (Coder + LiteLLM +
  IPEX-LLM Ollama + Kasm) unless the change needs a real reason to diverge.
- No model weights, no `.env`, no real passwords / API keys / LAN IPs in any
  file.
- No CI that downloads models: this repo has no pipeline that pulls
  multi-gigabyte weights.
- Validate locally before opening:

  ```sh
  bash -n scripts/bootstrap.sh scripts/pull-models.sh
  docker compose config -q
  terraform fmt -check templates/docker-dev
  ```
