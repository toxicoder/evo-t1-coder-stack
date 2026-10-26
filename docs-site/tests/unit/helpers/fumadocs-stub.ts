/**
 * Shared doubles for the component and content-source suites.
 *
 * Two things keep the site's own modules out of reach of a plain `node` test run: the chrome
 * comes from `fumadocs-ui` (Radix underneath, so it wants a DOM) and the content collection
 * comes from a bundler-time macro that throws when the bundler plugin did not compile it.
 * Each factory here stands in for one of those modules and renders its children inside a
 * plain element, so a suite can assert on the markup `renderToStaticMarkup` emits without a
 * browser, a dev server or a built site.
 *
 * `vi.mock` hoists its call above the file's imports, so reach these from the factory body
 * with a dynamic `import()` rather than a top-level import, which the hoist would read
 * before the module is evaluated. Elements are built through `react/jsx-runtime` for the same
 * reason: a suite that mocks `react` awaits this module from inside its factory, and a static
 * import of `react` here would wait on the mock that is still being produced.
 */

import { jsx } from "react/jsx-runtime";
import type { ElementType, ReactElement, ReactNode } from "react";
import { vi } from "vitest";

/* ------------------------------------------------------------------ element tree */

/** Minimal shape of the React elements the suites walk. */
export interface ElementLike {
  type: unknown;
  props: Record<string, unknown>;
}

/** Tag or component name of an element, used to find it in a tree. */
function elementName(element: ElementLike): string {
  if (typeof element.type === "string") return element.type;
  if (typeof element.type === "function") return element.type.name || "anonymous";
  return "fragment";
}

/** Depth-first list of every element below `node`, including `node` itself. */
function walkElements(node: unknown): ElementLike[] {
  if (typeof node !== "object" || node === null || !("type" in node) || !("props" in node)) {
    return [];
  }
  const element = node as ElementLike;
  const children = element.props.children;
  const nested = Array.isArray(children) ? children : [children];
  return [element, ...nested.flatMap(walkElements)];
}

/** Props of the first element named `name`, failing the test when the tree has none. */
export function propsOf(node: unknown, name: string): Record<string, unknown> {
  const found = walkElements(node).find((element) => elementName(element) === name);
  if (!found) {
    const seen = walkElements(node).map(elementName).join(", ");
    throw new Error(`no <${name}> in the rendered tree (saw: ${seen})`);
  }
  return found.props;
}

/* ------------------------------------------------------------------ component stubs */

/** One recorded call of a stubbed component or hook. */
export interface StubCall {
  name: string;
  props: Record<string, unknown>;
}

/** Recorded stub calls, in render order. */
const calls: StubCall[] = [];

/** Recorded calls for one stub. */
export function callsFor(name: string): StubCall[] {
  return calls.filter((call) => call.name === name);
}

/** Forget every recorded call; call it from `beforeEach`. */
export function resetStubs(): void {
  calls.length = 0;
  docsConfigs.length = 0;
  loaderCalls.length = 0;
  loaderPages.clear();
  loaderLookups.length = 0;
  searchClientArgs.length = 0;
  hrefLookups.length = 0;
  hrefResolution.current = { href: "/operate" };
  Object.assign(docsSearchState, {
    search: "",
    query: { data: [] as unknown[], isLoading: false }
  });
  Object.assign(themeState, { resolvedTheme: "light" });
  mermaidDouble.initialize.mockReset();
  mermaidDouble.render.mockReset();
}

/**
 * Component double that wraps its children in a marker element.
 *
 * The wrapper carries `data-stub`, so static markup shows both that the child tree reached
 * the fumadocs component and what surrounded it.
 *
 * @param name Name the stub is recorded and matched under.
 * @param tag Element the children are wrapped in.
 * @returns A component usable as a `vi.mock` replacement.
 */
export function wrapperStub(
  name: string,
  tag: ElementType = "div"
): (props: Record<string, unknown>) => ReactElement {
  const Stub = (props: Record<string, unknown>): ReactElement => {
    calls.push({ name, props });
    return jsx(tag, { "data-stub": name, children: props.children as ReactNode });
  };
  Object.defineProperty(Stub, "name", { value: name });
  return Stub;
}

