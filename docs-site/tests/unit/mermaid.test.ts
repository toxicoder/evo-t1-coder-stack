/**
 * Tests for the Mermaid fence renderer.
 *
 * Mermaid 12 rejects two `render()` calls that share an id, and React `useId()` values contain
 * colons (`:r1:`) that are not legal in the SVG id Mermaid emits, so the helper has to turn
 * those into distinct, CSS-safe ids for every diagram on a page (architecture has five). The
 * component has the rest of the job: draw into the container, follow the site scheme so a dark
 * page does not get a light diagram, and show the parse failure with the chart that caused it
 * instead of leaving a blank box on GitHub Pages.
 */

import { renderToStaticMarkup } from "react-dom/server";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { Mermaid, mermaidRenderId } from "../../components/mermaid";
import {
  configureHooks,
  mermaidDouble,
  resetStubs,
  runCleanups,
  runEffects,
  setCalls,
  themeState
} from "./helpers/fumadocs-stub";

vi.mock("react", async (importOriginal) => {
  const actual = await importOriginal<typeof import("react")>();
  const { reactHookStubs } = await import("./helpers/fumadocs-stub");
  return { ...actual, ...reactHookStubs() };
});

vi.mock("next-themes", async () => {
  const { useThemeStub } = await import("./helpers/fumadocs-stub");
  return { useTheme: useThemeStub };
});

vi.mock("mermaid", async () => {
  const { mermaidDouble: instance } = await import("./helpers/fumadocs-stub");
  return { default: instance };
});

const CSS_ID = /^[A-Za-z][A-Za-z0-9_-]*$/u;
const CHART = "graph TD; A-->B;";
const SVG = "<svg data-testid=\"diagram\">drawn</svg>";

/** Container the component draws into, as the effect sees it. */
function container(): { innerHTML: string } {
  return { innerHTML: "" };
}

/** Let the effect's async render run to completion. */
async function settled(): Promise<void> {
  await new Promise((resolve) => {
    setTimeout(resolve, 0);
  });
}

/** Render the fence and run its effect, with the container already attached. */
function mount(node: { innerHTML: string } | null, states: unknown[] = [undefined]): void {
  configureHooks({ refs: [node], ids: [":r3:"], states });
  renderToStaticMarkup(Mermaid({ chart: CHART } as never));
  runEffects();
}

beforeEach(() => {
  resetStubs();
  configureHooks();
  mermaidDouble.initialize.mockImplementation(() => undefined);
  mermaidDouble.render.mockResolvedValue({ svg: SVG });
  themeState.resolvedTheme = "light";
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("mermaidRenderId", () => {
  it("sanitizes a React useId value into a CSS-safe id", () => {
    expect(mermaidRenderId(":r1:")).toBe("mmdr1");
    expect(mermaidRenderId(":r1:")).toMatch(CSS_ID);
  });

  it("keeps two React ids distinct after sanitizing", () => {
    expect(mermaidRenderId(":r1:")).not.toBe(mermaidRenderId(":r2:"));
  });

  it("always starts with a letter even when the React id is only punctuation", () => {
    expect(mermaidRenderId(":::")).toMatch(CSS_ID);
  });
});

describe("Mermaid", () => {
  it("renders an empty container for the diagram to land in", () => {
    configureHooks({ refs: [container()], ids: [":r3:"] });
    const html = renderToStaticMarkup(Mermaid({ chart: CHART } as never));
    expect(html).toContain('aria-label="Mermaid diagram"');
    expect(html).toContain("overflow-auto text-center");
  });

  it("draws the chart into the container", async () => {
    const node = container();
    mount(node);
    await settled();
    expect(node.innerHTML).toBe(SVG);
  });

  it("renders under the id derived from the React id", async () => {
    mount(container());
    await settled();
    expect(mermaidDouble.render).toHaveBeenCalledWith("mmdr3", CHART);
  });

  it("turns off the palette mermaid would otherwise pick for itself", async () => {
    mount(container());
    await settled();
    expect(mermaidDouble.initialize).toHaveBeenCalledWith({
      startOnLoad: false,
      securityLevel: "strict",
      theme: "neutral"
    });
  });

  it("follows the site scheme when the reader is on dark", async () => {
    themeState.resolvedTheme = "dark";
    mount(container());
    await settled();
    expect(mermaidDouble.initialize).toHaveBeenCalledWith(
      expect.objectContaining({ theme: "dark" })
    );
  });

  it("treats an unresolved scheme as light", async () => {
    themeState.resolvedTheme = undefined;
    mount(container());
    await settled();
    expect(mermaidDouble.initialize).toHaveBeenCalledWith(
      expect.objectContaining({ theme: "neutral" })
    );
  });

  it("clears an earlier failure once a diagram draws", async () => {
    mount(container(), ["stale failure"]);
    await settled();
    expect(setCalls()).toContainEqual({ index: 0, value: undefined });
  });

  it("reports a parse failure by its message", async () => {
    mermaidDouble.render.mockRejectedValue(new Error("Parse error on line 2"));
    mount(container());
    await settled();
    expect(setCalls()).toContainEqual({ index: 0, value: "Parse error on line 2" });
  });

  it("reports a failure that threw something other than an Error", async () => {
    mermaidDouble.render.mockRejectedValue("diagram rejected");
    mount(container());
    await settled();
    expect(setCalls()).toContainEqual({ index: 0, value: "diagram rejected" });
  });

  it("shows the failure and the chart that caused it", () => {
    configureHooks({ refs: [container()], ids: [":r3:"], states: ["Parse error on line 2"] });
    const html = renderToStaticMarkup(Mermaid({ chart: CHART } as never));
    expect(html).toContain("Mermaid diagram failed to render");
    expect(html).toContain("Parse error on line 2");
    expect(html).toContain("graph TD; A--&gt;B;");
    expect(html).not.toContain('aria-label="Mermaid diagram"');
  });

  it("leaves the container alone when it never mounted", async () => {
    mount(null);
    await settled();
    expect(mermaidDouble.initialize).not.toHaveBeenCalled();
  });

  it("gives up when the container is gone before mermaid loads", async () => {
    const node = container();
    mount(node);
    runCleanups();
    await settled();
    expect(node.innerHTML).toBe("");
  });

  it("gives up when the container unmounts while mermaid renders", async () => {
    mermaidDouble.render.mockImplementation(async () => {
      runCleanups();
      return { svg: SVG };
    });
    const node = container();
    mount(node);
    await settled();
    expect(node.innerHTML).toBe("");
  });
});
