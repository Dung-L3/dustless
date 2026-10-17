import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BINARY, cleanupAll, REPO } from "./harness.ts";

afterAll(cleanupAll);

describe("large stdout survives a pipe", () => {
  test.skipIf(process.platform === "win32")(
    "ram --json is not truncated at the 64 KiB pipe buffer",
    async () => {
      const dir = mkdtempSync(join(tmpdir(), "dustless-pipe-"));
      const out = join(dir, "ram.json");
      try {
        const run = await Bun.$`${BINARY} ram --json | cat > ${out}`.cwd(REPO).quiet().nothrow();
        expect(run.exitCode).toBe(0);
        const text = readFileSync(out, "utf8");
        const parsed = JSON.parse(text) as { memory: unknown; processes: unknown };
        expect(parsed.memory).toBeDefined();
        expect(Array.isArray(parsed.processes)).toBe(true);
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    },
  );
});