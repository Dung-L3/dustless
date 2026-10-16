import { spawn } from "node:child_process";
import {
  createServer,
  type IncomingMessage,
  type Server,
  type ServerResponse,
} from "node:http";
import { apply } from "../core/apply.ts";
import { HOME } from "../core/paths.ts";
import { loadRules } from "../core/rules.ts";
import { scan } from "../core/scan.ts";
import { diskUsage, freeSpace } from "../core/space.ts";
import type { ScanReport, TierChoice } from "../types.ts";
import appJs from "./public/app.js" with { type: "text" };
import i18nJs from "./public/i18n.js" with { type: "text" };
import indexHtml from "./public/index.html" with { type: "text" };
import styleCss from "./public/style.css" with { type: "text" };
import uiHelpersJs from "./public/ui-helpers.js" with { type: "text" };

const HOST = "127.0.0.1";
const PREFERRED_PORT = 4477;
const MAX_BODY_BYTES = 1 << 20;
const LOOPBACK_HOSTS = new Set(["127.0.0.1", "localhost"]);

const CSP = [
  "default-src 'none'",
  "script-src 'self'",
  "style-src 'self'",
  "img-src 'self' data:",
  "connect-src 'self'",
  "base-uri 'none'",
  "form-action 'none'",
  "frame-ancestors 'none'",
].join("; ");

const ASSETS = new Map<string, readonly [string, string]>([
  ["/", ["text/html; charset=utf-8", indexHtml]],
  ["/index.html", ["text/html; charset=utf-8", indexHtml]],
  ["/style.css", ["text/css; charset=utf-8", styleCss]],
  ["/app.js", ["text/javascript; charset=utf-8", appJs]],
  ["/i18n.js", ["text/javascript; charset=utf-8", i18nJs]],
  ["/ui-helpers.js", ["text/javascript; charset=utf-8", uiHelpersJs]],
]);

const CHOICES = new Set(["green", "yellow", "skip"]);

class HttpError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
    this.name = "HttpError";
  }
}

let inflightScan: Promise<ScanReport> | null = null;
let lastReport: ScanReport | null = null;

function scanOnce(): Promise<ScanReport> {
  const pending = inflightScan ?? scan();
  inflightScan = pending;
  return pending.finally(() => {
    if (inflightScan === pending) inflightScan = null;
  });
}

async function diskSpace(): Promise<{ free: number; total: number }> {
  const [free, usage] = await Promise.all([freeSpace(), diskUsage(HOME)]);
  return { free, total: usage.bytes };
}

