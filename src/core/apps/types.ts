import type { Reason } from "../../types.ts";

export type RelatedKind =
  | "app-support"
  | "caches"
  | "preferences"
  | "logs"
  | "saved-state"
  | "container"
  | "group-container"
  | "webkit"
  | "http-storage"
  | "app-scripts"
  | "launch-agent"
  | "cookies";

export type RelatedCategory =
  | "cache"
  | "config"
  | "user-data"
  | "diagnostic"
  | "integration"
  | "other";

export type RelatedItem = {
  path: string;
  kind: RelatedKind;
  category: RelatedCategory;
  bytes: number | null;
};

export type AppInfo = {
  bundleId: string;
  name: string;
  path: string;
  bytes: number;
  relatedPaths: string[];
  related: RelatedItem[];
  protected: boolean;
};

export type ListAppsOptions = {
  home: string;
  appDirs?: string[];
};

export type UninstallOptions = {
  home: string;
  appPath: string;
  relatedPaths: string[];
  confirm: boolean;
  appDirs?: string[];
  purge?: boolean;
  trashDir?: string;
  beforeDelete?: () => void | Promise<void>;
};

export type UninstallOutcome = {
  path: string;
  status: "trashed" | "purged" | "skipped" | "failed";
  bytes: number;
  detail: Reason | null;
};

export type UninstallReport = {
  outcomes: UninstallOutcome[];
  summary: {
    trashed: number;
    purged: number;
    skipped: number;
    failed: number;
    totalBytes: number;
  };
};