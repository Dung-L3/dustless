import { readdir, stat } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";

const INSTALL_MARKERS = [".package-lock.json", ".modules.yaml"];

export async function npmOrPnpmLinked(dir: string): Promise<boolean> {
  try {
    const entries = await readdir(dir, { withFileTypes: true });
    return entries.some((entry) => entry.isSymbolicLink());
  } catch {
    return false;
  }
}

export async function isLiveDependencyTree(dir: string): Promise<boolean> {
  const manifestPath = join(dirname(resolve(dir)), "package.json");
  const installed = await newestInstallMarker(dir);
  try {
    const manifest = (await stat(manifestPath)).mtimeMs;
    return installed === null || installed >= manifest;
  } catch {
    return false;
  }
}

async function newestInstallMarker(dir: string): Promise<number | null> {
  let newest: number | null = null;
  for (const marker of INSTALL_MARKERS) {
    try {
      const mtime = (await stat(join(dir, marker))).mtimeMs;
      if (newest === null || mtime > newest) newest = mtime;
    } catch {
      continue;
    }
  }
  return newest;
}
