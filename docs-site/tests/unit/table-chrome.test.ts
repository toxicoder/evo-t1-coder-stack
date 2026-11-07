// @vitest-environment jsdom
/**
 * Tests for the pinned table head and the mirrored scroll bar.
 *
 * fumadocs wraps every content table in an overflow container, which is why a CSS
 * `position: sticky` head does not survive: the head scrolls out with the container it sits in.
 * The component detaches a clone of the head and positions it under the navbar while the table
 * is on screen, and mirrors the container's horizontal scroll into a bar at the viewport bottom
 * so a reader mid-table can still reach the columns. jsdom lays nothing out, so every box the
 * component measures is handed to it here, and `requestAnimationFrame` is pumped by hand to
 * make a repaint a synchronous, countable event.
 */

import { createElement } from "react";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { TableChrome } from "../../components/table-chrome";
import { mount, setBox, unmount } from "./helpers/dom-harness";

/** Bottom edge of the docs navbar, which the pinned head has to clear. */
const PIN = 60;
const VIEWPORT_HEIGHT = 768;

/** A rectangle, with the fields the component reads filled in. */
interface Box {
  top: number;
  bottom: number;
  left: number;
  right: number;
  width: number;
  height: number;
}

/** A box that sits at `top` and is `height` tall, `left` across and `width` wide. */
function box(top: number, left: number, width: number, height: number): Box {
  return { top, bottom: top + height, left, right: left + width, width, height };
}

/** One frame callback waiting to be pumped, by the id the component was handed. */
let frames: Map<number, FrameRequestCallback>;
let nextFrameId: number;

/** Run every queued animation frame; the component coalesces repeats into one. */
function flush(): void {
  const queued = [...frames.values()];
  frames.clear();
  for (const frame of queued) frame(0);
}

/** Ask the component to repaint, the way a scroll would. */
function repaint(): void {
  window.dispatchEvent(new Event("scroll"));
  flush();
}

/** Every element this suite lays out, keyed by what it is. */
interface Scene {
  article: HTMLElement;
  wrap: HTMLElement;
  table: HTMLTableElement;
  head: HTMLTableSectionElement;
  rows: HTMLTableRowElement[];
  cells: HTMLTableCellElement[];
}

/**
 * Build the content the component measures.
 *
 * @param options `head`: build a `thead`; `rows`: body rows to build; `class`: class on the
 *   table, which fumadocs uses to mark tables it already styles; `scrollWidth`/`clientWidth`:
 *   the overflow container's metrics, which jsdom reports as zero without help.
 */
function buildScene(options: {
  head?: boolean;
  emptyHead?: boolean;
  rows?: number;
  tableClass?: string;
  scrollWidth?: number;
  clientWidth?: number;
  header?: boolean;
} = {}): Scene {
  document.body.innerHTML = "";
  const {
    head = true,
    emptyHead = false,
    rows = 2,
    tableClass,
    scrollWidth = 500,
    clientWidth = 500,
    header = true
  } = options;

  if (header) {
    const bar = document.createElement("header");
    const nav = document.createElement("nav");
    bar.appendChild(nav);
    document.body.appendChild(bar);
  }

  const article = document.createElement("article");
  const wrap = document.createElement("div");
  const table = document.createElement("table");
  if (tableClass) table.className = tableClass;
  if (head) {
    const thead = document.createElement("thead");
    if (!emptyHead) {
      const tr = document.createElement("tr");
      for (const label of ["Service", "Port"]) {
        const th = document.createElement("th");
        th.textContent = label;
        tr.appendChild(th);
      }
      thead.appendChild(tr);
    }
    table.appendChild(thead);
  }
  const tbody = document.createElement("tbody");
  for (let row = 0; row < rows; row += 1) {
    const tr = document.createElement("tr");
    for (const label of ["coder", "4000"]) {
      const td = document.createElement("td");
      td.textContent = label;
      tr.appendChild(td);
    }
    tbody.appendChild(tr);
  }
  table.appendChild(tbody);
  wrap.appendChild(table);
  article.appendChild(wrap);
  document.body.appendChild(article);

  Object.defineProperties(wrap, {
    scrollWidth: { configurable: true, writable: true, value: scrollWidth },
    clientWidth: { configurable: true, writable: true, value: clientWidth },
    scrollLeft: { configurable: true, writable: true, value: 0 }
  });

  return {
    article,
    wrap,
    table,
    head: table.tHead as HTMLTableSectionElement,
    rows: [...(table.tBodies[0]?.rows ?? [])],
    cells: [...table.querySelectorAll("th")]
  };
}

