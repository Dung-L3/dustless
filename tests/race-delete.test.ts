import { afterAll, describe, expect, test } from "bun:test";
import { lstat, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { moveToTrash } from "../src/core/apps/index.ts";
import { realGuard } from "../src/core/paths.ts";

const roots: string[] = [];

afterAll(async () => {
  for (const root of roots) await rm(root, { recursive: true, force: true });
});

async function box(): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "dustless-race-"));
  roots.push(root);
  return root;
}

async function cache(root: string, name = "cache"): Promise<string> {
  const src = join(root, name);
  await mkdir(src, { recursive: true });
  await writeFile(join(src, "data.txt"), "payload");
  return src;
}

describe("delete race", () => {
  test("control: a clean source is trashed", async () => {
    const root = await box();
    const src = await cache(root);
    const result = await moveToTrash(src, join(root, "Trash"));
    expect(result.status).toBe("trashed");
    expect(await readFile(join(root, "Trash", "cache", "data.txt"), "utf8")).toBe("payload");
  });

  test("swapping the source for a symlink into a red directory refuses the delete", async () => {
    const root = await box();
    const src = await cache(root);
    const red = join(root, "Documents");
    await mkdir(red, { recursive: true });
    await writeFile(join(red, "keep.txt"), "keep");
    const result = await moveToTrash(src, join(root, "Trash"), {
      beforeDelete: async () => {
        await rm(src, { recursive: true, force: true });
        await symlink(red, src);
      },
    });
    expect(result.status).toBe("failed");
    expect(result.detail?.code).toBe("red_list");
    expect(await readFile(join(red, "keep.txt"), "utf8")).toBe("keep");
  });

  test("swapping the target to a different real directory refuses the delete", async () => {
    const root = await box();
    const src = await cache(root);
    const other = await cache(root, "elsewhere");
    const result = await moveToTrash(src, join(root, "Trash"), {
      beforeDelete: async () => {
        await rm(src, { recursive: true, force: true });
        await symlink(other, src);
      },
    });
    expect(result.status).toBe("failed");
    expect(result.detail?.code).toBe("changed");
    expect(await readFile(join(other, "data.txt"), "utf8")).toBe("payload");
  });

  test("a red source is refused before the hook runs", async () => {
    const root = await box();
    const src = await cache(join(root, "Documents"), "notes");
    let ran = false;
    const result = await moveToTrash(src, join(root, "Trash"), {
      beforeDelete: () => {
        ran = true;
      },
    });
    expect(result.status).toBe("failed");
    expect(result.detail?.code).toBe("red_list");
    expect(ran).toBe(false);
    expect(await readFile(join(src, "data.txt"), "utf8")).toBe("payload");
  });

  test("a source reached through a symlinked parent is refused and its target survives", async () => {
    const root = await box();
    const victim = await cache(root, "victim");
    const link = join(root, "link");
    await symlink(victim, link);
    const result = await moveToTrash(join(link, "data.txt"), join(root, "Trash"));
    expect(result.status).toBe("failed");
    expect(result.detail?.code).toBe("symlink");
    expect(await readFile(join(victim, "data.txt"), "utf8")).toBe("payload");
  });

  test("a trailing separator on a leaf symlink still unlinks only the link", async () => {
    const root = await box();
    const target = await cache(root, "target");
    const link = join(root, "link");
    await symlink(target, link);
    const linkSize = (await lstat(link)).size;
    const result = await moveToTrash(`${link}/`, join(root, "Trash"));
    expect(result.status).toBe("trashed");
    expect(result.bytes).toBe(linkSize);
    expect(await readFile(join(target, "data.txt"), "utf8")).toBe("payload");
    expect(await lstat(link).then(() => false, () => true)).toBe(true);
    expect(await lstat(join(root, "Trash", "link")).then(() => true, () => false)).toBe(true);
  });

  test("realGuard accepts a clean path and refuses a red-resolving one", async () => {
    const root = await box();
    const src = await cache(root);
    const clean = realGuard(src);
    expect("real" in clean).toBe(true);
    const red = join(root, "Documents");
    await mkdir(red, { recursive: true });
    await writeFile(join(red, "keep.txt"), "keep");
    const link = join(root, "link");
    await symlink(red, link);
    expect(realGuard(link)).toEqual({ refused: "red" });
    expect(realGuard(join(root, "missing"))).toEqual({ real: join(root, "missing") });
  });
});
