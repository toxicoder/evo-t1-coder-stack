/**
 * Site-wide last-published stamp.
 *
 * Resolution order is `EVO_DOCS_PUBLISHED_AT`, then `SOURCE_DATE_EPOCH`, then git HEAD.
 * Never wall-clock now: an export that stamps itself with the clock would tell a reader the
 * page changed a moment ago every time the same commit is rebuilt.
 */

import { execFileSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

function parseDatetime(raw: string): Date | undefined {
  const trimmed = raw.trim();
  if (!trimmed) return undefined;
  if (/^-?\d+$/.test(trimmed)) {
    const ms = Number(trimmed) * 1000;
    const date = new Date(ms);
    return Number.isNaN(date.getTime()) ? undefined : date;
  }
  const parsed = new Date(trimmed.replace("Z", "+00:00"));
  return Number.isNaN(parsed.getTime()) ? undefined : parsed;
}

function gitHead(): Date | undefined {
  try {
    const here = dirname(fileURLToPath(import.meta.url));
    const repo = resolve(here, "../..");
    const iso = execFileSync("git", ["-C", repo, "log", "-1", "--format=%cI"], {
      encoding: "utf8",
      timeout: 2000
    }).trim();
    return parseDatetime(iso);
  } catch {
    return undefined;
  }
}

/** Aware UTC stamp for this build, or undefined when none can be resolved. */
export function publishedAt(): Date | undefined {
  const envRaw = process.env.EVO_DOCS_PUBLISHED_AT;
  if (envRaw !== undefined && envRaw.trim() !== "") {
    return parseDatetime(envRaw);
  }
  const epoch = (process.env.SOURCE_DATE_EPOCH ?? "").trim();
  if (epoch) {
    const stamp = parseDatetime(epoch);
    if (stamp) return stamp;
  }
  return gitHead();
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** English calendar label with no zero-padded day, e.g. `4 Sep 2026`. */
export function formatPublishedLabel(stamp: Date): string {
  return `${stamp.getUTCDate()} ${MONTHS[stamp.getUTCMonth()]} ${stamp.getUTCFullYear()}`;
}
