/**
 * Tests for the site-wide published stamp.
 *
 * The chip in the page header tells a reader how old the page they are reading is, so two
 * failures matter: a stamp taken from the clock, which would tell everyone the page changed a
 * moment ago every time the same commit is rebuilt, and a stamp that fails to resolve at all,
 * which drops the chip from the export. The build host decides which of the three sources wins
 * (`EVO_DOCS_PUBLISHED_AT`, then `SOURCE_DATE_EPOCH`, then git HEAD), so each is driven here
 * with git stood in for by a double.
 */

import { execFileSync } from "node:child_process";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { formatPublishedLabel, publishedAt } from "../../lib/published";

vi.mock("node:child_process", () => ({
  execFileSync: vi.fn()
}));

/**
 * The checkout `lib/published.ts` walks up to: two levels above the `lib` directory that
 * holds it, which is the same tree this test sits in. Derived from this file's own URL so
 * the assertion still names the right directory where the checkout is not named after the
 * repository, which is how `//scripts:test-in-image` runs it (the tree mounts at `/work`).
 */
const checkoutRoot = resolve(fileURLToPath(new URL("../../..", import.meta.url)));

const gitRun = vi.mocked(execFileSync);

const ENV_KEYS = ["EVO_DOCS_PUBLISHED_AT", "SOURCE_DATE_EPOCH"] as const;
const saved: Record<string, string | undefined> = {};

beforeEach(() => {
  for (const key of ENV_KEYS) {
    saved[key] = process.env[key];
    delete process.env[key];
  }
  gitRun.mockReset();
});

afterEach(() => {
  for (const key of ENV_KEYS) {
    if (saved[key] === undefined) delete process.env[key];
    else process.env[key] = saved[key];
  }
});

/** Ask for this build's stamp and report it as an ISO string, or `undefined`. */
function stamp(): string | undefined {
  return publishedAt()?.toISOString();
}

describe("publishedAt", () => {
  it("takes the datetime the build host named", () => {
    process.env.EVO_DOCS_PUBLISHED_AT = "2026-09-04T08:30:00Z";
    expect(stamp()).toBe("2026-09-04T08:30:00.000Z");
    expect(gitRun).not.toHaveBeenCalled();
  });

  it("tolerates the padding a shell substitution leaves behind", () => {
    process.env.EVO_DOCS_PUBLISHED_AT = "  2026-09-04T08:30:00Z\n";
    expect(stamp()).toBe("2026-09-04T08:30:00.000Z");
  });

  it("accepts the stamp as whole seconds since the epoch", () => {
    process.env.EVO_DOCS_PUBLISHED_AT = "1787376600";
    expect(stamp()).toBe(new Date(1787376600 * 1000).toISOString());
  });

  it("reports no stamp when the build host named one that is not a date", () => {
    process.env.EVO_DOCS_PUBLISHED_AT = "yesterday";
    expect(stamp()).toBeUndefined();
    expect(gitRun).not.toHaveBeenCalled();
  });

  it("reports no stamp when the named epoch seconds overflow a date", () => {
    process.env.EVO_DOCS_PUBLISHED_AT = "99999999999999999999";
    expect(stamp()).toBeUndefined();
  });

  it("treats an empty variable as unset and keeps looking", () => {
    process.env.EVO_DOCS_PUBLISHED_AT = "   ";
    process.env.SOURCE_DATE_EPOCH = "1787376600";
    expect(stamp()).toBe(new Date(1787376600 * 1000).toISOString());
  });

  it("falls back to reproducible-build seconds when no stamp was named", () => {
    process.env.SOURCE_DATE_EPOCH = "1787376600";
    expect(stamp()).toBe(new Date(1787376600 * 1000).toISOString());
    expect(gitRun).not.toHaveBeenCalled();
  });

  it("keeps looking when the reproducible-build seconds are unreadable", () => {
    process.env.SOURCE_DATE_EPOCH = "not-a-number";
    gitRun.mockReturnValue("2026-09-04T08:30:00+02:00\n");
    expect(stamp()).toBe("2026-09-04T06:30:00.000Z");
  });

  it("asks git for the commit date of the checkout when nothing was named", () => {
    gitRun.mockReturnValue("2026-09-04T08:30:00Z\n");
    expect(stamp()).toBe("2026-09-04T08:30:00.000Z");
    const [command, args] = gitRun.mock.calls[0] ?? [];
    expect(command).toBe("git");
    expect(args?.[0]).toBe("-C");
    expect(args?.[1]).toBe(checkoutRoot);
    expect(args?.slice(2)).toEqual(["log", "-1", "--format=%cI"]);
  });

  it("reports no stamp when the checkout has no git to ask", () => {
    gitRun.mockImplementation(() => {
      throw new Error("not a git repository");
    });
    expect(stamp()).toBeUndefined();
  });

  it("reports no stamp when git answers with nothing", () => {
    gitRun.mockReturnValue("   ");
    expect(stamp()).toBeUndefined();
  });
});

describe("formatPublishedLabel", () => {
  it("writes the day, an English month name, and the year", () => {
    expect(formatPublishedLabel(new Date("2026-09-04T08:30:00Z"))).toBe("4 Sep 2026");
  });

  it("does not pad a single-digit day", () => {
    expect(formatPublishedLabel(new Date("2026-01-01T00:00:00Z"))).toBe("1 Jan 2026");
  });

  it("reads the date in UTC rather than the build host's zone", () => {
    expect(formatPublishedLabel(new Date("2026-12-31T23:30:00Z"))).toBe("31 Dec 2026");
  });

  it("names every month", () => {
    const labels = Array.from({ length: 12 }, (_, month) =>
      formatPublishedLabel(new Date(Date.UTC(2026, month, 9)))
    );
    expect(labels).toEqual([
      "9 Jan 2026",
      "9 Feb 2026",
      "9 Mar 2026",
      "9 Apr 2026",
      "9 May 2026",
      "9 Jun 2026",
      "9 Jul 2026",
      "9 Aug 2026",
      "9 Sep 2026",
      "9 Oct 2026",
      "9 Nov 2026",
      "9 Dec 2026"
    ]);
  });
});
