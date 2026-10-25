import { defineConfig } from "vitest/config";

/**
 * Unit-test scope for the documentation site: the browser-free widget and content-transform
 * suites, run by `npm run unit` and //docs-site:unit.
 */
export default defineConfig({
  test: {
    include: ["tests/unit/**/*.test.{ts,tsx,mjs}"],
    environment: "node"
  }
});
