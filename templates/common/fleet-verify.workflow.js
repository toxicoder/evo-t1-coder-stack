/**
 * ---
 * name: fleet-verify
 * description: Map a change with parallel read-only explorers, implement it on the swarm lane, then have a panel of three independent skeptics on agent-review try to disprove the result
 * when_to_use: When one request needs a survey of the code, an edit, and an independent check that the edit actually holds - and you want the three phases placed on the local Spark lanes the stack pins rather than left on the session model.
 * phase: Map -- Two read-only explorers answer one question each, on agent-explore
 * phase: Implement -- One writer lands the change on the swarm lane
 * phase: Verify -- A panel of three skeptics (requirements, proof, adversary) is dispatched together on agent-review and reports each claim kept or broken
 * ---
 */

// Local lanes only. Every model id here is an alias in litellm/config.yaml over the three
// Spark boxes: agent-explore is the read/search lane (thinking low, session pin lifted, so a
// wave spreads over every box), agent-swarm is the fan-out lane (xhigh, pin lifted), and
// agent-review is the skeptic lane (xhigh, pin lifted). A cloud id would not resolve on this
// box, and a name the catalog does not carry makes the agent fail, so check
// `grok inspect` after editing an alias.

export default async function fleetVerify(args) {
  const goal = args?.query ?? args?.goal ?? "the change described in the current session";
  const question = args?.question ?? "where this is implemented, and what tests or gates cover it";
  const angles = ["where it lives in the code", "how it is tested and gated"];

  const notes = await Promise.all(
    angles.map((angle, i) =>
      host
        .agent(
          `Read-only survey. In this repository, find what matters for: ${goal}. Report ${angle}, ` +
            `as numbered claims, each with its file path and line. Cite path:line for every claim, ` +
            `say what you could not confirm, and write nothing.`,
          { label: `Map/angle-${i + 1}`, readonly: true, model: "agent-explore" },
        )
        .wait(),
    ),
  );

  const found = notes
    .filter((note) => note.status === "completed")
    .map((note) => note.text)
    .join("\n\n---\n\n");

  const build = await host
    .agent(
      `Land this change, keeping the diff as small as the request allows and matching the style of ` +
        `the files you touch: ${goal}\n\nWhat the survey found:\n\n${found}\n\n` +
        `Report the files you changed and the exact command that proves the change, with its output.`,
      { label: "Implement/change", model: "agent-swarm" },
    )
    .wait();

  // The independent pass is a panel: three angles dispatched in one turn and awaited
  // together, so the wall-clock cost stays one skeptic while three attack surfaces get covered.
  const skepticAngles = [
    { name: "requirements", focus: "every acceptance check the request stated or implied, each one reported kept or broken" },
    { name: "proof", focus: "the command the producer says proves the change - re-run it and report whether the artifact backs what the report claims" },
    { name: "adversary", focus: "ways to break it: regressions, edge and error states, and the path a feature flag takes when it is off" },
  ];

  const reports = await Promise.all(
    skepticAngles.map((skeptic) =>
      host
        .agent(
          `Independent skeptical review. You wrote none of this. Try to disprove the result of: ${goal}\n\n` +
            `The producer reported:\n\n${build.status === "completed" ? build.text : "(the implementer did not finish)"}\n\n` +
            `Your angle is ${skeptic.name}: ${skeptic.focus}. The other skeptics on this panel cover the ` +
            `rest, so stay on yours. Re-run the command the producer says proves the change - do not trust ` +
            `the report. Check the diff (` + "`git diff`" + `) for anything the request did not ask for. ` +
            `Default position: the claim is wrong until the artifact proves it. Report each claim kept or ` +
            `broken with path:line and the command you ran. Write nothing.`,
          {
            label: `Verify/${skeptic.name}`,
            readonly: true,
            model: "agent-review",
            schema: {
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
            },
          },
        )
        .wait(),
    ),
  );

  // A panel member that did not finish is reported as unchecked, never dropped.
  const panels = reports.map((report, i) =>
    report.status === "completed" && report.structured
      ? report.structured
      : { verdict: "unchecked", findings: [{ claim: `the ${skepticAngles[i].name} skeptic did not return a verdict`, status: "unchecked", evidence: report.status }] },
  );
  const verdict = panels.some((panel) => panel.verdict === "broken")
    ? "broken"
    : panels.some((panel) => panel.verdict === "mixed")
      ? "mixed"
      : panels.every((panel) => panel.verdict === "kept")
        ? "kept"
        : "unchecked";
  const findings = panels.flatMap((panel) => panel.findings);

  const broken = findings.filter((f) => f.status !== "kept");
  const lines = [`verdict: ${verdict}`, `broken or unchecked: ${broken.length}`];
  for (const f of broken) {
    lines.push(`- [${f.status}] ${f.claim} (${f.evidence})`);
  }
  return lines.join("\n");
}
