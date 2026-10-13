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
  purge?: boolean;
  trashDir?: string;
};

export type UninstallOutcome = {
  path: string;
  status: "trashed" | "purged" | "skipped" | "failed";
  bytes: number;
  detail: string;
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