---
title: Operate the box
description: Day-to-day operation — the dashboard and desktops, what to refresh after a git pull, the public shape, and the symptom-first fix list.
tags: [operate, dashboard, maintain, overview]
---

**What's on this page**

- Which page answers which operational question
- The two commands an operator runs most

**What this enables**

- Getting to the right runbook in one click instead of searching the README
- Refreshing a stale checkout before diagnosing what it looks like

## The two commands

Everything else is a target those two feed:

```sh
bazelisk run //scripts:prod-stack -- status
```

```sh
bazelisk run //scripts:update-configs -- all
```

`prod-stack` addresses the stable project by name from any directory; `dev-stack` does the
same for the dev one. `update-configs` is what a `git pull` cannot do for you, because the
files that go stale are not tracked — see
[config-updates.md](../config-updates.md).

## Where to look

| Symptom or task | Page |
| --- | --- |
| A card is red, or the dashboard will not load | [dashboard.md](../dashboard.md) |
| Something fails, and you have an error string | [troubleshooting.md](../troubleshooting.md) |
| A `git pull` landed and the ports moved | [config-updates.md](../config-updates.md) |
| A model answered from the wrong backend | [litellm-routing.md](../litellm-routing.md) |
| A workspace is stuck, or its editor will not start | [coder-templates.md](../coder-templates.md) |
| A public name does not resolve or redirects wrong | [public-access.md](../public-access.md) |
| The assistant will not sign in | [hermes.md](../hermes.md) |

## Before you reach for a hammer

`storage-clean` is the janitor for the persistent layer and asks before it deletes; the
dev-stack `reset` and a Kasm reset both destroy state that has no backup. The cost of each
is spelled out on the entry in [troubleshooting.md](../troubleshooting.md) — read that line
first.
