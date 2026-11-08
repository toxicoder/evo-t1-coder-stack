# Trunk-based + feature flags (non-negotiable)

<!-- managed-by: evo-t1-coder-stack -->

These constraints apply to every change in this repository and to any repository this agent is
asked to convert. The full procedure is the `trunk-refactor` skill
(`skills/trunk-refactor/SKILL.md`, reachable as `/trunk-refactor`); the prose is
`docs/workflows/trunk-feature-flags-refactor.md`; the rule of record is `docs/branching.md`.

1. `main` is the only long-lived branch and is always deployable. A merge to `main` is a
   deployable state.
2. `development`, `staging`, and `production` are environments: a GitHub Environment with its
   secrets and protection rules, a compose project name plus env file, a namespace plus overlay,
   or an inventory group. They are never git branches, and a deploy job never selects an
   environment by branch name.
3. Work branches are `feat/`, `fix/`, `refactor/`, `docs/`, `chore/`, `ci/`, cut from the tip of
   `main`, merged by pull request, deleted on merge. Anything older than the agreed branch
   lifetime is a cleanup candidate, not a backlog.
4. Incomplete or experimental work lands on `main` behind a flag that defaults off. Use the
   first mechanism that fits, in this order: environment variable with a dotenv sample, compose
   `profiles:`, a checked-in `config/flags.yaml` (see `config/flags.yaml.example`), then the
   platform's own template or module parameters. A flag service, an SDK, or a flag table in a
   database needs an explicit operator request.
5. Every flag carries an owner and an expiry, is read at one seam, is exercised on and off by the
   gate, and is deleted with its off-path in a later `chore:` change.
6. Promotion applies the same commit or tag to a different environment. Two environments never
   build two artifacts.
7. Branch cleanup is part of the work: inventory every non-trunk branch, port what is valuable
   (behind a flag when it is unfinished), and present the rest for deletion with its tip SHA
   recorded.
8. Never force-push, never rewrite history on a shared branch, never delete a remote branch
   without explicit confirmation, never merge your own pull request.
9. No secret in a committed file - the flags file included. Samples carry key names and inert
   defaults; read a value with the operator CLI that prints it.
10. Keep the existing gates green (`bazelisk test //:test-fast`, `//:lint`, `//:test-all`) and
    extend a script or target that already exists. No new CI system, no new platform, no new
    dependency, and no Kubernetes.
