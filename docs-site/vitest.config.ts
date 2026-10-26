import { defineConfig } from "vitest/config";

/**
 * Unit-test scope for the documentation site: the browser-free widget and content-transform
 * suites, run by `npm run unit` and //docs-site:unit.
 *
 * `npm run unit:coverage` adds the measured gate. The bar is 100% of the functions in every
 * file the site ships as application code. The files under `exclude` below are Next and
 * fumadocs glue with no branch of their own to exercise: they are listed with a reason so a
 * reader can tell a deliberate exclusion from an oversight, and adding to the list needs that
 * reason beside it.
 */

/** Application code the coverage gate measures. */
const COVERED = [
  "lib/**/*.ts",
  "components/**/*.ts",
  "components/**/*.tsx",
  "app/api/**/*.ts",
  "scripts/**/*.mjs",
];

/** Glue with no logic of its own, each excluded for a stated reason. */
const EXCLUDED_FROM_COVERAGE = [
  // Next re-exports this generated file; it holds no site code.
  "source.config.ts",
  // Build knobs read by Next itself, with no callable surface.
  "next.config.ts",
  "postcss.config.mjs",
  // Root layout: font and provider wiring that only Next's renderer invokes.
  "app/layout.tsx",
  // 404 page: a single static render Next mounts by route, with no branch.
  "app/not-found.tsx",
  // Route renderer whose every path calls into fumadocs and Next's request handling;
  // the page contract it depends on is asserted by docs-content.test.ts instead.
  "app/[[...slug]]/page.tsx",
];

export default defineConfig({
  test: {
    include: ["tests/unit/**/*.test.{ts,tsx,mjs}"],
    environment: "node",
    coverage: {
      provider: "v8",
      reporter: ["text", "json-summary"],
      reportsDirectory: "coverage",
      // Every file under `include` is measured whether or not a test imported
      // it. Vitest 4 made that the default and dropped the `all` key from
      // CoverageOptions, so setting it here is a type error. The measured
      // coverage section of docs/contribute/test-with-bazel.md records how to
      // prove the default still held after a vitest bump: an uncalled
      // lib/__cov_probe.ts must show up at 0% and fail the run.
      include: COVERED,
      exclude: EXCLUDED_FROM_COVERAGE,
      thresholds: {
        perFile: true,
        functions: 100,
        lines: 95,
      },
    },
  },
});
