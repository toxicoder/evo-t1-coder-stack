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
- How a subagent fan-out is sized, laned, and dispatched from a micro-plan
- The seeded fleet suite: six definitions, three personas, four skills, the five advisor
  commands, the seeded guard hooks, and the skeptic that closes every multi-file change
- The per-user state volumes, the per-workspace `config.toml`, and what each boot rewrites
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

### How a new terminal picks its tmux session

- The `tmux` profile gives each terminal of a folder its own pane. The base session
  name is unchanged: `vscode-<folder>-<hash>`.
  - A new terminal walks into one of that folder's sessions only while no client is
    attached to it, oldest first - that is the closed-tab rejoin, so a tab you closed
    or reloaded leaves its session unattached and the next terminal finds it with its
    history intact, and `ssh` + `tmux attach -t <session>` lands there too.
  - A terminal opened when every session of the folder already has a client takes the
    next numbered sibling instead: `vscode-<folder>-<hash>-2`, `-3`, ...
  - Sessions persist unattached until the container restarts, so a reattached terminal
    still reaches the output a closed tab produced.
  - `tmux ls` lists the names and `tmux list-clients` says who is looking at each.
  - Every target the helper gives tmux carries the `=` exact-match prefix (a bare name
    is answered by any session starting with it, so a closed `foo` could be answered by
    a live `foo-2` and re-create the mirror), and a reopen whose session vanished
    mid-attach raises a fresh session rather than exiting along with the tab.
  - Two tmux behaviors shape that path: a session raised by a tab's own foreground
    `new-session` has its first pane closed when that client exits
    ([superuser#575909](https://superuser.com/questions/575909/optionally-run-several-commands-when-starting-tmux)),
    which is why the helper creates detached and attaches separately
    - With the default `exit-empty` the server itself leaves when its last session
      does ([tmux#2081](https://github.com/tmux/tmux/issues/2081)), which is why a
      reopen probes the server before raising anything - a tab whose server is gone has
      ended normally, and re-raising there would boot a server for a terminal nobody is
      looking at (tmux has no server probe: `has-session` answers the same for a
      missing session and a missing server, which is why upstream declined to add
      `check-server`, [tmux#2523](https://github.com/tmux/tmux/issues/2523)).
  - No upstream issue accounts for the session loss: `destroy-unattached` is off, so a
    detached session is meant to survive, and tmux gives a session no grace period
    after it loses its last client
    ([tmux#5821](https://github.com/tmux/tmux/issues/5821) is an open request for one).

### What a mirrored pane costs

- One pane per visible terminal is what that rule buys. Clients attached to one
  tmux session share that session's current window, so a design that always
  reattaches makes every extra browser tab a mirror of the same pane: another
  full xterm.js in the Chrome tab re-parsing the same stream (each holding a
  line-slot array sized from `terminal.integrated.scrollback`, with the cell
  data allocated per line as output arrives), and another full copy of the
  rendered stream through the pty.
  - Measured on one flooding pane, 16 mirrors took 78.7 MB out of the server over an
    8 s window where a single mirror took 4.9 MB, while the server's own CPU only moved
    from 420 ms to 630 ms - it renders the pane once, so a mirror is paid for in the
    tab.
  - A client activating or resizing repaints the window's other clients too.
  - Measured on this workspace: 14 attached clients against 2 real panes.
  - Two terminals opening in the same instant can still land on one session - that same
    mirror, and rarer than a keystroke.
- **An attached client is not the same thing as a viewer.** code-server's pty
  host keeps the pty open after the browser side of a tab goes away, so the tmux
  client stays attached, keeps its session's `session_attached` at 1, and
  receives nothing at all.
  - Measured on this workspace's live server: 7 of its 9 clients received 0 bytes
    across a 4 s window of continuous pane output while the 2 tabs actually on screen
    each received all 12858 of them, and the quiet ones had reported no input for 30
    minutes to 36 hours.
  - That number is the whole reuse decision in the attach helper, so one of these is
    enough to make a free session look watched forever, and the folder pays a new
    session for every later tab.
  - Both helpers now sweep their own sessions for a client that has been quiet past a
    6 h grace before they read the snapshot; `EVO_TMUX_STALE_AFTER` (seconds) moves the
    number.

  Seeing the state yourself:

  ```sh
  # Two reads a few seconds apart: a client whose written count does not move
  # while its pane produces output has stopped being a viewer.
  tmux list-clients -F '#{client_activity} #{client_written} #{client_tty} #{session_name}'
  ```

  Detaching one needs its tty: this tmux 3.4 answers `detach-client -t` for a
  `/dev/pts/…` path, refuses a pid with `can't find client`, and has no
  `kill-client` command at all.

### The Grok Build terminal session

- **Grok Build** keeps its own session, keyed off the repository: the helper walks up
  from the terminal's folder with `git rev-parse --show-toplevel` (or uses the
  terminal's `$PWD` outside a clone), names the session `grok-build-<folder>-<hash>`
  after that root, and runs `grok --cwd <repo root>` inside it. A terminal opened
  anywhere inside the clone rejoins the one session the repository shares, and starts
  Grok Build at the repository root.
  - That profile is deliberately the old always-reattach shape: watching the same agent
    run from several tabs is the feature, and the mirrors pay what mirrors pay. What the
    seed gives them is `focus-events on`, so a TUI in the pane can idle its animations
    while its tab is blurred, and `escape-time 10`, which keeps typing responsive on
    each of them.
  - Two things it does borrow from the attach helper:
    - the session is created detached and attached in a second call, because the tab
      that brings the server up is otherwise the one that can take a running agent down
      with it (the same 9-of-20 loss the helper documents)
    - The stale viewers above are detached on the way in, which is where the
      8-clients-on-one-pane count came from.

### When tmux is not available

- With no tmux (offline first boot) the helper execs a plain login shell, so the
  default terminal still opens.

### The web terminal app

- `display_apps.web_terminal` stays **off**: it would open a shell on the agent's
  working dir (`/home/coder`). A custom command-type `coder_app` named **Web
  Terminal** (`order = 6`, after **VS Code Web** at `order = 5`, before **GitHub
  reauth** at `order = 7` and **Install GitHub App** at `order = 8`) takes that slot,
  `cd`s to the clone folder - an empty `repo_url` keeps it on `/home/coder` - and
  execs a login shell. Like the built-in, it reads no `terminal.integrated.*`
  settings.

### The code-server install and its pinned release

- Neither template installs code-server through the Registry. Each `main.tf` carries
  an inlined fork (`coder_script.code_server` + `coder_app.code_server`), because the
  upstream module hardcodes `/icon/code.svg` and has no icon input. Both twins pin the
  release in one `code_server_version` local and pass it to the upstream installer as
  `--version`: without that flag `https://code-server.dev/install.sh` follows `latest`,
  and the editor would move under every workspace with no commit in this repo.

  - `workspace` installs code-server only while that pinned release is missing from
  `/home/coder/.local/share/code-server` (the guard names
  `lib/code-server-<version>/bin/code-server`, the directory the installer unpacks, not
  the `bin/code-server` symlink, which points at the last release installed and would
  hold a warm volume on its first one) and starts it with `--auth none --port 13337
  --app-name "VS Code Web" --ignore-last-opened <folder>`, passing no settings payload.

  - `devcontainer` has no persistent prefix to reuse, so it installs the pinned release
  fresh under `/tmp/code-server` on every start.

### The editor folder and its icon

- The editor opens on `http://localhost:13337/?folder=<urlencoded>`: the
  `coder_app` resource in `coder/coder` `~> 2.18` has no `folder` argument, so the
  folder rides in the URL and as a positional argument to the code-server binary
  with `--ignore-last-opened`.
  - `workspace` uses `/home/coder/workspace/<repo>` (and `/home/coder` with no
    repository); `devcontainer` uses `/workspaces/<repo>` inside a built dev container
    and `/srv/coder-devcontainers/<workspace-id>/<repo>` on the plain container.
  - On first start the inlined `coder_script.code_server` creates that folder and waits
    up to 60 s for `.git` (skipped when the folder is `/home/coder`) so the clone can
    land before code-server launches.
  - `coder_agent.dir` stays unset: the agent would chdir there before `startup.sh`, and
    a missing clone folder would fail the agent. With the sample `REPO_URL` that folder
    is `/home/coder/workspace/evo-t1-coder-stack`.
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
copying itself, the way it does in a native terminal on that machine.

OSC 52 is the one route that still depends on what sits at the other end of the
terminal, and it belongs to an app inside the pane rather than to the operator.

Where each claim below comes from:

- the tmux ones were read off the shipped tmux 3.4 on this box (what an attach
  writes to the client, and what `list-keys` still holds once the payload is sourced)
- the setting names, values and defaults were read out of code-server 4.145.0's
  own config registry (VS Code base 1.145.0). Both twins pin 4.145.2 now and that
  registry has not been re-read against it, so every default named below is a
  4.145.0 reading
- the two Clipboard-API observations -- that a client selection fires
  `navigator.clipboard.writeText`, and that `document.execCommand('copy')` is the
  fallback that still lands on an insecure origin -- come from the earlier
  headless-Chromium pass over that same 4.145.0 build with the rendered
  `settings.json` twin and the tmux payload loaded, when `mouse` was still on and
  the copy out was a Shift+drag; neither has been repeated on 4.145.2

That path is the client's own selection, which is what a plain drag drives now; the
plain drag is due the same pass before it is restated as measured under `mouse off`.

- **Out of a pane: drag, and it is already on the clipboard.** tmux asks the outer
  terminal for mouse reporting only while `mouse` is on: measured on tmux 3.4, an
  attach with `mouse on` writes `ESC[?1000h`, `ESC[?1002h` and `ESC[?1006h` to the
  client, and an attach with it off writes none of them.
  - With the seed's `mouse off` tmux never sees a button, so a plain drag is the
    client's own highlight and the seed's `terminal.integrated.copyOnSelection: true`
    puts that highlight on the machine clipboard with no chord (the harness recorded
    `navigator.clipboard.writeText` firing on a client selection, before this switch).
- **Right-click and middle-click paste that clipboard.** The seed sets
  `terminal.integrated.rightClickBehavior: "copyPaste"` - copy while there is a
  selection, paste when there is none - and pins
  `terminal.integrated.middleClickBehavior: "paste"`, because the config registry in
  code-server 4.145.0 gives that setting the default `"default"`, which pastes only
  on the Linux build - a reading off that build, not re-checked against the
  4.145.2 the twins pin now. tmux has no middle-click paste of its own to answer
  first: `MouseDown2Pane` is unbound in the root table.
- **tmux keeps no buffer, so there is nothing to paste out of one.** `Prefix-[`
  still enters vi copy-mode and it is a viewer: the cursor keys, `PPage`/`NPage`,
  `Ctrl-u`/`Ctrl-d` and `k`/`j` walk history, `q` leaves, and `Escape` clears a
  selection.
  - Every copy that used to end a selection is unbound - Enter, `C-j`, `D`, `A`, the
    word and line copies a double- or triple-click fires, the copy a drag release ran,
    and the `y` the earlier seed bound itself - along with the prefix paste `]` and the
    buffer picker `=`.
  - Selecting inside copy-mode with `Space`, `V` or the cursor keys stays bound and is
    inert, with no copy command left for it to end on.
  - Proof: sourcing the payload on a scratch server leaves `list-keys` with no copy
    command in `copy-mode-vi`, no `paste-buffer` or `choose-buffer` in `prefix`, and no
    `MouseDown2Pane` in `root`.
  - The pointer's other jobs keep their prefix keys: `Prefix-o` or `Prefix-q` to select
    a pane, and `Prefix-Alt-arrow` to resize (plain `Prefix-arrow` selects a pane in the
    shipped 3.4's own default table).
- **`Prefix m` is the wheel, not a copy route.** One press hands the pointer to
  tmux so the wheel walks pane history, the next hands it back.
  - It is the escape hatch for a long scroll, because tmux paints in the alternate
    screen - it sends `ESC[?1049h` either way - so the client holds no scrollback of its
    own and a wheel over a pane has nothing to walk.
  - Output that has scrolled away is copied by bringing it on screen first: `Prefix-[`,
    scroll it into view, select it with a client drag, `q`.
  - A drag while `Prefix m` has the pointer on selects nothing, since the copy bindings
    stay unbound either way.
- **An app inside the pane drives the machine clipboard over OSC 52; the browser
  build drops it.** `set -g set-clipboard on` stays in the seed for that one route
  alone: vim's `+` register, and anything else that emits the escape, reach the
  machine clipboard the way a native terminal hands them to it. Passthrough is no
  part of that route - measured on the shipped tmux 3.4 with a read-only client
  attached, the escape arrives with `allow-passthrough off` and arrives nowhere with
  `set-clipboard off`.
  - Over ssh from Ghostty, kitty, WezTerm or iTerm2 that copy lands.
  - code-server's browser build drops the escape before any clipboard call: a
    hand-written `printf '\033]52;c;<base64>\a'` was just as silent with
    `set-clipboard off` as with it on, which puts the drop in the browser and not in
    tmux.
  - Upstream
    [microsoft/vscode#318254](https://github.com/microsoft/vscode/issues/318254) is
    open with two unmerged fixes, and code-server 4.145.0 registers no OSC 52
    setting at all -- read off that build, not re-read on the 4.145.2 the twins
    pin now -- so there is nothing here to turn on.
  - Nothing on the tmux side can spoil that clipboard either: tmux has no copy left to
    send, so an accidental selection in the pane cannot overwrite what the client just
    put there.
- **`allow-passthrough` is off, and `Prefix p` switches it for one window.** What
  that option governs is the DCS-wrapped kind: a pane app's own sequences in tmux's
  `ESC Ptmux;` form, which the server copies to every attached client when it is on,
  the ones that stopped draining included. That is the class that reaches the screen
  as garbage over a TUI, so the seed ships it off and the clipboard needs none of it.
  - Press `Prefix p` in the window that genuinely wants to pass a DCS through, and
    that window alone takes them.
  - Proof: `tmux show-options -gw allow-passthrough` reads `allow-passthrough off`,
    and `tests/bats/tmux-fidelity.bats` boots a scratch server on the seed and reads
    that value and the `Prefix p` binding back.
- **Into the pane: `Ctrl+Shift+V` or right-click, on a secure context.** Both
  arrive bracketed (`ESC[200~ ... ESC[201~`) in a bash terminal and in a tmux
  pane alike, and a three-line paste arrives whole without a warning dialog.
  - Both chords ask the browser's clipboard API, which the browser only exposes to a
    secure context, so the URL the tab was opened on decides it.
  - On the TLS public name they work; on `http://<LAN-address>` `navigator.clipboard`
    is absent, right-click stops with VS Code's own toast ("This browser doesn't support
    the clipboard.readText API needed to trigger a paste, try Ctrl+V instead."), and the
    browser's native paste event is what still delivers.
  - A Clipboard site permission that was once denied breaks both API chords the same
    way, with `NotAllowedError: Read permission denied`.
  - Neither is a tmux route: the prefix paste `]` and the buffer picker `=` are
    unbound, so the client's own clipboard is what arrives in the pane.
- **`Ctrl+V` on a secure origin is not a paste.** VS Code binds terminal paste to
  `Ctrl+Shift+V` on Linux and `Cmd+V` on macOS, so `Ctrl+V` reaches the pane as
  the `\x16` byte (readline's quoted-insert, vim's visual-block). The seed
  re-binds nothing there on purpose: a TUI in the pane owns that chord.
- **Two scroll-back stores, two different budgets.** `terminal.integrated.scrollback`
  in the settings seed is the xterm.js buffer, which is what a plain `bash`
  profile scrolls through; tmux's `history-limit` is what `Prefix-[` walks
  inside a pane. They read 2000 and 100000 lines here, and the two numbers
  differ on purpose because the two stores are billed differently.
  - What VS Code preallocates from the setting is the buffer's array of line slots -
    xterm.js builds `new Array(rows + scrollback)` for it up front
    ([CircularList.ts](https://github.com/xtermjs/xterm.js/blob/master/src/common/CircularList.ts),
    [Buffer.ts](https://github.com/xtermjs/xterm.js/blob/master/src/common/buffer/Buffer.ts))
  - The cell data lands one `BufferLine` at a time as output arrives, at 3
    `Uint32` words per column per line
    ([BufferLine.ts](https://github.com/xtermjs/xterm.js/blob/master/src/common/buffer/BufferLine.ts)),
    against a VS Code default of 1000
    ([terminalConfiguration.ts](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/terminal/common/terminalConfiguration.ts)).
  - The setting costs a pointer array per terminal in the tab either way, and real
    memory only for the lines a pane actually emits - which is why a busy build log is
    where a large value is felt, and an idle prompt is not.
  - tmux holds its history once per pane, in the server, and every client of that pane
    shares the one buffer. Hence the split: the deep store is tmux's and the browser
    keeps a short viewport.
  - Inside a tmux pane the client's wheel has nothing to walk - tmux paints in the
    alternate screen, so that buffer holds no pane history - and the 100000 lines live
    behind `Prefix-[`, paid for in the server and not in the tab.
  - Measured on tmux 3.4 with one pane pushed to its limit, 100000 lines of 120-column
    output holds the tmux server at 381 MB RSS; the same 100000 lines of plain 80-column
    output costs 60 MB.
  - The same sweep repeated at 120 columns came out close to linear at about 3 KB of
    server per history line - 10 MB at 2000, 35 MB at 10000, 160 MB at 50000, 308 MB at
    100000 - so this is the one terminal number that turns a chatty pane into real
    container memory, and it is a deliberate trade: the deep store is what lets
    `Prefix-[` still reach the start of a build.
  - tmux reads `history-limit` when a pane is created, so an existing pane keeps the
    number it was born with.

### `grok doctor` findings in a workspace

`grok doctor` checks terminal, clipboard and microphone support without starting a
session, and `/doctor` inside a session adds the checks that need a live one. Each
item in the **Findings** list carries its own fix, and `--json` prints the same
report for a script. What the report should read here:

- **tmux options.** `templates/common/tmux.conf` seeds the four options Doctor's
  own fixes write, `set -g set-clipboard on`, `set -g allow-passthrough off`,
  `set -g extended-keys on` and the `*:RGB` `terminal-features` entry, plus the
  `xterm*:extkeys` entry Doctor leaves to the operator.
  - Of those four, `set-clipboard` alone carries the OSC 52 copy; `allow-passthrough`
    ships off and `Prefix p` flips it for one window, because what it governs is the
    DCS-wrapped kind, not the clipboard (see **`allow-passthrough` is off** above).
  - Those last two decide what survives the multiplexer: tmux rewrites 24-bit color down
    to the palette an attached client advertises, which is what makes a theme look
    washed out in the browser, and extkeys is what makes Shift+Enter and Ctrl+. arrive
    distinct from Enter.
  - A client picks up `terminal-features` when it attaches, so after a reseed run
    `tmux source-file ~/.tmux.conf` and then detach and reattach (a `refresh-client`
    keeps the client on its old features).
  - Proof: `tmux display -p '#{client_termfeatures}'` lists `RGB` and `extkeys`.
    `tests/bats/tmux-fidelity.bats` boots a scratch server on the seed and reads all of
    it back.
- **`terminal.limited-color` during an agent turn.** A tool command launched by a
  running Grok session inherits `NO_COLOR=1`, `FORCE_COLOR=0`, `CLICOLOR=0` and
  `CARGO_TERM_COLOR=never` from that session, so a `grok doctor` run from inside
  an agent turn reads color as off. The `grok` process itself and the tmux server
  carry none of those variables, so run it from a plain terminal for the real
  capability: the line reads `color truecolor` and `themes all`.
- **`voice.no-input-device`.** Expected in a workspace. The container has no
  capture device at all (`/dev/snd` and `/proc/asound` are absent) and no
  recorder on PATH.
  - The probe only looks for a recorder binary, so installing `alsa-utils` moves the
    line to `available` while capture still has nowhere to read from, and
    `features.voice_mode = false` leaves the finding in place.
  - Neither would be a fix, so the stack ships neither and the finding stands as an
    accurate report of a headless container. Dictation belongs on a laptop-side `grok`.
  - To give a workspace dictation instead: run PulseAudio on the workstation with its
    TCP module enabled, export `PULSE_SERVER=tcp=<workstation>:4713` into the workspace,
    and install `pulseaudio-utils` there for `parec`.
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

### How the CLI is baked in and pinned

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

### The upstream `/learn` question

- **No published source names an upstream `/learn`, and the bundled skill set never
  lands here**: the `xai-org/grok-build` built-in command table, all 240 pages of
  docs.x.ai, every first-party changelog under `x.ai/cli/changelogs/`, and the public
  `xai-org/plugin-marketplace` catalog carry zero occurrences of it.

  - The bundled platform skills are a separate set, enumerated by
  `FORMER_PLATFORM_SKILL_HASHES` in `crates/codegen/xai-grok-shell/src/builtin.rs`
  (help, imagine, create-skill, check-work, check, xlsx, pptx, docx, code-review,
  best-of-n, create-workflow), and neither `learn` nor `skillify` is among them.

  - That set is downloaded at runtime through the CLI's proxy endpoints config
  (`cli-chat-proxy.grok.com`, gated by `GROK_SKILLS_BASE_URL`) and needs an x.ai
  sign-in: the upstream `product_skills*` fetch in
  `crates/codegen/xai-grok-shell/src/session/slash_commands.rs` is gated on
  `xai_grok_login::GrokAuth`.

  - This stack has no x.ai credential: LiteLLM is the sole model transport, with
  `env_key = "LITELLM_API_KEY"` and `base_url` `http://host.docker.internal:4000/v1`, so
  `~/.grok/bundled/` is never created and there is no bundled copy for `grok inspect` to
  label.

  - The one surface nobody can read anonymously is the authenticated skills
  feed (`x.ai/skills/*` answers 403), so the honest claim is that no published
  source names `/learn`, not that it cannot exist behind that feed.

  - Nothing writes `~/.grok/skills/` either, but
  that is a stack choice, not a CLI limit: the upstream user guide
  (`crates/codegen/xai-grok-pager/docs/user-guide/08-skills.md`) documents both tiers -
  `~/.grok/skills/` is the User scope and `<repo_root>/.grok/skills/` the Repo one, and
  `grok inspect` labels each definition by its actual source (`user`, `project`,
  `bundled`) - and startup discovery skips project skills and commands in untrusted
  folders, so a project-tier folder has to be trusted first or its skill is withheld.

  - What separates the two consumers is that the **Coder Agents** chat agent reads
  `~/.coder/skills/` only, so reaching both means shipping both homes.

### The stack's own skill commands

- **The stack ships its own three skill commands as `/ez-learn`, `/ez-skillify` and
  `/ez-create-skill`**, so they are stack payloads like the delegation skill, not something
  to install, and the `ez-` prefix keeps them clear of the upstream names they sit
  beside: `/create-skill` is one of the CLI's bundled platform skills and
  `/flush`, `/dream`, `/remember`, `/memory` are its built-in memory commands, while no
  published source names a `/learn` or a `/skillify` at all.

  - A user-scope skill overrides a same-named bundled one, so a seed named
  `create-skill` would have hidden the bundled copy.

  - `/ez-learn` writes memory files - it reproduces the upstream `/flush`, `/dream`,
  `/remember` and `/memory`; the other two write skill files.

  - The three payloads - `templates/common/ez-learn.SKILL.md`, `ez-skillify.SKILL.md` and
  `ez-create-skill.SKILL.md` - are seeded at workspace start by
  `coder_script.stack_skills`: each is written into `~/.coder/skills/<name>/SKILL.md` and
  twin-copied to `~/.agents/skills/<name>/SKILL.md`, each only while that file is absent.

  - To take a copy over, edit it and delete the `managed-by: evo-t1-coder-stack` marker
  line: a marker-free file is user-owned, and the seeder leaves it alone unless you pass
  `--force`. A deletion is undone - the boot writes the file again whenever it is absent,
  and `refresh-configs` re-seeds an absent target, so the next boot restores the stack's
  copy.

  - To hide the slash command, set `disabled = ["ez-learn"]` under `[skills]` in
  `~/.grok/config.toml`.

  - A seeded `SKILL.md` shows up in `grok inspect --json` as `userInvocable: true`, and a
  live session advertises it in both `slash_commands` and `skills`, so it works on
  whichever CLI the image baked at `/usr/local/bin/grok` and this needs no image rebuild;
  the **Grok Build** terminal profile gets it because that profile execs the same binary.

### The repository-conversion commands

- **The stack ships its own four repository-conversion commands as `/ez-bazel-first`,
  `/ez-strong-types`, `/ez-trunk-based-repo` and `/trunk-refactor`**, and these stand in for
  nothing upstream: they convert whatever repository the workspace happens to hold, which is
  why they carry no path and no gate command that exists in only one repository - each one
  discovers the target repo's own gate and quotes what it found.

  They are seeded the same way, by
  `coder_script.stack_repo_skills`, from `templates/common/ez-bazel-first.SKILL.md`,
  `ez-strong-types.SKILL.md`, `ez-trunk-based-repo.SKILL.md` and
  `templates/common/trunk-refactor.SKILL.md`, plus the three python
  helpers they shell out to. Same absent-only contract, same marker-based takeover rule,
  same `[skills] disabled` escape hatch.

#### The four seed tiers

One row per tier, the destination it writes, and the body that writes it. The boot
implements these four by destination directory, and nothing crosses over:

| Tier | Destination | Written by |
| ---- | ----------- | ---------- |
| A - global rulebook, roles, hooks | `~/.grok/AGENTS.md`, `~/.grok/agents/`, `~/.grok/personas/`, `~/.grok/hooks/` | `agents-seed.sh.tftpl`, `stack-fleet.sh.tftpl`, `stack-advisors.sh.tftpl`, `stack-hooks.sh.tftpl` |
| B - global skill pair | `~/.coder/skills/<x>/SKILL.md` plus the `cp` twin in `~/.agents/skills/<x>/` | `stack-skills.sh.tftpl`, `stack-repo-skills.sh.tftpl`, `trunk-refactor-seed.sh.tftpl` |
| C - per clone | `<clone>/.grok/skills/<x>/SKILL.md` for a folder under `/home/coder/workspace/`, absent-only and link-guarded | `stack-repo-skills.sh.tftpl`, which gates each member of the tier on its own predicate |
| D - per owner | `~/.grok/notes`, `~/.grok/memory`, `~/.grok/sessions`, on the per-owner volumes | the volumes themselves, not a boot body |

- Tier C is the tier that keeps one repository's own commands out of every other
  workspace's session, and it now carries two artifacts. `/ez-bazel-first` is seeded
  into every Bazel repository (the `MODULE.bazel` / `WORKSPACE` predicate) because that
  command converts whatever repository it sits in. `/stack-repo-commands` is seeded
  only into a clone that tracks the `.evo-t1-stack-repo` sentinel at its root, from
  `templates/common/stack-repo-commands.SKILL.md`. That sentinel is tracked by the
  stack repository and by no other, so it must never be copied into another repo: its
  presence is what tells the boot the clone *is* the stack.

- Which commands moved, and which stayed. `bazelisk run //:fix` (this clone's formatter
  target), `bazelisk run //scripts:bazel-map -- tests-for` (this clone's Bazel graph
  reader) and `.githooks/pre-commit` (a hook only this repo installs) are true only
  inside a checkout of this repository, so they are Tier C: `~/.grok/AGENTS.md` no
  longer names them and points at `<clone>/.grok/skills/stack-repo-commands/SKILL.md`
  instead. The operator CLIs - `//scripts:dev-stack`, `//scripts:update-configs`,
  `//scripts:refresh-configs`, `//scripts:bootstrap`, `//scripts:github-auth`,
  `//scripts:search-check`, `//scripts:mcp-check` - live in that same checkout, but an
  agent in any workspace has to be able to ask for them, so they stay in the Tier-A
  rulebook, which now carries one sentence saying to run them from the stack
  repository's own checkout or a host shell. Stripping them would be a regression.

- Tier C is not home-relative, so it is not a reseed target: `config_seed.sh` lists
  destinations it re-roots at `$HOME`, which is why both of its members are absent from
  that manifest, the way `/ez-bazel-first` already is.

### The dispatch plan command

- **A fourth command rides that same body: `/ez-micro-plan`.** It converts nothing - it is
  the parent's dispatch protocol for a fan-out of subagents: a repo-local plan at
  `.grok/plans/<slug>/plan.md`, the change split into micro tasks, layered context briefs
  beside it, and a check that refuses a plan too narrow to fill the session's subagent
  slots.
  - It shares the body because that body exists to stay under the one-argument ceiling
    ([coder-templates.md](coder-templates.md#the-one-argument-ceiling)), not because the
    four commands do the same job; three of the four carry a python helper next to their
    `SKILL.md` and `ez-trunk-based-repo` carries none.
  - Its payloads are `templates/common/ez-micro-plan.SKILL.md` and
    `templates/common/ez-micro-plan.plan_check.py`, seeded into `~/.coder/skills/` and
    its `~/.agents` twin on the same absent-only contract, the helper under `scripts/`
    like the trio's.
  - What the plan carries and what the check prints is under
    [The fan-out seam](#the-fan-out-seam).

### The retired `/learn` seed

- **A leftover `/learn` seed retires itself.** This skill was seeded under the name
  `learn` until it moved, and a copy left standing keeps offering that old name beside
  `/ez-learn` for the life of the volume; there is no bundled `learn` for it to hide,
  because no published source names one.
  - Both startup scripts delete `~/.coder/skills/learn/SKILL.md` and
    `~/.agents/skills/learn/SKILL.md` and prune the directory each leaves, but only while
    the file still carries the `managed-by: evo-t1-coder-stack` marker; a marker-free
    `learn/SKILL.md` is user-owned and stays.
  - `refresh-configs`, `storage-clean` and `seed-dev-env` retire the same two paths on
    reseed.
  - That removal only finishes the rename: there is no upstream `/learn` waiting on the
    name, because no published source names one.

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

### The model aliases and their lanes

#### The alias set and the reasoning levels

- The twelve aliases (`agent`, `agent-low`, `agent-medium`, `agent-xhigh`, `agent-swarm`,
  `agent-explore`, `agent-review`, `agent-xhigh-fast`, `agent-swarm-fast`, `coder`,
  `coder-fast`, `chat`) are defined with `base_url` set to `litellm_url` and
  `env_key = "LITELLM_API_KEY"`. The key is injected as an environment variable, so
  it never appears in a file.

  `agent` carries three `[[model."agent".reasoning_efforts]]` tables (`xhigh` is
  the default). The `agent-low` / `agent-medium` / `agent-xhigh` / `agent-swarm` /
  `agent-explore` / `agent-review` / `agent-xhigh-fast` / `agent-swarm-fast` aliases
  set `supports_reasoning_effort = false` because LiteLLM bakes the level for
  callers that have no reasoning-effort field.

#### The reader lane and the skeptic lane

- The `agent-explore` / `agent-review` pair is the
  reader and the skeptic: the `explore` type and the seeded `explorer` ride
  `agent-explore` (`low`), and the seeded
  `reviewer` and `security-auditor` ride `agent-review` (`xhigh`). What each lifts, what
  it costs, and the `--var` that rolls it back are in
  [litellm-routing.md](litellm-routing.md#the-fan-out-lanes-agent-explore-and-agent-review).

#### The fast compaction pair

- The `agent-xhigh-fast` / `agent-swarm-fast` pair is their parent lane with one call of the
  conversation answered elsewhere: on those two aliases only, the proxy callback
  `litellm/compaction_router.py` re-serves the CLI's conversation-summary call from the Arc
  group `compaction-fast` and leaves every other call of the session on its Spark box.
  Nothing in either `[model.*]` block names that target, because no client key could - the
  hop is server-side, and it forks on `EVO_T1_FAST_COMPACTION_INPUT_LIMIT` (24000 tokens
  estimated):

  - within it the summary goes to the Arc group
  - above it to the Spark group `EVO_T1_FAST_COMPACTION_SPARK_TARGET` (default `agent-low`)

  because the Arc weights answer inside a 32768-token window and a bigger input would be
  truncated into a useless summary of the history the call exists to preserve.

  Both are selectable as `grok_default_model` and neither is a Coder Agents chat model. The
  mechanism, the five `EVO_T1_FAST_COMPACTION*` knobs, and the 107 s to 1915 s Spark-side
  compactions that motivated it are in
  [litellm-routing.md](litellm-routing.md#the-fast-compaction-lanes-agent-xhigh-fast-and-agent-swarm-fast).

#### The session pin header

- `[models]` also carries `extra_headers` with
  `x-litellm-session-id: ws-<workspace-id>` - the key LiteLLM uses to pin a
  workspace's traffic to one healthy Spark box. Each workspace renders its own
  key: `config.toml` is that workspace's own file.

#### The subagent width and depth keys

- `[subagents]` sets how wide a fan-out goes and `[subagents.models]` which lane each
  type rides, both rendered from template variables: `grok_subagents_lane` (default
  `agent-swarm`) for the writers, three more for the reader, planner and skeptic roles named
  below, and `grok_subagent_max_concurrent` (default 15, the variable's own shipped
  number; `null` is kept as the opt-in that hands the width to `grok_swarm_width`, the
  fleet's own ceiling), and `grok_subagent_max_depth` (default 2,
  validated 1..3) sets how deep the tree of children may go.

  - The width and the ceiling are two numbers on purpose, and `main.tf` is where they meet:
  `grok_subagent_max_concurrent = var.grok_subagent_max_concurrent != null ? var.grok_subagent_max_concurrent : var.grok_swarm_width`
  So the width is the variable's own shipped 15 whichever lane the writers ride, and the
  `: var.grok_swarm_width` arm answers only a caller that passes null on purpose;
  `--var grok_subagents_lane=agent` is the rollback that puts the writers back on
  the parent's pinned box and leaves that width alone, and an explicit
  `--var grok_subagent_max_concurrent=N` always wins.

  - The variable's own validation accepts any whole number 1..32 it is given, plus that
  explicit null,
  because past the fleet's ceiling a bigger number is only a longer queue.

#### What a pinned lane costs

- A parent session and every subagent it spawns
  carry the same `x-litellm-session-id`, so on a pinned lane the whole fan-out resolves
  to one deployment and competes for that box's `PARALLEL` streams - 5 by default, set in
  `scripts/spark-configure.sh` - so the width that is useful on one box is about 4: that
  box's `PARALLEL` minus the parent's own stream, which is why an operator who pins
  everything to one box narrows the queue by setting `grok_subagent_max_concurrent`
  rather than by switching lanes.

#### What the swarm lane buys

- The `agent-swarm` default is where widening pays: that
  group carries no pin, so each subagent request is placed on
  whichever reachable box has the fewest requests in flight and the ceiling becomes
  `PARALLEL` per box rather than per workspace - 3 boxes x 5 = 15, which asks the fleet
  for every stream it has, so treat 15 as a one-workspace-at-a-time number.
- `sampling_limit` is deliberately left unset: it defaults to `max_concurrent`, so the
  two caps cannot drift apart. `limit_behavior = "queue"` below them holds the overflow
  instead of failing the spawn, so overshoot costs a subagent latency rather than its
  life.

#### How deep the tree of children may go

- `max_depth` rides beside them, rendered from `grok_subagent_max_depth` and shipped
  at 2, and at 2 a child may spawn: `reviewer`, `security-auditor` and `tester` name
  `spawn_subagent` in their `tools` (`templates/common/reviewer.AGENT.md:5`), so a skeptic
  or a tester can fan read-only mappers out one level under itself.

  Each of those grandchildren is its own session with its own `max_concurrent`, and what
  it costs the
  fleet is one model stream, so a tree is budgeted by summing the in-flight `1 + spawns`
  over every task and keeping that total at or below the fleet's stream count (`fleet:` in
  the plan, 15 by default, `templates/common/ez-micro-plan.plan_check.py:42`). That total
  is a separate number from the session cap above, which counts one parent's own children.

  `max_depth = 1` is the rollback to no nesting, and it restores the behaviour the fleet
  shipped with before a child could spawn.

#### The four lane variables

- `[subagents.models]` pins every subagent type a session can get to a lane of its
  own, and there are four variables behind those pins, not one: `grok_subagents_lane`
  (default `agent-swarm`) for the writers, `grok_explore_lane` (default `agent-explore`) for the
  mappers, `grok_plan_lane` (default `agent`) for the planner, and `grok_review_lane`
  (default `agent-review`) for the skeptics.

  - Concretely the block renders `general-purpose`, `implementer` and `tester` from the
  writers' lane, `explore` and
  `explorer` from the reader's, `plan` and `architect` from the planner's, and `reviewer`
  and `security-auditor` from the skeptic's - the last six keys are the seeded role
  definitions named in [the seeded fleet suite](#the-seeded-fleet-suite), and a key no
  session selects is inert.

  - Splitting the block that way is what lets one role go back on the parent's lane without
  moving the others: a wave of mappers can spread over the whole
  fleet while the planner that steers the next wave stays pinned to one box.

  - Pinning only the two read-only types was the defect
    this block fixes: a spawn that names no type gets
  `general-purpose`, and that is the type every writer in a fan-out runs as, so those
  children inherited the parent's model and queued behind the one box a pinned parent
  resolves to while the swarm-named readers spread over three.

  - What those four variables decide is placement only:
    the in-flight width comes from `grok_subagent_max_concurrent`
  (its own shipped 15) on every lane, so `grok_subagents_lane` remains the knob a workspace
  turns on to fan out, and narrowing that width is the same variable rather than the lane.

#### The three feature flags

- `[features]` carries `telemetry = false`, `web_fetch = true` and
  `active_agent_messages = true`, the last of them giving the parent
  `send_subagent_message`: a child already running can be handed a new instruction and
  keep its context, which is cheaper than killing it and dispatching a replacement. All
  three keys are static in `templates/workspace/grok-config.toml.tftpl:368-373` and none
  is rendered from a template variable.

#### The two MCP server blocks

- `github_mcp` (default `true`, so the block renders unless you park it with
  `GITHUB_MCP=false` and re-push) adds the `github` HTTP MCP server
  (`https://api.githubcopilot.com/mcp/`), whose `Authorization` header references
  `${GH_TOKEN}` **by name**, so no token value is ever part of a template variable.
  The agent environment fills it from the Coder External Auth provider (id `github` by default); a
  workspace whose owner connected no GitHub account renders the block anyway and pays
  one failed handshake per session.
- `context7_mcp` (default `true`, parked the same way with `CONTEXT7_MCP=false`) adds
  the cached `context7` stdio MCP server.
  - Grok launches `/opt/npm-global/bin/mcp-cache-proxy` with
    `--config /home/coder/.grok/mcp-cache-proxy/config.json`, and that proxy fronts the
    official `/opt/npm-global/bin/context7-mcp`; both are pre-installed in the golden
    image, so nothing is fetched with `npx` at launch.
  - The proxy config names `$CONTEXT7_API_KEY` and nothing else: the key reaches the
    workspace environment from the sensitive template variable `context7_api_key`, filled
    by the push from `CONTEXT7_API_KEY` in the host `.env` - not from Coder External Auth,
    which is what fills `GH_TOKEN` above.

#### The verbatim escape hatch

- `grok_config_extra` appends whatever the create form's **Grok config extras** field
  holds, verbatim under its own comment header.

#### The approval default is a stack decision

- `[permission]` holds the guardrails the stack owns. The approval mode is a stack
  default now rather than a per-user call: the render writes
  `[ui] permission_mode = "always-approve"` unless the create form's **Grok approval
  mode** field (`grok_permission_mode`, whose accepted values are `default`, `ask`,
  `auto`, `always-approve`) names another, and the contributor seed takes the same
  choice from `GROK_PERMISSION_MODE`.

  What relaxes is prompting, not the guardrails: a
  `deny` rule still outranks every other list under always-approve, so the dotenv reads
  and the `rm -rf` deny still refuse.

#### The dotenv deny and the template allow list

- `Bash(rm -rf *)` blocks the destructive
  form, and the dotenv family is split by what a file actually holds:
  - the live `.env` and the populated suffixed shapes (`.env.local`, `.env.*.local`,
    `.env.production` / `.env.prod`, `.env.staging` / `.env.stage`, `.env.development` /
    `.env.dev`, `.env.test` / `.env.testing`, `.env.ci`, `.env.override`) are denied for
    `Read` and `Edit`
  - the secret-free templates a repo ships (`.env.example`, `.env.sample`,
    `.env.template`, `.env.dist`, `.env.defaults`, plus the `.env.*.example` /
    `.env.*.sample` spellings) are named in `allow`, so an agent maintains the env key
    list without a prompt in any mode.

  Neither list is the old blanket `**/.env.*`: deny outranks
  allow, so the blanket form blocked the templates along with the live files and
  left the key list -- the file that keeps a real `.env` honest -- to drift.

  `.gitignore` carries the matching half on the git side: the whole family is
  ignored except the names `allow` lists.

#### The git verbs the branch-first policy needs

- `allow` also carries the verbs the branch-first, commit-per-unit policy needs:
  `Bash(git switch *)`, `Bash(git checkout -b *)` and `-B`, `Bash(git add *)`,
  `Bash(git commit *)`.

  A grant that cannot be had is how that policy fails quietly:
  an unattended run (`grok -p`, how the delegation skill launches its children)
  answers "headless run cannot ask for approval" and drops the call, so a child
  would finish a whole task with its work uncommitted. Everything on that list is
  local to the checkout and undone by another git command.

  `git push` is absent on purpose - the one step that leaves the machine keeps a human in
  it - and so is
  anything that can lose work (`git branch -D`, `git restore`,
  `git reset --hard`). The deny side closes the two ways a commit could land with
  no gate having seen it:

  - `Bash(git commit --no-verify *)` / `-n`, past the hermetic pre-commit hook
  - `Bash(git add -f *)` / `--force`, past `.gitignore`

Both are prefix globs, so they narrow that door rather than seal it, and the
`Stage by path` rule in the seed text is the rest of the defence.

#### Why the recursive-delete deny catches benign cleanups

- `Bash(rm -rf *)` is a prefix glob, so it catches a benign per-path scratch cleanup
  along with the destruction it is there to prevent. Agents run into that constantly:
  across 271 workspace sessions, 86 recorded at least one denied tool call and 56
  attempted an `rm -rf`, and 55 sessions did both.

  The shapes that are never denied are per-path deletions - `find <dir> -type f -delete`, or
  `rm -f` naming each path - so clean scratch that way.

  An `allow` entry cannot rescue `rm -rf`, because deny outranks allow. Narrowing the pattern
  is an operator call and a deliberate one: it is the only thing between an agent and a
  recursive delete on a path it got wrong.

#### The self-teardown deny family

- The self-teardown family is denied alongside it, because an agent that closes its own
  terminal cannot finish the task that closed it. The following each match a `deny` rule:

  - `tmux kill-server` / `kill-session` / `kill-window` / `kill-pane` / `restart-server`
  - `pkill` and `killall` naming `tmux`, `node`, `code-server`, `grok` or `bash`
  - those killers aimed at a whole user or parent (`pkill -u`, `-U`, `-P`)
  - the shell forms that signal a whole process group (`kill 0`, `kill -- -<pgid>`,
    `kill -9 -1`)

  The reason is the shape of the workspace: the Bash tool runs inside the tmux session
  the agent was launched in, so a sweep that tidies up "stray" sessions or processes
  takes the agent, its tool shell and the in-flight reply down together, and the editor
  tab dies with `terminated with exit code: 1` over work left half-done.

  An agent stops one process it started with the `kill_command_or_subagent` tool; bringing
  down a whole tmux server or editor host stays an operator call.

  These are globs over the parsed command text, so an abbreviated tmux verb
  (`tmux kill-sess`) or a bracketed pattern (`pkill -f [t]mux`) walks past them - the seed
  rule that names the prohibition is the other half, and the plain `bash` profile is how a
  session reaches a shell once they are all gone.

#### The marker that keeps the config stack-owned

- Stack ownership of the file rests on either marker spelling: the line-1
  `managed-by: evo-t1-coder-stack` comment or the top-level `__evoT1Stack = true` key.
  Both twins emit both, because the comment alone does not last - `grok mcp add`
  persists its own settings by rewriting the file and deletes every comment line, so a
  comment-only marker handed the config to the user with no human in the loop, and the
  default lanes silently stopped arriving.

  - A hand-edited config is left alone only
  while it carries one of them, so takeover means deleting **both** lines; delete the
  file and restart to hand it back.

  - When the guard does re-render, the CLI-owned tables `[cli]`, `[ui]` and `[marketplace]` are
  carried over rather than wiped. The `[ui]` copy comes across minus the keys the render owns,
  and `permission_mode` is one of them now: the startup strips it from the operator's copy so
  the render's own line cannot land beside it, which would hand one `[ui]` table two identical
  keys and the CLI an invalid TOML file.

  - The strip says what it took - when it drops a mode the start prints one `warning:` line
  naming the value it dropped (`templates/workspace/startup.sh.tftpl:248`), so an approval
  mode lost at a restart is lost in the open. A workspace that quietly starts prompting, or
  stops prompting, is otherwise a report nobody can reproduce.

  - And the create form's four are what the `[ui] permission_mode` key documents, not the whole
  vocabulary: the CLI's own `--permission-mode` flag spells more
  (`templates/workspace/main.tf:389-392`). One of those belongs in the operator's `[ui]` block
  by hand, and the next start replaces it with the form's answer and says so on the startup
  log.

## The fan-out seam

Three stack-owned numbers decide whether a fan-out of subagents is parallel here at all:
how many slots one session gets, which lane those children's traffic rides, and whether
the work was cut finely enough to fill the slots. The first two are the rendered
`[subagents]` keys just above; the third is a seeded skill and one command the parent runs
before wave 1.

### The ceiling and the fleet width

**How a session learns its own ceiling.** `[subagents] max_concurrent` is the per-session
number, and `sampling_limit` is left unset because it defaults to that same number - one
variable, so the two caps cannot drift apart. The parent reads it once per session and
dispatches to it:

```sh
grep -A4 '^\[subagents\]' ~/.grok/config.toml
```

The rulebook (`~/.grok/AGENTS.md`, from
`templates/common/GROK_BUILD_AGENTS.md`) states the ceiling as that key rather than as a
number of its own: the prompt used to hardcode a smaller fleet and to tell the parent to
run two or three children per wave, and both are gone, because a cap the prompt invents is
wrong on both lanes - it leaves slots empty on a swarm session and overbooks a pinned
one.

Overflow is held, not failed (`limit_behavior = "queue"`), so an under-wide wave is
silent and counting it stays the parent's job.

The same grep prints the `max_depth` line
beside `max_concurrent`, and that key is now rendered from `grok_subagent_max_depth`
(default 2, validated 1..3) by `templates/workspace/grok-config.toml.tftpl:429`.

At the shipped 2 a child may spawn: `reviewer`, `security-auditor` and `tester` name
`spawn_subagent` in their `tools`, so a skeptic can put a wave of read-only mappers under
itself and get its evidence without a round trip through the parent.

Each grandchild is its own session, so it is not charged to the slot count above; what it
does cost is a model stream, which is why a tree is counted by summing the in-flight
`1 + spawns` over every task and keeping that total at or below the fleet's stream count
(`fleet:` in the plan, 15 by default).

`max_depth = 1` is the rollback: no child spawns, and one parent's slot count again
describes the whole tree.

**Two numbers, one rule.** The same grep opens its four lines of context with
`# fleet-width: 15` - the fleet's own ceiling, rendered into the same table from
`var.grok_swarm_width` (`templates/workspace/grok-config.toml.tftpl:427`, fed at
`templates/workspace/main.tf:558`) so an explicit width never erases it - while the number
below it is `grok_subagent_max_concurrent`, the variable's own shipped 15. The pair is
what the width gets read against:

- Equal numbers mean the session is sized for the fleet: every slot it holds is a stream a
  box can actually serve.
- A width below its fleet-width means a persisted value - on the template, from a raw
  `coder templates push --var`, or on the workspace, from `coder start --parameter` /
  `coder update --parameter` or the Variables tab (`--var` is a push-only flag;
  `coder start` has none) - unless an operator set it there on purpose to sit inside one
  pinned box.
- A width above its fleet-width is the pair a one-knob fleet change leaves behind: the two
  keys are separate numbers, so a workspace that shrank the fleet with
  `--var grok_swarm_width=10` moved the ceiling alone and kept the shipped 15.

That pair is not a stale stored value, it is a fleet that got smaller under a width that
never moved.

`bazelisk run //scripts:subagent-check` reads both and names which of the three readings you
have, and counts the above one as a `note:` beside the ok items, since past the fleet's
streams the extra spawns queue in LiteLLM rather than failing.

The same comparison runs at every start, in stage 6 of
`templates/workspace/startup.sh.tftpl`, where a narrower width is one `note:` line on the
startup log and a wider one prints nothing. Neither value can be cleared from inside the
workspace, because both sit in the Coder database on the host. So shrinking a shared fleet
is a two-knob job: dropping `grok_swarm_width` moves the ceiling alone, and
`grok_subagent_max_concurrent` has to go with it in the same push, or a 15-wide session
meets `NoRoom` on a 10-stream fleet.

### Lane choice and the review panel

**What the lane choice buys.** `grok_subagents_lane` is the knob for the writers and it
decides placement, not size: the in-flight width comes from
`grok_subagent_max_concurrent` (the variable's own shipped 15) on every lane, and only a
workspace that sets it to `null` on purpose takes the width from `grok_swarm_width` instead
(its validation accepts any whole number 1..32 plus that explicit null).

That 15 is the fleet's arithmetic rather than taste.

A parent and every child it spawns carry the same `x-litellm-session-id`, so a pinned lane
places the whole fan-out on one box and the useful width is that box's `PARALLEL` - 5 by
default, from `scripts/spark-configure.sh` - minus the parent's own stream; past that, extra
slots are LiteLLM queue depth.

`agent-swarm` is one of four Spark groups with no session pin -
`agent-explore`, `agent-review` and `agent-swarm-fast` lift it the same way, and
[litellm-routing.md](litellm-routing.md#the-fan-out-lanes-agent-explore-and-agent-review)
is where what each lane buys is worked out - so each child lands on whichever reachable
box has the fewest requests in flight and the ceiling
becomes `PARALLEL` per box: 3 boxes x 5 = 15, which is every stream the fleet has and
therefore a one-workspace-at-a-time number.

The pins no longer put every type on that one lane: `[subagents.models]` renders

- `general-purpose` and the seeded `implementer` and `tester` from `grok_subagents_lane`
- `explore` and the seeded `explorer` from `grok_explore_lane` (default `agent-explore`)
- `plan` and the seeded `architect` from `grok_plan_lane` (default `agent`, still pinned,
  because one planner is a conversation that steers every wave after it)
- the seeded `reviewer` and `security-auditor` from `grok_review_lane` (default
  `agent-review`)

What has not changed is why the block exists at all: every writer in a fan-out is a
`general-purpose` child, and while only the two read-only types were pinned those writers
inherited the parent's model, so a swarm-named wave still queued its edits behind one box's
streams.

The lane is therefore a config decision: the guide documents `[subagents.models]` as the per-type
override that "applies for any parent", and documents the spawn call's own `model`
argument as the agent's choice of one child's model, without saying which of the two wins
when both name one. Set the pin when the lane matters.

**The review pass is a panel.** The independent check that closes a fleet run is a wave of
skeptics dispatched in one turn, each riding `agent-review` through the `grok_review_lane`
pin above, each owning no file, and each re-running the producers' own `done:` commands
rather than reading their reports. The default panel is three angles:

- requirements, which answers every acceptance check kept or broken
- proof, which runs the `done:` commands and quotes what they printed
- adversary, which looks for the regression, the edge state and the flag-off path

Each may fan out up to three read-only mappers of its own under the depth above.

`templates/common/ez-micro-plan.plan_check.py:227` accepts a `review:` key
naming the whole panel, comma or space separated, and holds each reviewer to owning nothing
while needing every task that ships a file.

A contributor home gets the same seam from the environment of the seed, so a laptop
matches what a template `--var` renders:

```sh
GROK_SUBAGENTS_LANE=agent-swarm bazelisk run //scripts:seed-dev-env -- --home <dir>
```

`GROK_SUBAGENTS_LANE` names the writers' lane and `GROK_SUBAGENT_MAX_CONCURRENT` the width,
which defaults to the same `default = 15` the variable ships in both twins' `coder.tf`, so
the seeder and the template agree on the width without a second knob.

`GROK_SWARM_WIDTH`
(default 15) now feeds only the `# fleet-width:` line the seed writes directly above the
width, `scripts/seed-dev-env.sh:286`, so a contributor home carries the same pair a
workspace renders; `GROK_EXPLORE_LANE` (default `agent-explore`),
`GROK_PLAN_LANE` (default `agent`) and `GROK_REVIEW_LANE` (default `agent-review`) name the
three role lanes the same way.

A value the seeder cannot use is refused in place and
the default goes in, so a typo is a line in the output rather than a broken key in
`~/.grok/config.toml`:

```text
note: GROK_SUBAGENTS_LANE='not a model id' is not a model id - using agent-swarm
note: GROK_SUBAGENT_MAX_CONCURRENT='99' is past the fleet's ceiling - using 32
```

### Cutting the plan and dispatching the wave

**How the work is cut.** `/ez-micro-plan` is the parent's protocol for splitting one
multi-file change across that fleet, and it writes its own document, separate from Grok
Build's `/plan`: `/plan` lives at `~/.grok/sessions/<cwd>/<session-id>/plan.md`, is the
Plan Mode preview, and dies with the session, while this one is repo-local at
`.grok/plans/<slug>/plan.md` and is what the parent and every child read from.

It carries `## Goal` with numbered acceptance checks, `## Dispatch` (lane, `slots:`, where the slot
count came from, `parent keeps:` for the hotspots the parent merges itself), `## Lanes`,
`## Tasks`, `## Ledger`, and `## Not doing`. Beside it sit the context briefs and the
child reports:

| file | answers | written by | read by | cap |
|---|---|---|---|---|
| `ctx/L0.md` | what is being built, and every pinned seam | parent | every child | 80 lines |
| `ctx/L1-<lane>.md` | that lane's file map and the pattern to copy | parent | that lane's children | 40 lines |
| `ctx/L2-T<nn>.md` | the one fact only this task needs | parent, just in time | one child | 20 lines |
| `results/T<nn>.md` | what happened and what was found | child | parent | 12 lines |

One writer per layer is the rule that keeps a child from inheriting the parent's session:
children write only their own `results/T<nn>.md`, never a brief, and the parent is the
only thing that moves a fact sideways from one child to the next (a child reports
`found:`, the parent writes it into the lane brief before the next wave).

`ctx/L0.md` is frozen before wave 1, because children already running read the copy that
was there when
they started - editing it mid-run is a re-dispatch, not an edit.

A task is micro when all of this holds:

- one deliverable
- three or fewer files in `owns` from one directory family
- a `calls:` budget of 15 or fewer counting the reads a child needs to get oriented
- one `done:` command a reviewer can run
- no other ready task sharing a path
- `needs:` naming only finished tasks

Below that bar the plan costs more than it saves, which is why the skill opens by asking
whether the change touches about five files at all.

**How it is dispatched, and what the check prints.** `plan_check.py` is the gate, and it
is the same file in both skill homes:

```sh
python3 ~/.agents/skills/ez-micro-plan/scripts/plan_check.py \
  .grok/plans/<slug>/plan.md --ready
```

It prints one `error:` or `warning:` line per finding and then a tally, so a parent reads
six lines instead of a plan:

```text
warning: T02 reads the L1-src brief from lane map
summary: 2 tasks | 2 lanes | 2 slots | wave width 2 | 0 errors, 1 warnings
T01
T02
```

The bare ids after the summary are the wave to spawn - `--ready` prints the tasks whose
`needs:` are all satisfied, capped at `slots`, and the parent takes that set rather than
the plan's order and spawns the whole wave in one turn.

The refusals are the collisions a fan-out otherwise discovers at wave 3; a plan with two
ready tasks on the same file and a
read-only role handed that file prints:

```text
error: T02 is explore but owns scripts/lib/search.sh
error: T01 and T02 both own scripts/lib/search.sh and no dependency orders them
warning: T02 reads the L1-src brief from lane map
summary: 2 tasks | 2 lanes | 2 slots | wave width 2 | 2 errors, 1 warnings
```

It also refuses:

- a missing task key
- a task with no `done:` check
- a `calls` budget over 25 (over 15 is a warning - 15 is the bar for a micro task, 25 is
  where the plan is wrong)
- a dependency cycle or an unknown dependency id
- a lane or context file that does not exist on disk
- a task without a `## Ledger` row
- a first wave narrower than `slots` (compared against `min(slots, task count)`, so a small
  plan is not scolded for being small, but a coarse one is)

The flags:

- `--slots N` overrides the plan's number
- `--json` prints the same findings as an object with `plan`, `slots`, `tasks`, `lanes`,
  `ready`, `errors` and `warnings` for a script to read
- `--no-files` skips the on-disk existence check for the briefs
- `--strict` makes warnings fail

Exit is 0 clean, 1 with violations, 2 when the plan path is missing or unreadable.

The plan is a work artifact rather than the record, so its tree stays out of git:
`notes_ensure_excludes` in `templates/common/notes-setup.sh` adds `.grok/plans/` to the
stack's global excludes file (`~/.grok/notes/exclude`, or the `core.excludesFile` you already
point at) next to `notes.md` and `.scratch-notes.md`, and `results/` is deleted once the
change is committed.

The seam is pinned by `bazelisk test //tests:bats_grok_subagent_slots_test`
(both twins' `[subagents]` block, the `coder.tf` validation, the `main.tf` derivation, and
the rulebook's slot-filling rule) and `bazelisk test //tests:bats_ez_micro_plan_test`
(the checker driven over a scratch plan tree).

## The seeded fleet suite

The seam above is what a fan-out costs; this is who is in it. The family has its own seeding
`coder_script`, `stack_fleet` (`templates/workspace/main.tf:753`,
`templates/devcontainer/main.tf:804`), which puts thirteen payloads in place on every start
from `templates/common/`, and `//scripts:seed-dev-env` seeds the same thirteen into a
contributor home through the `~/.grok/agents`, `~/.grok/personas` and fleet-skill rows of
`seed_seed_targets` (`scripts/lib/config_seed.sh:130-147`, seventeen of them; the
`documenter.md` row at 136 sitting in the middle belongs to the advisor family below).

The body that writes them is
`templates/common/stack-fleet.sh.tftpl`, its own body for the same one-argument reason the
two skill families have theirs
([coder-templates.md](coder-templates.md#the-one-argument-ceiling)). Thirteen is six agent
definitions, three persona overlays, and four parent-side skills.

### The six agent definitions

Each is a markdown file with YAML frontmatter whose body is the child's system prompt; the
seeds are `templates/common/<name>.AGENT.md` and they land at
`~/.grok/agents/<name>.md`. A definition is what fixes a role's model, tools and prompt
mode, which a persona deliberately does not (`~/.grok/docs/user-guide/16-subagents.md:77`).

| Definition | What it delivers | Baked lane |
|---|---|---|
| `explorer` | a digest of numbered claims, each with the `path:line` that proves it, plus what it looked for and did not find | `agent-explore` |
| `architect` | the approach, the single-writer slices, and the seam a consumer needs before it can be written | `agent` |
| `implementer` | one owned slice as a minimal patch, with its own check quoted | `agent-swarm` |
| `tester` | the verdict on one `done:` line: the command run verbatim and what it printed | `agent-swarm` |
| `reviewer` | findings ordered by what breaks if they stand, each with the command that proves it | `agent-review` |
| `security-auditor` | secrets, injection, authorization and egress hunts, ranked by what an attacker gets | `agent-review` |

#### The edit tools each definition names

Within these six, only `implementer` names `search_replace`, and only `implementer` and
`tester` name `write` at all; the other four name no edit tool and each says in its own body
that it edits nothing. The seventh definition `templates/common/` holds, `documenter`, is the
advisor family's rather than this one's and names both `search_replace` and `write`
(`templates/common/documenter.AGENT.md:5`), because the deliverable of that role is an edit to
a page - see [The five advisor commands](#the-five-advisor-commands).

`explorer` is the one definition here that inherits the MCP catalog, because it is the one
whose tools name
`search_tool` and `use_tool`; the other five set `mcpInheritance: none`,
the frontmatter key the guide documents for that choice
(`~/.grok/docs/user-guide/16-subagents.md:228`), on the seeds' own reasoning that an
inherited catalog with no MCP tool in `tools:` would be empty anyway.

#### The spawn ceiling

Three of the seven name `spawn_subagent`: `reviewer`, `security-auditor` and `tester`
(`templates/common/reviewer.AGENT.md:5`, `templates/common/security-auditor.AGENT.md:5`,
`templates/common/tester.AGENT.md:5`). `explorer`, `architect`, `implementer` and
`documenter` name none of it, so a mapper cannot recurse and the wave a spawner raises one
level down is made of read-only mappers. The `tools` list is what enforces that ceiling; the
body prose of each seed only explains it.

#### Which layer names a definition

**How one is selected.** Four layers name an agent definition, and they are not the same
knob:

- `[agent] name` in `~/.grok/config.toml` picks the definition for an interactive `grok`
  run; a missing name falls through to `GROK_AGENT`, which takes an absolute path or a bare
  agent name (`~/.grok/docs/user-guide/05-configuration.md:124-132`, `:810`).
- `--agent-profile` overrides both and loads no file, so that session runs the default agent
  unless the client names one (`~/.grok/docs/user-guide/15-agent-mode.md:69`).
- A child's type names its definition: `spawn_subagent` offers project and user agents in
  its `subagent_type` enum, which is how a parent asks for `reviewer` by name
  (`~/.grok/docs/user-guide/16-subagents.md:69-71`). A depth-1 child that spawns resolves
  its own children through these same layers, so a grandchild reaches the reader lane
  through the one `grok_explore_lane` pin and needs nothing set on the spawner.
- `[subagents.models]` pins the lane for that type, and it is what the workspace renders -
  see [The fan-out seam](#the-fan-out-seam).

The four layers can name different lanes: the guide ranks the per-type pin as applying "for
any parent" without ranking it against a definition's own `model:`
(`~/.grok/docs/user-guide/16-subagents.md:287`). All six bake the same alias their
pin defaults to, `implementer` and `tester` among them, so a workspace that wants its
writers somewhere specific should set the variable rather than rely on the file.
`/config-agents` (alias `/agents`) is where a person sees and toggles the set.

### The three persona overlays

`thorough-researcher`, `senior-implementer` and `skeptical-reviewer` ship as
`templates/common/<name>.PERSONA.toml` and land at `~/.grok/personas/<name>.toml`, where the
file stem is the persona name (`~/.grok/docs/user-guide/16-subagents.md:93`). Discovery runs
the project's `.grok/personas/`, then this user directory, then the bundled catalog, and an
inline `[subagents.personas]` table outranks all three (`:89-93`).

A persona is an overlay only: its `instructions` reach the child as a
`<system-reminder>` and move tone, output format and task focus, never the agent type, the
model, or the tools (`:77`) - which is why none of the three names either, and why the header
comment in each file says so. `thorough-researcher` and `skeptical-reviewer` also declare
`[[inputs]]` and `[[outputs]]` contracts, so a parent knows what to hand each role and what
artifact to expect back; `senior-implementer` declares none.

The caveat worth knowing before you wire one in: Grok Build applies personas through subagent
resolution and roles, not through a `spawn_subagent` parameter - the parent does not pass a
persona name when it spawns a child (`~/.grok/docs/user-guide/16-subagents.md:97`). A persona
is therefore configured, not handed over: it attaches through a role or through
`[subagents.personas]`, and `/personas` is where the catalog is read.

### The four skills

`templates/common/<name>.SKILL.md` for `feature-implementation`, `skeptical-review`,
`security-audit` and `bug-hunt`, each seeded twice - `~/.coder/skills/<name>/SKILL.md` for
the Coder Agents chat and `~/.agents/skills/<name>/SKILL.md` for the Grok Build CLI, the
second always a `cp` of the first:

- `/feature-implementation <request-or-issue> [--slots N] [--dry-run]` takes one request
  from Plan Mode to a verified change: map with read-only explorers, hand the split to
  `/ez-micro-plan`, fan the writers out, close with an independent tester and reviewer.
- `/skeptical-review <diff-spec|pr-number> [--focus <risk>] [--json]` takes the author's
  claim as unverified, re-runs the exact commands the producer said proved it, attacks the
  change from several independent angles, and reports each requirement kept or broken with
  the line that decides it.
- `/security-audit <path-or-diff> [--scope secrets|injection|authz|egress] [--json]`
  inventories sources and sinks separately, traces each source to a sink with read-only
  tracers, and ranks findings by severity with one checkable line of proof each.
- `/bug-hunt <symptom-or-issue> [--bisect <good-ref>] [--no-fix]` reproduces before
  touching anything, localises with explorers and a real bisect, tests competing hypotheses
  with a fleet, and ships the test that fails before the fix and passes after it.

All four name only the local aliases - `agent-explore` for their mapping lanes,
`agent-swarm` for their writers, `agent-review` for their skeptic - and none of them reaches
for a cloud model id, which is the rule in
[litellm-routing.md](litellm-routing.md#the-alias-table) rather than a preference.

### The five advisor commands

Five more commands ride a `coder_script` of their own, `stack_advisors`
(`templates/workspace/main.tf:784`, `templates/devcontainer/main.tf:835`), whose body is
`templates/common/stack-advisors.sh.tftpl`.
Four are advisors that each gate a different kind of work, and the fifth writes the local
map described at the end of this section.

Same contract and same two homes as the four above:
`~/.coder/skills/<name>/SKILL.md` for the chat and the
`cp` twin at `~/.agents/skills/<name>/SKILL.md` for the CLI, each written only while
absent, and `//scripts:seed-dev-env` seeds the same copies into a contributor home
through the twelve advisor rows of `seed_seed_targets`
(`scripts/lib/config_seed.sh:148-159`).

- `/documenter <commit-ish|path|PR-number> [--surface docs|readme|rulebook|comments]` documents
  a change that already exists: read the diff, fan read-only mappers over every documentation
  surface on `agent-explore` to find the text the change made wrong, write one file per writer,
  then put the result past an independent skeptic on `agent-review` that runs every command the
  new prose names.
- `/performance-optimizer <path|command> [--metric <name>] [--no-change]` takes a baseline with
  an instrument that is already local (`time`, `rg --stats`, Bazel `--profile`), hunts the cost
  with read-only mappers, ranks proposals by measured cost rather than how bad the code looks,
  lands at most one change, re-measures, and ends its skeptical pass on `agent-review`.
- `/debugger <symptom|failing-test|issue-number> [--no-fix]` is the gate against the
  guess-and-patch pass: no fix is written until a read-only `agent-explore` child has quoted the
  failing command and its real output, and the skeptic re-runs both the red and the green run.
- `/migrator <dep>@<version>|<api-change>` pins where a version actually lives by `path:line`,
  reads the upstream delta from a research lane rather than from memory, writes the plan and the
  rollback before touching anything, then fans the edits out and answers to a skeptic.
- `/ez-code-index [repo-path]` writes the local map described below.

One new role definition ships with this family rather than with the fleet: `documenter`
(`templates/common/documenter.AGENT.md`, landing at `~/.grok/agents/documenter.md`) is the
light read-and-write role `/documenter` dispatches, and it rides the same body as the skill so
a start has both or has neither.

#### The local code index

The code index is a file, not a service:

```sh
python3 ~/.agents/skills/ez-code-index/scripts/code_index.py --repo <clone>
```

It writes `code-index.json` for a program and `code-index.md` for a person under
`~/.grok/notes/<host>/<owner>/<repo>/` - the same notes directory `ez-learn` owns, outside the
clone, carried by the owner's `grok-notes-<owner-id>` volume, so nothing new runs and
nothing is committed.

`--home DIR` points it at another profile home instead of `$HOME`, and `--json` prints
the whole record instead of the one `ok: N files, M symbols -> ...` line. The helper is
`templates/common/ez-code-index.code_index.py`, seeded into a `scripts/` subdir of the same
skill directory the way the other helper-carrying skills ship theirs. The `code-index.md`
header records the `sha` it indexed, so compare that line against `git rev-parse HEAD` before
trusting a `path:line` the map hands you; a stale map is a fresh `rg`.

### The saved workflows

`.grok/workflows/fleet-verify.js` is the same three phases as a saved workflow rather than a
procedure an agent follows by hand: **Map** puts two read-only explorers on `agent-explore`,
**Implement** puts one writer on `agent-swarm`, and **Verify** puts an independent skeptic on
`agent-review` that re-runs the producer's own command and returns a structured verdict of
`kept`, `broken` or `mixed` with the evidence behind each finding. Its three model ids are
aliases in `litellm/config.yaml`, so `grok inspect` is the check after an alias edit - a name
the catalog no longer carries fails the run rather than degrading it.

Three more sit beside it in the same directory, invocable by name under the same rule that every
id in them is a local alias:

- `implement-reviewed` (`{ goal, question, verify }`) is `fleet-verify` with the repair round
  added: map on `agent-explore`, fan the change out on `agent-swarm`, close on `agent-review`,
  then one bounded fix round for the findings the skeptic marked `broken` and one more skeptic
  pass. Without `verify` the writer names the proof and the skeptic challenges that choice.
- `debug-fix` (`{ symptom, issue, bisect }`) is the defect shape: evidence on `agent-explore`
  before any edit, because **Reproduce** quotes the failing command with the output it really
  produced and no reproduction means no fix; two read-only explorers then localise on disjoint
  hypotheses (one bisecting when a known-good ref is given), one writer on `agent-swarm` lands
  the fix with the test that is red before the change and green after, and a skeptic on
  `agent-review` re-runs both runs.
- `open-bugs` (`{ issue, label, labelInProgress, limit, openPr, scratchDir }`) is the queue
  shape: **Discover** reads the open `bug`-labelled issues off the tracker with gh on
  `agent-explore` (an empty queue is a reported outcome, not a failure), **Triage** puts one
  read-only explorer per candidate on that lane to reproduce the report or say what it saw
  instead, **Fix** puts one writer per reproducible issue on `agent-swarm` with the test red
  before the change and green after, and **Review** puts a skeptic per fix on `agent-review`
  that re-runs the producer's own command. The issues go out as one wave and each runs its
  phases in order. **Write back** posts every outcome through one seam that keeps both tracker
  rules - `gh issue comment <n> --body-file`, the body never in argv, and the in-progress label
  only after `gh label list` proves the repository already declares it - and it never closes,
  reopens, reassigns, labels beyond that one label, or milestones an issue. **Associate** is
  what keeps a bug tied to its fix: the run writes the pull-request body to
  `/tmp/open-bugs/pr-body-issue-<n>.md` (`scratchDir` moves it), prints that path in its report,
  and posts the issue comment that names the branch, the tip sha `git rev-parse` reports, and
  that path. The keyword is decided, not typed: `Closes #<n>` only when the fixer reported
  PR-ready and the skeptic kept every claim it tested, `Refs #<n>` for everything else, and it
  lives in that body file alone - never in a commit subject, never in an issue comment, never on
  a number this run did not work. If a pull request already exists for the branch, the comment
  names its number and url, which is the link back onto the issue.
- **The push and the pull request are the operator's.** `openPr` is off, so a run reports
  `push and pull request: NOT run - the operator's action` rather than going quiet, and the
  hand-off agent is told not to push and to print the two commands instead. The checklist for
  that step, per issue row in the report: read `pr-body:` and open that file, fill the two
  lines it asks for, then run the printed `git push -u origin fix/<n>-<slug>` and
  `gh pr create --head fix/<n>-<slug> --body-file <that path>`, both through
  `env -u GH_TOKEN -u GITHUB_TOKEN`. Passing `openPr: true` hands those two commands to the
  run's own hand-off agent, and each row then reports what it really did under `pushed:`.
  Pick by what you have in front of you - `open-bugs` is the discovery half,
  `debug-fix` is the single-symptom half, and `bug-hunt` is the skill an agent follows by hand.

### The seeded workflow tier

A workflow has two homes and Grok reads both. A *project* workflow is
`.grok/workflows/<name>.js` at the root of the trusted clone, and a *user* workflow is
`~/.grok/workflows/<name>.js` (`$GROK_HOME/workflows`); only `.js` files run, a built-in
keeps its name over both, and a project name keeps its name over a user one. That second
tier is the one that travels, so it is the one this stack seeds.

The reason is the first tier's load rule: project workflows come from the clone in front of
the session, so the workflows this repo carries are visible in this repo and nowhere else -
a workspace that cloned some other repository never sees them. `coder_script
"stack_workflows"` therefore writes all four general-purpose ones into the user home on
every start, from `templates/common/stack-workflows.sh.tftpl`, the route the agent
definitions and the personas already take. Where each piece lives:

- the canonical body: `templates/common/<name>.workflow.js`, one per workflow;
- the repo-tier entry: `.grok/workflows/<name>.js`, a symlink to `../../templates/common/`
  like `.grok/agents/architect.md` is, so there is one copy of each to edit;
- the seed: `templates/common/stack-workflows.sh.tftpl`, declared in both template twins.

The seed is marker-aware, the hooks contract rather than the absent-only one the skills
keep: a written file carries `// managed-by: evo-t1-coder-stack`, a copy still carrying it
gets the current bytes on every boot, a copy whose marker you deleted is yours and the boot
leaves it alone with a `note:`. Nothing is ever deleted. A workflow you write yourself under
`~/.grok/workflows/` under a name the stack does not use is untouched, and a project
workflow of the same name still overrides the user copy - which is why the four names here
are reserved and yours should differ. `//tests:bats_stack_workflows_test` pins the links,
the marker pair, and both twins.

### Hooks

Six payloads in `templates/common/` become one manifest and five files under `~/.grok/hooks/`:
`evo-t1-hooks.json` plus, under `hooks/bin/`, the four guards and the deny list the command
guard reads.

Grok Build reads `~/.grok/hooks/*.json`, and a handler `command` that is a relative path
resolves against the manifest's own directory and is started directly, so each script is seeded
`0755` with the payload's `#!` line still on row 1. Every one reads one line of event JSON on
stdin. The two PreToolUse guards always print a parseable decision there - `{"decision":"allow"}`
or `{"decision":"deny","reason":...}` - and a deny additionally exits 2; a PostToolUse handler
cannot block at all, so it stays silent on stdout unless it has something to tell the model.

No guard exits non-zero on its own account, so a broken one cannot wedge a session.

#### The secret guard

- `PreToolUse`, matcher `Edit|Write|search_replace|write` -> `bin/secret-guard.sh`: denies a
  write whose text carries an AWS access-key id, a GitHub token, a Slack token, a Google API
  key, a `-----BEGIN ... PRIVATE KEY-----` block, a URL that carries both a user and a
  password, or a credential-keyword assignment (`api_key`, `secret`, `token`, `password`, and
  their upper-case SDK spellings) whose value carries a digit.

  - It sweeps the fields a write puts text into - the flat `new_string`, `content`, `contents`,
  `command` and `text`, and
  `new_string`, `new_text`, `content`, `contents` and `text` inside each entry of a batched
  `edits` array - one level deep and no deeper, so an unknown nesting is not swept and the
  truncation check is what covers it.

  - It leaves the read-side `old_string`/`old_text` alone, so a secret an older commit wrote
  cannot convict every later edit beside it.

  - A value that names the environment instead of carrying a secret is the correct pattern, not a
  hit, so
  `os.environ/X`, `os.environ["X"]`, `process.env.X` and `getenv("X")` are folded to one short
  token before the scan. The deny reason names the pattern
  class and never the matched text.

  - It fails open on an event it cannot parse, and denies when
  the runner reports `toolInputTruncated`, because that is text the scan never saw
  (`templates/common/hooks.secret-guard.sh`).

#### The command guard

- `PreToolUse`, matcher `Bash|run_terminal_command` -> `bin/dangerous-command-guard.sh`: tests
  `toolInput.command` against the list beside itself and denies, naming the file, the line
  number and the pattern that matched.

#### The post-edit formatter

- `PostToolUse`, matcher `Edit|Write|search_replace|write` -> `bin/post-edit-format.sh`: the
  formatters the golden image already ships, at the same invocations `//:fix` uses for shell and
  Bazel files - `shfmt -w -s -i 2 -ci` for `.sh`, `buildifier -mode=fix` for `BUILD`,
  `BUILD.bazel`, `MODULE.bazel` and `.bzl` - plus `ruff format --quiet` for `.py`. It refuses:

  - anything outside `CLAUDE_PROJECT_DIR`, addressed directly or reached through a link (the
    containment test runs again on the resolved path)
  - anything under `.git/`, `bazel-out/`, `bazel-bin/`, `bazel-testlogs/`, `node_modules/` or
    `__pycache__/`, `.env` and `.env.*`
  - any path containing `/.grok/`, `/.agents/` or `/.coder/`

  It only ever answers, never blocks: a rewrite is reported as `additionalContext`, and silence
  means nothing changed or the formatter is not on PATH.

#### The selective test runner

- `PostToolUse`, matcher `Edit|Write|search_replace|write` -> `bin/selective-test-runner.sh`:
  **off unless `EVO_T1_HOOK_TESTS=1`**. When it is on, the hook derives one Bazel label -
  `//tests:bats_<stem>_test` straight from a `tests/bats/<stem>.bats` path, otherwise the first
  label `bazelisk run //scripts:bazel-map -- tests-for <path>` prints - and starts
  `bazelisk test <label>` detached with `nohup`, logging to
  `${TMPDIR:-/tmp}/evo-t1-hook-tests/<sanitized-label>.log`.

  It returns one context line naming the label and that log; it never runs a test inline, so the
  edit turn does not wait on the suite.

#### Extending the deny list

The deny list is the extension point. `~/.grok/hooks/bin/deny-patterns.txt` holds one extended
regex per line, `#` starts a comment and blank lines are ignored, so an operator forbids one
more command by appending one line - and because there is no allow list, deleting a line is the
only way to permit something again.

That copy is stack-owned: the boot rewrites it from
`templates/common/hooks.deny-patterns.txt` while its `managed-by:` marker stands, so a line
appended in a workspace is gone at the next start.

Land the rule in the seed (with the Bats case
in `tests/bats/stack-hooks.bats` that denies it), or delete the marker from that one file to keep
a copy of your own, which the boot then leaves alone. A line that does not compile as an ERE is
skipped with a
single note on stderr rather than blocking every shell call, which is why the file's own header
carries the one-line compile check to run before you commit a rule:
`LC_ALL=C grep -E -q -- '<pattern>' </dev/null`.

#### Three limits of a clean scan

Three limits are worth knowing before you trust a clean scan, and each is a choice rather than
an oversight.

- The secret guard's generic assignment scan requires a digit on the matched line, which is
  what keeps a variable name from reading as a credential.

  - The cost runs in both directions: `api_key = XyZaBcDeFgHiJk` (a name the list
    carries, no digit) walks through, and so does
    `github_token_string = Abcd1234EFGH5678` (a digit, a name the list does not carry).

  - Only the five known-format scans (AWS, GitHub, Slack, Google, private-key block)
    plus the credential-bearing URL are exact, and they run on the text before the
    environment-reference fold, so a vendor key pasted inside `getenv("...")` still
    denies.

  - What the fold does excuse is entropy sitting in the name position of a reference -
    `os.environ/KEY_XyZaBc12345678` - because that position is where the correct
    pattern lives and the guard's whole job is to keep it writable.

  - A missed shape is a line in `hooks.secret-guard.sh`, not a reason to trust the ones
    it does catch.
- The command guard matches the whole command string, case-sensitively and byte-wise, so a
  command that *quotes* a denied form is refused the same way a real one is: `awk '/dd if=/'
  notes.txt` denies, and so does a commit message that names `rm -rf` followed by a space.

  Stripping quoted regions before matching would clear those and would catch a quoted dot
  (`find "." -type f -delete`) for free, and it would equally blind the guard to `sh -c "..."`
  and `bash -c "..."`, the indirection a command actually travels through most - so the string
  is read as written, and the few rules that have to see inside a quote spell the quote
  themselves.

  The remedy for the rest is to rewrite the quoted sentence; the stack's own
  `Bash(rm -rf *)` permission deny behaves the same way for the same reason.
- The deny list is a floor, not a fence. It catches the forms this repo has actually measured,
  and a novel destructive command walks straight through it. Nothing in a hook reads the state
  the command will act on, which is why "confirm before an action that is hard to undo" stays a
  rulebook rule that no pattern can replace.

#### Who seeds the hooks

Two things seed them, and both are wanted. `coder_script "stack_hooks"`
(`templates/workspace/main.tf:810`, `templates/devcontainer/main.tf:861`) runs
`templates/common/stack-hooks.sh.tftpl` on every workspace start (`run_on_start`, gated on
`data.coder_workspace.me.start_count`), and `scripts/lib/config_seed.sh:160-165` carries the
same six targets for a host tree or a workspace that missed a boot.

This family is **marker-aware** rather than absent-only like the skills: a copy that still
carries the stack marker - the `"__evoT1Stack": true` key in the manifest, which has to stay
parseable JSON, and the `managed-by: evo-t1-coder-stack` comment in the shell files - is
rewritten on every start.

That is deliberate, because a guard that drifted from the seed is a silent behaviour change:
these scripts decide what a session may run and what it may write. Delete the marker and the
copy is yours, and the boot leaves it alone.

### The rule the suite exists to enforce

Every multi-file change ends with an independent review panel that wrote none of it, on
`agent-review`, before anything is reported done: three angles sent in one turn
(requirements, proof, adversary), each owning no file, where one skeptic over all three
angles is enough for a single-file fix.

The rulebook states it as a requirement, not a suggestion
(`templates/common/GROK_BUILD_AGENTS.md`, "Mandatory independent review"),
and its reasoning is one sentence: a delegated result is a claim, and a review that trusts
the claim rather than the artifact is not a review.

Each panelist re-runs the producers'
`done:` commands rather than reading their reports of them, which is why `tester`,
`reviewer` and `security-auditor` exist as separate definitions whose spawn tool reaches
read-only mappers, rather than as instructions tacked onto the writer.

### How a seeded file becomes yours

The family splits by home, and the split is deliberate:

- The fleet's six `~/.grok/agents/*.md` definitions and its three
  `~/.grok/personas/*.toml` overlays are **marker-aware**, the way
  `~/.grok/AGENTS.md` is: a copy that still carries `managed-by: evo-t1-coder-stack` is
  stack-owned and gets the current seed text on every start, so a stale role definition
  cannot silently change how every child in every workspace behaves. Delete the marker line
  and the file is the person's - the boot leaves a marker-free copy alone.
- `~/.grok/hooks/` is **marker-aware** on the same rule, with two spellings because its two
  kinds of file have two readers: the `"__evoT1Stack": true` key, which is the only marker
  spelling that leaves the manifest parseable JSON, and the `managed-by: evo-t1-coder-stack`
  comment in the four scripts and the deny list. A guard that drifted from the seed is a
  behaviour change nobody sees, so this family gets the refresh rather than the first-write
  rule. See [Hooks](#hooks).
- The skill copies are **absent-only**, like the `ez-` families: a `SKILL.md` that
  already exists belongs to the user and is never rewritten - the fleet's eight, and the
  advisor family's twelve, which are five `SKILL.md`s plus `code_index.py` in each of the two
  homes. The advisor family's `~/.grok/agents/documenter.md` rides that absent-only contract
  with the skill it serves rather than the refresh the fleet's six keep, on the body's own
  reasoning that a stale piece of advice misleads one run while a stale guard decides what a
  session may do.
- A managed path that is a **symlink** is left alone in both families. The marker test
  reads the file a path points at, so writing through a link would replace a file the
  stack does not own - a link aimed at `~/.grok/AGENTS.md` would have the seed overwrite
  the rulebook. A link a person planted stays theirs, and one symlinked root stops the
  seed before its first write.

Either way the fix is the seed under `templates/common/` and a re-materialize, never a patch
to the copy that is running - the same rule the two skill families above live by
([the three stack-seeded skill commands](#the-three-stack-seeded-skill-commands)).

## Grok Build state: shared state, per-workspace config

Every workspace gets its own `/home/coder` volume, and `~/.grok` sits on it as an
ordinary directory, `config.toml` included.

What is shared is **state**: three nested mounts inside that home volume, one per concern,
each a Docker volume named for the owner (`grok-notes-<owner-id>`,
`grok-memory-<owner-id>`, `grok-sessions-<owner-id>`), referenced by name rather than
declared as a Terraform resource, which every workspace of that owner mounts read-write at
its own path **while that workspace is in `shared` mode**.

### The two modes

- `shared` (the default here): the three state directories ride their owner's
  volumes, so the notes, the memory and the sessions are the same files in every
  workspace that account owns, and they survive a rebuild. `config.toml` is not part
  of that share - each workspace renders its own.
- `private`: no per-owner volume at all. The notes, the memory and the sessions live
  on that workspace's own home volume, differ from its siblings, and die with the
  workspace. `config.toml` is per workspace either way.
- Set in two places: the template variable `grok_profile_mode`
  (`GROK_PROFILE_MODE=shared|private` in `.env`, forwarded by `push-template.sh` as
  `--var grok_profile_mode`), and the create form's per-workspace **Grok profile**
  field, which defaults to the variable. One workspace can therefore sit outside the
  shared state while its siblings stay inside it.
- Changing the mode needs a **rebuild** - the three nested mounts either exist or they
  do not. A workspace that goes from `shared` to `private` starts on whatever those
  three directories already hold on its own home volume: nothing is copied, and the
  owner's volumes are left alone.

### What is shared

In `shared` mode, three directories: `notes/` (the canonical copy of each
repository's private scratch `notes.md`), `memory/`, and `sessions/` - one volume
each, mounted at `~/.grok/notes`, `~/.grok/memory` and `~/.grok/sessions`. Nothing
else under `~/.grok` is shared: `config.toml`, `skills/`, the MCP warm caches and a CLI
you installed yourself under `~/.grok/bin` are regular files on this workspace's own
home volume, and those die with the workspace.

The CLI's own skill directories,
`skills/` and `bundled/`, are never created here without an x.ai sign-in; the stack's
skill seeds live under `~/.coder/skills` and `~/.agents/skills`, outside this tree.

The whole-profile volume this template used to mount over all of `~/.grok`,
`grok-profile-<owner-id>`, is still mounted in `shared` mode, but **read-only** and at
`~/.grok-legacy`, purely so the first start after that split can copy its `notes/`,
`memory/` and `sessions/` across once: `notes_hoist_legacy` in
`templates/common/notes-setup.sh` takes a concern only when the destination is missing
or empty, and nothing reads that mount afterwards. A later `chore:` removes it.

#### The notes file and its watcher

`notes/<host>/<owner>/<repo>/notes.md` is keyed per git remote, so every clone a
workspace holds — the primary and each additional repository — has its own file. What you
edit is the regular file at the clone root: that is what the editor, the terminal and a
nested dev container all see, since the inner container mounts the clone bind and has
its own `~/.grok`.

The copy runs both ways, and not only at boot.

Startup copies the live file here and restores it when a recreate leaves the clone with
nothing or with only the seeded stub line, and then leaves **one background watcher per
container** that repeats the back-copy about every 30 seconds (`NOTES_SYNC_INTERVAL`, in
seconds) over every clone under `$HOME/workspace`; the devcontainer template watches its
`/srv/coder-devcontainers` bind root instead, since those clones sit there rather than
under the workspace home.

The watcher is single-instance behind a non-blocking `flock` on
`$HOME/.notes-sync.lock`, in the container's own home rather than the shared volume,
because each of the owner's workspaces needs its own.

#### What a recreate keeps

That is what makes "survives workspace recreate" true rather than a hope: an edit is on the
volume within roughly one interval, so a recreate no longer waits on someone restarting the
workspace to pick up what was typed since the last boot. What is not promised is the tail
- a file written in the last two seconds is left for the next tick, because copying it
whole could archive a half-saved file.

Going the other way, two guards stop a recreate from erasing notes: a live file that is
empty or still holds only the seeded stub never replaces
a canonical copy carrying real notes, and a real canonical copy restores over such a stub
in a clone.

Before any substantive canonical copy is replaced it is archived as
`notes/<host>/<owner>/<repo>/backups/notes-YYYYmmdd-HHMMSS.md`, keeping the newest
`NOTES_BACKUP_KEEP` (10 by default), and that directory is where an operator recovers notes
after an accident. `grok_profile_mode=private` mounts no shared volume, so those notes die
with that workspace; `shared` is the default. Like the memory tree, the last workspace
started for a given user and repository wins.

#### What boot writes

Two things about that start are worth knowing before you go looking for a vanished
setting. Boot **writes `git config --global core.excludesFile`** — but only when you
have not set it yourself. Left unset it points at `~/.grok/notes/exclude`, which lists
`notes.md` and `.scratch-notes.md`, so from then on *every* git repository in that
workspace ignores both names at any depth; if you already set the option, those two
lines are appended to the file it names and nothing else about it is touched.

Boot also drops the same two lines into each clone's own `.git/info/exclude`, which is the
layer that works even with no global config at all.

And when a repository tracks a `notes.md`
of its own, the scratch file is written as `.scratch-notes.md` beside it instead — your
clone is never asked to delete somebody else's committed file.

### The out-of-band session archive

Beside the three state mounts there is one more volume, and it shares nothing with
them: `grok-session-archive`, mounted read-write at `/var/lib/grok-session-archive`.
It is deliberately outside `~/.grok`, and it is host-wide rather than per-owner - every
workspace on that daemon mounts the same volume, each writing under its own
`workspaces/<hostname>/` leaf.

- Like the per-owner volumes it is a plain string name in `main.tf`, not a
  `docker_volume` resource, so Docker creates it on the first container start that
  names it and reuses it afterwards.

#### How the archive is written

- The copy is made by a background `rsync` that stage 9 of `startup.sh.tftpl` starts
  and leaves running for the life of the container: every 180 seconds it mirrors
  `~/.grok/sessions/` into `workspaces/<leaf>/`, skipping `*.tmp` and `*.lock`. It
  runs without `--delete`, so a session pruned from the live tree keeps its archived
  copy. `flock -n` on a per-leaf lock file in the volume root is what keeps the stage
  idempotent: Coder re-runs the startup body on every start, and a second loop over the
  same leaf would only double the write rate.

  The stage is best-effort: it warns and
  carries on when the volume root or the leaf is not writable, or when `flock` is
  missing, and re-tests for the sessions directory each tick because the CLI creates
  that directory on its first run, which can be long after boot.
- The leaf is the container hostname with anything outside `[A-Za-z0-9._-]` folded to
  `-`, so a name carrying a slash cannot write outside `workspaces/` and an empty one
  cannot collapse every workspace into a single mirror. The sanctioned reader accepts
  exactly that character set, so the write side and the read side agree.
- A fresh named volume arrives `root:root` while the agent runs as `coder`, so the
  stage chowns the mount point to the home owner first, exactly as the `~/.grok` and
  `~/.shared` volumes above do.

#### Who may read the archive

- **Nothing reads it back.** `~/.grok/sessions` stays the only session state the CLI,
  the rulebook, and Coder's session management know about; no config key and no startup
  logic points at the archive, and the hooks deny list
  (`templates/common/hooks.deny-patterns.txt`) refuses any agent command that names the
  path, the volume, or a globbed form of either. The point is a copy an operator can
  inspect later, from the host, after the workspace that made it is gone.
- Read it with `bazelisk run //scripts:session-archive -- list`. Every verb mounts the
  volume read-only, so the reader cannot write it either, and there is no pruning verb:
  the volume grows until an operator removes it.

  The raw `docker run -v <volume>:ro` and
  `docker volume rm <volume>` forms are host-shell commands, and the same deny list that
  protects the archive from a workspace agent refuses them there - run them in a host
  shell, not from an agent prompt.
- One consequence of the volume being host-wide rather than per-owner: the leaf is named
  for the workspace, and Coder workspace names are unique per organization. Two owners
  who both call a workspace `dev` mirror into the same `workspaces/dev`, and every
  workspace user is uid 1000, so nothing on the filesystem separates them inside the
  volume. That is acceptable for the archive's only purpose - an operator reading their
  own box's history - and is why no agent is ever given a route to it. Give the leaf an
  owner component if a box ever holds more than one trusted operator's sessions.

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
- There is no longer one `config.toml` to set once for a whole account: each
  workspace renders its own from the template on start. A hand edit there lasts until
  **that** workspace restarts and touches no other workspace, and the next start after
  a template re-push brings the file back from the new template.

## Search lane and MCP servers

- `searxng` (SearXNG metasearch, host port 8181) is the search backend the stack runs
  for itself: keyless engines only, no key, no account, no request logging. A
  workspace reaches it through the host gateway, so the workspace networks stay
  untouched.

### Why the native search tool is parked

- It is **not** a model transport, and the native tool is parked: both twins render
  `disable_web_search = true` at top level, so a session starts with no `web_search`
  tool at all. Measured 2026-10-25: no model transport this box ships serves that
  tool type.

  - The `agent` group is LiteLLM in front of the Spark boxes
  (`openai/Qwen3.8-Flash-Next`), and it refuses the request before anything is
  fetched - `tools of type 'web_search' are not supported: this server runs function
  tools only`, HTTP 400.

  - `supports_backend_search = false` does not route around it, because the client-side
  fallback still hands the model alias a `web_search`-typed tool, which is the exact
  shape that endpoint rejects. The fallback lane fails too: it is the `coder` alias,
  Ollama `qwen2.5-coder:32b`, and that model is not pulled on the host.

  - So `web_search = "agent"` and `supports_backend_search = false` stay as
  they are - the role stays filled so re-enabling is a one-key flip - but while the
  key reads `true` nothing dials it.

### The MCP search lane and its probe

- The `searxng` MCP stdio server is what answers instead, and it is the search lane
  rather than a fallback: both templates render that block gated on `search_mcp`,
  which defaults to true. It dials `$SEARXNG_URL` (default
  `http://host.docker.internal:8181`), the same key `main.tf` puts in the agent
  environment.

  It carries nine tools - `search`, `image_search`, `news_search`,
  `video_search`, `music_search`, `paper_search`, `fetch_content`, `autocomplete`,
  `list_engines` - and an agent's two workhorses are the first and the seventh:
  `search` for anything that is not a library question, `fetch_content` for a URL
  already in hand. Measure the self-hosted lane with:

  ```sh
  bazelisk run //scripts:search-check
  ```

  - An empty result page and "no answer" are different answers, which is why the probe
  reports which one it got.

  - It also names every engine the instance has parked and
  the reason its backend gave (`parked by its backend: google: access denied`),
  read out of the reply body whether or not that reply found results - an instance
  running on half its engines is visible there before it starts answering empty.

  - A park is temporary: SearXNG holds an engine out for `search.suspended_times`
  seconds after it refuses, so re-run before writing one off.

  - `--json` adds `engines_parked`. It checks the service hop; `grok mcp doctor searxng`
  inside the workspace checks the MCP hop.

  - The binary it launches
  (`/opt/npm-global/bin/searxng-mcp-server`) is baked into the golden image, so a
  probe that answers with results plus a failed handshake is a server, URL or port
  problem, not a missing package.

### Turning native search back on

- To put native search back on a transport that really serves the tool: flip the key
  to `false` in the seed - both `templates/workspace/grok-config.toml.tftpl` and
  `templates/devcontainer/`'s copy - and re-push, which applies it fleet-wide. For one
  workspace without a push, the create form's **Grok config extras** field appends
  free-form TOML verbatim to that workspace's file. Either way start a new session,
  and expect the same 400 back if the endpoint still answers function tools only.

### The three declared MCP servers

- **MCP servers: the default render declares three - `github`, `context7` and the
  gated `searxng` server, which is the search lane itself.** Each is a boolean gate in
  the template, so one env flag parks exactly one block and a template re-push applies
  it fleet-wide: `GITHUB_MCP=false`, `CONTEXT7_MCP=false`, `SEARCH_MCP=false`.

  The `searxng` block names the pre-installed `searxng-mcp-server` binary (pinned in
  `images/dev/tool-versions.env` and baked into the golden image), is gated on
  `search_mcp` (default true) and dials the service above through `SEARXNG_URL`.

  That URL is one of six keys the render sets in `[mcp_servers.searxng.env]`; the
  others pin the bridge's own tuning rather than taking its compiled-in defaults:

  - `SEARXNG_TIMEOUT_MS` (20s, above the instance's per-engine budget and equal to the
    probe's `--timeout`)
  - `SEARXNG_CACHE_TTL_MS` (15 minutes, which switches on the bounded 128-entry response
    cache that ships disabled, so a repeated query stops re-dialling backends that already
    refused this instance)
  - `SEARXNG_MAX_RESULTS` (a ceiling that keeps one search inside the MCP output cap - on the
    pinned 1.0.77 CLI that cap rides `GROK_MAX_MCP_OUTPUT_BYTES`, because `grok inspect`
    still answers `[mcp] — unrecognized config key` and never applies it)
  - `SEARXNG_DEFAULT_SAFESEARCH` (mirrors `search.safe_search` in `searxng/settings.yml`)
  - `SEARXNG_DEFAULT_LANGUAGE` (`all`, so an image bump cannot quietly start geo-filtering
    every agent search)

### The offline stdio servers stay undeclared

  The five offline stdio servers (`filesystem`, `memory`, `sequential-thinking`,
  `git` and `time`) stay pre-installed in the image (`npm -g` for the first
  three, `uv tool` for the Python two), but the rendered `config.toml` names
  none of them: the session traces collected on this machine called none of
  their tools, and a declared-but-unused server still costs every session its
  handshake time and tool schemas. Declare one by hand and check a stubborn
  server with `grok mcp doctor <name>` inside a workspace.

### The github server

- The `github` server (`https://api.githubcopilot.com/mcp/`) renders by default even
  though it needs a token and outbound network: with GitHub tools on, the agent can
  drive the repository it is working in, and the cheaper failure is the block that
  renders with no credential and pays one failed handshake per session. `github_mcp`
  (default true) is the gate; `$GH_TOKEN` comes from Coder External Auth, never from a
  PAT.

### The context7 server and its cache

- The `context7` server (library and API docs) also renders by default, and is the
  only cached one. `context7_mcp` (default true) is its gate, and the block it
  renders runs `mcp-cache-proxy` in front of the official `context7-mcp` - two packages
  pinned in `images/dev/tool-versions.env` and baked into the golden image, so parking
  or restoring it is a flag plus a template push, while changing the packages
  themselves takes an image rebuild.

  - The proxy keeps its SQLite cache under
  `~/.grok/mcp-cache-proxy/`, which sits on this workspace's own
  home volume, so each workspace warms its own cache, and the cache TTL is 12 h: the first
  lookup of a
  library reaches the Context7 API and needs network, while an identical lookup inside
  the TTL is answered locally.

  - `CONTEXT7_API_KEY` is optional and the lane does not
  depend on it: an empty value sends no `Authorization` header at all, so the server
  handshakes and answers at the public rate limit, with private libraries the only
  thing out of reach. A key in `.env` plus a re-push fills the env.

  - What *parks* the
  lane on purpose is `CONTEXT7_MCP=false` in `.env` (relayed by `push-template.sh`) or
  `--var context7_mcp=false` on a template push; a `[mcp_servers.context7]` block
  missing from a render that got neither of those is a defect, not a park. The lookup
  order is fixed - `resolve-library-id` first, then `query-docs` on the id it returns -
  and `search_tool` lists the live tool names rather than a hardcoded list.

  - Prove it
  with `grok mcp doctor context7` inside a workspace.

### Proving the lanes with mcp-check

- Prove all three at once with `bazelisk run //scripts:mcp-check`: it reads the
  rendered `~/.grok/config.toml`, reports whether each lane is declared, whether its
  `command=` binary is present, whether the lane's credential and cache config are
  there, and what each server's handshake says. A binary the box cannot find is image
  drift (the running `evo-t1-dev` predates the npm bake), and the check prints the
  pinned `npm i -g --prefix /opt/npm-global` command that restores it.

### The three failure shapes

- A lane an agent needs fails in exactly three shapes, and that check tells them
  apart, so run it before editing anything:
  - **The block is missing from the rendered config.** That is a failure, not a
    warning: the default render declares the lane, so something took it away - a push
    passed its gate `false`, the workspace runs an older template, or the file lost
    its stack marker and nothing re-renders it.

    Remedy: clear the gate and re-push, then re-materialize the file with
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

### What the rulebook tells the agent

- What the agent is told about all this lives in `~/.grok/AGENTS.md`, which
  `coder_script.agents_seed` renders from `templates/common/GROK_BUILD_AGENTS.md` into a
  body of its own (see "The one-argument ceiling" in
  [coder-templates.md](coder-templates.md#the-one-argument-ceiling)). Two sections cover
  the lanes. **Research
  lanes** makes a lookup part of the normal loop rather than a last resort, with the
  routing fixed by question type:

  - a library, framework, CLI or setup question goes to `context7` (resolve the library id
    first, then query docs on that id)
  - anything else on the web goes to the `searxng` `search` tool
  - a URL already in hand goes to `searxng`'s `fetch_content`, because Grok's native
    `web_fetch` is unavailable here too - `features.web_fetch` is on, but on a non-xAI
    endpoint that tool only runs through `toolset.web_fetch.proxy_endpoint`, and this stack
    sets none

  It also states that native `web_search` is parked so nobody spends a turn rediscovering
  the 400.
  **Tool output stays out of the parent context** makes that
  tool use delegated work: the child returns a digest - numbered findings, each one
  claim, one source URL and at most two lines of support, no raw result dumps,
  confidence stated - and keeps the raw pages to itself.

### Cline, Roo, and the shared editor settings

- Cline and Roo/Kilo are pre-wired to the LiteLLM proxy (endpoint from `litellm_url`,
  default `http://host.docker.internal:4000/v1`; model alias `agent`, with
  `agent-low`/`agent-medium`/`agent-xhigh`/`agent-xhigh-fast`/`agent-swarm`/`agent-swarm-fast`/`coder`/`coder-fast`/`chat`
  listed in `__evoT1StackModels`).

  The seed is
  `settings.json.tftpl`, copied onto the per-owner volume
  `vscode-settings-<owner-id>` (mounted at `~/.shared/vscode/settings.json`) only
  while that file is absent, where it stays as the shared overlay. What code-server
  actually reads, `~/.local/share/code-server/User/settings.json`, is a real file on
  this workspace's own home volume, which `templates/workspace/startup.sh.tftpl`
  rewrites on every start in three passes:

  - the per-workspace render as the base
  - Every key of that overlay on top so an API key entered once still wins
  - `workbench.colorTheme` re-asserted from the render last, so a theme put in the
    shared overlay loses to this workspace's own theme (the **Editor colour theme** field,
    `vscode_color_theme`, default `Default Dark Modern`)

Startup chowns that volume to the home owner before the first write (empty named volumes
are `root:root` 755).

Edits to the overlay stick, and every workspace that owner has gets them layered over its
own render; delete it to copy the template in again. From the
host it is the volume's `settings.json`:

  ```sh
  docker run --rm -it -v vscode-settings-<owner-id>:/vscode alpine vi /vscode/settings.json
  ```

### The built dev container bakes the seed

- A built dev container sees neither the volume nor that overlay, so it is the one
  place the seed is **baked** rather than layered: the inlined
  `coder_script.code_server` fork bakes a base64 copy of it and writes it over the
  dev container's private `User/settings.json` (or merges over a copy that survived a
  rebuild, when `jq` is on PATH; without `jq` the existing file is kept).

  Edits inside a built dev container therefore survive neither a rebuild nor a look at
  the shared file. Everywhere else no settings map is passed at all, because a merge
  would replace the symlink.

### Installing the extensions by hand

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

#### The seeder command

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

#### Which config is the default

The deployment default follows the health gate. `agent` is registered as the default,
and when LiteLLM reports no healthy deployment behind the Spark alias the Arc `chat`
config takes the default in its place. That matters because a chat opened without an
explicit model pick has only the default to resolve to, so a stack that comes up while
the Spark lane is dark still gets an Agents chat that answers.

An existing config is left as it stands, since this API surface has no PATCH: the
script names the Admin
screen to correct it when a stored row drifted.

The closing summary counts how many of the four auxiliary lanes carry a pin, and a lane
left without one prints a `warning:` that names the lane.

#### The wait window and the seeder log

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

#### What the script writes

A chat turn needs an enabled chat model config - the chat's own pick, else the
deployment default, else it errors before the first tool call - and that wiring is
what the script writes. It mints a short-lived admin API token from the stack's own
Postgres (`token_name 'stack-coder-agents'`, deleted by the trap, never printed) and
drives the server's experimental chat API:

#### The provider row

- an `openai-compat` AI provider named **`litellm`** (not `litellm-auto`), base URL
  `http://litellm:4000/v1` - LiteLLM over the compose network, *server-side*,
  authenticated with `LITELLM_MASTER_KEY`. The agent dials the in-process AI Gateway
  (aibridge), which forwards to the provider's `base_url` + `/chat/completions`, so
  `/v1` has to be part of the base URL and the key has to match the live proxy.

  With `.env` leaving the key empty, compose still boots the proxy on its
  `change-me-litellm` interpolation default, and that default is what gets sent.
  Created when absent, drift-patched when an existing provider carries a drifted
  `base_url` or key.

#### The model config rows

- chat model configs `agent` (context limit 262144, set as the default; LiteLLM bakes
  `reasoning_effort` `xhigh`), `agent-low` / `agent-medium` / `agent-xhigh` (same
  lane with a baked thinking level, not default), `agent-swarm` (same lane and the same
  baked level with the session pin lifted for that group, not default), and `chat`
  (32768), for models not already registered.

  - `coder` and `coder-fast` stay out on purpose: on this stack's IPEX-LLM runtime those
  weights return tool calls as plain text with no `tool_calls`, and an agent turn without
  callable tools cannot browse or edit, so registering them would only add a silently
  broken model to the pickers.

  - `context_limit` is the agent's own compaction budget (a 70 per cent default
  compaction threshold applies), which is why it is pinned per alias. The
  two fast-compaction lanes are absent too, for a mechanical reason rather than a measured
  one: the hop keys on the summary instruction the Grok CLI appends, the aibridge behind
  these pickers never sends one, and `compaction-fast` is no client alias at all, so an
  Agents chat on `agent-xhigh-fast` would be a chat on `agent-xhigh` under a longer name.

  - Before that sweep the script asks the proxy `GET /v1/model/info` and `GET /health`
  and joins them on `model_id`, so it knows which aliases still have a healthy
  deployment.

  - An alias with none is not registered: `chat` goes unhealthy the moment
  `qwen2.5:7b` is not pulled on the Arc, and a dead entry in the model picker is a chat
  that errors on the first send.

  - `/health` is read without `?check_deployments=true` because that form fires a live
  completion per deployment and evicts the Spark prompt caches the health-check notes
  in `litellm/config.yaml` warn about.

  - The gate fails open: a proxy that will not answer leaves every alias
  registerable, and `CODER_AGENTS_LIVE_ALIASES="agent chat"` overrides it outright.

#### The auxiliary pins

- pins for the four auxiliary lanes - `general` and `explore` (the two subagent
  types) prefer `agent`, `compaction` and `title_generation` (the helper calls)
  prefer `chat` - chosen only from the aliases the health gate left standing, and
  written when a lane carries no pin or is pinned to one of these configs whose alias
  has since gone unhealthy.

  A pin aimed at a config the script did not create is the
  admin's and is left alone.

  Both helper lanes landing on a dead `chat` is what made
  conversations lose their titles and die at the compaction threshold, which is why a
  stale pin now moves instead of being kept forever.

  Neither preference list names `agent-swarm`: that config is registered for the model picker
  only, because these lanes
  serve the control-plane chat agent, which is one conversation, and one conversation
  wants the pin.

#### The read-only drift check

- a read-only drift check on the stored configs: a config that is disabled, is not
  the deployment default, or carries a `context_limit` that does not match the alias's
  serving window is reported with a `warning:` and the screen to fix it on. The
  experimental chat API has no PATCH for model configs, so these are named rather than
  written.
- a three-line system-prompt addendum, appended after Coder's default prompt text
  (`include_default_system_prompt: true`), that keeps the delegation and
  secret-hygiene rules which must hold even when a chat has no workspace attached.

#### The AI Gateway stays off

Coder's optional AI Gateway proxy stays off - LiteLLM remains the model transport,
which is why no AI-Gateway keys exist in `docker-compose.yml`.

### Whose compaction is whose

The `compaction` pin above belongs to Coder's chat agent and to nothing else.

It is one of the four auxiliary lanes the seeder writes into Coder's own model-config
store, so it decides which alias serves *that* agent's summariser and title call.

It never reaches a Grok Build CLI: the CLI reads no Coder table, and its compaction
summary is an **in-session call on the session model** - the `[models] default` alias,
`agent` here - which is why the summary inherits that lane's output ceiling (measured
on the wire at `max_tokens: 32768`) instead of a cheap helper lane's.

`[models] session_summary` is not that call either; the key serves titles and the
session recap.

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

#### The two fast-compaction lanes

That is still the shape on the two fast-compaction lanes, and it is why the remedy is
server-side rather than a client setting: a session on `agent-xhigh-fast` or
`agent-swarm-fast` sends the same in-session summary call on its session model, and
`litellm/compaction_router.py` moves that one request onto the Arc group
`compaction-fast` before the proxy picks a deployment. Nothing in `~/.grok/config.toml`
asks for it, every other call of that session still rides the Spark lane, and a session on
any other alias compacts as it always has.

The limit is the Arc's own 32768-token window:
above `EVO_T1_FAST_COMPACTION_INPUT_LIMIT` (24000 estimated tokens) the summary goes to
`agent-low` instead, which keeps the 262144-token window and drops the baked `xhigh`,
because a slow summary beats one Ollama silently clamped. The key cannot raise that limit:
the target group's declared `max_input_tokens` caps it and logs one line when it does.

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

Twenty-six files seed into every new workspace, on first boot and only while the file is
absent (the fleet family adds seventeen more paths under `~/.grok/agents`,
`~/.grok/personas` and the two skill homes, on the contracts in
[The seeded fleet suite](#the-seeded-fleet-suite)):

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
11. `~/.coder/skills/reflect-and-evolve/SKILL.md`
12. `~/.agents/skills/reflect-and-evolve/SKILL.md`
13. `~/.coder/skills/reflect-and-evolve-repo/SKILL.md`
14. `~/.agents/skills/reflect-and-evolve-repo/SKILL.md`
15. `~/.coder/skills/ez-strong-types/SKILL.md`
16. `~/.agents/skills/ez-strong-types/SKILL.md`
17. `~/.coder/skills/ez-strong-types/scripts/type_baseline.py`
18. `~/.agents/skills/ez-strong-types/scripts/type_baseline.py`
19. `~/.coder/skills/ez-trunk-based-repo/SKILL.md`
20. `~/.agents/skills/ez-trunk-based-repo/SKILL.md`
21. `~/.coder/skills/ez-micro-plan/SKILL.md`
22. `~/.agents/skills/ez-micro-plan/SKILL.md`
23. `~/.coder/skills/ez-micro-plan/scripts/plan_check.py`
24. `~/.agents/skills/ez-micro-plan/scripts/plan_check.py`
25. `~/.coder/skills/trunk-refactor/SKILL.md`
26. `~/.agents/skills/trunk-refactor/SKILL.md`

#### What each numbered path is for

- 1 and 2 are the Coder agent's *default* discovery paths.
- 3 and 4 are the same text under the Grok Build CLI's convention, and the CLI is
  what `execute`-lane delegation drives. The chat agent dedupes skills by name,
  first match wins, home scope before a working-dir path, so one agent never loads a
  skill twice: the twins exist for the CLI, not as a second source for chat.

#### Which body writes each family

- 1-4 are written by `startup.sh.tftpl`. 5-14 are the stack's five single-agent skill
  commands and are written by `coder_script.stack_skills`, whose own `execve` carries the
  five payloads;
  they ride their own script body rather than the startup argument because that argument
  has a single-argument ceiling of its own
  ([coder-templates.md](coder-templates.md#the-one-argument-ceiling)). Each `.agents`
  copy is a `cp` of the managed `.coder` copy, never a second inline body, so the pair
  cannot drift.
- 15-26 are the five commands of that second family - the four repository conversions
  plus the `/ez-micro-plan` dispatcher - and are written by
  `coder_script.stack_repo_skills`, a second body with its own ceiling, for the same
  reason and because this family also ships the python helpers 17-18 and 23-24
  that two of its five commands invoke by `~/.agents` path. Same absent-only contract and
  the same `cp` twin rule; the helper directories are made by the body, so a workspace that
  already has the `SKILL.md` but lost a helper still gets the helper back. The sixth
  command of that body, `/ez-bazel-first`, is absent from this list on purpose: it is
  seeded into each Bazel repository's own checkout rather than into the two skill homes.

#### The memory and skill trio

- 5 and 6 are `/ez-learn`: this stack's copy of the upstream memory commands `/flush`,
  `/dream`, `/remember` and `/memory`. It turns the current session into durable facts -
  flush the conversation into a session log under the workspace's `~/.grok/memory/`
  directory, dream those logs into an organized `MEMORY.md`, save one note, or browse and
  clear what was stored. Reaching past those logs into the raw transcripts under
  `~/.grok/sessions/` is opt-in depth, done only when the operator asks for it. Its
  default mode is report-only, and it writes memory files, never a skill.

- 7 and 8 are `/ez-skillify`, which turns the session that just worked into a skill from its
own transcript, and 9 and 10 are `/ez-create-skill`, which scaffolds one from what the
operator describes.

The three payloads are
`templates/common/ez-learn.SKILL.md`, `ez-skillify.SKILL.md` and
`ez-create-skill.SKILL.md`, on the same absent-only contract.

`/ez-create-skill` stands in for the bundled platform skill
`create-skill`, which arrives only in the skills
bundle behind an x.ai sign-in this stack does not have; `/ez-skillify` has no published
upstream counterpart at all; and the memory family `/ez-learn` copies is upstream
*built-ins*: `/flush`, `/dream` and `/memory` are gated behind cross-session memory,
which is off by default, while `/remember` is a pager command with no such gate. Either
way the seed is what makes the three commands exist.

Each ships under its own `ez-` name to stay clear
of those upstream names, since a user-scope skill overrides a
same-named bundled one and a seed named `create-skill` would hide the bundled copy on a
workspace that ever does sign in.

The boot and the reseed delete a leftover
marker-carrying `skills/learn/SKILL.md` from before the rename. See the CLI section
above.

#### The orchestration protocol text

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
  working-dir-relative `.agents/skills`, which resolves inside the agent's working dir

  (`/home/coder` in `workspace`; in `devcontainer` with the toggle on, the
  cloned folder under `/srv/coder-devcontainers/...`, where a dev container built on
  the sidecar carries its own home and no seeded path is visible from inside it
  anyway).

#### Where the marker sits in each seed

- Each seeded file carries the stack marker - the `managed-by: evo-t1-coder-stack`
  comment, or the `"__evoT1Stack": true` / `__evoT1Stack = true` key in a JSON or TOML
  file - in `SKILL.md` directly under the `---` frontmatter, since the agent's skill
  parser requires frontmatter on line 1 and silently drops anything else.

  Delete a file to take it over; edit it and the stack leaves it alone.
  `~/.grok/config.toml` is the one seed where deleting a file is not the way: it needs
  both marker lines gone, see
  [The rendered `~/.grok` config](#the-rendered-grok-config).

  Either way the marker never reaches the model: the agent strips HTML comments from
  injected instruction text.
- The seeds live per workspace, on that workspace's own home volume, and seeding
  does not care whether the three shared state mounts exist.

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
tip SHAs; `/trunk-refactor` is the deep version of that same model - six phases, twelve
criteria, and a report that carries every branch it proposes for deletion with its tip SHA.
All four take a repository path and work on that checkout, so they are useful in
a workspace cloned against any of the fleet's repositories.

They differ from the authoring trio in one structural way: two of them shell out to a
python helper, so their seed ships `scripts/owned_files_check.py`, `scripts/glob_budget.py`
and `scripts/type_baseline.py` beside the `SKILL.md`. Those helpers are stack payload like
everything else here, which means the copy in a workspace is stack-owned while it carries the
marker, and the way to fix a helper is to fix the seed under `templates/common/` and
re-materialize, never to patch the copy that is running.

`/trunk-refactor` and `/ez-trunk-based-repo` cover one model at two depths, and both
discover a target repo's own gates at inventory time rather than assuming Bazel, so each
works in a Compose, K3s, Ansible or Terraform repository too. The canonical body is
`templates/common/trunk-refactor.SKILL.md`; the repository that ships it keeps a tracked
symlink at `.grok/skills/trunk-refactor/SKILL.md`, which is what makes it a slash command
there, and its prose twin is `docs/workflows/trunk-feature-flags-refactor.md`.

The fifth payload `coder_script.stack_repo_skills` seeds is not a converter.
`/ez-micro-plan` is the parent's protocol for splitting one change across a fleet of
subagents and proving the split dispatches; how its slots, lane and check fit together is
[The fan-out seam](#the-fan-out-seam).

### The reflection runbooks

#### The session reviewer

`/reflect-and-evolve` reviews past Grok Build sessions and turns what it finds into planned changes.
It reads the per-session `signals.json` under `~/.grok/sessions/<escaped-cwd>/`, ranked by the bundled
sweeper `~/.agents/skills/reflect-and-evolve/scripts/session_signals.py` - in the repository
that ships it, `templates/common/reflect-and-evolve.session_signals.py`, which is still the only
sanctioned way into `~/.grok/sessions/` - plus the `/ez-learn` session logs and the notes file.
It changes the seeds in the shipping repository, never the copies a workspace booted with.
Seeded like the rest of the suite by `coder_script.stack_skills`: canonical at
`templates/common/reflect-and-evolve.SKILL.md`, and discovered in the shipping repository
through the `.grok/skills/reflect-and-evolve/SKILL.md` symlink, pinned by
`tests/bats/reflect-and-evolve-skill.bats`.

### The repo-scoped runbook

`/reflect-and-evolve-repo` is its sibling against a different subject: where
`/reflect-and-evolve` improves the agent setup, this one reviews past work in *this
repository* and turns what it finds into planned improvements to code, project
conventions, scripts, docs and configs.

It reads the same ranked `signals.json` table through the same bundled
`~/.agents/skills/reflect-and-evolve/scripts/session_signals.py` (in the shipping
repository, `templates/common/reflect-and-evolve.session_signals.py`, which is the
canonical source the seed reads), which stays the only
sanctioned way into `~/.grok/sessions/`, and it adds what a repo run has and a session run does
not: git history, and the repo's own tooling and gate.

Seeded like the rest of the suite by `coder_script.stack_skills`: canonical at
`templates/common/reflect-and-evolve-repo.SKILL.md`, and discovered in the shipping
repository through the `.grok/skills/reflect-and-evolve-repo/SKILL.md` symlink, pinned by
`tests/bats/reflect-and-evolve-repo-skill.bats`.

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

### The credential question

**Why the daemon and not the Coder API.** A workspace that can host a session is a
*running* one, and a running workspace is a labelled container: both templates stamp
`coder.workspace_id` and `coder.workspace_name`, the same labels
`scripts/github-auth.sh` enumerates.

Reading the daemon needs no credential, which matters because the only Coder token this
stack mints is the root-equivalent one `scripts/push-template.sh` creates for the length
of a push and deletes on the way out.

A chat turn should not mint one to answer "what is running", so where a verb belongs
to Coder rather than to the daemon the CLI prints the hand-off command.

### Reading the right container

**Two details that make the answer correct.** Each workspace creates a
`coder-<id>-dind-sidecar` carrying the same labels; it runs a Docker daemon and no
shell, so it is dropped by name. And a tmux server belongs to one uid and listens on
`/tmp/tmux-<uid>/default`, so the sockets are enumerated per uid - `docker exec`
lands as the image's user, and asking *that* user for its default server reports
"no sessions" for an agent the operator can see on screen.

### What each state word means

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