/** Where a normal on-screen table sits: its head has scrolled up under the navbar. */
function layOut(scene: Scene, options: { tableTop?: number; tableBottom?: number } = {}): void {
  const nav = document.querySelector("header nav") ?? document.querySelector("header");
  if (nav) setBox(nav, { ...box(0, 0, 1024, PIN) });
  const top = options.tableTop ?? 40;
  const bottom = options.tableBottom ?? 400;
  setBox(scene.table, { top, bottom, left: 12, right: 512, width: 500, height: bottom - top });
  setBox(scene.wrap, { top, bottom, left: 10, right: 510, width: 500, height: bottom - top });
  if (scene.head) setBox(scene.head, box(top, 12, 500, 30));
  for (const row of scene.rows) setBox(row, box(top + 30, 12, 500, 20));
  for (const [index, cell] of scene.cells.entries()) setBox(cell, box(top, 12 + index * 250, 250, 30));
}

/** Mount the chrome over the scene that is currently in the document. */
function mountChrome(): void {
  mount(createElement(TableChrome));
  flush();
}

/** The pinned-head overlay, if one exists. */
function overlay(): HTMLElement | null {
  return document.querySelector<HTMLElement>(".ez-table-pin");
}

/** The mirrored scroll bar, if one exists. */
function bar(): HTMLElement | null {
  return document.querySelector<HTMLElement>(".ez-table-hscroll");
}

beforeEach(() => {
  frames = new Map();
  nextFrameId = 0;
  vi.spyOn(window, "requestAnimationFrame").mockImplementation((callback) => {
    nextFrameId += 1;
    frames.set(nextFrameId, callback);
    return nextFrameId;
  });
  vi.spyOn(window, "cancelAnimationFrame").mockImplementation((id) => {
    frames.delete(id);
  });
  Object.defineProperty(window, "innerHeight", { configurable: true, writable: true, value: VIEWPORT_HEIGHT });
  Object.defineProperty(window, "innerWidth", { configurable: true, writable: true, value: 1024 });
});

afterEach(() => {
  unmount();
  document.body.innerHTML = "";
  vi.restoreAllMocks();
});

