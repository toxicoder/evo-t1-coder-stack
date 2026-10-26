/**
 * Tests for glossary tooltip placement.
 *
 * Native `title` bubbles are delayed and often suppressed inside Fumadocs table wrappers
 * (`overflow: auto`), so the hover popover is positioned in a portal. Placement has to stay
 * on-screen without a DOM, and the component has to keep both halves of the trade: the native
 * `title` while the term is at rest, the portal once it is hovered or focused, and a measured
 * position that follows the term when the page scrolls.
 *
 * The environment stays `node`, so the React hooks are stubbed: `renderToStaticMarkup` never
 * runs an effect, and the pointer handlers are only reachable through the props the component
 * returns.
 */

import { renderToStaticMarkup } from "react-dom/server";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { GlossaryTerm, placeGlossaryTooltip } from "../../components/glossary-term";
import {
  configureHooks,
  propsOf,
  resetStubs,
  runCleanups,
  runEffects,
  setCalls,
  type ElementLike
} from "./helpers/fumadocs-stub";

vi.mock("react", async (importOriginal) => {
  const actual = await importOriginal<typeof import("react")>();
  const { reactHookStubs } = await import("./helpers/fumadocs-stub");
  return { ...actual, ...reactHookStubs() };
});

vi.mock("react-dom", async () => {
  const { createPortalStub } = await import("./helpers/fumadocs-stub");
  return { createPortal: createPortalStub, default: { createPortal: createPortalStub } };
});

const tooltip = { width: 200, height: 40 };
const viewport = { width: 1000, height: 800 };
const DEFINITION = "Docker-in-Docker";

/** Measured box, as `getBoundingClientRect` reports it. */
function measured(top: number, left: number, width: number, height: number) {
  return { getBoundingClientRect: () => ({ top, left, width, height }) };
}

/** Static markup of the term, with `props` overriding what it is called with. */
function renderTerm(props: Record<string, unknown> = {}): string {
  return renderToStaticMarkup(GlossaryTerm({ title: DEFINITION, children: "DinD", ...props } as never));
}

/** Props the component attached to its `<abbr>`. */
function abbrProps(props: Record<string, unknown> = {}): Record<string, unknown> {
  const element = GlossaryTerm({
    title: DEFINITION,
    children: "DinD",
    ...props
  } as never) as unknown as ElementLike;
  return propsOf(element, "abbr");
}

/** Invoke one pointer handler the component attached to the term. */
function fire(name: string, event: unknown = {}, props: Record<string, unknown> = {}): void {
  const handler = abbrProps(props)[name] as (value: unknown) => void;
  handler(event);
}

/** Call the component so its effect is registered, then run that effect. */
function mountEffect(): void {
  GlossaryTerm({ title: DEFINITION, children: "DinD" } as never);
  runEffects();
}

/** Stand in for the browser APIs the positioning effect reaches for. */
function stubWindow(): { addEventListener: ReturnType<typeof vi.fn>; removeEventListener: ReturnType<typeof vi.fn> } {
  const listeners = { addEventListener: vi.fn(), removeEventListener: vi.fn() };
  vi.stubGlobal("window", {
    innerWidth: viewport.width,
    innerHeight: viewport.height,
    ...listeners
  });
  return listeners;
}