/**
 * Component double that renders its children with no wrapper of its own.
 *
 * @param name Name the stub is recorded and matched under.
 * @returns A component usable as a `vi.mock` replacement.
 */
function passthroughStub(name: string): (props: Record<string, unknown>) => ReactNode {
  const Stub = (props: Record<string, unknown>): ReactNode => {
    calls.push({ name, props });
    return props.children as ReactNode;
  };
  Object.defineProperty(Stub, "name", { value: name });
  return Stub;
}

/* ------------------------------------------------------------------ react hook harness */

/** A box as produced by the fake `useRef`, so a suite can attach a fake node to it. */
interface RefBox {
  current: unknown;
}

/** One value a stubbed state setter received. */
export interface SetCall {
  /** Index of the `useState` call in the render, so a suite can tell the setters apart. */
  index: number;
  value: unknown;
}

interface HookRun {
  boxes: RefBox[];
  sets: SetCall[];
  effects: (() => (() => void) | void)[];
  cleanups: (() => void)[];
}

/** Values the fake hooks hand back, in hook-call order: slot 0 is the first hook of a render. */
interface HookPlan {
  states: unknown[];
  refs: unknown[];
  ids: string[];
}

const plan: HookPlan = { states: [], refs: [], ids: [] };

function freshRun(): HookRun {
  return { boxes: [], sets: [], effects: [], cleanups: [] };
}

let run = freshRun();
let cursor = { state: 0, ref: 0, id: 0 };

/**
 * Start a render: set what the next hook calls return and forget the previous run.
 *
 * `states[i]` overrides the value of the i-th `useState`, which is how a suite renders a
 * component as if a state update had already happened, without a DOM to drive one.
 */
export function configureHooks(options: Partial<HookPlan> = {}): void {
  plan.states = options.states ?? [];
  plan.refs = options.refs ?? [];
  plan.ids = options.ids ?? [];
  cursor = { state: 0, ref: 0, id: 0 };
  run = freshRun();
}

/** Values the stubbed setters received, in call order. */
export function setCalls(): SetCall[] {
  return run.sets;
}

/** Run every effect the last render registered and keep the cleanups they returned. */
export function runEffects(): void {
  for (const effect of [...run.effects]) {
    const cleanup = effect();
    if (typeof cleanup === "function") run.cleanups.push(cleanup);
  }
}

/** Run the cleanups the effects returned. */
export function runCleanups(): void {
  for (const cleanup of [...run.cleanups]) cleanup();
}

/**
 * Replacements for the React hooks a component can be driven with directly.
 *
 * `useEffect` and `useLayoutEffect` only record their callback: `renderToStaticMarkup` never
 * runs effects, and the suites want to decide when one runs. Spread the result over the real
 * module inside a `vi.mock("react", ...)` factory.
 */
export function reactHookStubs(): Record<string, unknown> {
  return {
    useId: () => plan.ids[cursor.id++] ?? ":r0:",
    useRef: <T>(initial: T): RefBox => {
      const box: RefBox = { current: cursor.ref < plan.refs.length ? plan.refs[cursor.ref] : initial };
      cursor.ref += 1;
      run.boxes.push(box);
      return box;
    },
    useState: <T>(initial: T): [unknown, (value: unknown) => void] => {
      const index = cursor.state;
      cursor.state += 1;
      const value = index < plan.states.length ? plan.states[index] : initial;
      return [
        value,
        (next: unknown) => {
          run.sets.push({ index, value: next });
        }
      ];
    },
    useEffect: (effect: () => (() => void) | void) => {
      run.effects.push(effect);
    },
    useLayoutEffect: (effect: () => (() => void) | void) => {
      run.effects.push(effect);
    },
    useMemo: <T>(factory: () => T): T => factory(),
    useCallback: <T>(callback: T): T => callback
  };
}

/* ------------------------------------------------------------------ fumadocs / next doubles */

/** Configuration objects `defineDocs` received, in call order. */
export const docsConfigs: Record<string, unknown>[] = [];

/** The collection `lib/content.ts` declares, as the suites see it. */
export const docsStub = {
  toFumadocsSource: () => ({ kind: "fumadocs-source" })
};

/** Stand-in for the `fumadocs-mdx/macro` `defineDocs`, which only the bundler can compile. */
export function defineDocsStub(config: Record<string, unknown>): typeof docsStub {
  docsConfigs.push(config);
  return docsStub;
}

