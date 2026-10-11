import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import type { Sandbox, UiServer } from "./harness.ts";
import {
  assertInsideSandbox,
  connectFrom,
  listeners,
  makeSandbox,
  nonLoopbackAddress,
  sizeOf,
  startUiServer,
} from "./harness.ts";
import { measuredFreed } from "../e2e/harness.ts";

type Finding = { ruleId: string; tier: string; path: string; bytes: number; blocked: boolean };
type Report = { findings: Finding[]; reclaimable: number; scannedMs: number };
type Outcome = { ruleId: string; path: string; status: string; detail: string };
type ApplyResult = { outcomes: Outcome[]; freed: number; freeBefore: number; freeAfter: number };
type Parsed = { status: number; body: unknown; res: Response };

let box: Sandbox;
let server: UiServer;
let report: Report;

async function call(path: string, init?: RequestInit): Promise<Parsed> {
  const res = await fetch(`${server.url}${path}`, init);
  const text = await res.text();
  let body: unknown = text;
  try {
    body = JSON.parse(text);
  } catch {
    body = text;
  }
  return { status: res.status, body, res };
}

const jsonBody = (tiers: unknown): RequestInit => ({
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ tiers }),
});

const skipAll = (source: Report): Record<string, string> =>
  Object.fromEntries(source.findings.map((finding) => [finding.ruleId, "skip"]));

beforeAll(async () => {
  box = await makeSandbox();
  server = await startUiServer(box);
  report = (await call("/api/scan")).body as Report;
});

afterAll(async () => {
  await server?.stop();
  await box?.dispose();
});

describe("the ui server only serves the local page", () => {
  test("the sandbox HOME is what the server scans", () => {
    expect(report.findings.length).toBeGreaterThan(0);
    for (const finding of report.findings) expect(finding.path.startsWith(box.home)).toBe(true);
  });

  test("the page and its assets are served with their real content types", async () => {
    const page = await call("/");
    expect({ status: page.status, type: page.res.headers.get("content-type") }).toEqual({
      status: 200,
      type: "text/html; charset=utf-8",
    });
    for (const [path, type] of [
      ["/app.js", "text/javascript"],
      ["/i18n.js", "text/javascript"],
      ["/style.css", "text/css"],
    ] as const) {
      const asset = await call(path);
      expect({ path, status: asset.status, type: asset.res.headers.get("content-type") }).toEqual({
        path,
        status: 200,
        type: `${type}; charset=utf-8`,
      });
    }
  });

  test("every response carries the hardening headers", async () => {
    const headers = (await call("/")).res.headers;
    expect(headers.get("content-security-policy")).toContain("frame-ancestors 'none'");
    expect(headers.get("content-security-policy")).toContain("connect-src 'self'");
    expect(headers.get("x-content-type-options")).toBe("nosniff");
    expect(headers.get("referrer-policy")).toBe("no-referrer");
    expect(headers.get("cache-control")).toBe("no-store");
  });

  test("an unknown route is a json 404, never html and never 500", async () => {
    const missing = await call("/nope");
    expect({
      status: missing.status,
      type: missing.res.headers.get("content-type"),
      error: typeof (missing.body as { error?: unknown }).error,
    }).toEqual({ status: 404, type: "application/json; charset=utf-8", error: "string" });
  });

  test("a non-loopback Host header is refused on read and on write", async () => {
    const spoofed = { headers: { Host: "evil.example.com", "Content-Type": "application/json" } };
    const read = await fetch(`${server.url}/api/scan`, spoofed);
    expect({ status: read.status, body: await read.json() }).toEqual({
      status: 403,
      body: { error: "only loopback hosts may talk to this server" },
    });
    const write = await fetch(`${server.url}/api/apply`, { method: "POST", body: "{}", ...spoofed });
    expect(write.status).toBe(403);
  });

  test("the listener is bound to 127.0.0.1 and nothing else", () => {
    const bound = listeners(server.port);
    expect(bound.length).toBeGreaterThan(0);
    expect(bound).toEqual([`127.0.0.1:${server.port}`]);
  });

  test.skipIf(!nonLoopbackAddress())("a connection from a non-loopback address is refused", async () => {
    expect(await connectFrom(nonLoopbackAddress() as string, server.port)).toBe("ECONNREFUSED");
  });

  test("concurrent scans share one in-flight walk", async () => {
    const answers = await Promise.all(Array.from({ length: 5 }, async () => (await call("/api/scan")).body as Report));
    expect(new Set(answers.map((answer) => answer.scannedMs)).size).toBe(1);
    expect(answers.every((answer) => answer.findings.length === report.findings.length)).toBe(true);
  });
});

