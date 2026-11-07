/**
 * GitHub issue URL for a documentation bug, prefilled from the page the reader is on.
 */

import { REPO_URL } from "./site";

/** Facts the heading button knows when the reader clicks. */
export interface DocsBugReport {
  pageUrl: string;
  pageTitle: string;
  heading: string;
  headingId: string;
  sourcePath: string;
  sourceUrl: string;
  gitRef: string;
  docsAlias: string;
  userAgent: string;
  viewport: string;
  colorScheme: string;
  selection: string;
}

const ISSUE_NEW = `${REPO_URL}/issues/new`;

/** Stay under GitHub's issue-URL limit once the query string is encoded. */
const MAX_HREF = 5500;

/**
 * Collapse whitespace and cap a field so the issue URL stays openable.
 *
 * @param value Raw text.
 * @param max Maximum length, including an ellipsis when trimmed.
 * @returns A single-line string.
 */
function clip(value: string, max: number): string {
  const text = value.replace(/\s+/g, " ").trim();
  if (text.length <= max) return text;
  if (max < 4) return "";
  return `${text.slice(0, max - 3)}...`;
}

/**
 * Build a new-issue URL the reader can revise and submit.
 *
 * Title shape is `Docs: <page> - <heading>`. The body names the page, heading,
 * docs alias, git ref, and source file, then leaves two blanks for the reader.
 *
 * @param report Page and browser facts.
 * @returns `https://github.com/.../issues/new?title=&body=`.
 */
export function docsBugHref(report: DocsBugReport): string {
  const title = clip(`Docs: ${report.pageTitle} - ${report.heading}`, 140);

  const build = (selection: string, agent: string): string => {
    const lines = [
      "Documentation bug. Edit the blanks, then submit.",
      "",
      `- Page: ${report.pageUrl}`,
      `- Heading: ${report.heading} (\`#${report.headingId}\`)`,
      `- Docs alias: ${report.docsAlias}`,
      `- Git ref: ${report.gitRef}`,
      `- Source file: ${report.sourcePath}`,
      `- Source: ${report.sourceUrl}`,
      "",
      "## What is wrong",
      "",
      "<!-- Replace this line. -->",
      "",
      "## What it should say",
      "",
      "<!-- Replace this line. -->",
      "",
      "## Browser",
      "",
      `- Viewport: ${report.viewport}`,
      `- Color scheme: ${report.colorScheme}`,
      `- User agent: ${agent}`
    ];
    if (selection) lines.push(`- Selected text: ${selection}`);
    const params = new URLSearchParams({ title, body: lines.join("\n"), labels: "documentation" });
    return `${ISSUE_NEW}?${params.toString()}`;
  };

  let href = build(clip(report.selection, 400), clip(report.userAgent, 180));
  if (href.length > MAX_HREF) href = build("", clip(report.userAgent, 80));
  if (href.length > MAX_HREF) href = build("", "");
  return href;
}