/** Options every `loader()` call received, in call order. */
export const loaderCalls: Record<string, unknown>[] = [];

/** Pages the stubbed loader serves, keyed by their path without a leading slash. */
export const loaderPages = new Map<string, { url: string; path: string }>();

/** Segments every `getPage()` lookup was asked for, in call order. */
export const loaderLookups: string[][] = [];

/** The single loader object `lib/source.ts` holds; `loaderStub` always hands back this one. */
const fakeLoader = {
  getPage(segments: string[]): { url: string; path: string } | undefined {
    loaderLookups.push(segments);
    return loaderPages.get(segments.filter((segment) => segment.length > 0).join("/"));
  }
};

/** Stand-in for `loader` from `fumadocs-core/source`, which reads a compiled collection. */
export function loaderStub(options: Record<string, unknown>): typeof fakeLoader {
  loaderCalls.push(options);
  return fakeLoader;
}

/** Stand-in for `createFromSource`, whose real form builds a search API over the collection. */
export const createFromSourceStub = vi.fn(() => ({ kind: "search-api" }));

/** What the stubbed `resolveDocHref` reports; a suite assigns it before it renders a link. */
export const hrefResolution: { current: { href?: string; external?: boolean } } = {
  current: { href: "/operate" }
};

/** Every link the stubbed `resolveDocHref` was asked to resolve, in call order. */
export const hrefLookups: { href: string | undefined; path: string }[] = [];

/** Stand-in for `resolveDocHref`, which otherwise needs the compiled content collection. */
export function resolveDocHrefStub(
  href: string | undefined,
  page: { path: string }
): { href?: string; external?: boolean } {
  hrefLookups.push({ href, path: page.path });
  return hrefResolution.current;
}

/** Stand-in for `defaultMdxComponents`, whose real form is a large map of theme components. */
export const defaultMdxComponentsStub: Record<string, unknown> = {
  Callout: passthroughStub("Callout"),
  Card: wrapperStub("Card")
};

/** Stand-in for the `fumadocs-core/link` default export. */
export function LinkStub(props: Record<string, unknown>): ReactElement {
  calls.push({ name: "Link", props });
  return jsx("a", { "data-stub": "Link", href: props.href as string, children: props.children as ReactNode });
}

/** The colour scheme the stubbed `useTheme` reports as resolved. */
export const themeState = { resolvedTheme: "light" as string | undefined };

/** Stub for `useTheme` from `next-themes`. */
export function useThemeStub(): { resolvedTheme: string | undefined } {
  calls.push({ name: "useTheme", props: {} });
  return { resolvedTheme: themeState.resolvedTheme };
}

/** The double the dynamically imported `mermaid` module resolves to. */
export const mermaidDouble = {
  initialize: vi.fn(),
  render: vi.fn<(id: string, chart: string) => Promise<{ svg: string }>>()
};

/** Stub for `useI18n` from `fumadocs-ui/contexts/i18n`. */
export function useI18nStub(): { locale: string } {
  return { locale: "en" };
}

/** Arguments the stubbed static client and search hook were called with. */
export const searchClientArgs: unknown[] = [];

/** What the stubbed `useDocsSearch` reports; a suite assigns to it before it renders. */
export const docsSearchState: { search: string; query: { data: unknown; isLoading: boolean } } = {
  search: "",
  query: { data: [], isLoading: false }
};

/** Stub for `staticClient` from `fumadocs-core/search/client/orama-static`. */
export function staticClientStub(options: unknown): { kind: "static-client" } {
  searchClientArgs.push(options);
  return { kind: "static-client" };
}

/** Stub for `useDocsSearch` from `fumadocs-core/search/client`. */
export function useDocsSearchStub(options: unknown): {
  search: string;
  setSearch: (value: string) => void;
  query: { data: unknown; isLoading: boolean };
} {
  searchClientArgs.push(options);
  return {
    search: docsSearchState.search,
    setSearch: (value: string) => {
      docsSearchState.search = value;
    },
    query: docsSearchState.query
  };
}

/** Stub for `createPortal` from `react-dom`, which needs a real DOM node to mount into. */
export function createPortalStub(node: unknown): unknown {
  return node;
}
