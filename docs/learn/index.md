---
title: Learn the stack
description: The concepts behind the box — what the templates build, how a model request is routed, what the agents file seeds, and the rules a change follows.
tags: [learn, concepts, overview]
---

**What's on this page**

- Which page explains which part of the stack
- The order that makes the pieces click, if you are reading them all

**What this enables**

- Understanding a behaviour before trying to change it
- Knowing which page owns a concept when two of them seem to

## How the pieces fit

Two templates turn a git URL into a running container: the plain `workspace` template, and
`devcontainer`, which builds the clone's own `.devcontainer` on a DinD sidecar. Both are
pushed from this checkout, and both seed the agent config the workspace starts with.

[Coder workspace templates](../coder-templates.md) owns the templates, the create form and
the variables; [Grok Build, Coder Agents, and the workspace terminal](../grok-build-and-agents.md)
owns what runs inside the container once it is up.

## The model lane

One OpenAI-compatible door, several backends behind it: the Arc 140T through IPEX-LLM, and
optional Spark boxes. Which one answers is a routing decision made in
[litellm-routing.md](../litellm-routing.md), not in the client — and that page also states the
one thing the local model cannot do.

## The assistant on the host

[Hermes](../hermes.md) is the interactive assistant with the checkout, the compose project and
the docker socket in reach, gated by approval prompts. Its public name is opt-in through
`STACK_PUBLIC_HOSTS`; with that list empty the dashboard stays on the LAN.
[public-access.md](../public-access.md) is the page that decides what the box exposes.

## The rules a change follows

[project-conventions.md](../project-conventions.md) is what a script has to look like to be
mergeable, and [branching.md](../branching.md) is how it gets to `main`. The Bazel harness they
both assume is in the [Contribute](../contribute/building-with-bazel.md) tab.
