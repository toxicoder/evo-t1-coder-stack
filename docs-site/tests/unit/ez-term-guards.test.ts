/**
 * Tests for the glossary trigger's missing-node guards.
 *
 * `ez-term.test.ts` mounts the trigger in a real DOM, where React always attaches the dialog
 * ref before an effect runs, so the two effects' "no dialog yet" branches are unreachable from
 * there. This suite drives the same component through the hook doubles in
 * `./helpers/fumadocs-stub.ts`, which lets a suite hand the refs nothing and assert that the
 * effects do nothing rather than throwing on `showModal()` of a node that is not there.
 */

import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";

import { beforeEach, describe, expect, it, vi } from "vitest";

import { EzTerm } from "../../components/ez-term";
import { configureHooks, resetStubs, runEffects } from "./helpers/fumadocs-stub";

vi.mock("react", async (importOriginal) => {
  const actual = await importOriginal<typeof import("react")>();
  const { reactHookStubs } = await import("./helpers/fumadocs-stub");
  return { ...actual, ...reactHookStubs() };
});

/** Render the trigger with every ref handed to the effects as absent. */
function renderWithoutDialog(): string {
  configureHooks({ refs: [null, null, null], states: [false], ids: [":g1:"] });
  const markup = renderToStaticMarkup(
    createElement(EzTerm, { term: "DinD", definition: "Docker inside Docker.", children: "DinD" })
  );
  runEffects();
  return markup;
}

beforeEach(() => {
  resetStubs();
  configureHooks();
});

describe("EzTerm without its dialog", () => {
  it("opens nothing when the dialog node is missing", () => {
    expect(() => {
      renderWithoutDialog();
    }).not.toThrow();
  });

  it("still renders the trigger and the dialog markup it can render", () => {
    const markup = renderWithoutDialog();
    expect(markup).toContain('class="ez-term"');
    expect(markup).toContain("Docker inside Docker.");
  });

  it("ignores an open request while the dialog is unattached", () => {
    configureHooks({ refs: [null, null, null], states: [true], ids: [":g2:"] });
    expect(() => {
      renderToStaticMarkup(
        createElement(EzTerm, { term: "DinD", definition: "Docker inside Docker.", children: "DinD" })
      );
      runEffects();
    }).not.toThrow();
  });
});