beforeEach(() => {
  resetStubs();
  configureHooks();
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("placeGlossaryTooltip", () => {
  it("places the tooltip above the term when there is room", () => {
    const pos = placeGlossaryTooltip({ top: 400, left: 400, width: 80, height: 16 }, tooltip, viewport);
    expect(pos.top).toBe(400 - 40 - 8);
    expect(pos.left).toBe(400 + 80 / 2 - 200 / 2);
  });

  it("flips below when the term is near the top of the viewport", () => {
    const pos = placeGlossaryTooltip({ top: 10, left: 400, width: 80, height: 16 }, tooltip, viewport);
    expect(pos.top).toBe(10 + 16 + 8);
  });

  it("clamps to the left edge of the viewport", () => {
    const pos = placeGlossaryTooltip({ top: 400, left: 0, width: 20, height: 16 }, tooltip, viewport);
    expect(pos.left).toBe(8);
  });

  it("clamps to the right edge of the viewport", () => {
    const pos = placeGlossaryTooltip({ top: 400, left: 980, width: 20, height: 16 }, tooltip, viewport);
    expect(pos.left).toBe(1000 - 200 - 8);
  });

  it("keeps a popover wider than the viewport inside the margin", () => {
    const pos = placeGlossaryTooltip(
      { top: 400, left: 500, width: 20, height: 16 },
      { width: 1400, height: 40 },
      viewport
    );
    expect(pos.left).toBe(8);
  });

  it("honours a caller-supplied gap", () => {
    const pos = placeGlossaryTooltip({ top: 400, left: 400, width: 80, height: 16 }, tooltip, viewport, 24);
    expect(pos.top).toBe(400 - 40 - 24);
  });
});

describe("GlossaryTerm at rest", () => {
  beforeEach(() => {
    configureHooks({ states: [false, null] });
  });

  it("keeps the native title and a tab stop for keyboard readers", () => {
    const html = renderTerm();
    expect(html).toContain('class="glossary-term"');
    expect(html).toContain(`title="${DEFINITION}"`);
    expect(html).toContain('tabindex="0"');
    expect(html).toContain(">DinD<");
  });

  it("renders no popover until the reader hovers the term", () => {
    const html = renderTerm();
    expect(html).not.toContain('role="tooltip"');
    expect(html).not.toContain("aria-describedby");
  });

  it("merges the class the MDX compiler passed", () => {
    expect(renderTerm({ className: "text-teal-600" })).toContain('class="glossary-term text-teal-600"');
  });

  it("leaves a term without a definition inert", () => {
    const html = renderTerm({ title: undefined, children: "abbr" });
    expect(html).not.toContain("title=");
    expect(html).not.toContain("tabindex");
    expect(html).toContain(">abbr<");
  });

  it("keeps the attributes the compiler passed", () => {
    expect(abbrProps({ id: "term-dind" }).id).toBe("term-dind");
  });
});

describe("GlossaryTerm while open", () => {
  beforeEach(() => {
    vi.stubGlobal("document", { body: {} });
  });

  it("swaps the native title for the portal", () => {
    configureHooks({ states: [true, { top: 352, left: 340 }], ids: [":r7:"] });
    const html = renderTerm();
    expect(html).not.toContain("title=");
    expect(html).toContain('role="tooltip"');
    expect(html).toContain(`>${DEFINITION}<`);
  });

  it("ties the term to its popover for a screen reader", () => {
    configureHooks({ states: [true, { top: 352, left: 340 }], ids: [":r7:"] });
    const html = renderTerm();
    expect(html).toContain('aria-describedby=":r7:"');
    expect(html).toContain('id=":r7:"');
  });

  it("positions the popover where the last measurement put it", () => {
    configureHooks({ states: [true, { top: 352, left: 340 }] });
    const html = renderTerm();
    expect(html).toContain("top:352px");
    expect(html).toContain("left:340px");
    expect(html).toContain("visibility:visible");
  });

  it("hides the popover before it has been measured", () => {
    configureHooks({ states: [true, null] });
    const html = renderTerm();
    expect(html).toContain("visibility:hidden");
    expect(html).toContain("top:0;");
  });

  it("never portals a term that has no definition to show", () => {
    configureHooks({ states: [true, null] });
    expect(renderTerm({ title: undefined })).not.toContain('role="tooltip"');
  });

  it("mounts the popover on the document body", () => {
    configureHooks({ states: [true, { top: 352, left: 340 }] });
    expect(renderTerm()).toContain('data-glossary-tooltip=""');
  });
});

describe("GlossaryTerm pointer handlers", () => {
  it("opens on hover", () => {
    fire("onMouseEnter");
    expect(setCalls()).toContainEqual({ index: 0, value: true });
  });

  it("closes when the pointer leaves", () => {
    fire("onMouseLeave");
    expect(setCalls()).toContainEqual({ index: 0, value: false });
  });

  it("opens on focus, so the keyboard reaches the definition", () => {
    fire("onFocus");
    expect(setCalls()).toContainEqual({ index: 0, value: true });
  });

  it("closes on blur", () => {
    fire("onBlur");
    expect(setCalls()).toContainEqual({ index: 0, value: false });
  });

  it("stays shut for a term with nothing to define", () => {
    fire("onMouseEnter", {}, { title: undefined });
    fire("onFocus", {}, { title: "" });
    expect(setCalls()).toEqual([]);
  });

  it("still calls the handlers the MDX compiler passed", () => {
    const enter = vi.fn();
    const leave = vi.fn();
    const focus = vi.fn();
    const blur = vi.fn();
    fire("onMouseEnter", { type: "enter" }, { onMouseEnter: enter });
    fire("onMouseLeave", { type: "leave" }, { onMouseLeave: leave });
    fire("onFocus", { type: "focus" }, { onFocus: focus });
    fire("onBlur", { type: "blur" }, { onBlur: blur });
    expect(enter).toHaveBeenCalledWith({ type: "enter" });
    expect(leave).toHaveBeenCalledWith({ type: "leave" });
    expect(focus).toHaveBeenCalledWith({ type: "focus" });
    expect(blur).toHaveBeenCalledWith({ type: "blur" });
  });
});

describe("GlossaryTerm positioning effect", () => {
  it("clears a stale position while the popover is closed", () => {
    configureHooks({ states: [false, { top: 352, left: 340 }] });
    mountEffect();
    expect(setCalls()).toContainEqual({ index: 1, value: null });
  });

  it("places the popover against the term and the measured popover", () => {
    stubWindow();
    configureHooks({ states: [true, null], refs: [measured(400, 400, 80, 16), measured(0, 0, 200, 40)] });
    mountEffect();
    expect(setCalls()).toContainEqual({ index: 1, value: { top: 352, left: 340 } });
  });

  it("follows the page while it scrolls or resizes", () => {
    const { addEventListener } = stubWindow();
    configureHooks({ states: [true, null], refs: [measured(400, 400, 80, 16), measured(0, 0, 200, 40)] });
    mountEffect();
    const handler = addEventListener.mock.calls[0]?.[1] as () => void;
    expect(addEventListener).toHaveBeenCalledWith("scroll", handler, true);
    expect(addEventListener).toHaveBeenCalledWith("resize", handler);
    setCalls().length = 0;
    handler();
    expect(setCalls()).toContainEqual({ index: 1, value: { top: 352, left: 340 } });
  });

  it("detaches both listeners when the popover goes away", () => {
    const { removeEventListener } = stubWindow();
    configureHooks({ states: [true, null], refs: [measured(400, 400, 80, 16), measured(0, 0, 200, 40)] });
    mountEffect();
    runCleanups();
    expect(removeEventListener).toHaveBeenCalledWith("scroll", expect.any(Function), true);
    expect(removeEventListener).toHaveBeenCalledWith("resize", expect.any(Function));
  });

  it("leaves the position alone until both nodes are mounted", () => {
    stubWindow();
    configureHooks({ states: [true, null], refs: [measured(400, 400, 80, 16), null] });
    mountEffect();
    expect(setCalls()).toEqual([]);
  });

  it("does not measure anything for a term with no definition", () => {
    const { addEventListener } = stubWindow();
    configureHooks({ states: [true, null], refs: [measured(400, 400, 80, 16), measured(0, 0, 200, 40)] });
    GlossaryTerm({ children: "abbr" } as never);
    runEffects();
    expect(addEventListener).not.toHaveBeenCalled();
  });
});