describe("TableChrome", () => {
  it("pins a clone of the head under the navbar once it scrolls up", () => {
    const scene = buildScene();
    layOut(scene);
    mountChrome();
    const pin = overlay();
    expect(pin).not.toBeNull();
    expect(pin?.hidden).toBe(false);
    expect(pin?.getAttribute("aria-hidden")).toBe("true");
    expect(pin?.style.top).toBe(`${PIN}px`);
    expect(pin?.style.left).toBe("10px");
    expect(pin?.style.width).toBe("500px");
    expect(pin?.style.height).toBe("31px");
  });

  it("copies the head so the pinned row shows the same columns", () => {
    const scene = buildScene();
    layOut(scene);
    mountChrome();
    const clone = overlay()?.querySelector("thead");
    expect(clone).not.toBeNull();
    expect([...(clone?.querySelectorAll("th") ?? [])].map((th) => th.textContent)).toEqual(["Service", "Port"]);
  });

  it("aligns the cloned columns with the widths of the real ones", () => {
    const scene = buildScene();
    layOut(scene);
    mountChrome();
    const widths = [...(overlay()?.querySelectorAll("th") ?? [])].map((th) => th.style.width);
    expect(widths).toEqual(["250px", "250px"]);
  });

  it("shifts the clone by the amount the container has scrolled sideways", () => {
    const scene = buildScene();
    scene.wrap.scrollLeft = 7;
    layOut(scene);
    mountChrome();
    expect(overlay()?.querySelector("table")?.style.transform).toBe("translateX(2px)");
  });

  it("hides the pin while the whole table is still below the fold", () => {
    const scene = buildScene();
    layOut(scene, { tableTop: 900, tableBottom: 1400 });
    mountChrome();
    expect(overlay()?.hidden).toBe(true);
  });

  it("hides the pin until the head actually reaches the navbar", () => {
    const scene = buildScene();
    layOut(scene, { tableTop: PIN + 40, tableBottom: 500 });
    mountChrome();
    expect(overlay()?.hidden).toBe(true);
  });

  it("keeps the pin from covering the last rows as the table runs out", () => {
    const scene = buildScene();
    layOut(scene, { tableTop: 40, tableBottom: 100 });
    mountChrome();
    expect(overlay()?.hidden).toBe(false);
    expect(overlay()?.style.top).toBe("45px");
  });

  it("hides the pin for a table with no head at all", () => {
    const scene = buildScene({ head: false });
    layOut(scene);
    mountChrome();
    expect(overlay()?.hidden).toBe(true);
  });

  it("hides the pin for a head that has no rows yet", () => {
    const scene = buildScene({ emptyHead: true });
    layOut(scene);
    mountChrome();
    expect(overlay()?.hidden).toBe(true);
  });

  it("leaves a table fumadocs already styles alone", () => {
    const scene = buildScene({ tableClass: "fd-table" });
    layOut(scene);
    mountChrome();
    expect(overlay()).toBeNull();
    expect(bar()).toBeNull();
  });

  it("shows a scroll bar for a wide table whose tail is off screen", () => {
    const scene = buildScene({ scrollWidth: 900, clientWidth: 500 });
    layOut(scene, { tableTop: 40, tableBottom: 900 });
    scene.wrap.scrollLeft = 40;
    mountChrome();
    const scrollBar = bar();
    expect(scrollBar).not.toBeNull();
    expect(scrollBar?.hidden).toBe(false);
    expect(scrollBar?.style.left).toBe("10px");
    expect(scrollBar?.style.width).toBe("500px");
    expect(scrollBar?.style.bottom).toBe("0px");
    expect(scrollBar?.querySelector(".ez-table-hscroll__inner")?.getAttribute("style")).toContain("width: 900px");
    expect(scrollBar?.scrollLeft).toBe(40);
  });

  it("hides the scroll bar when the container fits without scrolling", () => {
    const scene = buildScene({ scrollWidth: 500, clientWidth: 500 });
    layOut(scene, { tableTop: 40, tableBottom: 900 });
    mountChrome();
    expect(bar()?.hidden).toBe(true);
  });

  it("hides the scroll bar while the whole table is on screen", () => {
    const scene = buildScene({ scrollWidth: 900, clientWidth: 500 });
    layOut(scene, { tableTop: 40, tableBottom: 400 });
    mountChrome();
    expect(bar()?.hidden).toBe(true);
  });

  it("drags the container along when the reader scrolls the bar", () => {
    const scene = buildScene({ scrollWidth: 900, clientWidth: 500 });
    layOut(scene, { tableTop: 40, tableBottom: 900 });
    mountChrome();
    const scrollBar = bar();
    if (!scrollBar) throw new Error("the scroll bar did not render");
    scrollBar.scrollLeft = 120;
    scrollBar.dispatchEvent(new Event("scroll"));
    expect(scene.wrap.scrollLeft).toBe(120);
  });

  it("follows the container when the reader scrolls the table itself", () => {
    const scene = buildScene({ scrollWidth: 900, clientWidth: 500 });
    layOut(scene, { tableTop: 40, tableBottom: 900 });
    mountChrome();
    scene.wrap.scrollLeft = 210;
    scene.wrap.dispatchEvent(new Event("scroll"));
    flush();
    expect(bar()?.scrollLeft).toBe(210);
  });

  it("paints once per frame however many scrolls arrive", () => {
    const scene = buildScene();
    layOut(scene);
    mountChrome();
    const pin = overlay();
    frames.clear();
    window.dispatchEvent(new Event("scroll"));
    window.dispatchEvent(new Event("scroll"));
    window.dispatchEvent(new Event("resize"));
    expect(frames.size).toBe(1);
    flush();
    expect(document.querySelectorAll(".ez-table-pin")).toHaveLength(1);
    expect(document.querySelectorAll(".ez-table-hscroll")).toHaveLength(1);
    expect(overlay()).toBe(pin);
  });

  it("never treats its own cloned head as a content table", () => {
    const scene = buildScene();
    layOut(scene);
    mountChrome();
    repaint();
    repaint();
    repaint();
    expect(document.querySelectorAll("article table:not([class])")).toHaveLength(1);
    expect(document.querySelectorAll(".ez-table-pin")).toHaveLength(1);
    expect(document.querySelectorAll(".ez-table-hscroll")).toHaveLength(1);
  });

  it("re-creates the pin if something removed it from the page", () => {
    const scene = buildScene();
    layOut(scene);
    mountChrome();
    overlay()?.remove();
    repaint();
    expect(overlay()).not.toBeNull();
  });

  it("attaches the container scroll listener once, however often it paints", () => {
    const scene = buildScene({ scrollWidth: 900, clientWidth: 500 });
    layOut(scene, { tableTop: 40, tableBottom: 900 });
    mountChrome();
    repaint();
    repaint();
    expect(scene.wrap.getAttribute("data-ez-pin-scroll")).toBe("1");
    scene.wrap.scrollLeft = 90;
    scene.wrap.dispatchEvent(new Event("scroll"));
    flush();
    expect(bar()?.scrollLeft).toBe(90);
  });

  it("falls back to the theme bar for the pin line, then to the top of the page", () => {
    const scene = buildScene({ header: false });
    const theme = document.createElement("div");
    theme.setAttribute("data-theme", "");
    document.body.insertBefore(theme, document.body.firstChild);
    setBox(theme, box(0, 0, 1024, 48));
    layOut(scene);
    mountChrome();
    expect(overlay()?.style.top).toBe("48px");
  });

  it("uses the header box when a page has a header without a nav", () => {
    const scene = buildScene();
    layOut(scene, { tableTop: 30, tableBottom: 400 });
    document.querySelector("header nav")?.remove();
    setBox(document.querySelector("header") as HTMLElement, box(0, 0, 1024, 52));
    mountChrome();
    expect(overlay()?.style.top).toBe("52px");
  });

  it("clears its overlays and stops repainting when the page unmounts", () => {
    const scene = buildScene({ scrollWidth: 900, clientWidth: 500 });
    layOut(scene, { tableTop: 40, tableBottom: 900 });
    mountChrome();
    expect(overlay()).not.toBeNull();
    unmount();
    expect(document.querySelector(".ez-table-pin")).toBeNull();
    expect(document.querySelector(".ez-table-hscroll")).toBeNull();
    window.dispatchEvent(new Event("scroll"));
    flush();
    expect(document.querySelector(".ez-table-pin")).toBeNull();
  });

  it("cancels the frame it had queued when it unmounts", () => {
    const scene = buildScene();
    layOut(scene);
    mountChrome();
    frames.clear();
    window.dispatchEvent(new Event("scroll"));
    expect(frames.size).toBe(1);
    const [queued] = [...frames.keys()];
    unmount();
    expect(window.cancelAnimationFrame).toHaveBeenCalledWith(queued);
    expect(frames.size).toBe(0);
  });

  it("does nothing on a page with no content tables", () => {
    document.body.innerHTML = "<article><p>prose</p></article>";
    mountChrome();
    expect(overlay()).toBeNull();
    expect(bar()).toBeNull();
  });
});
