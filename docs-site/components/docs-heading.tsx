"use client";

import {
  createContext,
  isValidElement,
  useContext,
  useEffect,
  useState,
  type ComponentPropsWithoutRef,
  type ReactNode
} from "react";
import { Bug, Check, Link as LinkIcon } from "lucide-react";

import { docsBugHref, type DocsBugReport } from "@/lib/docs-bug";

/** Page facts the server knows and every heading bug button needs. */
export interface DocsPageFacts {
  title: string;
  description?: string;
  sourcePath: string;
  sourceUrl: string;
  gitRef: string;
  docsAlias: string;
}

const DocsPageContext = createContext<DocsPageFacts | null>(null);

/**
 * Supplies the current page's source path and docs alias to heading chrome.
 */
export function DocsPageProvider({
  facts,
  children
}: {
  facts: DocsPageFacts;
  children: ReactNode;
}) {
  return <DocsPageContext.Provider value={facts}>{children}</DocsPageContext.Provider>;
}

/** Flatten heading children to the text a reader sees. */
function headingText(node: ReactNode): string {
  if (typeof node === "string" || typeof node === "number") return String(node);
  if (Array.isArray(node)) return node.map(headingText).join("");
  if (isValidElement<{ children?: ReactNode }>(node)) return headingText(node.props.children);
  return "";
}

/**
 * Issue URL for this heading, including the live page address and browser facts.
 */
function reportFor(facts: DocsPageFacts | null, heading: string, headingId: string): DocsBugReport {
  const url = new URL(window.location.href);
  if (headingId) url.hash = headingId;
  const selection = window.getSelection()?.toString() ?? "";
  const dark = document.documentElement.classList.contains("dark");
  return {
    pageUrl: url.toString(),
    pageTitle: facts?.title || document.title,
    heading,
    headingId,
    sourcePath: facts?.sourcePath ?? "",
    sourceUrl: facts?.sourceUrl ?? "",
    gitRef: facts?.gitRef ?? "",
    docsAlias: facts?.docsAlias ?? "local",
    userAgent: navigator.userAgent,
    viewport: `${window.innerWidth}x${window.innerHeight}`,
    colorScheme: dark ? "dark" : "light",
    selection
  };
}

const iconButtonClass =
  "inline-flex items-center justify-center rounded-md p-1 [&_svg]:size-4 not-prose shrink-0 text-fd-muted-foreground opacity-0 transition-opacity group-hover/heading:opacity-100 focus-visible:opacity-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-fd-ring hover:bg-fd-accent hover:text-fd-accent-foreground";

type HeadingTag = "h1" | "h2" | "h3" | "h4" | "h5" | "h6";

/**
 * Heading with the anchor-copy control and a documentation-bug control beside it.
 *
 * Headings without an id stay plain, matching Fumadocs.
 */
function DocsHeading({
  as,
  id,
  children,
  className,
  ...rest
}: { as: HeadingTag } & ComponentPropsWithoutRef<HeadingTag>) {
  const As = as;
  const facts = useContext(DocsPageContext);
  const label = headingText(children).replace(/\s+/g, " ").trim();
  const [copied, setCopied] = useState(false);
  const [bugHref, setBugHref] = useState("#");

  useEffect(() => {
    if (!id) return undefined;
    setBugHref(docsBugHref(reportFor(facts, label, id)));
    return undefined;
  }, [facts, id, label]);

  if (!id) {
    return (
      <As id={id} className={className} {...rest}>
        {children}
      </As>
    );
  }

  const armBugHref = (anchor: HTMLAnchorElement) => {
    const href = docsBugHref(reportFor(facts, label, id));
    anchor.href = href;
    setBugHref(href);
  };

  return (
    <As
      id={id}
      {...rest}
      className={["group/heading flex scroll-m-28 flex-row items-center gap-1", className]
        .filter(Boolean)
        .join(" ")}
    >
      <a data-card="" href={`#${id}`}>
        {children}
      </a>
      <button
        type="button"
        aria-label={copied ? "Copied anchor link" : "Copy anchor link"}
        className={iconButtonClass}
        onClick={() => {
          const url = new URL(window.location.href);
          url.hash = id;
          void navigator.clipboard.writeText(url.href).then(() => {
            setCopied(true);
            window.setTimeout(() => setCopied(false), 1500);
          });
        }}
      >
        {copied ? <Check aria-hidden /> : <LinkIcon aria-hidden />}
      </button>
      <a
        data-docs-bug=""
        href={bugHref}
        target="_blank"
        rel="noreferrer noopener"
        aria-label="File a documentation bug"
        className={iconButtonClass}
        onPointerDown={(event) => armBugHref(event.currentTarget)}
      >
        <Bug aria-hidden />
      </a>
    </As>
  );
}

/**
 * Page title heading, and the lead paragraph under it.
 *
 * The page header used to print the frontmatter title and then the authored `# H1`
 * printed it again, so every page opened with the same string twice. The authored heading
 * is the one anchors and the table of contents point at, so it is the only title, and the
 * frontmatter description becomes its lead paragraph. A page whose first heading is not its
 * title keeps the plain heading and no lead paragraph.
 */
export function DocsH1(props: ComponentPropsWithoutRef<"h1">) {
  const facts = useContext(DocsPageContext);
  const heading = <DocsHeading as="h1" {...props} />;
  const label = headingText(props.children).replace(/\s+/g, " ").trim();
  const isPageTitle =
    Boolean(facts?.title) &&
    label.localeCompare(facts?.title ?? "", "en", { sensitivity: "accent" }) === 0;
  if (!isPageTitle || !facts?.description) return heading;
  return (
    <>
      {heading}
      <p className="mb-6 text-lg text-fd-muted-foreground">{facts.description}</p>
    </>
  );
}
/** Section headings. Named exports so the server component map receives real client components. */
export function DocsH2(props: ComponentPropsWithoutRef<"h2">) {
  return <DocsHeading as="h2" {...props} />;
}
export function DocsH3(props: ComponentPropsWithoutRef<"h3">) {
  return <DocsHeading as="h3" {...props} />;
}
export function DocsH4(props: ComponentPropsWithoutRef<"h4">) {
  return <DocsHeading as="h4" {...props} />;
}
export function DocsH5(props: ComponentPropsWithoutRef<"h5">) {
  return <DocsHeading as="h5" {...props} />;
}
export function DocsH6(props: ComponentPropsWithoutRef<"h6">) {
  return <DocsHeading as="h6" {...props} />;
}
