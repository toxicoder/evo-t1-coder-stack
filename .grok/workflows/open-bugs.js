/**
 * ---
 * name: open-bugs
 * description: Sweep the tracker's open bug issues, triage each one with a read-only explorer that reproduces it, fix the reproducible ones on the swarm lane with a test that is red before the change, post the progress back to each issue with gh, then have one independent skeptic per fix re-run the producer's own command
 * when_to_use: When the bug queue has open issues nobody has picked up and you want the whole sweep done at once - discovery, reproduction, fix, tracker write-back, and an independent review per issue - rather than one hand-run session over a report you already have in front of you.
 * phase: Discover -- Read the open bug-labelled issues off the tracker with gh; an empty queue is a reported outcome, not a failure
 * phase: Triage -- One read-only explorer per candidate on agent-explore reads the body and every comment, reproduces or states why it cannot, and returns a structured verdict
 * phase: Fix -- One writer per reproducible issue on the swarm lane, working that issue number, with the test red first and green after
 * phase: Write back -- Post progress to each issue with gh issue comment and the body in a file, label it in progress, and never close it
 * phase: Review -- One skeptic per fix on agent-review re-runs the producer's own command rather than trusting its report
 * ---
 */

// Local lanes only. Every model id here is an alias in litellm/config.yaml over the three
// Spark boxes: agent-explore is the read/search lane (pin lifted, so a wave spreads over every
// box), agent-swarm is the fan-out lane, and agent-review is the skeptic lane. A cloud id would
// not resolve on this box, and a name the catalog does not carry makes the agent fail, so check
// `grok inspect` after editing an alias.

