import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { lstat, mkdir, mkdtemp, readdir, rm, symlink, truncate, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { assertTempRoot, cleanupAll, exec, sandbox, type Sandbox } from "./e2e/harness.ts";

const MiB = 1024 * 1024;
const FILM = 300 * MiB;
const BACKUP = 260 * MiB;
const NOTES = 150 * MiB;
const PINNED = new Date("2023-04-05T06:07:08Z");

type LargeFile = { path: string; size: number; mtime: number };
type Outcome = { path: string; status: string; bytes: number; detail: string };
type Report = { outcomes: Outcome[]; summary: { trashed: number; failed: number; totalBytes: number } };

const exists = async (path: string): Promise<boolean> => await lstat(path).then(() => true, () => false);

function dirname(path: string): string {
  return path.split(/[/\\]/).slice(0, -1).join("/");
}

async function plant(path: string, bytes: number, mtime?: Date): Promise<string> {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, "");
  await truncate(path, bytes);
  if (mtime) await utimes(path, mtime, mtime);
  return path;
}

async function stage(box: Sandbox, link: boolean): Promise<void> {
  const { home } = box;
  await plant(join(home, "Downloads", "film.mov"), FILM, PINNED);
  await plant(join(home, "Downloads", "backup.tar"), BACKUP);
  await plant(join(home, "Documents", "notes.bin"), NOTES);
  await plant(join(home, "Documents", "tiny.txt"), 1024);
  await plant(join(home, ".Trash", "already-deleted.bin"), 400 * MiB);
  await plant(join(home, "project", ".git", "objects", "pack-0001"), 500 * MiB);
  if (link) await symlink(join(home, "Downloads", "film.mov"), join(home, "Downloads", "film-link.mov"));
}

async function list(box: Sandbox, ...args: string[]): Promise<LargeFile[]> {
  const run = await box.run(["largefiles", "--json", ...args]);
  expect({ code: run.code, stderr: run.stderr }).toEqual({ code: 0, stderr: "" });
  return JSON.parse(run.stdout) as LargeFile[];
}

const names = (files: LargeFile[]): string[] => files.map((f) => f.path.split("/").pop() ?? "");

afterAll(cleanupAll);

describe("largefiles listing", () => {
  let box: Sandbox;
  beforeAll(async () => {
    box = await sandbox("largefiles");
    await stage(box, process.platform !== "win32");
  });

  test("lists only files over the default 200 MiB, largest first", async () => {
    const files = await list(box);
    expect(names(files)).toEqual(["film.mov", "backup.tar"]);
    expect(files.map((f) => f.size)).toEqual([FILM, BACKUP]);
  });

  test("skips the Trash, .git internals and files below the threshold", async () => {
    const files = await list(box, "--min-size", "1b");
    const listed = new Set(files.map((f) => f.path));
    for (const skipped of [".Trash/already-deleted.bin", "project/.git/objects/pack-0001"]) {
      expect([...listed].some((p) => p.endsWith(skipped))).toBe(false);
    }
    expect(names(files)).toContain("notes.bin");
    expect(names(files)).toContain("tiny.txt");
  });

  test("--min-size takes units or a plain byte count", async () => {
    expect(names(await list(box, "--min-size", "1mb"))).toEqual(["film.mov", "backup.tar", "notes.bin"]);
    expect(names(await list(box, "--min-size", "300MiB"))).toEqual(["film.mov"]);
    expect(names(await list(box, "--min-size", String(FILM)))).toEqual(["film.mov"]);
  });

  test("--min-size rejects nonsense without walking the disk", async () => {
    const run = await box.run(["largefiles", "--json", "--min-size", "twenty"]);
    expect(run.code).toBe(1);
    expect(JSON.parse(run.stdout)).toEqual({ error: "invalid --min-size", value: "twenty" });
  });

  test("--limit keeps the biggest N", async () => {
    const files = await list(box, "--min-size", "1mb", "--limit", "2");
    expect(names(files)).toEqual(["film.mov", "backup.tar"]);
  });

  test("reports the modified date", async () => {
    const [film] = await list(box);
    expect(Math.abs((film?.mtime ?? 0) - PINNED.getTime())).toBeLessThan(1000);
  });

  test("human output names the file, its size and its path", async () => {
    const run = await box.run(["largefiles"]);
    expect(run.code).toBe(0);
    expect(run.stdout).toContain("film.mov");
    expect(run.stdout).toContain("300.0 MB");
    expect(run.stdout).toContain(join(box.home, "Downloads", "film.mov"));
  });

  test.skipIf(process.platform === "win32")("never follows a symlink", async () => {
    const files = await list(box, "--min-size", "1b");
    expect(names(files)).not.toContain("film-link.mov");
    expect(names(files).filter((n) => n === "film.mov")).toHaveLength(1);
  });
});

