import type { Reason } from "../../types.ts";

export type AppInfo = {
  bundleId: string;
  name: string;
  path: string;
  bytes: number;
  relatedPaths: string[];
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