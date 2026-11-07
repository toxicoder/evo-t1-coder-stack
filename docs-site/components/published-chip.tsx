"use client";

import { useEffect, useState } from "react";

function relativeLabel(iso: string, fallback: string): string {
  const then = Date.parse(iso);
  if (Number.isNaN(then)) return fallback;
  let delta = Date.now() - then;
  if (delta < 0) delta = 0;
  const minute = 60 * 1000;
  const hour = 60 * minute;
  const day = 24 * hour;
  if (delta < minute) return "just now";
  if (delta < hour) {
    const mins = Math.floor(delta / minute);
    return mins === 1 ? "1 minute ago" : `${mins} minutes ago`;
  }
  if (delta < day) {
    const hours = Math.floor(delta / hour);
    return hours === 1 ? "1 hour ago" : `${hours} hours ago`;
  }
  if (delta < 14 * day) {
    const days = Math.floor(delta / day);
    return days === 1 ? "1 day ago" : `${days} days ago`;
  }
  return fallback;
}

/** Last-published chip. `datetime` stays absolute UTC; the visible label may go relative. */
export function PublishedChip({ iso, label }: { iso: string; label: string }) {
  const [text, setText] = useState(label);
  useEffect(() => {
    setText(relativeLabel(iso, label));
  }, [iso, label]);
  const utc = new Date(iso);
  const title = `Last published ${label}, ${String(utc.getUTCHours()).padStart(2, "0")}:${String(utc.getUTCMinutes()).padStart(2, "0")} UTC`;
  return (
    <span className="ez-published-chip" role="status" title={title}>
      <svg className="ez-published-chip__icon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
        <path d="M19 4h-1V2h-2v2H8V2H6v2H5c-1.11 0-1.99.9-1.99 2L3 20a2 2 0 0 0 2 2h14c1.1 0 2-.9 2-2V6c0-1.1-.9-2-2-2m0 16H5V10h14zM5 8V6h14v2z" />
      </svg>
      <span className="ez-published-chip__label">Last published</span>
      <span className="ez-published-chip__sep" aria-hidden="true">
        -
      </span>
      <time dateTime={iso}>{text}</time>
    </span>
  );
}
