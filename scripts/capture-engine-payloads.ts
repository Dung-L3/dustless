import { mkdir, utimes, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { age, cleanupAll, DAY, plant, REPO, sandbox, type Sandbox } from "../tests/e2e/harness.ts";
import type { ApplyReport, Finding, ScanReport } from "../src/types.ts";

const OUT = join(REPO, "apps", "dustless-mac", "Tests", "DustlessAppTests", "Fixtures");
const PINNED_MTIME = 1_700_000_000_000;

async function stage(box: Sandbox): Promise<void> {
  const { home } = box;
  await plant(join(home, ".npm", "_cacache", "content-v2", "aa"), 300 * 1024, 3);
  await plant(join(home, ".cache", "pip", "wheels"), 120 * 1024, 2);
  await plant(join(home, "Library", "Containers", "com.docker.docker", "Data", "vms", "0", "data"), 2_400 * 1024, 5);
  await plant(join(home, ".bun", "install", "cache", "pkg"), 90 * 1024, 2);
  await plant(join(home, ".gradle", "caches", "9.0"), 700 * 1024, 4);
  await mkdir(join(home, ".gradle", "wrapper", "dists"), { recursive: true });
  await writeFile(join(home, ".gradle", "wrapper", "dists", "gradle-8.7-bin.properties"), "x");
  await plant(join(home, "work", "svc", "node_modules", "left-pad"), 512 * 1024, 2);
  await writeFile(join(home, "work", "svc", "node_modules", ".package-lock.json"), "{}");
  await writeFile(join(home, "work", "svc", "package.json"), '{"name":"svc","dependencies":{"left-pad":"1.3.0"}}');
  await age(join(home, "work", "svc"), 40);
  const recent = new Date(Date.now() - 3 * DAY);
  await utimes(join(home, "work", "svc", "package.json"), recent, recent);
}

function pin(report: ScanReport): ScanReport {
  return {
    ...report,
    findings: report.findings.map((f: Finding, at: number) => ({
      ...f,
      mtime: PINNED_MTIME + at * 1_000,
      atime: PINNED_MTIME + at * 2_000,
      ageDays: Number((40 + at * 1.5).toFixed(3)),
    })),
    scannedMs: 128,
  };
}

function deriveApply(report: ScanReport): ApplyReport {
  const statuses = ["deleted", "skipped", "failed"] as const;
  const outcomes = report.findings.map((f, at) => ({
    ruleId: f.ruleId,
    tier: f.tier,
    path: f.path,
    status: f.blocked ? "skipped" : statuses[at % statuses.length] ?? "skipped",
    bytes: f.bytes,
    detail: f.blocked
      ? "KHÔNG XÓA: cross-verification failed"
      : `captured from scan finding ${at}, never executed`,
  }));
  const freed = outcomes
    .filter((o) => o.status === "deleted")
    .reduce((sum, o) => sum + o.bytes, 0);
  return {
    outcomes,
    freed,
    freeBefore: report.freeBefore,
    freeAfter: report.freeBefore + freed,
    elapsedMs: 412,
  };
}

const box = await sandbox("capture");
try {
  await stage(box);
  const run = await box.run(["scan", "--json"]);
  if (run.code !== 0) throw new Error(`scan failed (${run.code}): ${run.stderr}`);
  const pinned = pin(JSON.parse(run.stdout) as ScanReport);
  await mkdir(OUT, { recursive: true });
  await writeFile(join(OUT, "scan.json"), `${JSON.stringify(pinned, null, 2)}\n`);
  await writeFile(join(OUT, "apply.json"), `${JSON.stringify(deriveApply(pinned), null, 2)}\n`);
  const tiers = pinned.findings.reduce<Record<string, number>>((acc, f) => {
    acc[f.blocked ? "blocked" : f.tier] = (acc[f.blocked ? "blocked" : f.tier] ?? 0) + 1;
    return acc;
  }, {});
  console.log(`findings=${pinned.findings.length} tiers=${JSON.stringify(tiers)}`);
  console.log(`reclaimable=${pinned.reclaimable} blocked=${pinned.totals.blocked.bytes}`);
} finally {
  await cleanupAll();
}
