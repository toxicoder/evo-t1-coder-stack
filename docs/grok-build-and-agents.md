---
title: Grok Build, Coder Agents, and the workspace terminal
description: "What runs inside a workspace and in the Coder control plane: terminal profiles, the shared `~/.grok` profile, and where models come from."
tags: [grok, agents, workspace, mcp]
---

# Grok Build, Coder Agents, and the workspace terminal

**What's on this page**

- Terminal and editor defaults, and the profile the templates seed
- What `grok doctor` reports inside a workspace, and which findings are expected
- The Grok Build CLI in the golden image, and how it is pinned
- The rendered `~/.grok/config.toml`: model aliases and role fallbacks
- One shared profile volume per user, and what last-booted rewrites
- The search lane and the MCP servers behind it
- Coder Agents on the control plane and the model config it needs

**What this enables**

- Changing a model alias in one place and knowing which workspaces see it
- Explaining why one workspace's `~/.grok` disagrees with another's
- Knowing why the native `web_search` tool is parked and the SearXNG lane answers

Deep reference for what runs *inside* a workspace and in the Coder control plane: the
terminal profiles, the per-user `~/.grok` profile, where the CLI and the chat agent get
their models, and what the stack seeds for the agent.

Related: [coder-templates.md](coder-templates.md) (the template files themselves),
[litellm-routing.md](litellm-routing.md) (what the aliases route to), and
[troubleshooting.md](troubleshooting.md).

## Terminal and editor defaults

- `terminal.integrated.defaultProfile.linux` is `tmux`; the automation profile stays
  `/bin/bash`, so build and task commands never wait on tmux. Plain `bash` and **Grok
  Build** stay available as extra profiles.
