<!--
  Project-wide glossary definitions (hover tooltips), read by
  docs-site/lib/remark-glossary.ts. Keep each definition tooltip-sized.
-->

*[Coder]: The control plane: provisions one Docker container per workspace over the host Docker socket.
*[LiteLLM]: The single OpenAI-compatible proxy in front of every model, local and remote.
*[Ollama]: The model-serving API the local runtime speaks; reached only through LiteLLM.
*[IPEX-LLM]: Intel's XPU runtime that puts the models on the Arc 140T iGPU.
*[Kasm]: Workspaces that stream desktops from a privileged DinD container.
*[Homepage]: The dashboard that links the services and shows live status.
*[Hermes]: The Nous Research host assistant, with the Web Dashboard and its approval prompts.
*[SearXNG]: The keyless metasearch lane that answers the agent's web searches.
*[Bazel]: The hermetic build and test system every operator CLI is a target of.
*[Bazelisk]: Version-aware launcher that runs the Bazel version this repo pins.
*[Bats]: Bash Automated Testing System; the hermetic suite framework under tests/.
*[DinD]: Docker-in-Docker — a workspace's own sidecar daemon, addressed through DOCKER_HOST.
*[golden image]: evo-t1-dev:latest, the image every workspace container is created from.
*[External Auth]: Coder's GitHub OAuth login, the only GitHub credential this stack provisions.
*[Authelia]: The authentication gate in front of the public subdomains, on the other machine.
*[Traefik]: The reverse proxy that terminates TLS for the public names.
*[Tailscale]: The private network the host assistant is reachable over besides the LAN.
*[MoE]: Mixture-of-Experts model — 32B-class quality with fewer active parameters per token.
