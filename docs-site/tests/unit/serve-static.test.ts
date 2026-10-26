/**
 * Tests for the static-export preview server.
 *
 * The exported site is a directory of `index.html` files, and this server is what a browser is
 * driven through during verification, so the routes that matter are the ones the exporter
 * produces: `/` and `/guides` have to reach the `index.html` inside them, every asset has to
 * carry the content type the browser sniffs otherwise, a path that climbs out of the export
 * root has to be refused rather than read, and a page that is not there has to answer with the
 * export's own `404.html`.
 *
 * `node:http` is doubled, so the handler is called directly with a fake response and no socket
 * is ever bound; the export itself is a real scratch tree under the OS temp directory, so the
 * reads are real. Run it from `docs-site/` with `npm run unit`, or `npm run unit:coverage` for
 * the gate.
 */

import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

/** What the server sees of a request: only `url` is read. */
interface RequestLike {
  url?: string;
}

/** What the server writes to a response, recorded instead of sent. */
interface ResponseLike {
  writeHead(status: number, headers?: Record<string, string | number>): void;
  end(body?: unknown): void;
}

type RequestHandler = (req: RequestLike, res: ResponseLike) => Promise<void> | void;

/** Double for `node:http`: records the handler and the `listen` arguments, binds nothing. */
const httpDouble = vi.hoisted(() => {
  const handlers: unknown[] = [];
  const listens: { port: number; host: string; callback: () => void }[] = [];
  return {
    handlers,
    listens,
    createServer(handler: unknown) {
      handlers.push(handler);
      return {
        listen(port: number, host: string, callback: () => void) {
          listens.push({ port, host, callback });
        }
      };
    }
  };
});

vi.mock("node:http", () => ({
  createServer: (handler: RequestHandler) => httpDouble.createServer(handler)
}));

const PORT = 4131;

/** The exported tree: one file per shape the export actually emits. */
const EXPORT_FILES: Record<string, string> = {
  "index.html": "<!doctype html><title>Docs</title>",
  "guides/index.html": "<!doctype html><title>Guides</title>",
  "app.js": "console.log(1);",
  "site.css": "body{margin:0}",
  "data.json": '{"pages":[]}',
  "icon.svg": "<svg xmlns='http://www.w3.org/2000/svg'/>",
  "page.png": "png-bytes",
  "photo.jpg": "jpeg-bytes",
  "favicon.ico": "ico-bytes",
  "robots.txt": "User-agent: *",
  "font.woff2": "woff2-bytes",
  "data.map": "{}",
  "STYLE.CSS": "BODY{margin:0}",
  "mystery.unknown": "raw bytes"
};

/** Scratch tree: `<base>/out` is the served root, `<base>/secret.txt` sits beside it. */
let baseDir = "";
let root = "";

/** Everything the server wrote for one request. */
interface Written {
  status: number | undefined;
  headers: Record<string, string | number> | undefined;
  body: unknown;
}

/** Drive one request through the captured handler. */
async function send(url: string | undefined): Promise<Written> {
  const handler = httpDouble.handlers[0] as RequestHandler | undefined;
  if (!handler) throw new Error("the server never registered a request handler");
  const written: Written = { status: undefined, headers: undefined, body: undefined };
  await handler(
    { url },
    {
      writeHead(status, headers) {
        written.status = status;
        written.headers = headers;
      },
      end(body) {
        written.body = body;
      }
    }
  );
  return written;
}

beforeAll(async () => {
  baseDir = mkdtempSync(join(tmpdir(), "serve-static-"));
  root = join(baseDir, "out");
  const originalArgv = process.argv;
  process.argv = ["node", "serve_static.mjs", String(PORT), root];
  try {
    // The CLI is untyped JavaScript imported for its side effects, so the specifier is widened
    // to `string` to keep tsc from demanding a declaration file for it.
    await import("../../scripts/serve_static.mjs" as string);
  } finally {
    process.argv = originalArgv;
  }
});

beforeEach(() => {
  rmSync(baseDir, { recursive: true, force: true });
  mkdirSync(root, { recursive: true });
  writeFileSync(join(baseDir, "secret.txt"), "outside the export root");
  for (const [relative, content] of Object.entries(EXPORT_FILES)) {
    const file = join(root, relative);
    mkdirSync(join(file, ".."), { recursive: true });
    writeFileSync(file, content);
  }
});