export default async function openBugs(args) {
  const onlyIssue = args?.issue;
  const label = args?.label ?? "bug";
  const workingLabel = args?.labelInProgress ?? "status:in-progress";
  const limit = Number.isFinite(Number(args?.limit))
    ? Math.max(1, Math.floor(Number(args?.limit)))
    : 5;

  // The gh prefix is not decoration: the token pair Coder injects at workspace start expires
  // about an hour later and gh consults it directly, so an unprefixed gh call is a 401 waiting
  // to happen mid-fan-out.
  const listCommand =
    "env -u GH_TOKEN -u GITHUB_TOKEN gh issue list --state open --label " +
    `${label} --json number,title,labels,url`;
  const cmd = (command) => "`" + command + "`";
  const viewCommand = (number) =>
    `env -u GH_TOKEN -u GITHUB_TOKEN gh issue view ${number} --comments`;
  const commentCommand = (number, file) =>
    `env -u GH_TOKEN -u GITHUB_TOKEN gh issue comment ${number} --body-file ${file}`;

  // One auth path, and it is a checker with a verdict, not a guess. A HANDOFF line is three
  // clicks a human owes the Coder UI, so it ends the run instead of starting a workaround.
  const authRule =
    "If a gh call fails on authentication, run " +
    "`bazelisk run //scripts:github-auth -- check <repo-url>` once and quote its last line; " +
    "`push would FAIL` means run `bazelisk run //scripts:github-auth -- fix <repo-url>` once, " +
    "then retry that call once. A line beginning HANDOFF means stop and report the three " +
    "Coder-UI clicks: GitHub reauth, Install GitHub App for private repos, restart the " +
    "workspace. Never hand-roll a GIT_ASKPASS script, never write a credential.helper line, " +
    "never run gh auth login, never read .env, and never put a token in argv, a URL, or a " +
    "committed file.";

  const discovery = await host
    .agent(
      `Read-only discovery of this repository's open bug queue. Run ` + cmd(listCommand) + ` and ` +
        `report what it returned. ` +
        (onlyIssue
          ? `This run works one issue: keep only #${onlyIssue}, and if gh does not list it, say ` +
            `so in note rather than substituting another issue. `
          : `Keep at most ${limit} issues, oldest first, and say in note how many the query ` +
            `returned in total. `) +
        `Report every issue you keep with its number, title, labels, and url exactly as gh ` +
        `returned them - the number is what every later phase works from. Do not triage, ` +
        `reproduce, or edit anything here. An empty queue is a normal answer, not a failure: ` +
        `report ok with no issues and say what you ran. ` + authRule,
      {
        label: "Discover/queue",
        readonly: true,
        model: "agent-explore",
        schema: {
          type: "object",
          required: ["ok", "issues"],
          properties: {
            ok: { type: "string", enum: ["ok", "auth-failed", "error"] },
            issues: {
              type: "array",
              items: {
                type: "object",
                required: ["number", "title"],
                properties: {
                  number: { type: "integer" }, title: { type: "string" },
                  labels: { type: "array", items: { type: "string" } }, url: { type: "string" },
                },
              },
            },
            note: { type: "string" }, handoff: { type: "string" },
          },
        },
      },
    )
    .wait();

  if (discovery.status !== "completed") {
    return [
      "verdict: no queue", `why: the discover agent did not finish (status ${discovery.status})`,
      `command: ${listCommand}`, "nothing was dispatched",
    ].join("\n");
  }
  if (discovery.structured?.handoff) {
    return [
      "verdict: HANDOFF - the credential cannot write, and this run stops here",
      `checker: ${discovery.structured.handoff}`,
      "a human owes three clicks in the Coder UI: GitHub reauth, Install GitHub App for private " +
        "repos, restart the workspace",
      "no triage, fix, write-back, or review ran",
    ].join("\n");
  }
  if (discovery.structured?.ok !== "ok") {
    return [
      "verdict: no queue", `why: the tracker query failed (${discovery.structured?.ok})`,
      `command: ${listCommand}`, `note: ${discovery.structured?.note ?? "(none)"}`,
      "nothing was dispatched",
    ].join("\n");
  }

  const queue = (discovery.structured.issues ?? [])
    .filter((issue) => Number.isFinite(Number(issue.number)))
    .map((issue) => ({
      number: Number(issue.number), title: issue.title ?? "(no title)",
      url: issue.url ?? "(no url)", labels: issue.labels ?? [],
    }))
    .filter((issue) => !onlyIssue || issue.number === Number(onlyIssue))
    .slice(0, limit);

  if (!queue.length) {
    return [
      "verdict: queue empty", `label: ${label}`, `command: ${listCommand}`,
      `note: ${discovery.structured.note ?? "(the discover agent returned none)"}`,
      "no open bug issue matched, which is a clean tracker, not a failure; nothing was dispatched",
    ].join("\n");
  }

  // One write-back seam for every post this workflow makes, so the two rules that are easy to
  // break on a tracker - body in a file, never in argv, and never a close - are stated once.
  const postBack = (issue, body, { addLabel = false } = {}) =>
    host
      .agent(
        `Write back to open bug issue #${issue.number} ("${issue.title}") on this repository's ` +
          `tracker. Post exactly this body, verbatim, as a new comment. Write it to a scratch ` +
          `file outside the repository first, then run ` +
          cmd(commentCommand(issue.number, "<that file>")) +
          ` - the body never goes in argv, because a multi-line body in a shell argument is ` +
          `mangled. ${
            addLabel
              ? `Then mark it in progress with ` +
                cmd(`env -u GH_TOKEN -u GITHUB_TOKEN gh issue edit ${issue.number} --add-label ${workingLabel}`) +
                `. If that label does not exist in this repository, report that instead of ` +
                `creating one: never create, rename, or delete a label. `
              : ""
          }` +
          `Hard rules: never close, reopen, reassign, or milestone this issue, and never write a ` +
          `closing keyword (Closes #, Fixes #) in the comment - the close belongs to the pull ` +
          `request and to the human who merges it. Keep every line pure ASCII. Report the comment ` +
          `url gh printed, or the error it printed. ` + authRule +
          `\n\nBody to post, verbatim:\n\n${body}`,
        {
          label: `Write-back/issue-${issue.number}`,
          model: "agent-swarm",
          schema: {
            type: "object",
            required: ["posted"],
            properties: {
              posted: { type: "string", enum: ["commented", "failed", "not-posted"] },
              comment_url: { type: "string" },
              note: { type: "string" },
            },
          },
        },
      )
      .wait();

  // Each issue runs its own phases in order; the issues themselves go out as one wave.
  const workIssue = async (issue) => {
    const row = {
      number: issue.number, url: issue.url, verdict: "unchecked", branch: "(none)",
      commit: "(none)", prReady: "no", posted: "not-posted", review: "not-run",
    };
    const setPosted = (reply) => {
      row.posted = reply.status === "completed" ? (reply.structured?.posted ?? "failed") : "failed";
      if (reply.structured?.comment_url) row.posted += ` (${reply.structured.comment_url})`;
    };

    const triage = await host
      .agent(
        `Read-only triage of open bug issue #${issue.number} ("${issue.title}") at ${issue.url}. ` +
          `Read the report before anything else: run ` + cmd(viewCommand(issue.number)) + ` and ` +
          `read the body AND every comment. Quote the reporter's reproduction and acceptance ` +
          `wording verbatim in acceptance, because that wording is what a fix has to answer to. ` +
          `Then try to make it fail: run the command, test, or gate the report names and quote ` +
          `what it really produced. If you cannot reproduce it, say so and report exactly what you ` +
          `ran and what you saw instead - do not invent a failure, and do not edit anything. Name ` +
          `the suspected area with path:line, propose the smallest fix that would satisfy the ` +
          `reporter, and rate the risk of that fix (blast radius, which tests or gates it touches, ` +
          `whether a feature flag is on the path). Post nothing to the tracker: a separate agent ` +
          `writes back. ` + authRule,
        {
          label: `Triage/issue-${issue.number}`,
          readonly: true,
          model: "agent-explore",
          schema: {
            type: "object",
            required: ["reproduced", "area", "proposed_fix", "risk"],
            properties: {
              reproduced: { type: "string", enum: ["reproduced", "not-reproduced", "unclear"] },
              command: { type: "string" }, output: { type: "string" },
              acceptance: { type: "string" }, area: { type: "string" },
              proposed_fix: { type: "string" }, risk: { type: "string" },
            },
          },
        },
      )
      .wait();

    if (triage.status !== "completed" || triage.structured?.reproduced !== "reproduced") {
      // "Cannot reproduce" is a finding, not a fix: what was run and what was seen goes to the
      // issue, and the issue stays open for the reporter.
      row.verdict = triage.status === "completed"
        ? (triage.structured?.reproduced ?? "unclear")
        : `triage-incomplete (${triage.status})`;
      const why = `Command run: ${triage.structured?.command ?? "(none)"}\nWhat it produced:\n${triage.structured?.output ?? "(nothing captured)"}`;
      setPosted(await postBack(
        issue,
        `## Bug hunt: could not reproduce #${issue.number}\n\n` +
          `Verdict: ${row.verdict}. Suspected area: ${triage.structured?.area ?? "not located"}.\n\n` +
          `${why}\n\nNo fix branch, no commit: this run reproduced nothing, so it fixed nothing, ` +
          `and the issue stays open. Nothing here closes this issue.`,
      ));
      return row;
    }

    const reproBlock =
      `Command: ${triage.structured.command ?? "(not reported)"}\n` +
      `Output:\n${triage.structured.output ?? "(not captured)"}`;
    const acceptance = (triage.structured.acceptance ?? "").trim();
    row.verdict = "reproduced";

    setPosted(await postBack(
      issue,
      `## Bug hunt: reproduced #${issue.number}, starting work\n\n` +
        `Reproduced by an independent read-only agent on this tree.\n\n` +
        "```\n" + reproBlock + "\n```\n\n" +
        `Suspected area: ${triage.structured.area}\nProposed fix: ${triage.structured.proposed_fix}\n` +
        `Risk: ${triage.structured.risk}\n\n` +
        (acceptance ? `Reporter's acceptance wording:\n> ${acceptance}\n\n` : "") +
        `Work is about to start on a short-lived fix branch. This comment does not close this ` +
        `issue; only the pull request and the human who merges it do that.`,
      { addLabel: true },
    ));

    const fix = await host
      .agent(
        `Fix open bug issue #${issue.number} ("${issue.title}", ${issue.url}). Read the report and ` +
          `every comment first: run ` + cmd(viewCommand(issue.number)) + `. Work that issue number ` +
          `and nothing else.\n\nReproduction (confirm it fails before you touch anything):\n` +
          `${reproBlock}\n\nWhat the triage agent found:\nSuspected area: ` +
          `${triage.structured.area}\nProposed fix: ${triage.structured.proposed_fix}\n` +
          `Risk: ${triage.structured.risk}\n\n` +
          (acceptance ? `The reporter's acceptance wording, which this run answers to:\n${acceptance}\n\n` : "") +
          `Cut a short-lived branch off the tip of main named fix/${issue.number}-<slug>, and ` +
          `commit there. Do not push and do not open a pull request - that hand-off belongs to ` +
          `the parent and the human reviewer. Required: add the test that is red on the pre-fix ` +
          `tree and green after your fix, in the suite that already covers the area. Run it first ` +
          `and quote the failing output verbatim, then make the smallest change that passes it and ` +
          `quote the passing output verbatim. Keep the diff to exactly what this issue asks: no ` +
          `drive-by refactor, reformat, or rename, and pure ASCII in every line you write. Follow ` +
          `the repository's own AGENTS.md and run the gate its docs name. Report the branch, the ` +
          `commit sha, the files you changed, the test path, and both runs. Post nothing to the ` +
          `tracker - a separate agent writes back. ` + authRule,
        {
          label: `Fix/issue-${issue.number}`,
          model: "agent-swarm",
          schema: {
            type: "object",
            required: ["branch", "commit", "pr_ready"],
            properties: {
              branch: { type: "string" }, commit: { type: "string" },
              files: { type: "array", items: { type: "string" } }, test_path: { type: "string" },
              red_output: { type: "string" }, green_output: { type: "string" },
              gate: { type: "string" },
              pr_ready: { type: "string", enum: ["yes", "no"] },
            },
          },
        },
      )
      .wait();

    row.branch = fix.structured?.branch ?? "(not reported)";
    row.commit = fix.structured?.commit ?? "(not reported)";
    row.prReady = fix.status === "completed" ? (fix.structured?.pr_ready ?? "no") : "no";
    if (fix.status !== "completed") row.verdict = `fix-incomplete (${fix.status})`;

    const review = await host
      .agent(
        `Independent skeptical review of the fix for open bug issue #${issue.number} ` +
          `("${issue.title}", ${issue.url}). You wrote none of this and you change nothing.\n\n` +
          `Reproduction:\n${reproBlock}\n\nThe fixer reported:\n\n` +
          `${fix.status === "completed" ? fix.text : "(the fixer did not finish)"}\n\n` +
          `Re-run the command the fixer says proves the fix, yourself, rather than trusting the ` +
          `report: the new test against a pre-fix tree recreated in a scratch copy outside the ` +
          "repository (`git worktree add` at the commit before the change), confirming it fails " +
          `for the reason the report gives, and the same test against the current tree, confirming ` +
          `it passes. Also confirm the reproduction above no longer fails, that the test is new ` +
          "rather than a pre-existing one being re-run, and that the diff (`git diff`, `git log`) " +
          `holds nothing the issue did not ask for. ` +
          (acceptance ? `Answer the reporter's acceptance wording, quoted: ${acceptance}\n` : "") +
          `Default position: the claim is wrong until the artifact proves it. Cite path:line and ` +
          `the command you ran for each finding, and post nothing to the tracker. ` + authRule,
        {
          label: `Review/issue-${issue.number}`,
          readonly: true,
          model: "agent-review",
          schema: {
            type: "object",
            required: ["verdict", "findings"],
            properties: {
              verdict: { type: "string", enum: ["fixed", "not-fixed", "mixed", "unchecked"] },
              findings: {
                type: "array",
                items: {
                  type: "object",
                  required: ["claim", "status", "evidence"],
                  properties: {
                    claim: { type: "string" },
                    status: { type: "string", enum: ["kept", "broken", "unchecked"] },
                    evidence: { type: "string" },
                  },
                },
              },
            },
          },
        },
      )
      .wait();

    // A skeptic that did not finish is reported as unchecked, never dropped.
    const panel = review.status === "completed" && review.structured
      ? review.structured
      : { verdict: "unchecked", findings: [{ claim: "the skeptic did not return a verdict", status: "unchecked", evidence: review.status }] };
    const problems = panel.findings.filter((finding) => finding.status !== "kept");
    row.review = panel.verdict;
    if (panel.verdict === "not-fixed") row.prReady = "no";

    setPosted(await postBack(
      issue,
      `## Bug hunt: fix attempt for #${issue.number}\n\n` +
        `Branch: ${row.branch}\nCommit: ${row.commit}\nTest: ${fix.structured?.test_path ?? "(not reported)"}\n` +
        `PR-ready: ${row.prReady} | Independent review: ${panel.verdict}\n\n` +
        `Red before the fix:\n` + "```\n" + (fix.structured?.red_output ?? "(not captured)") + "\n```\n" +
        `Green after the fix:\n` + "```\n" + (fix.structured?.green_output ?? "(not captured)") + "\n```\n" +
        `Reproduction command: ${triage.structured.command ?? "(not reported)"}\n\n` +
        (problems.length
          ? `Unchecked or broken claims:\n${problems.map((f) => `- [${f.status}] ${f.claim} (${f.evidence})`).join("\n")}\n\n`
          : "The independent skeptic kept every claim it tested.\n\n") +
        `No pull request is open yet and this comment closes nothing: closing this issue happens ` +
        `on the pull request, at a human merge.`,
    ));

    return row;
  };

  const rows = await Promise.all(queue.map(workIssue));
  const ready = rows.filter((row) => row.prReady === "yes");
  const reproduced = rows.filter((row) => row.verdict !== "not-reproduced");
  const verdict = !reproduced.length
    ? "none-reproduced"
    : ready.length === rows.length
      ? "all-ready"
      : ready.length
        ? "partial"
        : "none-ready";

  const lines = [
    `verdict: ${verdict}`,
    `label: ${label}`,
    `open bug issues swept: ${rows.length}`,
    `reproduced: ${reproduced.length}   fixed and PR-ready: ${ready.length}`,
    "closing is not this workflow's job: every issue stays open for the pull request and the merge",
    "",
  ];
  for (const row of rows) {
    lines.push(
      `- #${row.number} ${row.url} verdict: ${row.verdict} | branch: ${row.branch} | ` +
        `commit: ${row.commit} | pr-ready: ${row.prReady} | posted: ${row.posted} | ` +
        `review: ${row.review}`,
    );
  }
  return lines.join("\n");
}
