/**
 * Tests for the page-brief remark transform.
 *
 * Every authored page opens with a two-column scan card built from a fixed four-node pair:
 * a bold `What's on this page` line and its list, then a bold `What this enables` line and its
 * list. This plugin is what turns those eight source lines into one `<PageBrief>` element, and
 * it has to be exact in both directions. Rewriting a page that did not earn the card would
 * wrap arbitrary prose in it; missing the rewrite leaves the reader with two plain bullet lists
 * where the layout expects a card. Both cases are asserted here on hand-built mdast trees.
 */

import { describe, expect, it } from "vitest";

import { remarkPageBrief } from "../../lib/remark-page-brief";

/** Any mdast node, kept loose so a case can build the shape it needs. */
type Node = Record<string, unknown> & { type: string };

/** The document root the transformer is handed. */
type Tree = { type: string; children?: Node[] };

/** A top-level heading. */
function heading(depth: number, text: string): Node {
  return { type: "heading", depth, children: [{ type: "text", value: text }] };
}

/** A paragraph whose whole content is one bold phrase. */
function bold(label: string): Node {
  return { type: "paragraph", children: [strong(label)] };
}

/** A paragraph with anything else in it. */
function paragraph(text: string): Node {
  return { type: "paragraph", children: [{ type: "text", value: text }] };
}

/** A bare strong node, for a paragraph that mixes it with other inline content. */
function strong(label: string): Node {
  return { type: "strong", children: [{ type: "text", value: label }] };
}

/** A bold paragraph whose strong node carries extra inline content. */
function boldWithTrailing(label: string): Node {
  return {
    type: "paragraph",
    children: [
      { type: "strong", children: [{ type: "text", value: label }, { type: "text", value: "!" }] }
    ]
  };
}

/** A bullet list with one item. */
function list(label: string): Node {
  return {
    type: "list",
    ordered: false,
    children: [
      { type: "listItem", children: [paragraph(`${label} one`)] }
    ]
  };
}

/** The four source nodes the card is built from, in document order. */
function pair(): [Node, Node, Node, Node] {
  return [bold("What's on this page"), list("scan"), bold("What this enables"), list("gain")];
}

/** Run the transform over a document and return what the root holds afterwards. */
function transform(children: Node[] | undefined): Node[] | undefined {
  const tree: Tree = { type: "root", children };
  remarkPageBrief()(tree);
  return tree.children;
}

/** The card element a successful rewrite left behind, which follows the page title. */
function onlyCard(children: Node[] | undefined): Node {
  const card = children?.find((node) => node["type"] === "mdxJsxFlowElement");
  if (!card) {
    throw new Error(`no PageBrief card in ${String(children?.length)} node(s)`);
  }
  return card;
}

describe("remarkPageBrief", () => {
  it("wraps the scan pair in one PageBrief element", () => {
    const card = onlyCard(transform([heading(1, "Title"), ...pair()]));
    expect(card.type).toBe("mdxJsxFlowElement");
    expect(card.name).toBe("PageBrief");
    expect(card.data).toEqual({ _mdxExplicitJsx: true });
    expect(card.attributes).toEqual([]);
  });

  it("moves the four source nodes into the card in order", () => {
    const [scanLabel, scanList, enablesLabel, enablesList] = pair();
    const title = heading(1, "Title");
    const card = onlyCard(transform([title, scanLabel, scanList, enablesLabel, enablesList]));
    const moved = card.children as Node[] | undefined;
    expect(moved?.[0]).toBe(scanLabel);
    expect(moved?.[1]).toBe(scanList);
    expect(moved?.[2]).toBe(enablesLabel);
    expect(moved?.[3]).toBe(enablesList);
  });

  it("leaves the rest of the document outside the card", () => {
    const more = heading(2, "More");
    const body = paragraph("body");
    const children = transform([heading(1, "Title"), ...pair(), more, body]);
    if (!children) throw new Error("the root lost its children");
    expect(children).toHaveLength(4);
    expect(children[1]).toHaveProperty("name", "PageBrief");
    expect(children[2]).toBe(more);
    expect(children[3]).toBe(body);
  });

  it("matches the label with the padding a stray space leaves behind", () => {
    const children = transform([heading(1, "Title"), bold("  What's on this page \n"), ...pair().slice(1)]);
    expect(children?.[1]).toHaveProperty("name", "PageBrief");
  });

  it("leaves a document with no children alone", () => {
    const tree: Tree = { type: "root" };
    expect(() => {
      remarkPageBrief()(tree);
    }).not.toThrow();
    expect(tree.children).toBeUndefined();
  });

  it("leaves a page whose first heading is not the title alone", () => {
    const children = transform([paragraph("intro"), ...pair()]);
    if (!children) throw new Error("the root lost its children");
    expect(children).toHaveLength(5);
    expect(children.some((node) => node["type"] === "mdxJsxFlowElement")).toBe(false);
  });

  it("leaves a page without the scan pair alone", () => {
    const children = transform([heading(1, "Title"), paragraph("prose"), list("scan"), paragraph("more")]);
    if (!children) throw new Error("the root lost its children");
    expect(children).toHaveLength(4);
  });

  it("stops scanning at the next heading rather than adopting a later pair", () => {
    const children = transform([heading(1, "Title"), heading(2, "Section"), ...pair()]);
    if (!children) throw new Error("the root lost its children");
    expect(children).toHaveLength(6);
  });

  it("leaves the pair alone when the first list is not a list", () => {
    const children = transform([
      heading(1, "Title"),
      bold("What's on this page"),
      paragraph("no list here"),
      bold("What this enables"),
      list("gain")
    ]);
    if (!children) throw new Error("the root lost its children");
    expect(children).toHaveLength(5);
  });

  it("leaves the pair alone when the second label is the wrong phrase", () => {
    const children = transform([
      heading(1, "Title"),
      bold("What's on this page"),
      list("scan"),
      bold("What this unlocks"),
      list("gain")
    ]);
    if (!children) throw new Error("the root lost its children");
    expect(children).toHaveLength(5);
  });

  it("leaves the pair alone when the second list is not a list", () => {
    const children = transform([
      heading(1, "Title"),
      bold("What's on this page"),
      list("scan"),
      bold("What this enables"),
      paragraph("no list here")
    ]);
    if (!children) throw new Error("the root lost its children");
    expect(children).toHaveLength(5);
  });

  it("ignores a bold phrase that shares its paragraph with other text", () => {
    const children = transform([
      heading(1, "Title"),
      { type: "paragraph", children: [strong("What's on this page"), { type: "text", value: " too" }] },
      ...pair().slice(1)
    ]);
    if (!children) throw new Error("the root lost its children");
    expect(children).toHaveLength(5);
  });

  it("ignores a strong node that carries more than the label", () => {
    const children = transform([heading(1, "Title"), boldWithTrailing("What's on this page"), ...pair().slice(1)]);
    if (!children) throw new Error("the root lost its children");
    expect(children).toHaveLength(5);
  });

  it("ignores a bold phrase whose content is not plain text", () => {
    const children = transform([
      heading(1, "Title"),
      { type: "paragraph", children: [{ type: "strong", children: [{ type: "inlineCode", value: "What's on this page" }] }] },
      ...pair().slice(1)
    ]);
    if (!children) throw new Error("the root lost its children");
    expect(children).toHaveLength(5);
  });
});
