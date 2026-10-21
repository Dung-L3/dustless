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

export type ReasonCode =
  | "min_age"
  | "stale_days"
  | "verify_failed"
  | "busy_process"
  | "listing_unavailable"
  | "not_determinable"
  | "revalidate_age"
  | "revalidate_verify"
  | "not_selected"
  | "needs_confirmation"
  | "declined"
  | "missing"
  | "red_list"
  | "home"
  | "root"
  | "protected"
  | "symlink"
  | "unresolvable"
  | "changed"
  | "io_error"
  | "outside_roots"
  | "not_executable"
  | "not_a_regular_file"
  | "engine_unavailable"
  | "confirm_required"
  | "not_an_app"
  | "system_app"
  | "not_allowed_dir"
  | "denied_path"
  | "no_bundle_id"
  | "bad_bundle_id"
  | "leftover_escapes_home"
  | "not_a_leftover"
  | "not_found"
  | "moved_to_trash"
  | "purged";

export type Reason = {
  code: ReasonCode;
  params?: Record<string, string>;
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
  note: Reason[];
};

export type TierStat = { count: number; bytes: number };

export type UnscannableReason = "absent" | "no_access" | "not_supported" | "error" | "red" | "protected";

export type UnscannableSummary = {
  absent: number;
  no_access: number;
  not_supported: number;
  error: number;
  red: number;
  protected?: number;
};

export type UnscannableRule = {
  ruleId: string;
  tier: Tier;
  desc: string;
  reason: UnscannableReason;
  pathPatterns: string[];
};

export type ScanReport = {
  schemaVersion: number;
  findings: Finding[];
  totals: Record<Tier, TierStat>;
  reclaimable: number;
  freeBefore: number;
  platform: Platform;
  scannedMs: number;
  unscannable: UnscannableRule[];
  unscannableSummary: UnscannableSummary;
};

export type ApplyStatus = "deleted" | "skipped" | "failed";

export type ApplyOutcome = {
  ruleId: string;
  tier: Tier;
  path: string;
  status: ApplyStatus;
  bytes: number;
  detail: Reason | null;
};

export type ApplyReport = {
  schemaVersion: number;
  outcomes: ApplyOutcome[];
  deletedBytes: number;
  freed: number;
  freeBefore: number;
  freeAfter: number;
  elapsedMs: number;
};

export type TierChoice = Record<string, "green" | "yellow" | "skip">;

export const SCHEMA_VERSION = 2;
export const SCHEMA_MAJOR = Math.floor(SCHEMA_VERSION / 10);
