/**
 * Wrap the first **What's on this page** / **What this enables** pair after the page
 * title into `<PageBrief>`. Source markdown stays bold + bullets (not headings).
 */

import { visit } from "unist-util-visit";

function isStrongParagraph(node: { type?: string; children?: { type?: string; children?: { type?: string; value?: string }[] }[] }, label: string): boolean {
  if (node.type !== "paragraph" || !Array.isArray(node.children) || node.children.length !== 1) return false;
  const child = node.children[0];
  if (child?.type !== "strong" || !Array.isArray(child.children) || child.children.length !== 1) return false;
  const text = child.children[0];
  return text?.type === "text" && String(text.value ?? "").trim() === label;
}

/**
 * Rewrite the scan-list pair into a PageBrief MDX element.
 *
 * @returns A remark transformer.
 */
export function remarkPageBrief() {
  return (tree: { type: string; children?: unknown[] }) => {
    const children = tree.children;
    if (!Array.isArray(children)) return;

    visit(tree, "heading", (node: { depth?: number }, index, parent) => {
      if (node.depth !== 1 || parent !== tree || typeof index !== "number") return;
      let onPageAt = -1;
      for (let i = index + 1; i < children.length - 3; i += 1) {
        const n = children[i] as { type?: string };
        if (n.type === "heading") break;
        if (isStrongParagraph(n as never, "What's on this page")) {
          onPageAt = i;
          break;
        }
      }
      if (onPageAt < 0) return;
      const listA = children[onPageAt + 1] as { type?: string };
      const enables = children[onPageAt + 2] as { type?: string };
      const listB = children[onPageAt + 3] as { type?: string };
      if (listA?.type !== "list") return;
      if (!isStrongParagraph(enables as never, "What this enables")) return;
      if (listB?.type !== "list") return;

      const brief = {
        type: "mdxJsxFlowElement",
        name: "PageBrief",
        attributes: [],
        children: [children[onPageAt], listA, enables, listB],
        data: { _mdxExplicitJsx: true }
      };
      children.splice(onPageAt, 4, brief);
    });
  };
}
