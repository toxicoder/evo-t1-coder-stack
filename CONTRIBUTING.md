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
  bash -n scripts/*.sh
  docker compose config -q
  cmp .env.sample .env.example            # .env.example is a copy — keep them identical
  terraform -chdir=templates/docker-dev fmt -check
  python3 -c "import yaml,glob; [yaml.safe_load(open(f)) for f in glob.glob('homepage/config/*.yaml')+['litellm/config.yaml']]"
  ```

## Changing version pins

`images/dev/tool-versions.env` is the single source of truth for the workspace
image. `scripts/build-dev-image.sh` refuses to build if a pin has no matching
`ARG` in `images/dev/Dockerfile`, so add both sides of a new pin together.

- Confirm the upstream asset exists before you commit a new version. A wrong
  download URL now fails the build (`curl -f`), which is the point — earlier
  revisions of the Dockerfile could swallow a 404 mid-`&&`-chain and ship an
  image with tools quietly missing, so keep every fetch `-fsSL --fail` and keep
  the version-print smoke checks at the end of each layer.
- GitHub release URLs are inconsistent about the leading `v` in the tag versus
  the asset name. Check the release's asset list rather than guessing:
  `gh release view <tag> -R <owner>/<repo>`.
- `go install` wants the version as a suffix of the full package path
  (`…/cmd/protoc-gen-go@v1.36.12`). `module@version/cmd/tool` is rejected as a
  disallowed version string.
- After editing pins, `./scripts/build-dev-image.sh` and then
  `docker image inspect evo-t1-dev:latest` — the script proves the tag is in the
  local store, which is what the Coder docker provider needs to avoid a pull.