afterAll(() => {
  rmSync(baseDir, { recursive: true, force: true });
});

describe("serve_static", () => {
  it("listens on the loopback address and reports where the site is", () => {
    expect(httpDouble.listens).toHaveLength(1);
    const [listen] = httpDouble.listens;
    expect(listen?.port).toBe(PORT);
    expect(listen?.host).toBe("127.0.0.1");

    const logged = vi.spyOn(console, "log").mockImplementation(() => {});
    listen?.callback();
    expect(logged).toHaveBeenCalledWith(`serving ${root} on http://127.0.0.1:${PORT}\n`);
    logged.mockRestore();
  });

  it("serves the root index.html for the site root", async () => {
    const response = await send("/");

    expect(response.status).toBe(200);
    expect(response.headers?.["Content-Type"]).toBe("text/html; charset=utf-8");
    expect(String(response.body)).toBe(EXPORT_FILES["index.html"]);
    expect(response.headers?.["Content-Length"]).toBe(
      Buffer.byteLength(EXPORT_FILES["index.html"] ?? "")
    );
  });

  it("serves the root index.html when the request carries no url", async () => {
    const response = await send(undefined);

    expect(response.status).toBe(200);
    expect(String(response.body)).toBe(EXPORT_FILES["index.html"]);
  });

  it("serves a directory page from the index.html inside it", async () => {
    const response = await send("/guides");

    expect(response.status).toBe(200);
    expect(String(response.body)).toBe(EXPORT_FILES["guides/index.html"]);
  });

  it("maps every emitted extension to the type the browser expects", async () => {
    const expected: [string, string][] = [
      ["/site.css", "text/css"],
      ["/app.js", "text/javascript"],
      ["/data.json", "application/json"],
      ["/icon.svg", "image/svg+xml"],
      ["/page.png", "image/png"],
      ["/photo.jpg", "image/jpeg"],
      ["/favicon.ico", "image/x-icon"],
      ["/robots.txt", "text/plain; charset=utf-8"],
      ["/font.woff2", "font/woff2"],
      ["/data.map", "application/json"],
      ["/STYLE.CSS", "text/css"]
    ];

    for (const [url, type] of expected) {
      const response = await send(url);
      expect(response.status, url).toBe(200);
      expect(response.headers?.["Content-Type"], url).toBe(type);
    }
  });

  it("declares the byte length of the body it sends", async () => {
    const response = await send("/site.css");

    expect(response.headers?.["Content-Length"]).toBe(Buffer.byteLength("body{margin:0}"));
    expect((response.body as Buffer).byteLength).toBe(14);
  });

  it("falls back to a generic type for an extension the export does not use", async () => {
    const response = await send("/mystery.unknown");

    expect(response.status).toBe(200);
    expect(response.headers?.["Content-Type"]).toBe("application/octet-stream");
    expect(String(response.body)).toBe("raw bytes");
  });

  it("answers a missing page with the export's own 404.html", async () => {
    writeFileSync(join(root, "404.html"), "<!doctype html><title>Not found</title>");

    const response = await send("/no-such-page");

    expect(response.status).toBe(404);
    expect(response.headers?.["Content-Type"]).toBe("text/html; charset=utf-8");
    expect(String(response.body)).toBe("<!doctype html><title>Not found</title>");
  });

  it("answers a missing page plainly when the export has no 404.html", async () => {
    rmSync(join(root, "404.html"), { force: true });

    const response = await send("/no-such-page");

    expect(response.status).toBe(404);
    expect(String(response.body)).toBe("not found");
  });

  it("treats an exported directory without an index as no page at all", async () => {
    rmSync(join(root, "404.html"), { force: true });
    mkdirSync(join(root, "blog"), { recursive: true });

    const response = await send("/blog");

    expect(response.status).toBe(404);
    expect(String(response.body)).toBe("not found");
  });

  it("refuses a path that climbs out of the export root", async () => {
    rmSync(join(root, "404.html"), { force: true });

    const response = await send("/..%2F..%2Fsecret.txt");

    expect(response.status).toBe(404);
    expect(String(response.body)).not.toContain("outside the export root");
    expect(readFileSync(join(baseDir, "secret.txt"), "utf8")).toBe("outside the export root");
  });

  it("answers 500 when the request path cannot be decoded", async () => {
    const response = await send("/%zz");

    expect(response.status).toBe(500);
    expect(String(response.body)).toContain("URI malformed");
  });
});
