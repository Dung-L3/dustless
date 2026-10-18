export type Platform = "mac" | "win" | "linux";
export type Tier = "green" | "yellow" | "red" | "blocked";

export type VerifyName =
  | "gradle_version_unused"
  | "git_clean"
  | "not_in_gitignore";

export type Rule = {
  id: string;
  tier: Tier;
  desc: string;
  paths: Partial<Record<Platform | "all", string | string[]>>;
  match?: string;
  requireVerify?: VerifyName;
  minAgeDays?: number;
  nativeCommand?: string;
  recoveryLabel?: "download" | "rebuild";
  busyProcesses?: string[];
  staleDays?: number;
  gitClean?: boolean;
};

export type Finding = {
  ruleId: string;
  tier: Tier;
  desc: string;
  path: string;
  bytes: number;
  mtime: number;
  atime: number;
  ageDays: number;
  verified: boolean;
  blocked: boolean;
  note: string;
};

export type TierStat = { count: number; bytes: number };

export type ScanReport = {
  findings: Finding[];
  totals: Record<Tier, TierStat>;
  reclaimable: number;
  freeBefore: number;
  platform: Platform;
  scannedMs: number;
};

export type ApplyStatus = "deleted" | "skipped" | "failed";

export type ApplyOutcome = {
  ruleId: string;
  tier: Tier;
  path: string;
  status: ApplyStatus;
  bytes: number;
  detail: string;
};

export type ApplyReport = {
  outcomes: ApplyOutcome[];
  freed: number;
  freeBefore: number;
  freeAfter: number;
  elapsedMs: number;
};

export type TierChoice = Record<string, "green" | "yellow" | "skip">;