describe("a malformed apply payload is refused and deletes nothing", () => {
  const probes: { name: string; init: RequestInit; status: number }[] = [
    { name: "malformed json", init: { method: "POST", headers: { "Content-Type": "application/json" }, body: "{not json" }, status: 400 },
    { name: "tiers as an array", init: jsonBody([]), status: 400 },
    { name: "tiers as a string", init: jsonBody("green"), status: 400 },
    { name: "tiers as null", init: jsonBody(null), status: 400 },
    { name: "tiers missing", init: { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" }, status: 400 },
    { name: "an unknown tier value", init: jsonBody({ "npm.cacache": "delete-everything" }), status: 400 },
    { name: "an oversized body", init: { method: "POST", headers: { "Content-Type": "application/json" }, body: "x".repeat(2 * 1024 * 1024) }, status: 413 },
  ];

  for (const probe of probes) {
    test(`${probe.name} returns ${probe.status} with a json error`, async () => {
      const before = await box.fingerprint();
      const res = await fetch(`${server.url}/api/apply`, probe.init);
      const text = await res.text();
      let body: unknown = text;
      try {
        body = JSON.parse(text);
      } catch {
        body = text;
      }
      expect({ status: res.status, type: res.headers.get("content-type") }).toEqual({
        status: probe.status,
        type: "application/json; charset=utf-8",
      });
      expect(typeof (body as { error?: unknown }).error).toBe("string");
      expect(await box.fingerprint()).toBe(before);
    });
  }
});

describe("apply is inert unless the payload says so", () => {
  test("an all-skip payload deletes nothing and frees nothing", async () => {
    const before = await box.fingerprint();
    const tiers = skipAll(report);
    expect(Object.keys(tiers).length).toBeGreaterThan(0);
    const response = await call("/api/apply", jsonBody(tiers));
    const result = response.body as ApplyResult;
    expect(response.status).toBe(200);
    expect(result.outcomes.length).toBe(report.findings.length);
    expect(result.outcomes.map((outcome) => outcome.status)).toEqual(result.outcomes.map(() => "skipped"));
    expect(result.freed).toBe(measuredFreed(result));
    expect(await box.fingerprint()).toBe(before);
  });

  test("a cross-origin post cannot reach the delete path", async () => {
    const before = await box.fingerprint();
    const res = await fetch(`${server.url}/api/apply`, {
      method: "POST",
      headers: { "Content-Type": "text/plain", Origin: "http://evil.example.com" },
      body: JSON.stringify({ tiers: skipAll(report) }),
    });
    expect(res.status).toBeGreaterThanOrEqual(400);
    expect(await box.fingerprint()).toBe(before);
  });
});

describe("a blocked finding survives even when the ui asks for its rule", () => {
  let guardBox: Sandbox;
  let guardServer: UiServer;

  beforeAll(async () => {
    guardBox = await makeSandbox();
    guardServer = await startUiServer(guardBox);
  });

  afterAll(async () => {
    await guardServer?.stop();
    await guardBox?.dispose();
  });

  test("asking to delete every rule still leaves the blocked finding on disk", async () => {
    const scan = (await fetch(`${guardServer.url}/api/scan`).then((res) => res.json())) as Report;
    for (const finding of scan.findings) assertInsideSandbox(finding.path, guardBox.root);
    const blocked = scan.findings.filter((finding) => finding.blocked);
    expect(blocked.length).toBe(1);
    const blockedPath = assertInsideSandbox(blocked[0]?.path ?? "", guardBox.root);

    const applied = (await fetch(`${guardServer.url}/api/apply`, jsonBody(
      Object.fromEntries(scan.findings.map((finding) => [finding.ruleId, "yellow"])),
    )).then((res) => res.json())) as { outcomes: Outcome[] };
    const outcome = applied.outcomes.find((item) => item.path === blockedPath);

    expect(outcome?.status).toBe("skipped");
    expect(outcome?.detail).toContain("KHÔNG XÓA");
    const planted = guardBox.planted.find((path) => path.startsWith(blockedPath));
    expect({
      blockedDirBytes: await sizeOf(blockedPath),
      plantedFileBytes: await sizeOf(planted ?? ""),
    }).toEqual({ blockedDirBytes: expect.any(Number), plantedFileBytes: 2 * 1024 * 1024 });
  });
});