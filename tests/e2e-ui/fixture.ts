import type { Finding, ScanReport, Tier } from "../../src/types.ts";

const MB = 1024 * 1024;
const DAY = 86_400_000;
const HOME = "/Users/dev";

export const NPM_CACHE = `${HOME}/.npm/_cacache`;
export const BUILD_ONE = `${HOME}/work/app/build`;
export const BUILD_TWO = `${HOME}/work/lib/build`;
export const BUILD_THREE = `${HOME}/work/docs/build`;
export const BLOCKED_GRADLE = `${HOME}/.gradle/caches/8.14`;
export const RED_HOME = `${HOME}/Documents/notes`;

export const GREEN_RULE = "npm.cacache";
export const YELLOW_RULE = "project.build";
export const BLOCKED_RULE = "gradle.version_cache";
export const RED_RULE = "docs.archive";

type Seed = {
  ruleId: string;
  tier: Tier;
  desc: string;
  path: string;
  bytes: number;
  ageDays: number;
  verified?: boolean;
  blocked?: boolean;
  note?: string;
};

function finding(seed: Seed): Finding {
  const mtime = Date.now() - seed.ageDays * DAY;
  return {
    ruleId: seed.ruleId,
    tier: seed.tier,
    desc: seed.desc,
    path: seed.path,
    bytes: seed.bytes,
    mtime,
    atime: mtime,
    ageDays: seed.ageDays,
    verified: seed.verified ?? true,
    blocked: seed.blocked ?? false,
    note: seed.note ?? "",
  };
}

function tally(findings: Finding[]): ScanReport["totals"] {
  const totals: ScanReport["totals"] = {
    green: { count: 0, bytes: 0 },
    yellow: { count: 0, bytes: 0 },
    red: { count: 0, bytes: 0 },
    blocked: { count: 0, bytes: 0 },
  };
  for (const item of findings) {
    const bucket = item.blocked ? totals.blocked : totals[item.tier];
    bucket.count += 1;
    bucket.bytes += item.bytes;
  }
  return totals;
}

export function buildReport(seeds: Seed[]): ScanReport {
  const findings = seeds.map(finding);
  const totals = tally(findings);
  return {
    findings,
    totals,
    reclaimable: totals.green.bytes + totals.yellow.bytes,
    freeBefore: 301 * 1024 * MB,
    platform: "mac",
    scannedMs: 412,
  };
}

export const SEEDS: Seed[] = [
  {
    ruleId: GREEN_RULE,
    tier: "green",
    desc: "npm cache tarball",
    path: NPM_CACHE,
    bytes: 5 * MB,
    ageDays: 40,
  },
  {
    ruleId: GREEN_RULE,
    tier: "green",
    desc: "npm cache tarball",
    path: `${HOME}/.npm/_npx`,
    bytes: 2 * MB,
    ageDays: 12,
  },
  {
    ruleId: YELLOW_RULE,
    tier: "yellow",
    desc: "Build output của project",
    path: BUILD_ONE,
    bytes: 8 * MB,
    ageDays: 2,
  },
  {
    ruleId: YELLOW_RULE,
    tier: "yellow",
    desc: "Build output của project",
    path: BUILD_TWO,
    bytes: 4 * MB,
    ageDays: 2,
  },
  {
    ruleId: YELLOW_RULE,
    tier: "yellow",
    desc: "Build output của project",
    path: BUILD_THREE,
    bytes: 1 * MB,
    ageDays: 40,
  },
  {
    ruleId: BLOCKED_RULE,
    tier: "yellow",
    desc: "Gradle cache của version không project nào dùng",
    path: BLOCKED_GRADLE,
    bytes: 6 * MB,
    ageDays: 45,
    verified: false,
    blocked: true,
    note: `KHÔNG XÓA: project ${HOME}/work/app uses Gradle 8.14`,
  },
];

export const MIXED_REPORT = buildReport(SEEDS);

export const EMPTY_REPORT = buildReport([]);

export const RED_REPORT = buildReport([
  {
    ruleId: RED_RULE,
    tier: "red",
    desc: "Ghi chú cá nhân",
    path: RED_HOME,
    bytes: 3 * MB,
    ageDays: 90,
  },
]);

export const RULES = [
  { id: GREEN_RULE, tier: "green", desc: "npm cache tarball" },
  { id: YELLOW_RULE, tier: "yellow", desc: "Build output của project" },
  { id: BLOCKED_RULE, tier: "green", desc: "Gradle cache của version không project nào dùng" },
];

export const SPACE = { free: 301 * 1024 * MB, total: 460 * 1024 * MB };