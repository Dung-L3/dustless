import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BINARY, cleanupAll, REPO } from "./harness.ts";

afterAll(cleanupAll);

// Bun can hand a piped stdout to the kernel non-blocking, so a single large
// write is only partially accepted (the pipe buffer holds 64 KiB) and the tail
// is dropped on exit. `ram --json` lists every process — hundreds of KB — so
// `dustless ram --json | cat` received 64 KiB while `> file` looked fine.
//
// The pipe has to be drained by a blocking reader (`cat`) to reproduce; a Node
// stream reads it fast enough to hide the race. `cat` is POSIX, so this is
// skipped on Windows.
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
        // If the write was cut at the pipe buffer, JSON.parse throws here.
        const parsed = JSON.parse(text) as { memory: unknown; processes: unknown };
        expect(parsed.memory).toBeDefined();
        expect(Array.isArray(parsed.processes)).toBe(true);
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    },
  );
});
