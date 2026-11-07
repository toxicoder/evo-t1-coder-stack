"use client";

import { BRAND, SITE_NAME } from "@/lib/site";

/**
 * Lowercase brand wordmark with the project name as the docs subtitle.
 *
 * MkDocs rendered the site name as the header title; the brand voice replaces it and the
 * project name moves to the secondary line, which is how the Voltage brand sheet pairs them.
 */
export function Wordmark({ className }: { className?: string | undefined }) {
  return (
    <div className={`flex flex-col leading-none ${className ?? ""}`} aria-label={`${BRAND} ${SITE_NAME}`}>
      <span className="text-1.125rem font-bold tracking-tight lowercase text-fd-foreground">{BRAND}</span>
      <span className="text-0.6875rem font-medium text-fd-muted-foreground">{SITE_NAME}</span>
    </div>
  );
}
