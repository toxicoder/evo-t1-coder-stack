/**
 * 404 page for the exported site.
 *
 * GitHub Pages serves this file for unknown URLs, and a static export has no server to
 * fall back on, so the not-found document is the entry point a bad deep link lands on.
 */
import Link from "fumadocs-core/link";

export default function NotFound() {
  return (
    <main className="mx-auto max-w-3xl px-6 py-24">
      <h1 className="text-2xl font-bold text-fd-foreground">Page not found</h1>
      {/* Link, not a plain anchor: only Next's component prefixes href with basePath. */}
      <p className="mt-3 text-fd-muted-foreground">
        That page is not part of the documentation.  Use search, or start from the
        <Link className="text-fd-primary underline underline-offset-2" href="/">
          {" "}
          overview
        </Link>
        .
      </p>
    </main>
  );
}

/** Rendered inside the root layout, which supplies the theme providers. */
export const metadata = { title: "Page not found" };