async function readChoices(req: IncomingMessage): Promise<TierChoice> {
  const chunks: Buffer[] = [];
  let bytes = 0;
  let overflow = false;
  await new Promise<void>((resolve, reject) => {
    req.on("data", (chunk: Buffer) => {
      bytes += chunk.length;
      if (bytes > MAX_BODY_BYTES) {
        overflow = true;
        req.pause();
        resolve();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", resolve);
    req.on("error", reject);
  });
  if (overflow) {
    req.resume();
    throw new HttpError(413, "request body too large");
  }
  let body: unknown;
  try {
    body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new HttpError(400, "body must be valid JSON");
  }
  const tiers =
    typeof body === "object" && body !== null && !Array.isArray(body)
      ? (body as { tiers?: unknown }).tiers
      : undefined;
  if (typeof tiers !== "object" || tiers === null || Array.isArray(tiers)) {
    throw new HttpError(400, "tiers must be a JSON object of ruleId to tier");
  }
  const choices: TierChoice = {};
  for (const [ruleId, choice] of Object.entries(tiers as Record<string, unknown>)) {
    if (typeof choice !== "string" || !CHOICES.has(choice)) {
      throw new HttpError(400, `tier for ${ruleId} must be green, yellow or skip`);
    }
    choices[ruleId] = choice as TierChoice[string];
  }
  return choices;
}

function isLoopback(req: IncomingMessage): boolean {
  const host = (req.headers.host ?? "").toLowerCase().replace(/:\d+$/, "");
  return LOOPBACK_HOSTS.has(host);
}

function crossOrigin(req: IncomingMessage): string | null {
  const origin = req.headers.origin;
  if (!origin) return null;
  try {
    const url = new URL(origin);
    if (LOOPBACK_HOSTS.has(url.hostname.toLowerCase())) return null;
    return origin;
  } catch {
    return origin;
  }
}

function sendJson(res: ServerResponse, status: number, payload: unknown, done?: () => void): void {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
  });
  res.end(body, done);
}

async function handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.setHeader("Referrer-Policy", "no-referrer");
  res.setHeader("Cache-Control", "no-store");
  res.setHeader("Content-Security-Policy", CSP);
  if (!isLoopback(req)) {
    res.setHeader("Connection", "close");
    sendJson(res, 403, { error: "only loopback hosts may talk to this server" });
    return;
  }
  const path = new URL(req.url ?? "/", `http://${HOST}`).pathname;
  const method = req.method ?? "GET";
  if (method !== "GET" && method !== "HEAD") {
    const origin = crossOrigin(req);
    if (origin) {
      res.setHeader("Connection", "close");
      sendJson(res, 403, { error: `cross-origin ${method} refused from ${origin}` });
      return;
    }
    if (!/^application\/json\b/i.test(req.headers["content-type"] ?? "")) {
      res.setHeader("Connection", "close");
      sendJson(res, 415, { error: "Content-Type must be application/json" });
      return;
    }
  }
  const asset = ASSETS.get(path);
  try {
    if (method === "GET" && asset) {
      res.writeHead(200, {
        "Content-Type": asset[0],
        "Content-Length": Buffer.byteLength(asset[1]),
      });
      res.end(asset[1]);
      return;
    }
    if (method === "GET" && path === "/api/scan") {
      lastReport = await scanOnce();
      return sendJson(res, 200, lastReport);
    }
    if (method === "GET" && path === "/api/rules") return sendJson(res, 200, await loadRules());
    if (method === "GET" && path === "/api/space") return sendJson(res, 200, await diskSpace());
    if (method === "POST" && path === "/api/apply") {
      const tiers = await readChoices(req);
      const report = lastReport ?? (await scanOnce());
      return sendJson(res, 200, await apply(report, { tiers, assumeYes: true }));
    }
    sendJson(res, 404, { error: `no route for ${method} ${path}` });
  } catch (error) {
    const status = error instanceof HttpError ? error.status : 500;
    if (status === 413) res.setHeader("Connection", "close");
    sendJson(res, status, { error: error instanceof Error ? error.message : "internal error" }, () => req.destroy());
  }
}

function listenOn(server: Server, port: number): Promise<number> {
  return new Promise<number>((resolve, reject) => {
    const onError = (error: Error) => reject(error);
    server.once("error", onError);
    server.listen(port, HOST, () => {
      server.removeListener("error", onError);
      const address = server.address();
      resolve(address !== null && typeof address === "object" ? address.port : port);
    });
  });
}

function openInBrowser(url: string): void {
  const isWindows = process.platform === "win32";
  const command = isWindows ? "cmd" : process.platform === "darwin" ? "open" : "xdg-open";
  const args = isWindows ? ["/c", "start", "", url] : [url];
  spawn(command, args, { stdio: "ignore", detached: true }).unref();
}

export type UiServer = { url: string; port: number; close(): Promise<void> };

export async function startServer(opts: { port?: number; open?: boolean } = {}): Promise<UiServer> {
  const server = createServer();
  server.requestTimeout = 0;
  server.timeout = 0;
  server.on("request", (req, res) => void handle(req, res));

  const attempts = opts.port === undefined ? [PREFERRED_PORT, 0] : [opts.port];
  let port = 0;
  for (const attempt of attempts) {
    try {
      port = await listenOn(server, attempt);
      break;
    } catch (error) {
      const taken = (error as { code?: string }).code === "EADDRINUSE";
      if (!taken || attempt === opts.port) throw error;
    }
  }

  const url = `http://${HOST}:${port}`;
  if (opts.open) openInBrowser(url);
  return {
    url,
    port,
    close: () =>
      new Promise<void>((resolve) => {
        server.closeAllConnections();
        server.close(() => resolve());
      }),
  };
}