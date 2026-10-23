import { afterAll, describe, expect, test } from "bun:test";
import { chmod, link, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { scan } from "../src/core/scan.ts";
import { treeUsage } from "../src/core/space.ts";

const sandbox = await mkdtemp(join(tmpdir(), "dustless-hardlinks-"));
const originalXdg = process.env["XDG_CONFIG_HOME"];
process.env["XDG_CONFIG_HOME"] = join(sandbox, "config");

const writeRules = async (body: string): Promise<void> => {
  await mkdir(join(sandbox, "config", "dustless"), { recursive: true });
  await writeFile(join(sandbox, "config", "dustless", "rules.yaml"), body);
};

afterAll(async () => {
  if (originalXdg === undefined) delete process.env["XDG_CONFIG_HOME"];
  else process.env["XDG_CONFIG_HOME"] = originalXdg;
  await chmod(sandbox, 0o700).catch(() => undefined);
  await rm(sandbox, { recursive: true, force: true });
});

describe("size accounting counts a hardlinked inode once per tree", () => {
  test("treeUsage never double-counts aliases inside one tree", async () => {
    const dir = join(sandbox, "store");
    await mkdir(dir, { recursive: true });
    await writeFile(join(dir, "one.bin"), Buffer.alloc(4096, "a"));
    await writeFile(join(dir, "unique.bin"), Buffer.alloc(8192, "b"));
    await link(join(dir, "one.bin"), join(dir, "two.bin"));

    const usage = await treeUsage(dir);

    expect(usage?.bytes).toBe(12288);
  });

  test.skipIf(process.platform === "win32")("scan counts the hardlinked content once per finding", async () => {
    const dir = join(sandbox, "scanned");
    await mkdir(dir, { recursive: true });
    await writeFile(join(dir, "one.bin"), Buffer.alloc(4096, "a"));
    await writeFile(join(dir, "unique.bin"), Buffer.alloc(8192, "b"));
    await link(join(dir, "one.bin"), join(dir, "two.bin"));
    await writeRules(`- id: test.store\n  tier: green\n  desc: store\n  paths: { all: ${JSON.stringify(dir)} }\n`);

    const report = await scan({ roots: [sandbox] });

    expect(report.findings.some((f) => f.ruleId === "test.store" && f.bytes === 12288)).toBe(true);
  });
});
