/**
 * Shared harness for the suites that mount a client component for real.
 *
 * The fumadocs stubs in `./fumadocs-stub.ts` render through `renderToStaticMarkup`, which
 * never runs an effect and never dispatches an event. That is the right instrument for the
 * fumadocs glue, but the site's own chrome (the glossary dialog, the table overlays, the
 * published chip) is mostly effect and event code: a static render cannot show that
 * `showModal()` ran, that a scroll handler repainted an overlay, or that a timer re-labelled
 * a stamp. Those suites mount into a jsdom container with `createRoot` and drive the
 * component through `act`, so the effects React really committed are the ones under test.
 *
 * Every file that uses this one has to opt into the DOM with `// @vitest-environment jsdom`
 * as its first line; the project default is `node`, where `document` does not exist.
 */

import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { ReactNode } from "react";

// React only warns-and-waits for `act` when it knows it is in a test environment.
(globalThis as unknown as { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

let container: HTMLDivElement | undefined;
let root: Root | undefined;

/**
 * Mount `node`, or re-render the tree already mounted.
 *
 * @param node Element to render.
 * @returns The container the tree lives in.
 */
export function mount(node: ReactNode): HTMLElement {
  if (!root) {
    container = document.createElement("div");
    document.body.appendChild(container);
    root = createRoot(container);
  }
  const current = root;
  void act(() => {
    current.render(node);
  });
  if (!container) {
    throw new Error("the mount container was removed while a tree was mounted");
  }
  return container;
}

/** Unmount the tree and drop the container; call it from `afterEach`. */
export function unmount(): void {
  const current = root;
  if (current) {
    void act(() => {
      current.unmount();
    });
    root = undefined;
  }
  container?.remove();
  container = undefined;
}

/**
 * Run one browser-style interaction and let React flush what it caused.
 *
 * @param action The click, key, or scroll to dispatch.
 */
export async function interact(action: () => void): Promise<void> {
  await act(async () => {
    action();
  });
}

/** Let queued microtasks and the effects they chained run inside `act`. */
export async function settle(): Promise<void> {
  await act(async () => {
    await new Promise((resolve) => {
      setTimeout(resolve, 0);
    });
  });
}

/**
 * Let real timers elapse inside `act`, for a component that arms its own timeout.
 *
 * @param ms Milliseconds to wait out.
 */
export async function waitMs(ms: number): Promise<void> {
  await act(async () => {
    await new Promise((resolve) => {
      setTimeout(resolve, ms);
    });
  });
}

/**
 * Give an element the box a real layout would have reported.
 *
 * jsdom lays nothing out, so every `getBoundingClientRect()` answers with zeroes and code
 * that positions itself against the page decides nothing is visible. A suite passes the
 * geometry the browser would have produced and asserts what the component did with it.
 *
 * @param element Element to fake the box of.
 * @param box The rectangle to report.
 */
export function setBox(
  element: Element,
  box: { top: number; left: number; bottom: number; right: number; width: number; height: number }
): void {
  const rect = { ...box, x: box.left, y: box.top, toJSON: () => box };
  element.getBoundingClientRect = () => rect as unknown as DOMRect;
}
