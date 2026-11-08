---
name: web-research
description: Look something up on the public web through the stack's own SearXNG - what to ask, how to read an empty answer, and what this lane deliberately cannot do.
version: 1.0.0
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [evo-t1, web, search, searxng, research]
---

# web-research

Use when the answer is not on this box: a release date, a current version number,
an upstream flag you have never seen, an error string you did not just produce, or
"what does the project actually say about this". Everything about *this* host -
which container is restarting, what a port serves, why a workspace will not start -
you answer locally, with compose and the shell. Searching for a fact you can
measure is how a session wastes four minutes.

## The one route

`web_search` is pinned to this stack's SearXNG. The seed sets
`web.search_backend: searxng`, and compose gives the container
`SEARXNG_URL` (default `http://searxng:8181`, resolved on the compose network).
SearXNG aggregates the public engines and returns its own ranked rows; it is the
only bundled provider that needs no credential, and it is the only one this lane
uses.

Both keyless switches are off (`web.keyless_fallback: false`,
`web.keyless_rescue: false`). That is the whole privacy claim, so treat a search
that cannot reach the instance as **failed**, not as a hint to try somewhere else.
With the ring disabled there is no fallback to stumble into, and there is no
reason to create one.

## Ask well

- One question per query, in the words the upstream docs would use. A second,
  narrower query beats one long one.
- Do not name an engine. A pinned engine is answered by that engine alone, and
  the general-purpose ones bot-wall first: one that answers "access denied" or a
  CAPTCHA returns zero rows while the same query unpinned returns twenty. Let the
  instance choose, then read what came back.
- A `200` with no results is normally the engines being refused, not a broken
  deployment. The JSON body carries an `unresponsive_engines` key naming them, and
  a park expires on its own after `search.suspended_times`. Widen or reword the
  query before you suspect the container.
- Cite what you use: the URL, and the date you read it. A current fact with no
  source is a guess with better formatting - say "unverified" when you could not
  confirm it.

## The deliberate hole

`web_extract` is unconfigured. SearXNG aggregates results and fetches no page, and
the seed leaves `web.backend` and `web.extract_backend` empty, so a page fetch
fails with "no extract provider configured". That is the design: reaching an
outside extractor is a decision with a privacy cost, and it belongs to the
operator.

So when the answer needs a whole page, say what you found in the snippets, name
the URL you would need to fetch, and offer the two honest options: the operator
reads it, or they deliberately set `web.extract_backend` and a vendor key. Do not
work around the hole with a `curl` to a third-party reader - that is the same
egress the config refuses, with extra steps.

## Prove the lane

```sh
curl -s -H 'Accept: application/json' \
  "$SEARXNG_URL/search?q=<terms>&format=json" | head -c 400
```

That is the exact request the provider makes. Read it in this order: an empty
`SEARXNG_URL` means the provider was never registered (env problem, not search
problem); a `403` before the query parses means the instance does not offer the
`json` format, which `searxng/settings.yml` is what enables here; a `200` with an
empty `results` array and a populated `unresponsive_engines` is the engines, not
the box.

`bazelisk run //scripts:search-check` is the deeper probe - it queries per engine
and prints each parked one with the reason its backend gave - and it is a host
command: this image carries no bazelisk, so hand the line to the operator rather
than inventing its output.

## Do not

- Do not put a secret in a query. No token, no `.env` value, no private hostname,
  no repository name that identifies a customer. A query leaves the box.
- Do not add a vendor key, a `web.backend`, or a `web.extract_backend` to make a
  lookup easier. Name the cost and let the operator decide.
- Do not dial `:8181` on the host, or another box's instance, when
  `SEARXNG_URL` is empty. An empty variable is the finding.
- Do not present a search snippet as a fact about this host. It is a claim about
  the internet on the day you asked.

## Related skills

`model-routing` for which model to run the loop with, `evo-stack-ops` for the stack
itself, and `host-diagnostics` when the search lane is the thing that is broken.
