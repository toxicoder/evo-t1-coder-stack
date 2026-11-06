// @ts-check
/**
 * PostCSS configuration for the docs site.
 *
 * `postcss-load-config` is not a dependency of this project — Next loads this file
 * directly — so the plugin map is typed structurally instead of importing that
 * package's `Config`, which would be an unresolvable type reference.
 *
 * @module
 */

/** @type {{ plugins: Readonly<Record<string, unknown>> }} */
const config = {
  plugins: {
    "@tailwindcss/postcss": {}
  }
};

export default config;
