/**
 * ---
 * name: debug-fix
 * description: Reproduce a defect before anyone edits, localise it with two parallel explorers, fix it with a test that is red before the change and green after, then have an independent skeptic re-run both runs
 * when_to_use: When something fails and the report may or may not be real - a bug report, a failing command, or a regression between two refs - and you want the reproduction proven, the fix pinned by a test, and the result disproved on the review lane.
 * phase: Reproduce -- One read-only explorer runs the failing command and quotes it with its real output; no reproduction, no fix
 * phase: Localise -- Two read-only explorers work disjoint hypotheses on agent-explore, one bisecting when a known-good ref is given
 * phase: Fix -- One writer on the swarm lane lands the fix with the test that is red first and green after
 * phase: Prove -- An independent skeptic on agent-review re-runs both the red and the green run and confirms the test was really red before the change
 * ---
 */

// Local lanes only. Every model id here is an alias in litellm/config.yaml over the three
// Spark boxes: agent-explore is the read/search lane (pin lifted, so a wave spreads over every
// box), agent-swarm is the fan-out lane, and agent-review is the skeptic lane. A cloud id would
// not resolve on this box, and a name the catalog does not carry makes the agent fail, so check
// `grok inspect` after editing an alias.

export default async function debugFix(args) {
  const symptom =
    args?.symptom ?? args?.query ?? args?.goal ?? "the defect described in the current session";
  const issue = args?.issue;
  const knownGood = args?.bisect;

  const repro = await host
    .agent(
      `Read-only. Reproduce this defect exactly as reported: ${symptom}\n\n` +
        (issue
          ? `Read the report first: run ` +
            "`env -u GH_TOKEN -u GITHUB_TOKEN gh issue view " + issue + " --comments`" +
            `, then quote the reporter's reproduction and acceptance wording verbatim in the acceptance ` +
            `field, because that wording is what this run answers to. `
          : "") +
        `Run the failing command yourself and quote it, with the output it really produced, verbatim. ` +
        `If you cannot make it fail, say so, report what you ran and what you saw instead, and do not ` +
        `invent a failure, guess at a cause, or edit anything.`,
      {
        label: "Reproduce/explorer",
        readonly: true,
        model: "agent-explore",
        schema: {
          type: "object",
          required: ["reproduced", "command", "output"],
          properties: {
            reproduced: { type: "string", enum: ["reproduced", "not-reproduced", "unclear"] },
            command: { type: "string" }, output: { type: "string" }, acceptance: { type: "string" },
          },
        },
      },
    )
    .wait();

  // No later phase runs on an unconfirmed reproduction.
  if (repro.status !== "completed" || repro.structured?.reproduced !== "reproduced") {
    const why = repro.status === "completed"
      ? `${repro.structured?.reproduced}: the command never failed`
      : `the reproduce agent did not finish (status ${repro.status})`;
    return [
      "verdict: no reproduction, no fix", `why: ${why}`,
      `command: ${repro.structured?.command ?? "(not run)"}`, `output: ${repro.structured?.output ?? "(not captured)"}`,
      "test red before, green after: not proven",
      "- [unchecked] localise, fix and prove did not run: the defect was never made to fail (no reproduction)",
    ].join("\n");
  }

  const reproBlock = `Command: ${repro.structured.command}\nOutput:\n${repro.structured.output}`;
  const acceptance = (repro.structured.acceptance ?? "").trim();

  const hypotheses = [
    {
      label: "Localise/cause",
      text: "the code path behind this failure: follow the command above to the exact branch, function or line that decides the wrong behaviour, and name the test or gate that should have caught it",
    },
    knownGood
      ? { label: "Localise/bisect", text: `where the behaviour changed: run a real bisect between ${knownGood} (known good) and HEAD using the reproduction command as the predicate, then report where the bisect landed, the first bad commit, and the files that commit touched` }
      : { label: "Localise/surroundings", text: "the callers, inputs and fixtures feeding that path, and the recent changes, missing guards or absent tests around it that could have produced this failure" },
  ];

  const maps = await Promise.all(
    hypotheses.map((hypothesis) =>
      host
        .agent(
          `Read-only localisation for a reproduced defect: ${symptom}\n\nReproduction:\n${reproBlock}\n\n` +
            `Investigate only this hypothesis, not the other one: ${hypothesis.text}. Report numbered ` +
            `claims, each with the file path and line it rests on (path:line), quote the command you ran ` +
            `for any claim about behaviour, say what you could not confirm, and write nothing.`,
          { label: hypothesis.label, readonly: true, model: "agent-explore" },
        )
        .wait(),
    ),
  );
  const gaps = maps
    .map((map, i) => (map.status === "completed" ? null : { claim: `${hypotheses[i].label} returned no map`, status: "unchecked", evidence: map.status }))
    .filter(Boolean);
  const found = maps.filter((map) => map.status === "completed").map((map) => map.text).join("\n\n---\n\n");

  const fix = await host
    .agent(
      `Fix this defect, keeping the diff to exactly what the request needs: ${symptom}\n\n` +
        `Reproduction (confirm it fails before you touch anything):\n${reproBlock}\n\n` +
        `What the two localisers found:\n\n${found}\n\n` +
        `Required: add the test that is red on the current tree and green after your fix. Run it first ` +
        `and quote the failing output, then make the smallest change that passes it and quote the passing ` +
        `output. Report the files you changed, the test path, and both runs verbatim.`,
      { label: "Fix/defect", model: "agent-swarm" },
    )
    .wait();

  const report = await host
    .agent(
      `Independent skeptical review. You wrote none of this and you change nothing. Defect: ${symptom}\n\n` +
        `Reproduction:\n${reproBlock}\n\nThe fixer reported:\n\n` +
        `${fix.status === "completed" ? fix.text : "(the fixer did not finish)"}\n\n` +
        `Re-run both runs yourself; do not trust the report. (1) The new test against a pre-fix tree: ` +
        `recreate it in a scratch copy outside the repository (` + "`git worktree add`" + ` at the commit ` +
        `before the change), run it there, and confirm it fails for the reported reason. (2) The new test ` +
        `against the current tree: confirm it passes and that the reproduction above no longer fails. ` +
        `Confirm the test is new in ` + "`git diff`" + `, and that the diff holds nothing the request did not ` +
        `ask for. Default position: the claim is wrong until the artifact proves it. Report one finding ` +
        `each for the test being new, the red run, the green run, the reproduction no longer failing, and ` +
        `the diff holding to the request` +
        (acceptance ? `, plus one finding per acceptance criterion, its claim starting with "criterion: "` : "") +
        `. Cite path:line and the command you ran for each, and write nothing.\n\n` +
        (acceptance ? `Reporter's acceptance wording:\n${acceptance}\n` : ""),
      {
        label: "Prove/skeptic",
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

  const checked = report.status === "completed" && report.structured
    ? report.structured
    : { verdict: "unchecked", findings: [{ claim: "the skeptic did not return a verdict", status: "unchecked", evidence: report.status }] };
  const keptRun = (re) => checked.findings.some((f) => f.status === "kept" && re.test(f.claim));
  const criteria = checked.findings.filter((f) => f.claim.startsWith("criterion:"));
  const problems = checked.findings.filter((f) => f.status !== "kept").concat(gaps);

  const lines = [
    `verdict: ${checked.verdict}`,
    `test red before, green after: ${keptRun(/\bred run\b/i) && keptRun(/\bgreen run\b/i) ? "proven" : "not proven"}`,
    `broken or unchecked: ${problems.length}`,
  ];
  if (issue) {
    lines.push(
      `reporter's acceptance wording: ${acceptance || "(the reproduce agent returned none)"}`,
      `acceptance criteria reached: ${criteria.length ? `${criteria.filter((f) => f.status === "kept").length} of ${criteria.length}` : "not reported by the skeptic"}`,
    );
  }
  for (const finding of problems) {
    lines.push(`- [${finding.status}] ${finding.claim} (${finding.evidence})`);
  }
  return lines.join("\n");
}
