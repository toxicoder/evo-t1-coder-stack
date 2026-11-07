// @vitest-environment jsdom
/**
 * Tests for the last-published chip.
 *
 * The chip answers "how old is this page?" from a stamp the build resolved once, and the
 * answer is written twice: an absolute UTC instant for machines and the tooltip, and a
 * relative phrase a reader actually reads. The phrase is what goes stale and what lies, so the
 * suite pins the boundaries where it changes ("1 minute ago" beside "2 minutes ago", a day
 * beside fourteen) and the fallback that keeps a bad stamp from printing `NaN`. The clock is
 * fixed here because the whole component is a comparison against it.
 */

import { createElement } from "react";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { PublishedChip } from "../../components/published-chip";
import { mount, settle, unmount } from "./helpers/dom-harness";

/** The instant the build was published, and the clock a reader loads the page at. */
const STAMP = Date.UTC(2026, 10, 7, 8, 30, 0);
const NOW = Date.UTC(2026, 10, 7, 12, 0, 0);
const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

/** The ISO instant the chip is handed for a stamp this far before the clock. */
function isoBefore(ms: number): string {
  return new Date(NOW - ms).toISOString();
}

/** Render the chip and report the phrase the reader sees. */
async function chip(iso: string, label = "7 Nov 2026"): Promise<string> {
  mount(createElement(PublishedChip, { iso, label }));
  await settle();
  return document.querySelector("time")?.textContent ?? "";
}

beforeEach(() => {
  vi.spyOn(Date, "now").mockReturnValue(NOW);
});

afterEach(() => {
  unmount();
  vi.restoreAllMocks();
});

describe("PublishedChip", () => {
  it("labels the stamp so the phrase has a subject", async () => {
    await chip(isoBefore(HOUR));
    expect(document.querySelector("span.ez-published-chip__label")?.textContent).toBe("Last published");
    expect(document.querySelector("span.ez-published-chip")).not.toBeNull();
  });

  it("keeps the absolute instant on the time element", async () => {
    const iso = isoBefore(HOUR);
    await chip(iso);
    expect(document.querySelector("time")?.getAttribute("datetime")).toBe(iso);
  });

  it("marks the chip as a live status region with a decorative icon hidden", async () => {
    await chip(isoBefore(HOUR));
    expect(document.querySelector("span.ez-published-chip")?.getAttribute("role")).toBe("status");
    expect(document.querySelector("svg.ez-published-chip__icon")?.getAttribute("aria-hidden")).toBe("true");
  });

  it("says just now for a page published this minute", async () => {
    expect(await chip(isoBefore(30 * 1000))).toBe("just now");
  });

  it("says 1 minute ago at the minute boundary", async () => {
    expect(await chip(isoBefore(MINUTE))).toBe("1 minute ago");
  });

  it("counts the minutes below the hour", async () => {
    expect(await chip(isoBefore(12 * MINUTE))).toBe("12 minutes ago");
  });

  it("switches to hours at the hour and says 1 hour ago once", async () => {
    expect(await chip(isoBefore(HOUR))).toBe("1 hour ago");
    expect(await chip(isoBefore(6 * HOUR))).toBe("6 hours ago");
  });

  it("switches to days at the day and says 1 day ago once", async () => {
    expect(await chip(isoBefore(DAY))).toBe("1 day ago");
    expect(await chip(isoBefore(3 * DAY))).toBe("3 days ago");
  });

  it("gives up on the relative phrase after two weeks", async () => {
    expect(await chip(isoBefore(14 * DAY))).toBe("7 Nov 2026");
    expect(await chip(isoBefore(400 * DAY))).toBe("7 Nov 2026");
  });

  it("still says just now when the stamp is a little in the future", async () => {
    expect(await chip(new Date(NOW + 5 * MINUTE).toISOString())).toBe("just now");
  });

  it("falls back to the absolute label when the stamp is not a date", async () => {
    expect(await chip("published-yesterday", "7 Nov 2026")).toBe("7 Nov 2026");
  });

  it("puts the absolute instant and time in the tooltip", async () => {
    await chip(new Date(STAMP).toISOString(), "7 Nov 2026");
    expect(document.querySelector("span.ez-published-chip")?.getAttribute("title")).toBe(
      "Last published 7 Nov 2026, 08:30 UTC"
    );
  });

  it("pads a single-digit hour and minute in the tooltip", async () => {
    await chip(new Date(Date.UTC(2026, 10, 7, 4, 5, 0)).toISOString(), "7 Nov 2026");
    expect(document.querySelector("span.ez-published-chip")?.getAttribute("title")).toContain("04:05 UTC");
  });
});
