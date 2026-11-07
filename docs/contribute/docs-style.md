---
title: Writing documentation
description: "The contract every page in docs/ has to satisfy before the site will render it: frontmatter, the authored H1, the opening scan pair, and the navigation file that decides whether a page is reachable at all."
tags: [docs, fumadocs, writing, nav]
---

# Writing documentation

**What's on this page**

- What a page's frontmatter has to carry, and what each field is used for
- Why every page writes its own `# H1` and what the layout prints beside it
- The two opening lists that become the scan card, and the order they have to sit in
- How abbreviations, tables and diagrams pick up their chrome without a component call
- Where the sidebar comes from, and which check refuses a page it cannot reach

**What this enables**

- Adding a page that shows up in the menu, the search index and the prev/next footer
- Predicting what a reader sees from what you wrote, without opening a browser to find out
- Fixing a docs failure from the assertion that named it

The site is a Fumadocs app that reads `docs/` straight out of the repository, so the markdown
here is the source of record: nothing is copied into `docs-site/`, and the README's links keep
pointing at these files. Most of the chrome is derived from the prose rather than authored in
it, which is what keeps 20-odd pages consistent.

## Frontmatter

Every page declares three fields, and `docs-site/tests/unit/docs-content.test.ts` refuses a
page that is missing any of them:

```yaml
---
title: Branching
description: "Trunk-based branch rules: main is the only long-lived branch, ..."
tags: [git, branching, ci]
---
```

- `title` is the sidebar label, the search result title, and the string your `# H1` has to
  match character for character.
- `description` is printed as the lead paragraph under the title and indexed for search. Quote
  it when it contains a colon, or YAML reads the line as a mapping.
- `tags` are indexed, so a reader who searches for the word you filed the page under finds it.
  `pageSchema` strips unknown keys, which is why `tags` is declared explicitly in
  `docs-site/lib/content.ts` — a new field needs the same treatment or it silently never
  reaches the index.

## The page title

Each page writes its own `# H1`, once, as the first heading of the body, spelled exactly like
the frontmatter `title`. That heading is the one the table of contents and every `#anchor`
point at, so `DocsH1` prints it and then the description beneath it as the lead paragraph. A
page whose first heading is not its title keeps a plain heading and gets no lead paragraph,
which is the visible sign that the two strings drifted apart.

The reason the authored heading is the only title: the page header used to print the frontmatter
title and the body printed its own, so every page opened with the same string twice.

## The opening scan pair

Immediately after the title, two bold labels each followed by a bullet list:

```markdown
**What's on this page**

- The question this page answers
...

**What this enables**

- What you can do afterwards
...
```

`docs-site/lib/remark-page-brief.ts` recognises that four-node run and rewrites it into one
`<PageBrief>` — the two-column card with the list and tick icons. The match is exact: the label
has to be the whole paragraph, bold, and spelled `What's on this page` and `What this enables`;
the lists have to be lists; and no heading may sit between the title and the pair. Get any of
that wrong and the page renders the lists as plain bullets, which is the only symptom.

## Chrome that arrives on its own

Nothing below needs a component call in the page.

- **Abbreviations.** A term listed in `docs/includes/abbreviations.md` as `*[TERM]: definition`
  is wrapped wherever it appears in prose. Hover or focus shows the definition; click or Enter
  opens it in a dialog. Text inside a link, a heading, inline code, or an existing term is left
  alone. Keep each definition tooltip-sized.
- **Tables.** A content table gets its head pinned under the navbar while the table is on
  screen, and a mirrored scroll bar at the bottom of the viewport when its columns are wider
  than the page. Both come from `docs-site/components/table-chrome.tsx`; a table that already
  carries a class is left as authored.
- **Diagrams.** A ` ```mermaid ` fence renders through `Mermaid`, follows the light/dark switch,
  and shows the chart text beside a parse error rather than leaving a blank box.
- **Fenced code.** Every fence needs a language, checked by the same contract test, because the
  highlighter and the copy button both key off it.

## Navigation

The sidebar is not read from the filesystem: most pages sit flat in `docs/` while belonging to
different sections, and the reading order a prev/next footer needs is an editorial decision. The
tree is declared once in `NAV` inside `docs-site/scripts/gen_nav.py` and generated into
`docs-site/lib/nav.json`, which the page-tree builder imports and a Zod schema validates.

A section holds an ordered mix of leaves and collapsible folders. A leaf is `(label, path)` and a
folder is `(label, [child, ...])`. Folders stay ordinary directories: a section whose first entry
is an index page uses that page as its clickable label.

Regenerate after you change either the tree or the file layout:

```bash
bazelisk run //docs:nav                              # rewrite lib/nav.json
bazelisk run //docs-site:npm -- run nav:check         # fail if the two have drifted
```

`//docs-site:nav_test` and the contract test together refuse a page that exists but is not
declared, and a declaration whose file is gone, so an unlinked page cannot be merged.

## Checks

```bash
bazelisk run //docs:serve            # dev server with hot reload
bazelisk run //docs:preview          # build the export and serve it
bazelisk run //docs:verify           # missing pages, unprefixed assets, leaked .md links
bazelisk test //docs-site:nav_test   # nav.json matches the declaration
bazelisk test //docs-site:unit       # the contract test and the component suites
```

`docs/manage-docs.sh` is the same set as a single operator CLI (`serve`, `build`, `preview`,
`verify`, `typecheck`, `test`, `nav`, `status`, `clean`) for a host that has Node but not Bazel.
The gates run through Bazel; see [Testing with Bazel](test-with-bazel.md) for how the npm-backed
targets are wired and why they stay out of `//:test-fast`.
