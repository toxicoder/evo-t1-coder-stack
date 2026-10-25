/**
 * Tests for the published-site base path and the source-link ref.
 *
 * GitHub project Pages serves the repo at `/<repo>/`, so an alias build that bakes
 * `basePath=/feat-foo` asks the browser for `https://<user>.github.io/feat-foo/_next/...`
 * and every stylesheet 404s. The helper must prefix the repo name for *any* alias — `main`
 * publishes `latest` and every other docs branch publishes its own sanitized name — while
 * local `next dev` and the unprefixed export keep an empty path.
 */

import { afterEach, describe, expect, it } from "vitest";

import { basePath, docsAlias, gitRef, REPO } from "../../lib/site";

const ENV_KEYS = ["NEXT_BASE_PATH", "DOCS_ALIAS", "GITHUB_REF_NAME", "EVO_DOCS_GIT_REF"] as const;

const originalEnv: Record<string, string | undefined> = {};

afterEach(() => {
  for (const key of ENV_KEYS) {
    if (originalEnv[key] === undefined) {
      delete process.env[key];
    } else {
      process.env[key] = originalEnv[key];
    }
  }
});

for (const key of ENV_KEYS) {
  originalEnv[key] = process.env[key];
  delete process.env[key];
}

describe("basePath", () => {
  it("is empty for local dev and the unprefixed export", () => {
    expect(basePath()).toBe("");
  });

  it("prefixes the GitHub Pages repo path for the latest alias", () => {
    process.env.DOCS_ALIAS = "latest";
    expect(basePath()).toBe(`/${REPO.repo}/latest`);
  });

  it("prefixes the GitHub Pages repo path for a work-branch alias", () => {
    process.env.DOCS_ALIAS = "feat-foo";
    expect(basePath()).toBe(`/${REPO.repo}/feat-foo`);
  });

  it("accepts an alias that is not the long-lived name", () => {
    process.env.DOCS_ALIAS = "docs-restructure";
    expect(basePath()).toBe(`/${REPO.repo}/docs-restructure`);
  });

  it("lets NEXT_BASE_PATH override the alias", () => {
    process.env.DOCS_ALIAS = "latest";
    process.env.NEXT_BASE_PATH = "/custom";
    expect(basePath()).toBe("/custom");
  });

  it("strips a trailing slash from NEXT_BASE_PATH", () => {
    process.env.NEXT_BASE_PATH = "/custom/";
    expect(basePath()).toBe("/custom");
  });

  it("treats NEXT_BASE_PATH=/ as no prefix", () => {
    process.env.NEXT_BASE_PATH = "/";
    process.env.DOCS_ALIAS = "latest";
    expect(basePath()).toBe("");
  });

  it("ignores a blank alias", () => {
    process.env.DOCS_ALIAS = "   ";
    expect(basePath()).toBe("");
  });
});

describe("docsAlias", () => {
  it("reports the alias the publisher set", () => {
    process.env.DOCS_ALIAS = "feat-foo";
    expect(docsAlias()).toBe("feat-foo");
  });

  it("is empty when nothing was set", () => {
    expect(docsAlias()).toBe("");
  });
});

describe("gitRef", () => {
  it("points the latest alias at main", () => {
    process.env.DOCS_ALIAS = "latest";
    process.env.GITHUB_REF_NAME = "main";
    expect(gitRef()).toBe("main");
  });

  it("points a branch alias at the branch it was built from", () => {
    process.env.DOCS_ALIAS = "feat-foo";
    process.env.GITHUB_REF_NAME = "feat/foo";
    expect(gitRef()).toBe("feat/foo");
  });

  it("falls back to EVO_DOCS_GIT_REF without a ref name", () => {
    process.env.DOCS_ALIAS = "feat-foo";
    process.env.EVO_DOCS_GIT_REF = "feat/foo";
    expect(gitRef()).toBe("feat/foo");
  });

  it("prefers GITHUB_REF_NAME over the override", () => {
    process.env.GITHUB_REF_NAME = "fix/bar";
    process.env.EVO_DOCS_GIT_REF = "feat/foo";
    expect(gitRef()).toBe("fix/bar");
  });

  it("defaults to main when nothing says otherwise", () => {
    expect(gitRef()).toBe("main");
  });
});
