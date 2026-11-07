import Link from "next/link";
import { ChevronRight } from "lucide-react";

import type { NavTrail } from "@/lib/nav";

/**
 * Breadcrumb above the page title: section, then each sidebar folder, then the page.
 *
 * The left menu keeps every section in the tree beside the reader's own, so the trail is
 * what says which one they are standing in. fumadocs' own breadcrumb prints page titles: it
 * would name neither the section nor the leaf the way the menu rows do. Folders stay plain
 * text: a trail link that jumped sideways through the sidebar would compete with the sidebar
 * itself.
 */
export function DocsTrail({ trail, page, url }: { trail: NavTrail; page: string; url: string }) {
  const items: { name: string; url?: string }[] = [
    { name: trail.tab },
    ...trail.groups.map((name) => ({ name })),
    { name: page, url }
  ];
  return (
    <nav aria-label="Breadcrumb" className="flex items-center gap-1.5 text-sm text-fd-muted-foreground">
      {items.map((item, index) => (
        <span key={`${item.name}-${String(index)}`} className="flex items-center gap-1.5">
          {index > 0 ? <ChevronRight aria-hidden="true" className="size-3.5 shrink-0" /> : null}
          {item.url ? (
            <Link
              className="truncate text-fd-primary font-medium transition-opacity hover:opacity-80"
              href={item.url}
            >
              {item.name}
            </Link>
          ) : (
            <span className="truncate" title={item.name}>
              {item.name}
            </span>
          )}
        </span>
      ))}
    </nav>
  );
}