- The `tmux` profile gives each terminal of a folder its own pane. The base session
  name is unchanged: `vscode-<folder>-<hash>`. A new terminal walks into one of
  that folder's sessions only while no client is attached to it, oldest first -
  that is the closed-tab rejoin, so a tab you closed or reloaded leaves its
  session unattached and the next terminal finds it with its history intact, and
  `ssh` + `tmux attach -t <session>` lands there too. A terminal opened when
  every session of the folder already has a client takes the next numbered
  sibling instead: `vscode-<folder>-<hash>-2`, `-3`, ... Sessions persist
  unattached until the container restarts, so a reattached terminal still
  reaches the output a closed tab produced. `tmux ls` lists the names and
  `tmux list-clients` says who is looking at each. Every target the helper
  gives tmux carries the `=` exact-match prefix (a bare name is answered by any
  session starting with it, so a closed `foo` could be answered by a live
  `foo-2` and re-create the mirror), and a reopen whose session vanished
  mid-attach raises a fresh session rather than exiting along with the tab.
  Two tmux behaviors shape that path: a session raised by a tab's own
  foreground `new-session` has its first pane closed when that client exits
  ([superuser#575909](https://superuser.com/questions/575909/optionally-run-several-commands-when-starting-tmux)),
  which is why the helper creates detached and attaches separately; and with
  the default `exit-empty` the server itself leaves when its last session does
  ([tmux#2081](https://github.com/tmux/tmux/issues/2081)), which is why a
  reopen probes the server before raising anything - a tab whose server is gone
  has ended normally, and re-raising there would boot a server for a terminal
  nobody is looking at (tmux has no server probe: `has-session` answers the same
  for a missing session and a missing server, which is why upstream declined to
  add `check-server`, [tmux#2523](https://github.com/tmux/tmux/issues/2523)).
  No upstream issue accounts for the session loss: `destroy-unattached` is off,
  so a detached session is meant to survive, and tmux gives a session no grace
  period after it loses its last client
  ([tmux#5821](https://github.com/tmux/tmux/issues/5821) is an open request for
  one).
- One pane per visible terminal is what that rule buys. Clients attached to one
  tmux session share that session's current window, so a design that always
  reattaches makes every extra browser tab a mirror of the same pane: another
  full xterm.js in the Chrome tab re-parsing the same stream (each holding a
  line-slot array sized from `terminal.integrated.scrollback`, with the cell
  data allocated per line as output arrives), and another full copy of the
  rendered stream through the pty. Measured on one flooding pane, 16 mirrors
  took 78.7 MB out of the server over an 8 s window where a single mirror took
  4.9 MB, while the server's own CPU only moved from 420 ms to 630 ms - it
  renders the pane once, so a mirror is paid for in the tab. A client
  activating or resizing repaints the window's other clients too. Measured on
  this workspace: 14 attached clients against 2 real panes. Two terminals
  opening in the same instant can still land on one session - that same
  mirror, and rarer than a keystroke.
- **An attached client is not the same thing as a viewer.** code-server's pty
  host keeps the pty open after the browser side of a tab goes away, so the tmux
  client stays attached, keeps its session's `session_attached` at 1, and
  receives nothing at all. Measured on this workspace's live server: 7 of its 9
  clients received 0 bytes across a 4 s window of continuous pane output while
  the 2 tabs actually on screen each received all 12858 of them, and the quiet
  ones had reported no input for 30 minutes to 36 hours. That number is the
  whole reuse decision in the attach helper, so one of these is enough to make a
  free session look watched forever, and the folder pays a new session for every
  later tab. Both helpers now sweep their own sessions for a client that has been
  quiet past a 6 h grace before they read the snapshot;
  `EVO_TMUX_STALE_AFTER` (seconds) moves the number. Seeing the state yourself:

  ```sh
  # Two reads a few seconds apart: a client whose written count does not move
  # while its pane produces output has stopped being a viewer.
  tmux list-clients -F '#{client_activity} #{client_written} #{client_tty} #{session_name}'
  ```

  Detaching one needs its tty: this tmux 3.4 answers `detach-client -t` for a
  `/dev/pts/…` path, refuses a pid with `can't find client`, and has no
  `kill-client` command at all.
- **Grok Build** keeps its own session, keyed off the repository: the helper walks up
  from the terminal's folder with `git rev-parse --show-toplevel` (or uses the
  terminal's `$PWD` outside a clone), names the session `grok-build-<folder>-<hash>`
  after that root, and runs `grok --cwd <repo root>` inside it. A terminal opened
  anywhere inside the clone rejoins the one session the repository shares, and starts
  Grok Build at the repository root. That profile is deliberately the old
  always-reattach shape: watching the same agent run from several tabs is the
  feature, and the mirrors pay what mirrors pay. What the seed gives them is
  `focus-events on`, so a TUI in the pane can idle its animations while its tab
  is blurred, and `escape-time 10`, which keeps typing responsive on each of
  them. Two things it does borrow from the attach helper: the session is created
  detached and attached in a second call, because the tab that brings the server
  up is otherwise the one that can take a running agent down with it (the same
  9-of-20 loss the helper documents), and the stale viewers above are detached on
  the way in, which is where the 8-clients-on-one-pane count came from.
- With no tmux (offline first boot) the helper execs a plain login shell, so the
  default terminal still opens.
- `display_apps.web_terminal` stays **off**: it would open a shell on the agent's
  working dir (`/home/coder`). A custom command-type `coder_app` named **Web
  Terminal** (`order = 6`, after **VS Code Web** at `order = 5`, before **GitHub
  reauth** at `order = 7` and **Install GitHub App** at `order = 8`) takes that slot,
  `cd`s to the clone folder - an empty `repo_url` keeps it on `/home/coder` - and
  execs a login shell. Like the built-in, it reads no `terminal.integrated.*`
  settings.
- Neither template installs code-server through the Registry. Each `main.tf` carries
  an inlined fork (`coder_script.code_server` + `coder_app.code_server`), because the
  upstream module hardcodes `/icon/code.svg` and has no icon input. Both twins pin the
  release in one `code_server_version` local and pass it to the upstream installer as
  `--version`: without that flag `https://code-server.dev/install.sh` follows `latest`,
  and the editor would move under every workspace with no commit in this repo.
  `workspace` installs code-server only while that pinned release is missing from
  `/home/coder/.local/share/code-server` (the guard names
  `lib/code-server-<version>/bin/code-server`, the directory the installer unpacks, not
  the `bin/code-server` symlink, which points at the last release installed and would
  hold a warm volume on its first one) and starts it with `--auth none --port 13337
  --app-name "VS Code Web" --ignore-last-opened <folder>`, passing no settings payload.
  `devcontainer` has no persistent prefix to reuse, so it installs the pinned release
  fresh under `/tmp/code-server` on every start.
- The editor opens on `http://localhost:13337/?folder=<urlencoded>`: the
  `coder_app` resource in `coder/coder` `~> 2.18` has no `folder` argument, so the
  folder rides in the URL and as a positional argument to the code-server binary
  with `--ignore-last-opened`. `workspace` uses `/home/coder/workspace/<repo>` (and
  `/home/coder` with no repository); `devcontainer` uses `/workspaces/<repo>` inside a
  built dev container and `/srv/coder-devcontainers/<workspace-id>/<repo>` on the
  plain container. On first start the inlined `coder_script.code_server` creates that
  folder and waits up to 60 s for `.git` (skipped when the folder is `/home/coder`) so
  the clone can land before code-server launches. `coder_agent.dir` stays unset: the
  agent would chdir there before `startup.sh`, and a missing clone folder would fail
  the agent. With the sample `REPO_URL` that folder is
  `/home/coder/workspace/evo-t1-coder-stack`.
- The icon travels as a `data:image/svg+xml;base64` data URL read from
  `templates/common/vscode-alt.svg`: Coder serves icons only from its bundled
  `/icon/*` set or a full `https`/`data` URL, and that icon is not bundled.
  `workspace_apps.icon` is `varchar(256)` on Coder v2.36, so the SVG is a compact
  ribbon whose data URL fits that column; a larger file fails `templates push`
  with `pq: value too long for type character varying(256)`.

### Copy and paste between a tmux pane and the machine you type on

One clipboard is in play: the one on the computer you are typing on. The seed runs
`set -g mouse off` and unbinds every key and every click that could move text into
or out of tmux's own buffer, so the terminal client keeps each button and does the
copying itself, the way it does in a native terminal on that machine. OSC 52 is the
one route that still depends on what sits at the other end of the terminal, and it
belongs to an app inside the pane rather than to the operator. Where each claim
below comes from: the tmux ones were read off the shipped tmux 3.4 on this box (what
an attach writes to the client, and what `list-keys` still holds once the payload is
sourced), and the setting names, values and defaults were read out of the shipped
code-server 4.145.0's own config registry (VS Code base 1.145.0). The two
Clipboard-API observations -- that a client selection fires
`navigator.clipboard.writeText`, and that `document.execCommand('copy')` is the
fallback that still lands on an insecure origin -- come from the earlier
headless-Chromium pass over that build with the rendered `settings.json` twin and the
tmux payload loaded, when `mouse` was still on and the copy out was a Shift+drag.
That path is the client's own selection, which is what a plain drag drives now; the
plain drag is due the same pass before it is restated as measured under `mouse off`.

- **Out of a pane: drag, and it is already on the clipboard.** tmux asks the outer
  terminal for mouse reporting only while `mouse` is on: measured on tmux 3.4, an
  attach with `mouse on` writes `ESC[?1000h`, `ESC[?1002h` and `ESC[?1006h` to the
  client, and an attach with it off writes none of them. With the seed's
  `mouse off` tmux never sees a button, so a plain drag is the client's own
  highlight and the seed's `terminal.integrated.copyOnSelection: true` puts that
  highlight on the machine clipboard with no chord (the harness recorded
  `navigator.clipboard.writeText` firing on a client selection, before this switch).
- **Right-click and middle-click paste that clipboard.** The seed sets
  `terminal.integrated.rightClickBehavior: "copyPaste"` - copy while there is a
  selection, paste when there is none - and pins
  `terminal.integrated.middleClickBehavior: "paste"`, because the config registry in
  the shipped 4.145.0 gives that setting the default `"default"`, which pastes only
  on the Linux build. tmux has no middle-click paste of its own to answer first:
  `MouseDown2Pane` is unbound in the root table.
- **tmux keeps no buffer, so there is nothing to paste out of one.** `Prefix-[`
  still enters vi copy-mode and it is a viewer: the cursor keys, `PPage`/`NPage`,
  `Ctrl-u`/`Ctrl-d` and `k`/`j` walk history, `q` leaves, and `Escape` clears a
  selection. Every copy that used to end a selection is unbound - Enter, `C-j`, `D`,
  `A`, the word and line copies a double- or triple-click fires, the copy a drag
  release ran, and the `y` the earlier seed bound itself - along with the prefix
  paste `]` and the buffer picker `=`. Selecting inside copy-mode with `Space`, `V`
  or the cursor keys stays bound and is inert, with no copy command left for it to
  end on. Proof: sourcing the payload on a scratch server leaves `list-keys` with no
  copy command in `copy-mode-vi`, no `paste-buffer` or `choose-buffer` in `prefix`,
  and no `MouseDown2Pane` in `root`. The pointer's other jobs keep their prefix
  keys: `Prefix-o` or `Prefix-q` to select a pane, and `Prefix-Alt-arrow` to resize
  (plain `Prefix-arrow` selects a pane in the shipped 3.4's own default table).
- **`Prefix m` is the wheel, not a copy route.** One press hands the pointer to
  tmux so the wheel walks pane history, the next hands it back. It is the escape
  hatch for a long scroll, because tmux paints in the alternate screen - it sends
  `ESC[?1049h` either way - so the client holds no scrollback of its own and a wheel
  over a pane has nothing to walk. Output that has scrolled away is copied by
  bringing it on screen first: `Prefix-[`, scroll it into view, select it with a
  client drag, `q`. A drag while `Prefix m` has the pointer on selects nothing,
  since the copy bindings stay unbound either way.
- **An app inside the pane drives the machine clipboard over OSC 52; the browser
  build drops it.** `set -g set-clipboard on` with `set -g allow-passthrough on`
  stay in the seed for that one route: vim's `+` register, and anything else that
  emits the escape, reach the machine clipboard the way a native terminal hands them
  to it. Over ssh from Ghostty, kitty, WezTerm or iTerm2 that copy lands.
  code-server's browser build drops the escape before any clipboard call: a
  hand-written `printf '\033]52;c;<base64>\a'` was just as silent with
  `set-clipboard off` as with it on, which puts the drop in the browser and not in
  tmux. Upstream
  [microsoft/vscode#318254](https://github.com/microsoft/vscode/issues/318254) is
  open with two unmerged fixes, and the shipped 4.145.0 registers no OSC 52 setting
  at all, so there is nothing here to turn on. Nothing on the tmux side can spoil
  that clipboard either: tmux has no copy left to send, so an accidental selection
  in the pane cannot overwrite what the client just put there.
- **Into the pane: `Ctrl+Shift+V` or right-click, on a secure context.** Both
  arrive bracketed (`ESC[200~ ... ESC[201~`) in a bash terminal and in a tmux
  pane alike, and a three-line paste arrives whole without a warning dialog. Both
  chords ask the browser's clipboard API, which the browser only exposes to a
  secure context, so the URL the tab was opened on decides it. On the TLS public
  name they work; on `http://<LAN-address>` `navigator.clipboard` is absent,
  right-click stops with VS Code's own toast ("This browser doesn't support the
  clipboard.readText API needed to trigger a paste, try Ctrl+V instead."), and
  the browser's native paste event is what still delivers. A Clipboard site
  permission that was once denied breaks both API chords the same way, with
  `NotAllowedError: Read permission denied`. Neither is a tmux route: the prefix
  paste `]` and the buffer picker `=` are unbound, so the client's own clipboard is
  what arrives in the pane.
- **`Ctrl+V` on a secure origin is not a paste.** VS Code binds terminal paste to
  `Ctrl+Shift+V` on Linux and `Cmd+V` on macOS, so `Ctrl+V` reaches the pane as
  the `\x16` byte (readline's quoted-insert, vim's visual-block). The seed
  re-binds nothing there on purpose: a TUI in the pane owns that chord.
- **Two scroll-back stores, two different budgets.** `terminal.integrated.scrollback`
  in the settings seed is the xterm.js buffer, which is what a plain `bash`
  profile scrolls through; tmux's `history-limit` is what `Prefix-[` walks
  inside a pane. They read 2000 and 100000 lines here, and the two numbers
  differ on purpose because the two stores are billed differently. What VS Code
  preallocates from the setting is the buffer's array of line slots - xterm.js
  builds `new Array(rows + scrollback)` for it up front
  ([CircularList.ts](https://github.com/xtermjs/xterm.js/blob/master/src/common/CircularList.ts),
  [Buffer.ts](https://github.com/xtermjs/xterm.js/blob/master/src/common/buffer/Buffer.ts))
  - and the cell data lands one `BufferLine` at a time as output arrives, at
  3 `Uint32` words per column per line
  ([BufferLine.ts](https://github.com/xtermjs/xterm.js/blob/master/src/common/buffer/BufferLine.ts)),
  against a VS Code default of 1000
  ([terminalConfiguration.ts](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/terminal/common/terminalConfiguration.ts)).
  So the setting costs a pointer array per terminal in the tab either way, and
  real memory only for the lines a pane actually emits - which is why a busy
  build log is where a large value is felt, and an idle prompt is not. tmux
  holds its history once per pane, in the server, and every client of that pane
  shares the one buffer. Hence the split: the deep store is tmux's and the
  browser keeps a short viewport. Inside a tmux pane the client's wheel has nothing
  to walk - tmux paints in the alternate screen, so that buffer holds no pane
  history - and the 100000 lines live behind `Prefix-[`, paid for in the server and
  not in the tab. Measured on tmux 3.4 with one pane pushed to its limit, 100000
  lines of 120-column output holds the tmux server at 381 MB RSS; the same 100000
  lines of plain 80-column output costs 60 MB. The same sweep repeated at 120
  columns came out close to linear at about 3 KB of server per history line -
  10 MB at 2000, 35 MB at 10000, 160 MB at 50000, 308 MB at 100000 - so this is
  the one terminal number that turns a chatty pane into real container memory,
  and it is a deliberate trade: the deep store is what lets `Prefix-[` still
  reach the start of a build. tmux reads `history-limit` when a pane is created,
  so an existing pane keeps the number it was born with.

### `grok doctor` findings in a workspace

`grok doctor` checks terminal, clipboard and microphone support without starting a
session, and `/doctor` inside a session adds the checks that need a live one. Each
item in the **Findings** list carries its own fix, and `--json` prints the same
report for a script. What the report should read here:

- **tmux options.** `templates/common/tmux.conf` seeds the four options Doctor's
  own fixes write, `set -g set-clipboard on`, `set -g allow-passthrough on`,
  `set -g extended-keys on` and the `*:RGB` `terminal-features` entry, plus the
  `xterm*:extkeys` entry Doctor leaves to the operator. Those last two decide
  what survives the multiplexer: tmux rewrites 24-bit color down to the palette
  an attached client advertises, which is what makes a theme look washed out in
  the browser, and extkeys is what makes Shift+Enter and Ctrl+. arrive distinct
  from Enter. A client picks up `terminal-features` when it attaches, so after a
  reseed run `tmux source-file ~/.tmux.conf` and then detach and reattach
  (a `refresh-client` keeps the client on its old features). Proof:
  `tmux display -p '#{client_termfeatures}'` lists `RGB` and `extkeys`.
  `tests/bats/tmux-fidelity.bats` boots a scratch server on the seed and reads
  all of it back.
- **`terminal.limited-color` during an agent turn.** A tool command launched by a
  running Grok session inherits `NO_COLOR=1`, `FORCE_COLOR=0`, `CLICOLOR=0` and
  `CARGO_TERM_COLOR=never` from that session, so a `grok doctor` run from inside
  an agent turn reads color as off. The `grok` process itself and the tmux server
  carry none of those variables, so run it from a plain terminal for the real
  capability: the line reads `color truecolor` and `themes all`.
- **`voice.no-input-device`.** Expected in a workspace. The container has no
  capture device at all (`/dev/snd` and `/proc/asound` are absent) and no
  recorder on PATH. The probe only looks for a recorder binary, so installing
  `alsa-utils` moves the line to `available` while capture still has nowhere to
  read from, and `features.voice_mode = false` leaves the finding in place.
  Neither would be a fix, so the stack ships neither and the finding stands as an
  accurate report of a headless container. Dictation belongs on a laptop-side
  `grok`. To give a workspace dictation instead: run PulseAudio on the workstation
  with its TCP module enabled, export `PULSE_SERVER=tcp=<workstation>:4713` into
  the workspace, and install `pulseaudio-utils` there for `parec`.
- **`terminal.ssh-wrap`** is a recommendation about the computer you type `ssh`
  on, since the wrapper has to sit in front of that client: run
  `grok doctor fix ssh-wrap` there, or `grok wrap ssh <host>` per connection. It
  forwards copies to the local clipboard and restores terminal modes when the
  link drops. `/settings` -> **Show contextual hints** -> **SSH wrap** silences
  the tip.
- **`unavailable` tmux and runtime probes.** `tmux.version`,
  `tmux.client-features` and the `runtime.*` lines come back `unavailable`
  whenever Doctor has no interactive client of its own, which covers a piped run
  and a run from an agent tool call. Read them by hand (`tmux -V`,
  `tmux display -p '#{client_termfeatures}'`) or from `/doctor` in a live
  session.

## The Grok Build CLI in the golden image

- Baked in at `/usr/local/bin/grok`, with an `agent` link beside it, **outside** the
  `/home/coder` home volume, so a rebuilt volume cannot lose it.
- Pinned as `GROK_VERSION` in `images/dev/tool-versions.env` (1.0.77 at the time of
  writing, mirrored as the Dockerfile `ARG` default). The image build unpacks that
  pinned `.zst` and runs `grok --version` in two PATH contexts as a build-time smoke
  check.
- Each template's startup script probes `command -v grok` on every start and
  re-downloads from `https://x.ai/cli/install.sh` - bounded, with retries - only
  while `grok` is missing from PATH. That installer follows the `stable` pointer, not
  this pin. It deliberately does **not** fetch on every boot: the bake-in under
  `/usr/local/bin` is the upgrade path, so shipping a new CLI means bumping the pin,
  rebuilding the image (`bazelisk run //scripts:build-dev-image`) and re-pushing the templates.
- A self-installed CLI under `~/.grok/bin` stays first on the login-shell PATH, so it
  wins over the baked copy.
- **No published source names an upstream `/learn`, and the bundled skill set never
  lands here**: the `xai-org/grok-build` built-in command table, all 240 pages of
  docs.x.ai, every first-party changelog under `x.ai/cli/changelogs/`, and the public
  `xai-org/plugin-marketplace` catalog carry zero occurrences of it. The bundled
  platform skills are a separate set, enumerated by
  `FORMER_PLATFORM_SKILL_HASHES` in `crates/codegen/xai-grok-shell/src/builtin.rs`
  (help, imagine, create-skill, check-work, check, xlsx, pptx, docx, code-review,
  best-of-n, create-workflow), and neither `learn` nor `skillify` is among them. That
  set is downloaded at runtime through the CLI's proxy endpoints config
  (`cli-chat-proxy.grok.com`, gated by `GROK_SKILLS_BASE_URL`) and needs an x.ai
  sign-in: the upstream `product_skills*` fetch in
  `crates/codegen/xai-grok-shell/src/session/slash_commands.rs` is gated on
  `xai_grok_login::GrokAuth`. This stack has no x.ai credential:
  LiteLLM is the sole model transport, with `env_key = "LITELLM_API_KEY"` and
  `base_url` `http://host.docker.internal:4000/v1`, so `~/.grok/bundled/` is never
  created and there is no bundled copy for `grok inspect` to label. The one surface
  nobody can read anonymously is the authenticated skills feed (`x.ai/skills/*` answers
  403), so the honest claim is that no published source names `/learn`, not that it
  cannot exist behind that feed. Nothing writes `~/.grok/skills/` either, but
  that is a stack choice, not a CLI limit: the upstream user guide
  (`crates/codegen/xai-grok-pager/docs/user-guide/08-skills.md`) documents both tiers -
  `~/.grok/skills/` is the User scope and `<repo_root>/.grok/skills/` the Repo one, and
  `grok inspect` labels each definition by its actual source (`user`, `project`,
  `bundled`) - and startup discovery skips project skills and commands in untrusted
  folders, so a project-tier folder has to be trusted first or its skill is withheld.
  What separates the two consumers is that the **Coder Agents** chat agent reads
  `~/.coder/skills/` only, so reaching both means shipping both homes.
- **The stack ships its own three skill commands as `/ez-learn`, `/ez-skillify` and
  `/ez-create-skill`**, so they are stack payloads like the delegation skill, not something
  to install, and the `ez-` prefix keeps them clear of the upstream names they sit
  beside: `/create-skill` is one of the CLI's bundled platform skills and
  `/flush`, `/dream`, `/remember`, `/memory` are its built-in memory commands, while no
  published source names a `/learn` or a `/skillify` at all. A user-scope skill overrides
  a same-named bundled one, so a seed named `create-skill` would have hidden the bundled
  copy.
  `/ez-learn` writes memory files - it reproduces the upstream `/flush`, `/dream`,
  `/remember` and `/memory`; the other two write skill files.
  The three payloads - `templates/common/ez-learn.SKILL.md`, `ez-skillify.SKILL.md` and
  `ez-create-skill.SKILL.md` - are seeded at workspace start by
  `coder_script.stack_skills`: each is written into `~/.coder/skills/<name>/SKILL.md` and
  twin-copied to `~/.agents/skills/<name>/SKILL.md`, each only while that file is absent.
  To take a
  copy over, edit it and delete the `managed-by: evo-t1-coder-stack` marker line: a
  marker-free file is user-owned, and the seeder leaves it alone unless you pass
  `--force`. A deletion is undone - the boot writes the file again whenever it is
  absent, and `refresh-configs` re-seeds an absent target, so the next boot restores
  the stack's copy. To hide the slash command, set `disabled = ["ez-learn"]` under
  `[skills]` in `~/.grok/config.toml`. A seeded `SKILL.md` shows up in
  `grok inspect --json` as `userInvocable: true`, and a live session advertises it in
  both `slash_commands` and `skills`, so it works on whichever CLI the image baked at
  `/usr/local/bin/grok` and this needs no image rebuild; the **Grok Build** terminal
  profile gets it because that profile execs the same binary.
- **The stack ships its own three repository-conversion commands as `/ez-bazel-first`,
  `/ez-strong-types` and `/ez-trunk-based-repo`**, and these stand in for nothing upstream:
  they convert whatever repository the workspace happens to hold, which is why they carry no
  path that only exists in this stack. They are seeded the same way, by
  `coder_script.stack_repo_skills`, from `templates/common/ez-bazel-first.SKILL.md`,
  `ez-strong-types.SKILL.md` and `ez-trunk-based-repo.SKILL.md`, plus the three python
  helpers they shell out to. Same absent-only contract, same marker-based takeover rule,
  same `[skills] disabled` escape hatch.
- **A leftover `/learn` seed retires itself.** This skill was seeded under the name
  `learn` until it moved, and a copy left standing keeps offering that old name beside
  `/ez-learn` for the life of the volume; there is no bundled `learn` for it to hide,
  because no published source names one. Both startup scripts delete
  `~/.coder/skills/learn/SKILL.md` and `~/.agents/skills/learn/SKILL.md` and prune the
  directory each leaves, but only while the file still carries the
  `managed-by: evo-t1-coder-stack` marker; a marker-free `learn/SKILL.md` is user-owned
  and stays. `refresh-configs`, `storage-clean` and `seed-dev-env` retire the same two
  paths on reseed. That removal only finishes the rename: there is no upstream `/learn`
  waiting on the name, because no published source names one.

## The rendered `~/.grok` config

Rendered per workspace from `templates/workspace/grok-config.toml.tftpl` (and
`templates/devcontainer/`'s copy of the same payload), and re-rendered idempotently
while the managed block is intact.

- At top level the render sets `disable_web_search = true`, which parks Grok's native
  `web_search` tool: no transport this box ships serves that tool type, so the
  self-hosted `searxng` MCP server is the search lane. The search lane section below
  carries the measurement and how to flip the key back.
- `[models] default` points at the `grok_default_model` alias - `agent` unless the
  template variable or the create form's **Grok default model** dropdown names
  another. `[models] default_reasoning_effort = "xhigh"`. The Spark lane answers
  `low` / `medium` / `xhigh`; `high` is never advertised.
- The seven aliases (`agent`, `agent-low`, `agent-medium`, `agent-xhigh`, `coder`,
  `coder-fast`, `chat`) are defined with `base_url` set to `litellm_url` and
  `env_key = "LITELLM_API_KEY"`. The key is injected as an environment variable, so
  it never appears in a file. `agent` carries three
  `[[model."agent".reasoning_efforts]]` tables (`xhigh` is the default). The
  `agent-low` / `agent-medium` / `agent-xhigh` aliases set
  `supports_reasoning_effort = false` because LiteLLM bakes the level for callers
  that have no reasoning-effort field.
- `[models]` also carries `extra_headers` with
  `x-litellm-session-id: ws-<workspace-id>` - the key LiteLLM uses to pin a
  workspace's traffic to one healthy Spark box. Under a shared profile the
  last-booted workspace's key wins for the whole fleet.
- `github_mcp` (default `true`, so the block renders unless you park it with
  `GITHUB_MCP=false` and re-push) adds the `github` HTTP MCP server
  (`https://api.githubcopilot.com/mcp/`), whose `Authorization` header references
  `${GH_TOKEN}` **by name**, so no token value is ever part of a template variable.
  The agent environment fills it from the Coder External Auth provider (id `github` by default); a
  workspace whose owner connected no GitHub account renders the block anyway and pays
  one failed handshake per session.
- `context7_mcp` (default `true`, parked the same way with `CONTEXT7_MCP=false`) adds
  the cached `context7` stdio MCP server. Grok launches
  `/opt/npm-global/bin/mcp-cache-proxy` with
  `--config /home/coder/.grok/mcp-cache-proxy/config.json`, and that proxy fronts the
  official `/opt/npm-global/bin/context7-mcp`; both are pre-installed in the golden
  image, so nothing is fetched with `npx` at launch. The proxy config names
  `$CONTEXT7_API_KEY` and nothing else: the key reaches the workspace environment from
  the sensitive template variable `context7_api_key`, filled by the push from
  `CONTEXT7_API_KEY` in the host `.env` - not from Coder External Auth, which is what
  fills `GH_TOKEN` above.
- `grok_config_extra` appends whatever the create form's **Grok config extras** field
  holds, verbatim under its own comment header.
- `[permission]` holds the guardrails the stack owns; the approval mode itself stays
  a per-user call (`[ui] permission_mode`). `Bash(rm -rf *)` blocks the destructive
  form, and the dotenv family is split by what a file actually holds: the live
  `.env` and the populated suffixed shapes (`.env.local`, `.env.*.local`,
  `.env.production` / `.env.prod`, `.env.staging` / `.env.stage`,
  `.env.development` / `.env.dev`, `.env.test` / `.env.testing`, `.env.ci`,
  `.env.override`) are denied for `Read` and `Edit`, while the secret-free
  templates a repo ships (`.env.example`, `.env.sample`, `.env.template`,
  `.env.dist`, `.env.defaults`, plus the `.env.*.example` / `.env.*.sample`
  spellings) are named in `allow`, so an agent maintains the env key list without a
  prompt in any mode. Neither list is the old blanket `**/.env.*`: deny outranks
  allow, so the blanket form blocked the templates along with the live files and
  left the key list -- the file that keeps a real `.env` honest -- to drift.
  `.gitignore` carries the matching half on the git side: the whole family is
  ignored except the names `allow` lists.
- `allow` also carries the verbs the branch-first, commit-per-unit policy needs:
  `Bash(git switch *)`, `Bash(git checkout -b *)` and `-B`, `Bash(git add *)`,
  `Bash(git commit *)`. A grant that cannot be had is how that policy fails quietly:
  an unattended run (`grok -p`, how the delegation skill launches its children)
  answers "headless run cannot ask for approval" and drops the call, so a child
  would finish a whole task with its work uncommitted. Everything on that list is
  local to the checkout and undone by another git command. `git push` is absent on
  purpose - the one step that leaves the machine keeps a human in it - and so is
  anything that can lose work (`git branch -D`, `git restore`,
  `git reset --hard`). The deny side closes the two ways a commit could land with
  no gate having seen it: `Bash(git commit --no-verify *)` / `-n`, past the
  hermetic pre-commit hook, and `Bash(git add -f *)` / `--force`, past
  `.gitignore`. Both are prefix globs, so they narrow that door rather than seal
  it, and the `Stage by path` rule in the seed text is the rest of the defence.
- `Bash(rm -rf *)` is a prefix glob, so it catches a benign per-path scratch cleanup
  along with the destruction it is there to prevent. Agents run into that constantly:
  across 271 workspace sessions, 86 recorded at least one denied tool call and 56
  attempted an `rm -rf`, and 55 sessions did both. The shapes that are never denied
  are per-path deletions - `find <dir> -type f -delete`, or `rm -f` naming each path -
  so clean scratch that way. An `allow` entry cannot rescue `rm -rf`, because deny
  outranks allow. Narrowing the pattern is an operator call and a deliberate one: it
  is the only thing between an agent and a recursive delete on a path it got wrong.
- The self-teardown family is denied alongside it, because an agent that closes its own
  terminal cannot finish the task that closed it. `tmux kill-server` / `kill-session` /
  `kill-window` / `kill-pane` / `restart-server`, `pkill` and `killall` naming `tmux`,
  `node`, `code-server`, `grok` or `bash`, those killers aimed at a whole user or parent
  (`pkill -u`, `-U`, `-P`), and the shell forms that signal a whole process group
  (`kill 0`, `kill -- -<pgid>`, `kill -9 -1`) each match a `deny` rule. The reason is the
  shape of the workspace: the Bash tool runs inside the tmux session the agent was
  launched in, so a sweep that tidies up "stray" sessions or processes takes the agent,
  its tool shell and the in-flight reply down together, and the editor tab dies with
  `terminated with exit code: 1` over work left half-done. An agent stops one process it
  started with the `kill_command_or_subagent` tool; bringing down a whole tmux server or
  editor host stays an operator call. These are globs over the parsed command text, so
  an abbreviated tmux verb (`tmux kill-sess`) or a bracketed pattern (`pkill -f [t]mux`)
  walks past them - the seed rule that names the prohibition is the other half, and the
  plain `bash` profile is how a session reaches a shell once they are all gone.
- Stack ownership of the file rests on either marker spelling: the line-1
  `managed-by: evo-t1-coder-stack` comment or the top-level `__evoT1Stack = true` key.
  Both twins emit both, because the comment alone does not last - `grok mcp add`
  persists its own settings by rewriting the file and deletes every comment line, so a
  comment-only marker handed the config to the user with no human in the loop, and the
  default lanes silently stopped arriving. A hand-edited config is left alone only
  while it carries one of them, so takeover means deleting **both** lines; delete the
  file and restart to hand it back. When the guard does re-render, the CLI-owned tables
  `[cli]`, `[ui]` and `[marketplace]` are carried over rather than wiped, because the
  stack owns no approval mode - `[ui] permission_mode` / yolo stays a per-user call.

## Grok Build state: one shared profile per user

Every workspace gets its own `/home/coder` volume, and `~/.grok` is a **second,
nested** mount inside it: a Docker volume named `grok-profile-<owner-id>`,
referenced by name rather than declared as a Terraform resource, which every
workspace of that owner mounts read-write at the same path **while that workspace is
in `shared` mode**.

### The two modes

- `shared` (the default here, so a workspace gets the profile unless you turn the
  mode off): configure the CLI once and the rest of that account's workspaces
  inherit it.
- `private`: that workspace's `~/.grok` - `config.toml` included - lives on its own
  home volume, differs from its siblings, and dies with the workspace (or survives a
  rebuild on the same volume).
- Set in two places: the template variable `grok_profile_mode`
  (`GROK_PROFILE_MODE=shared|private` in `.env`, forwarded by `push-template.sh` as
  `--var grok_profile_mode`), and the create form's per-workspace **Grok profile**
  field, which defaults to the variable. One workspace can therefore sit outside the
  shared profile while its siblings stay inside it.
- Changing the mode needs a **rebuild** - the nested mount either exists or it does
  not. A workspace that goes from `shared` to `private` starts on an empty profile:
  nothing is copied, and the shared volume is left alone.

### What is shared

In `shared` mode: `config.toml`, `skills/`, `memory-v2/`, `sessions/`, `notes/` (the
canonical copy of each repository's private scratch `notes.md`), and a CLI you
installed yourself under `~/.grok/bin`. The CLI's own skill directories, `skills/` and
`bundled/`, are never created here without an x.ai sign-in; the stack's skill seeds
live under `~/.coder/skills` and `~/.agents/skills`, outside this volume.

`notes/<host>/<owner>/<repo>/notes.md` is keyed per git remote, so every clone a
workspace holds — the primary and each additional repository — has its own file. What you
edit is the regular file at the clone root: that is what the editor, the terminal and a
nested dev container all see, since the inner container mounts the clone bind and has
its own `~/.grok`. The copy runs both ways, and not only at boot. Startup copies the live
file here and restores it when a recreate leaves the clone with nothing or with only the
seeded stub line, and then leaves **one background watcher per container** that repeats
the back-copy about every 30 seconds (`NOTES_SYNC_INTERVAL`, in seconds) over every clone
under `$HOME/workspace`; the devcontainer template watches its `/srv/coder-devcontainers`
bind root instead, since those clones sit there rather than under the workspace home. The
watcher is single-instance behind a non-blocking `flock` on `$HOME/.notes-sync.lock`, in
the container's own home rather than the shared volume, because each of the owner's
workspaces needs its own.

That is what makes "survives workspace recreate" true rather than a hope: an edit is on the
volume within roughly one interval, so a recreate no longer waits on someone restarting the
workspace to pick up what was typed since the last boot. What is not promised is the tail
- a file written in the last two seconds is left for the next tick, because copying it
whole could archive a half-saved file. Going the other way, two guards stop a recreate from
erasing notes: a live file that is empty or still holds only the seeded stub never replaces
a canonical copy carrying real notes, and a real canonical copy restores over such a stub
in a clone. Before any substantive canonical copy is replaced it is archived as
`notes/<host>/<owner>/<repo>/backups/notes-YYYYmmdd-HHMMSS.md`, keeping the newest
`NOTES_BACKUP_KEEP` (10 by default), and that directory is where an operator recovers notes
after an accident. `grok_profile_mode=private` mounts no shared volume, so those notes die
with that workspace; `shared` is the default. Like `config.toml`, the last workspace
started for a given user and repository wins.

Two things about that start are worth knowing before you go looking for a vanished
setting. Boot **writes `git config --global core.excludesFile`** — but only when you
have not set it yourself. Left unset it points at `~/.grok/notes/exclude`, which lists
`notes.md` and `.scratch-notes.md`, so from then on *every* git repository in that
workspace ignores both names at any depth; if you already set the option, those two
lines are appended to the file it names and nothing else about it is touched. Boot also
drops the same two lines into each clone's own `.git/info/exclude`, which is the layer
that works even with no global config at all. And when a repository tracks a `notes.md`
of its own, the scratch file is written as `.scratch-notes.md` beside it instead — your
clone is never asked to delete somebody else's committed file.

### Caveats, honestly

- Keyed by **owner id**, never host-wide and never cross-user: another user's
  workspace mounts a differently named volume, and a stop or start of a *different
  user's* workspace never sees the volume at all.
- The memory and index files are SQLite, opened live by every workspace holding the
  mount, so two workspaces writing memory at once can race. *Roughly in sync* is the
  bar, not transactional sharing.
- Two workspaces of one owner that both hold a clone of the *same* repository each run a
  notes watcher over the same canonical path, so there too the last write wins, tick by
  tick. The stub and empty guards and the `backups/` archive are what bound the damage a
  losing tick can do; they do not merge two diverging files.
- One shared profile is one `config.toml` for every workspace that owner owns, and
  the last boot to re-render it wins - for the default model, the affinity key and
  the config extras alike.

## Search lane and MCP servers

- `searxng` (SearXNG metasearch, host port 8181) is the search backend the stack runs
  for itself: keyless engines only, no key, no account, no request logging. A
  workspace reaches it through the host gateway, so the workspace networks stay
  untouched.
- It is **not** a model transport, and the native tool is parked: both twins render
  `disable_web_search = true` at top level, so a session starts with no `web_search`
  tool at all. Measured 2026-10-25: no model transport this box ships serves that
  tool type. The `agent` group is LiteLLM in front of the Spark boxes
  (`openai/Qwen3.8-Flash-Next`), and it refuses the request before anything is
  fetched - `tools of type 'web_search' are not supported: this server runs function
  tools only`, HTTP 400. `supports_backend_search = false` does not route around it,
  because the client-side fallback still hands the model alias a `web_search`-typed
  tool, which is the exact shape that endpoint rejects. The fallback lane fails too:
  it is the `coder` alias, Ollama `qwen2.5-coder:32b`, and that model is not pulled on
  the host. So `web_search = "agent"` and `supports_backend_search = false` stay as
  they are - the role stays filled so re-enabling is a one-key flip - but while the
  key reads `true` nothing dials it.
- The `searxng` MCP stdio server is what answers instead, and it is the search lane
  rather than a fallback: both templates render that block gated on `search_mcp`,
  which defaults to true. It dials `$SEARXNG_URL` (default
  `http://host.docker.internal:8181`), the same key `main.tf` puts in the agent
  environment. It carries nine tools - `search`, `image_search`, `news_search`,
  `video_search`, `music_search`, `paper_search`, `fetch_content`, `autocomplete`,
  `list_engines` - and an agent's two workhorses are the first and the seventh:
  `search` for anything that is not a library question, `fetch_content` for a URL
  already in hand. Measure the self-hosted lane with:

  ```sh
  bazelisk run //scripts:search-check
  ```

  An empty result page and "no answer" are different answers, which is why the probe
  reports which one it got. It also names every engine the instance has parked and
  the reason its backend gave (`parked by its backend: google: access denied`),
  read out of the reply body whether or not that reply found results - an instance
  running on half its engines is visible there before it starts answering empty. A
  park is temporary: SearXNG holds an engine out for `search.suspended_times`
  seconds after it refuses, so re-run before writing one off. `--json` adds
  `engines_parked`. It checks the service hop; `grok mcp doctor searxng`
  inside the workspace checks the MCP hop. The binary it launches
  (`/opt/npm-global/bin/searxng-mcp-server`) is baked into the golden image, so a
  probe that answers with results plus a failed handshake is a server, URL or port
  problem, not a missing package.

- To put native search back on a transport that really serves the tool: flip the key
  to `false` in the seed - both `templates/workspace/grok-config.toml.tftpl` and
  `templates/devcontainer/`'s copy - and re-push, which applies it fleet-wide. For one
  workspace without a push, the create form's **Grok config extras** field appends
  free-form TOML verbatim to that workspace's file. Either way start a new session,
  and expect the same 400 back if the endpoint still answers function tools only.

- **MCP servers: the default render declares three - `github`, `context7` and the
  gated `searxng` server, which is the search lane itself.** Each is a boolean gate in
  the template, so one env flag parks exactly one block and a template re-push applies
  it fleet-wide: `GITHUB_MCP=false`, `CONTEXT7_MCP=false`, `SEARCH_MCP=false`.
  The `searxng` block names the pre-installed `searxng-mcp-server` binary (pinned in
  `images/dev/tool-versions.env` and baked into the golden image), is gated on
  `search_mcp` (default true) and dials the service above through `SEARXNG_URL`.
  That URL is one of six keys the render sets in `[mcp_servers.searxng.env]`; the
  others pin the bridge's own tuning rather than taking its compiled-in defaults:
  `SEARXNG_TIMEOUT_MS` (20s, above the instance's per-engine budget and equal to the
  probe's `--timeout`), `SEARXNG_CACHE_TTL_MS` (15 minutes, which switches on the
  bounded 128-entry response cache that ships disabled, so a repeated query stops
  re-dialling backends that already refused this instance), `SEARXNG_MAX_RESULTS`
  (a ceiling that keeps one search inside the MCP output cap - on the pinned 1.0.77
  CLI that cap rides `GROK_MAX_MCP_OUTPUT_BYTES`, because `grok inspect` still answers
  `[mcp] — unrecognized config key` and never applies it),
  `SEARXNG_DEFAULT_SAFESEARCH` (mirrors `search.safe_search` in
  `searxng/settings.yml`) and `SEARXNG_DEFAULT_LANGUAGE` (`all`, so an image bump
  cannot quietly start geo-filtering every agent search).
  The five offline stdio servers (`filesystem`, `memory`, `sequential-thinking`,
  `git` and `time`) stay pre-installed in the image (`npm -g` for the first
  three, `uv tool` for the Python two), but the rendered `config.toml` names
  none of them: the session traces collected on this machine called none of
  their tools, and a declared-but-unused server still costs every session its
  handshake time and tool schemas. Declare one by hand and check a stubborn
  server with `grok mcp doctor <name>` inside a workspace.
- The `github` server (`https://api.githubcopilot.com/mcp/`) renders by default even
  though it needs a token and outbound network: with GitHub tools on, the agent can
  drive the repository it is working in, and the cheaper failure is the block that
  renders with no credential and pays one failed handshake per session. `github_mcp`
  (default true) is the gate; `$GH_TOKEN` comes from Coder External Auth, never from a
  PAT.
- The `context7` server (library and API docs) also renders by default, and is the
  only cached one. `context7_mcp` (default true) is its gate, and the block it
  renders runs `mcp-cache-proxy` in front of the official `context7-mcp` - two packages
  pinned in `images/dev/tool-versions.env` and baked into the golden image, so parking
  or restoring it is a flag plus a template push, while changing the packages
  themselves takes an image rebuild. The proxy keeps its SQLite cache under
  `~/.grok/mcp-cache-proxy/`, which rides the owner's shared
  profile volume in `shared` mode, and the cache TTL is 12 h: the first lookup of a
  library reaches the Context7 API and needs network, while an identical lookup inside
  the TTL is answered locally. `CONTEXT7_API_KEY` is optional and the lane does not
  depend on it: an empty value sends no `Authorization` header at all, so the server
  handshakes and answers at the public rate limit, with private libraries the only
  thing out of reach. A key in `.env` plus a re-push fills the env. What *parks* the
  lane on purpose is `CONTEXT7_MCP=false` in `.env` (relayed by `push-template.sh`) or
  `--var context7_mcp=false` on a template push; a `[mcp_servers.context7]` block
  missing from a render that got neither of those is a defect, not a park. The lookup
  order is fixed - `resolve-library-id` first, then `query-docs` on the id it returns
  - and `search_tool` lists the live tool names rather than a hardcoded list. Prove it
  with `grok mcp doctor context7` inside a workspace.
- Prove all three at once with `bazelisk run //scripts:mcp-check`: it reads the
  rendered `~/.grok/config.toml`, reports whether each lane is declared, whether its
  `command=` binary is present, whether the lane's credential and cache config are
  there, and what each server's handshake says. A binary the box cannot find is image
  drift (the running `evo-t1-dev` predates the npm bake), and the check prints the
  pinned `npm i -g --prefix /opt/npm-global` command that restores it.
- A lane an agent needs fails in exactly three shapes, and that check tells them
  apart, so run it before editing anything:
  - **The block is missing from the rendered config.** That is a failure, not a
    warning: the default render declares the lane, so something took it away - a push
    passed its gate `false`, the workspace runs an older template, or the file lost
    its stack marker and nothing re-renders it. Remedy: clear the gate and re-push,
    then re-materialize the file with
    `bazelisk run //scripts:refresh-configs -- --container coder-<owner>-<ws>` from
    the stack host, or `bazelisk run //scripts:seed-dev-env -- --home <dir>` for a
    host home.
  - **The binary is missing from the golden image.** A warning: the running
    `evo-t1-dev` predates the npm bake. Remedy: rebuild the image and recreate the
    workspace, or run the `npm i -g --prefix /opt/npm-global` command the check prints
    to install the pinned package into the running box (pins in
    `images/dev/tool-versions.env`).
  - **The credential is missing.** Also a warning, and per lane it means something
    different. `github` with `$GH_TOKEN` empty is a real gap: connect GitHub External
    Auth (the **GitHub reauth** app) and start a new session. An empty
    `CONTEXT7_API_KEY` is not a gap - see the key's paragraph above, the lane answers
    keyless at the public rate limit.
- What the agent is told about all this lives in `~/.grok/AGENTS.md`, which
  `coder_script.agents_seed` renders from `templates/common/GROK_BUILD_AGENTS.md` into a
  body of its own (see "The one-argument ceiling" in
  [coder-templates.md](coder-templates.md#the-one-argument-ceiling)). Two sections cover
  the lanes. **Research
  lanes** makes a lookup part of the normal loop rather than a last resort, with the
  routing fixed by question type: a library, framework, CLI or setup question goes to
  `context7` (resolve the library id first, then query docs on that id); anything else
  on the web goes to the `searxng` `search` tool; a URL already in hand goes to
  `searxng`'s `fetch_content`, because Grok's native `web_fetch` is unavailable here
  too - `features.web_fetch` is on, but on a non-xAI endpoint that tool only runs
  through `toolset.web_fetch.proxy_endpoint`, and this stack sets none. It also states
  that native `web_search` is parked so nobody spends a turn rediscovering the 400.
  **Tool output stays out of the parent context** makes that
  tool use delegated work: the child returns a digest - numbered findings, each one
  claim, one source URL and at most two lines of support, no raw result dumps,
  confidence stated - and keeps the raw pages to itself.
- Cline and Roo/Kilo are pre-wired to the LiteLLM proxy (endpoint from `litellm_url`,
  default `http://host.docker.internal:4000/v1`; model alias `agent`, with
  `agent-low`/`agent-medium`/`agent-xhigh`/`coder`/`coder-fast`/`chat` listed in
  `__evoT1StackModels`). The seed is
  `settings.json.tftpl`, copied onto the per-owner volume
  `vscode-settings-<owner-id>` (mounted at `~/.shared/vscode/settings.json`) only
  while that file is absent, and symlinked from
  `~/.local/share/code-server/User/settings.json`. Startup chowns that volume to
  the home owner before the first write (empty named volumes are `root:root`
  755). Edits stick, and every workspace
  that owner has shares the file; delete it to copy the template in again. From the
  host it is the volume's `settings.json`:

  ```sh
  docker run --rm -it -v vscode-settings-<owner-id>:/vscode alpine vi /vscode/settings.json
  ```

- A built dev container mounts neither the volume nor the symlink, so it is the one
  place the seed is **merged** instead of linked: the inlined
  `coder_script.code_server` fork bakes a base64 copy of it and writes it over the
  dev container's private `User/settings.json` (or merges over a copy that survived a
  rebuild, when `jq` is on PATH; without `jq` the existing file is kept). Edits
  inside a built dev container therefore survive neither a rebuild nor a look at the
  shared file. Everywhere else no settings map is passed at all, because a merge
  would replace the symlink.
- Installing Cline, Roo, the Red Hat YAML extension and Material Icon Theme is a
  manual step in the Extensions panel (Open VSX by default). If an extension build
  names its settings differently, set the OpenAI-compatible endpoint and key in its
  UI.

## Coder Agents (control-plane)

Coder v2.36.6 ships *Coder Agents*: a coding agent that lives in the Coder **server** -
a chat UI and an API beside your workspaces, not inside one. A chat runs its tools
(`read_file`, `edit_files`, `execute`, `spawn_agent`) against a workspace over that
workspace's agent connection, and consults two pieces of per-workspace context first:
an **instructions** file and any **skills** it discovers. The agent itself is upstream
Coder, not a home-grown agent.

### It is always on

The chat agent is compiled into coderd unconditionally.

- `CODER_EXPERIMENTS` in `.env` (empty by default since 2026-10-08) has never gated
  anything about it: the old `agents` default was not a recognized experiment name,
  and the server logged `ignoring unknown experiment` and ignored it on every boot.
- `workspace_external_agent`, the entitlement the docs name, gates *external* agents
  (Claude Code, Codex, ...), not this one, and nothing here needs it.
- If you know a real experiment you want (`chat-advisor`, `chat-virtual-desktop`,
  ...), list it in `.env` and restart the coder service. Empty means no experiments
  on.

### Model wiring

Scripted, idempotent, re-runnable, and already started from `prod-stack` /
`dev-stack` `up` (`--apply --wait`, default 1800 s). Registering the first account
is the only operator step: the seeder continues once an owner exists, and the Agents
page is usable with no extra Coder UI setup. Print the plan:

```sh
bazelisk run //scripts:coder-agents -- --dry-run
```

Apply it (or re-run after a skip):

```sh
bazelisk run //scripts:coder-agents -- --apply
```

`--help` prints the same two commands with every flag and every `CODER_AGENTS_*`
override, which is the list to reach for from a shell.

The deployment default follows the health gate. `agent` is registered as the default,
and when LiteLLM reports no healthy deployment behind the Spark alias the Arc `chat`
config takes the default in its place. That matters because a chat opened without an
explicit model pick has only the default to resolve to, so a stack that comes up while
the Spark lane is dark still gets an Agents chat that answers. An existing config is
left as it stands, since this API surface has no PATCH: the script names the Admin
screen to correct it when a stored row drifted.

The closing summary counts how many of the four auxiliary lanes carry a pin, and a lane
left without one prints a `warning:` that names the lane.

`--wait` (or `--wait=SECONDS`) polls for that first owner instead of skip-0. The
window is counted from the database's first "no owner" answer, so a slow buildinfo
probe or a slow first query cannot spend it. `SKIP_CODER_AGENTS=1` skips bootstrap
and stack-up seeding. `CODER_AGENTS_WAIT_SECS`
is what stack `up` forwards as `--wait=`.

Stack `up` starts that seeder in the background and keeps its output in
`${TMPDIR:-/tmp}/coder-agents-seeder.log` (`CODER_AGENTS_SEED_LOG` moves it, and the
`note:` line stack `up` prints names the path it chose). Read that file first when
the Agents chat is dead after a boot: the seeder's most common outcome is a `skipped:`
line that exits 0 - no coder container yet, no db container, nobody registered - and
an unwritable log path degrades to the old discard with a `warning:` instead of
failing the boot.

A chat turn needs an enabled chat model config - the chat's own pick, else the
deployment default, else it errors before the first tool call - and that wiring is
what the script writes. It mints a short-lived admin API token from the stack's own
Postgres (`token_name 'stack-coder-agents'`, deleted by the trap, never printed) and
drives the server's experimental chat API:

- an `openai-compat` AI provider named **`litellm`** (not `litellm-auto`), base URL
  `http://litellm:4000/v1` - LiteLLM over the compose network, *server-side*,
  authenticated with `LITELLM_MASTER_KEY`. The agent dials the in-process AI Gateway
  (aibridge), which forwards to the provider's `base_url` + `/chat/completions`, so
  `/v1` has to be part of the base URL and the key has to match the live proxy: with
  `.env` leaving the key empty, compose still boots the proxy on its
  `change-me-litellm` interpolation default, and that default is what gets sent.
  Created when absent, drift-patched when an existing provider carries a drifted
  `base_url` or key.
- chat model configs `agent` (context limit 262144, set as the default; LiteLLM bakes
  `reasoning_effort` `xhigh`), `agent-low` / `agent-medium` / `agent-xhigh` (same
  lane with a baked thinking level, not default), and `chat` (32768), for models not
  already registered. `coder` and `coder-fast` stay out on purpose: on this stack's
  IPEX-LLM runtime those weights return tool calls as plain text with no
  `tool_calls`, and an agent turn without callable tools cannot browse or edit, so
  registering them would only add a silently broken model to the pickers.
  `context_limit` is the agent's own compaction budget (a 70 per cent default
  compaction threshold applies), which is why it is pinned per alias.
  Before that sweep the script asks the proxy `GET /v1/model/info` and `GET /health`
  and joins them on `model_id`, so it knows which aliases still have a healthy
  deployment. An alias with none is not registered: `chat` goes unhealthy the moment
  `qwen2.5:7b` is not pulled on the Arc, and a dead entry in the model picker is a
  chat that errors on the first send. `/health` is read without
  `?check_deployments=true` because that form fires a live completion per deployment
  and evicts the Spark prompt caches the health-check notes in `litellm/config.yaml`
  warn about. The gate fails open: a proxy that will not answer leaves every alias
  registerable, and `CODER_AGENTS_LIVE_ALIASES="agent chat"` overrides it outright.
- pins for the four auxiliary lanes - `general` and `explore` (the two subagent
  types) prefer `agent`, `compaction` and `title_generation` (the helper calls)
  prefer `chat` - chosen only from the aliases the health gate left standing, and
  written when a lane carries no pin or is pinned to one of these configs whose alias
  has since gone unhealthy. A pin aimed at a config the script did not create is the
  admin's and is left alone. Both helper lanes landing on a dead `chat` is what made
  conversations lose their titles and die at the compaction threshold, which is why a
  stale pin now moves instead of being kept forever.
- a read-only drift check on the stored configs: a config that is disabled, is not
  the deployment default, or carries a `context_limit` that does not match the alias's
  serving window is reported with a `warning:` and the screen to fix it on. The
  experimental chat API has no PATCH for model configs, so these are named rather than
  written.
- a three-line system-prompt addendum, appended after Coder's default prompt text
  (`include_default_system_prompt: true`), that keeps the delegation and
  secret-hygiene rules which must hold even when a chat has no workspace attached.

Coder's optional AI Gateway proxy stays off - LiteLLM remains the model transport,
which is why no AI-Gateway keys exist in `docker-compose.yml`.

### Whose compaction is whose

The `compaction` pin above belongs to Coder's chat agent and to nothing else. It is one
of the four auxiliary lanes the seeder writes into Coder's own model-config store, so it
decides which alias serves *that* agent's summariser and title call. It never reaches a
Grok Build CLI: the CLI reads no Coder table, and its compaction summary is an
**in-session call on the session model** - the `[models] default` alias, `agent` here -
which is why the summary inherits that lane's output ceiling (measured on the wire at
`max_tokens: 32768`) instead of a cheap helper lane's. `[models] session_summary` is not
that call either; the key serves titles and the session recap.

So the two compactions fail for unrelated reasons, and the fix for one is not the fix
for the other:

- Coder's chat dies at its context budget when `compaction` and `title_generation` both
  sit on a dead `chat` alias. `bazelisk run //scripts:coder-agents -- --apply` moves the
  stale pin, as above.
- A Grok Build session logging `compact failed: exceeded wall-clock budget 300s
  (runaway generation)` is the session-model summary hanging before its first token on
  the lane that also serves the whole agent loop. Its only live bounds are
  `GROK_COMPACTION_WALL_CLOCK_SECS`, rendered into the agent `env` because no TOML table
  takes it, and the proxy's `request_timeout`; [troubleshooting.md](troubleshooting.md)
  owns the measurement and the retry split that stops one hang being bought three times.
- The thresholds are separate as well. `context_limit` above is Coder's own compaction
  budget with its 70 per cent default, while the CLI fires at
  `[session] auto_compact_threshold_percent` (70) of its 262144-token window.

### The delegation sketch

Chat on the Agents page -> if the ask needs more tooling than chat has, Coder Agents
provisions or uses a workspace through `execute` -> big multi-file tasks are
*delegated inside* that workspace: a headless Grok Build CLI run, started backgrounded
and polled:

```sh
grok -p "<task brief with acceptance criteria>" --cwd <repo> --permission-mode acceptEdits --max-turns <budget>
```

Backgrounded and polled because `execute` waits only a short window per tool call
(about a minute), so a synchronous foreground `grok -p` would die mid-run on any big
task. Coder Agents then reviews the delegated diff, runs the project's tests, and
commits. Subagents spawned by Coder Agents cannot create workspaces: provisioning
decisions stop at the top-level chat.

### What seeds the agent's context

Twenty-two files seed into every new workspace, on first boot and only while the file is
absent:

1. `~/.coder/AGENTS.md`
2. `~/.coder/skills/grok-build-delegation/SKILL.md`
3. `~/.agents/INSTRUCTIONS.md`
4. `~/.agents/skills/grok-build-delegation/SKILL.md`
5. `~/.coder/skills/ez-learn/SKILL.md`
6. `~/.agents/skills/ez-learn/SKILL.md`
7. `~/.coder/skills/ez-skillify/SKILL.md`
8. `~/.agents/skills/ez-skillify/SKILL.md`
9. `~/.coder/skills/ez-create-skill/SKILL.md`
10. `~/.agents/skills/ez-create-skill/SKILL.md`
11. `~/.coder/skills/ez-bazel-first/SKILL.md`
12. `~/.agents/skills/ez-bazel-first/SKILL.md`
13. `~/.coder/skills/ez-bazel-first/scripts/owned_files_check.py`
14. `~/.agents/skills/ez-bazel-first/scripts/owned_files_check.py`
15. `~/.coder/skills/ez-bazel-first/scripts/glob_budget.py`
16. `~/.agents/skills/ez-bazel-first/scripts/glob_budget.py`
17. `~/.coder/skills/ez-strong-types/SKILL.md`
18. `~/.agents/skills/ez-strong-types/SKILL.md`
19. `~/.coder/skills/ez-strong-types/scripts/type_baseline.py`
20. `~/.agents/skills/ez-strong-types/scripts/type_baseline.py`
21. `~/.coder/skills/ez-trunk-based-repo/SKILL.md`
22. `~/.agents/skills/ez-trunk-based-repo/SKILL.md`

- 1 and 2 are the Coder agent's *default* discovery paths.
- 3 and 4 are the same text under the Grok Build CLI's convention, and the CLI is
  what `execute`-lane delegation drives. The chat agent dedupes skills by name,
  first match wins, home scope before a working-dir path, so one agent never loads a
  skill twice: the twins exist for the CLI, not as a second source for chat.
- 1-4 are written by `startup.sh.tftpl`. 5-10 are the stack's three skill commands and are
  written by `coder_script.stack_skills`, whose own `execve` carries the three payloads;
  they ride their own script body rather than the startup argument because that argument
  has a single-argument ceiling of its own
  ([coder-templates.md](coder-templates.md#the-one-argument-ceiling)). Each `.agents`
  copy is a `cp` of the managed `.coder` copy, never a second inline body, so the pair
  cannot drift.
- 11-22 are the stack's three repository-conversion commands and are written by
  `coder_script.stack_repo_skills`, a second body with its own ceiling, for the same
  reason and because this family also ships the python helpers 13-14, 16 and 19-20 that
  two of the bodies invoke by `~/.agents` path. Same absent-only contract and the same
  `cp` twin rule; the helper directories are made by the body, so a workspace that
  already has the `SKILL.md` but lost a helper still gets the helper back.
- 5 and 6 are `/ez-learn`: this stack's copy of the upstream memory commands `/flush`,
  `/dream`, `/remember` and `/memory`. It turns the current session into durable facts -
  flush the conversation into a session log under the workspace's `~/.grok/memory/`
  directory, dream those logs into an organized `MEMORY.md`, save one note, or browse and
  clear what was stored. Reaching past those logs into the raw transcripts under
  `~/.grok/sessions/` is opt-in depth, done only when the operator asks for it. Its
  default mode is report-only, and it writes memory files, never a skill. 7 and 8 are
  `/ez-skillify`, which turns the session that just worked into a skill from its own
  transcript, and 9 and 10 are `/ez-create-skill`, which scaffolds one from what the
  operator describes. The three payloads are
  `templates/common/ez-learn.SKILL.md`, `ez-skillify.SKILL.md` and
  `ez-create-skill.SKILL.md`, on the same absent-only contract. `/ez-create-skill` stands
  in for the bundled platform skill `create-skill`, which arrives only in the skills
  bundle behind an x.ai sign-in this stack does not have; `/ez-skillify` has no published
  upstream counterpart at all; and the memory family `/ez-learn` copies is upstream
  *built-ins*: `/flush`, `/dream` and `/memory` are gated behind cross-session memory,
  which is off by default, while `/remember` is a pager command with no such gate. Either
  way the seed is what makes the three commands exist. Each ships under its own `ez-`
  name to stay clear of those upstream names, since a user-scope skill overrides a
  same-named bundled one and a seed named `create-skill` would hide the bundled copy on a
  workspace that ever does sign in. The boot and the reseed delete a leftover
  marker-carrying `skills/learn/SKILL.md` from before the rename. See the CLI section
  above.
- The text of 1-4 is the orchestration protocol (fan-out / fan-in, the edit-conflict gate,
  probe-one-worker-first, verify-what-a-worker-actually-produced, the git cadence that
  cuts the branch before the first edit and commits each unit as it lands, holding the push
  for the pull request, and the issue etiquette that reads the report before planning, puts a
  single closing keyword in the pull request body, and leaves the actual close to the merge).
  It travels as
  `templates/common/GROK_BUILD_AGENTS.md`, staged beside the staged `main.tf` and
  read back with `file()` / `filebase64()`; `templates/common/` keeps one copy for
  both templates, and the push stages it into each template's pushed copy.
- `devcontainer` and `workspace` both seed it, so the seed is *not* fetched from
  GitHub any more: no `web_search`/`web_fetch` call is needed to inspect this repo,
  and the instruction text tells the agent so.
- Both `main.tf` files deliberately set **no** `CODER_AGENT_EXP_*` env keys on
  `coder_agent.main`: those keys *replace* the agent's discovery defaults, and the
  defaults already cover exactly the seeded paths - the `~/.coder` roots plus a
  working-dir-relative `.agents/skills`, which resolves inside the agent's working
  dir (`/home/coder` in `workspace`; in `devcontainer` with the toggle on, the
  cloned folder under `/srv/coder-devcontainers/...`, where a dev container built on
  the sidecar carries its own home and no seeded path is visible from inside it
  anyway).
- Each seeded file carries the stack marker - the `managed-by: evo-t1-coder-stack`
  comment, or the `"__evoT1Stack": true` / `__evoT1Stack = true` key in a JSON or TOML
  file - in `SKILL.md` directly under the `---` frontmatter, since the agent's skill
  parser requires frontmatter on line 1 and silently drops anything else. Delete a file
  to take it over; edit it and the stack leaves it alone. `~/.grok/config.toml` is the
  one seed where deleting a file is not the way: it needs both marker lines gone, see
  [The rendered `~/.grok` config](#the-rendered-grok-config). Either way the marker
  never reaches the model: the agent strips HTML comments from injected instruction
  text.
- The seeds live per workspace, on that workspace's own home volume. They are *not*
  on the shared `~/.grok` profile volume above, and seeding does not care whether
  that mount exists.

### The three stack-seeded skill commands

One line each: `/ez-learn` turns a session into durable memory - flush it into a session
log, dream the logs into organized memory, remember one note, or browse and clear the
store; `/ez-skillify` captures the session that just worked, working from its own
transcript; `/ez-create-skill` builds a skill from what the operator describes. The last
two write skill files; `/ez-learn` writes memory files.

Three things about skills matter in practice here:

- Write a specific `description` and `when-to-use`. That text is what the model matches
  on, so a vague one leaves the skill reachable only by its slash name.
- Set `disable-model-invocation: true` when only an explicit `/name` should run it.
  Anything that deploys, pushes or resets belongs behind that key.
- After creating or editing anything, check discovery and provenance with `grok inspect`,
  and `grok inspect --json` for each skill's `source` path and `userInvocable`. `/skills`
  opens the same set as a menu, where a toggle takes a skill out of the slash menu
  without deleting the file. Discovery reloads from disk, so an edit lands next turn
  with no restart.

This is workflow curation, separate from the memory system, which stores durable facts
(upstream `/remember`, `/memory`, `/dream`, shipped here as `/ez-learn`), and from
`AGENTS.md`, which is the always-loaded rules file. A skill loads when its `description`
matches, and holds a procedure.

### The three repository-conversion commands

One line each: `/ez-bazel-first` puts every tracked file behind a build target, budgets the
`glob()`s and drives the gate to full file coverage; `/ez-strong-types` pins a strict
checker profile per language and turns the broad-type census into a ratchet that fails on
any widening; `/ez-trunk-based-repo` retires environment branches, lands unfinished work
behind a flag that defaults off, and presents the leftover branches for deletion with their
tip SHAs. All three take a repository path and work on that checkout, so they are useful in
a workspace cloned against any of the fleet's repositories.

They differ from the authoring trio in one structural way: two of them shell out to a
python helper, so their seed ships `scripts/owned_files_check.py`, `scripts/glob_budget.py`
and `scripts/type_baseline.py` beside the `SKILL.md`. Those helpers are stack payload like
everything else here, which means the copy in a workspace is stack-owned while it carries the
marker, and the way to fix a helper is to fix the seed under `templates/common/` and
re-materialize, never to patch the copy that is running.

This repo keeps its own project-scoped `/trunk-refactor` under
`skills/trunk-refactor/SKILL.md`, which is the rule of record for *this* repository and
cites its gates by label. `/ez-trunk-based-repo` is the portable version of the same model:
it discovers a target repo's own gates at inventory time rather than assuming Bazel, so it
works in a Compose, K3s, Ansible or Terraform repository too.

### What this is not

Coder Agents is control-plane-native. This stack does not wrap Grok Build: the wiring
above *teaches* (skill + instructions) and *equips* (the workspace-side CLI with its
LiteLLM alias) the native Coder agent to drive Grok Build when work is too big to
hand-drive. Delegation is a taught habit, not the product.

## Watching those sessions from anywhere

The sessions above are tmux panes, which means they outlive the browser tab that
opened them and are visible to nothing else. `//scripts:coder-sessions` is the door
for the operator who is not at the desk:

```sh
bazelisk run //scripts:coder-sessions -- list
bazelisk run //scripts:coder-sessions -- show myrepo
bazelisk run //scripts:coder-sessions -- tail myrepo grok-build-myrepo-1a2b3c 40
bazelisk run //scripts:coder-sessions -- send myrepo grok-build-myrepo-1a2b3c "yes"
bazelisk run //scripts:coder-sessions -- launch --dir /home/coder/myrepo myrepo
bazelisk run //scripts:coder-sessions -- stop myrepo grok-build-myrepo-1a2b3c
bazelisk run //scripts:coder-sessions -- watch myrepo grok-build-myrepo-1a2b3c 1800
bazelisk run //scripts:coder-sessions -- check
```

`send`, `launch` and `stop` change things; the rest read. `watch` blocks: it returns
0 as soon as a session stops working and 4 when its budget runs out with the session
still `running`, which is what makes "tell me when it's done" a single call an
assistant can follow with a push. Global options
(`--json`, `--container`, `--timeout`, `--dry-run`) go before the subcommand, and
`--json` makes `list`, `show` and `watch` printable by a phone client.

**Why the daemon and not the Coder API.** A workspace that can host a session is a
*running* one, and a running workspace is a labelled container: both templates stamp
`coder.workspace_id` and `coder.workspace_name`, the same labels
`scripts/github-auth.sh` enumerates. Reading the daemon needs no credential, which
matters because the only Coder token this stack mints is the root-equivalent one
`scripts/push-template.sh` creates for the length of a push and deletes on the way
out. A chat turn should not mint one to answer "what is running", so where a verb
belongs to Coder rather than to the daemon the CLI prints the hand-off command.

**Two details that make the answer correct.** Each workspace creates a
`coder-<id>-dind-sidecar` carrying the same labels; it runs a Docker daemon and no
shell, so it is dropped by name. And a tmux server belongs to one uid and listens on
`/tmp/tmux-<uid>/default`, so the sockets are enumerated per uid - `docker exec`
lands as the image's user, and asking *that* user for its default server reports
"no sessions" for an agent the operator can see on screen.

**The state words** come from `state_word` in the script and are what the
`coding-agents` Hermes skill teaches: `running` (output within 30 s), `quiet` (an
agent loaded and silent for 30 s - finished, or parked on a question, which is what
"it's stuck" usually is), `waiting` (a client attached at a plain shell - a person
is already in that pane), `idle-shell`, `detached-shell`, and `unknown`. A state
word is a pointer at the pane, never a verdict: `tail` before you say done.

**From the phone.** The same file runs inside the Hermes container, whose image has
no bazelisk, straight off the identical-path checkout mount:

```sh
bash "${STACK_HOST_PATH:-/opt/stack}/scripts/coder-sessions.sh" list
```

That is the whole integration - see [hermes.md](hermes.md) for the doors Hermes
opens, and the `coding-agents` skill for the order the assistant works them in.
