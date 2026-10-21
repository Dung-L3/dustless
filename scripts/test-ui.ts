import { spawnSync } from "node:child_process";
import { rm } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

if (process.platform !== "darwin") {
  console.error("bun run test:ui requires macOS");
  process.exit(1);
}

const testDomain = "dev.dustless.e2e";
const testPrefs = join(homedir(), "Library", "Preferences", `${testDomain}.plist`);
const clearPrefs = async () => {
  spawnSync("defaults", ["delete", testDomain], { stdio: "ignore" });
  await rm(testPrefs, { force: true });
};

await clearPrefs();

const result = spawnSync("bun", ["test", "tests/ui", "--timeout", "600000"], {
  stdio: "inherit",
  env: { ...process.env, DUSTLESS_UI: "1" },
});

await clearPrefs();
process.exit(result.status ?? 1);
