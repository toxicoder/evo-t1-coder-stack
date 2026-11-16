/**
 * ---
 * name: implement-reviewed
 * description: Map a change with parallel read-only explorers, implement it on the swarm lane, have an independent skeptic on agent-review try to disprove the result, then run one bounded fix round
 * when_to_use: When a change should land checked rather than trusted - survey, bounded diff, a skeptic that re-runs the producer's own proof command, one repair round. Without args.verify the writer names the proof and the skeptic challenges that choice.
 * phase: Map -- Two read-only explorers answer one question each, on agent-explore
 * phase: Implement -- One writer lands the change on the swarm lane
 * phase: Verify -- An independent skeptic re-runs the proof on agent-review and reports kept or broken
 * phase: Fix -- One writer repairs the broken findings and the skeptic runs once more, capped at one round
 * ---
 */

// Local lanes only. Every model id here is an alias in litellm/config.yaml over the three
// Spark boxes: agent-explore is the read/search lane (thinking low, session pin lifted, so a
// wave spreads over every box), agent-swarm is the fan-out lane (xhigh, pin lifted), and
// agent-review is the skeptic lane (xhigh, pin lifted). A cloud id would not resolve on this
// box, and a name the catalog does not carry makes the agent fail, so check
// `grok inspect` after editing an alias.

export default async function implementReviewed(args) {
  const goal = args?.goal ?? args?.query ?? "the change described in the current session";
  const question = args?.question ?? "where this is implemented, and what tests or gates cover it";
  const proof = args?.verify ?? "";
  const angles = ["where it lives in the code", "how it is tested and gated"];
  const gaps = [];

  // An agent that did not finish is reported as unchecked, never dropped.
  const said = (reply, who) => {
    if (reply.status === "completed") return reply.text;
    gaps.push(`- [unchecked] ${who} did not finish: ${reply.status}`);
    return null;
  };
  const findingLine = (f) => `- [${f.status}] ${f.claim} (${f.evidence})`;
  const checkedOf = (report) =>
    report.status === "completed" && report.structured
      ? report.structured
      : { verdict: "unchecked", findings: [{ claim: "the skeptic did not return a verdict", status: "unchecked", evidence: report.status }] };

  const notes = await Promise.all(
    angles.map((angle, i) =>
      host
        .agent(
          `Read-only survey. Answer this for the change below: ${question}\n\nThe change: ${goal}\n\n` +
            `Your angle is ${angle}; the other explorer takes a different one, so stay on yours. Report ` +
            `numbered claims, each with its file path and line. Cite path:line for every claim, say what ` +
            `you could not confirm, and write nothing.`,
          { label: `Map/angle-${i + 1}`, readonly: true, model: "agent-explore" },
        )
        .wait(),
    ),
  );
  const answers = notes.map((note, i) => said(note, `survey angle ${i + 1} (${angles[i]})`));
  const found = answers.filter(Boolean).join("\n\n---\n\n");

  const build = await host
    .agent(
      `Land this change, keeping the diff to exactly what the request asks for and matching the style ` +
        `of the files you touch: ${goal}\n\nWhat the survey found:\n\n${found}\n\n` +
        (proof
          ? `Prove it with this command and quote its output: ${proof}`
          : `Name the one command that proves this change, run it, and quote its output.`) +
        `\n\nReport the files you changed.`,
      { label: "Implement/change", model: "agent-swarm" },
    )
    .wait();
  const buildText = said(build, "implementer") ?? "(the implementer did not finish)";

  const schema = {
    type: "object",
    properties: {
      verdict: { type: "string", enum: ["kept", "broken", "mixed"] },
      findings: {
        type: "array",
        items: {
          type: "object",
          properties: {
            claim: { type: "string" },
            status: { type: "string", enum: ["kept", "broken", "unchecked"] },
            evidence: { type: "string" },
          },
          required: ["claim", "status", "evidence"],
        },
      },
    },
    required: ["verdict", "findings"],
  };

  // No proof command was pinned, so the skeptic is told to challenge the one the writer chose.
  const challenge = proof
    ? ""
    : "Nobody was given the proof command, so the producer chose it - challenge that choice and run a stronger one. ";

  const askSkeptic = (text, extra, label) =>
    host
      .agent(
        `Independent skeptical review. You wrote none of this. Try to disprove the result of: ${goal}\n\n` +
          `The producer reported:\n\n${text}\n\nRe-run the command the producer says proves the change - ` +
          `do not trust the report. Check the diff (` + "`git diff`" + `) for anything the request did not ` +
          `ask for. ${extra}Default position: the claim is wrong until the artifact proves it. Report ` +
          `each claim kept, broken, or unchecked with path:line and the command you ran. Write nothing.`,
        { label, readonly: true, model: "agent-review", schema },
      )
      .wait();

  let checked = checkedOf(await askSkeptic(buildText, challenge, "Verify/skeptic"));
  let fixNote = "not needed";

  if (checked.verdict === "broken") {
    const list = checked.findings.filter((f) => f.status !== "kept").map(findingLine).join("\n");
    const repair = await host
      .agent(
        `An independent skeptic broke this change. Repair only what it lists, touching nothing else: ` +
          `${goal}\n\nBroken findings:\n\n${list}\n\nRe-run the proof command and quote its output. ` +
          `Report the files you changed.`,
        { label: "Fix/broken-findings", model: "agent-swarm" },
      )
      .wait();
    fixNote = "used once, capped at one round";
    const repairText = said(repair, "fixer") ?? "(the fixer did not finish)";
    checked = checkedOf(await askSkeptic(repairText, "", "Verify/skeptic-round-2"));
    if (checked.verdict === "broken") fixNote = "used once, still broken, capped at one round";
  }

  const broken = checked.findings.filter((f) => f.status !== "kept");
  return [
    `verdict: ${checked.verdict}`,
    `broken or unchecked: ${broken.length + gaps.length}`,
    `fix round: ${fixNote}`,
    ...broken.map(findingLine),
    ...gaps,
  ].join("\n");
}