describe("largefiles --delete", () => {
  let box: Sandbox;
  let film: string;
  beforeAll(async () => {
    box = await sandbox("largefiles-delete");
    await stage(box, false);
    film = join(box.home, "Downloads", "film.mov");
  });

  test("refuses without --confirm", async () => {
    const run = await box.run(["largefiles", "--delete", film, "--json"]);
    const report = JSON.parse(run.stdout) as Report;
    expect(run.code).toBe(1);
    expect(report.outcomes[0]?.detail).toBe("confirm required");
    expect(await exists(film)).toBe(true);
  });

  test("moves the file to the sandbox Trash instead of unlinking it", async () => {
    const run = await box.run(["largefiles", "--delete", film, "--confirm", "--json"]);
    const report = JSON.parse(run.stdout) as Report;
    expect(run.code).toBe(0);
    expect(report.summary.trashed).toBe(1);
    expect(report.outcomes[0]?.status).toBe("trashed");
    expect(report.summary.totalBytes).toBe(FILM);
    expect(await exists(film)).toBe(false);

    const trashed = join(box.home, ".Trash", "film.mov");
    expect(await readdir(join(box.home, ".Trash"))).toContain("film.mov");
    expect((await lstat(trashed)).size).toBe(FILM);
  });

  test("refuses a path outside the scanned roots and leaves it alone", async () => {
    const outside = assertTempRoot(await mkdtemp(join(tmpdir(), "dustless-largefiles-outside-")));
    const victim = await plant(join(outside, "keepme.bin"), FILM);
    try {
      const run = await exec(
        ["largefiles", "--delete", victim, "--confirm", "--json"],
        { PATH: "/usr/bin:/bin:/usr/sbin:/sbin", HOME: box.home, NO_COLOR: "1" },
        "/",
      );
      const report = JSON.parse(run.stdout) as Report;
      expect(run.code).toBe(1);
      expect(report.outcomes[0]?.detail).toBe("outside the scanned roots");
      expect(await exists(victim)).toBe(true);
    } finally {
      await rm(outside, { recursive: true, force: true });
    }
  });

  test.skipIf(process.platform === "win32")("refuses a symlink and keeps its target", async () => {
    const target = join(box.home, "Downloads", "backup.tar");
    const link = join(box.home, "Downloads", "backup-link.tar");
    await symlink(target, link);
    const run = await box.run(["largefiles", "--delete", link, "--confirm", "--json"]);
    const report = JSON.parse(run.stdout) as Report;
    expect(run.code).toBe(1);
    expect(report.outcomes[0]?.detail).toBe("refusing symlink");
    expect(await exists(target)).toBe(true);
  });

  test("refuses a directory, never deleting a tree", async () => {
    const dir = join(box.home, "Downloads");
    const run = await box.run(["largefiles", "--delete", dir, "--confirm", "--json"]);
    const report = JSON.parse(run.stdout) as Report;
    expect(run.code).toBe(1);
    expect(report.outcomes[0]?.detail).toBe("not a regular file");
    expect(await exists(dir)).toBe(true);
    expect(await exists(join(dir, "backup.tar"))).toBe(true);
  });

  test("refuses a red-listed path and leaves it in place", async () => {
    const doc = join(box.home, "Documents", "notes.bin");
    const run = await box.run(["largefiles", "--delete", doc, "--confirm", "--json"]);
    const report = JSON.parse(run.stdout) as Report;
    expect(run.code).toBe(1);
    expect(report.outcomes[0]?.status).toBe("failed");
    expect(report.outcomes[0]?.detail).toMatch(/red list/);
    expect(await exists(doc)).toBe(true);
    expect((await lstat(doc)).size).toBe(NOTES);
  });

  test("refuses a .git path even though the walker never enters one", async () => {
    const pack = join(box.home, "project", ".git", "objects", "pack-0001");
    const run = await box.run(["largefiles", "--delete", pack, "--confirm", "--json"]);
    const report = JSON.parse(run.stdout) as Report;
    expect(run.code).toBe(1);
    expect(report.outcomes[0]?.detail).toMatch(/red list/);
    expect(await exists(pack)).toBe(true);
  });

  test("a path that is not there is skipped, not failed", async () => {
    const ghost = join(box.home, "Downloads", "never-existed.mov");
    const run = await box.run(["largefiles", "--delete", ghost, "--confirm", "--json"]);
    const report = JSON.parse(run.stdout) as Report;
    expect(report.outcomes[0]?.status).toBe("skipped");
    expect(report.outcomes[0]?.detail).toBe("does not exist");
    expect(report.summary).toMatchObject({ skipped: 1, failed: 0 });
  });

  test("a flag with no value is a usage error, not a path named after the next flag", async () => {
    const before = await readdir(box.home);
    for (const args of [["largefiles", "--delete", "--json"], ["largefiles", "--delete", "--confirm", "--json"]]) {
      const run = await box.run(args);
      expect(run.code).toBe(1);
      expect((JSON.parse(run.stdout) as { error: string }).error).toMatch(/--delete/);
    }
    expect(await readdir(box.home)).toEqual(before);
  });
});