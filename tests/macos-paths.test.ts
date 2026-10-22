import { describe, expect, test } from "bun:test";
import { mkdir, rm } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { HOME, isHomeOrAncestor, isRed, patternVerdict, realGuard } from "../src/core/paths.ts";
import { userRulesPath } from "../src/core/rules.ts";

describe("the red list covers the macOS places that hold real user data", () => {
  test("the Trash is red, because it is the user's own undo", () => {
    expect(isRed(join(HOME, ".Trash"))).toBe(true);
    expect(isRed(join(HOME, ".Trash", "old-file"))).toBe(true);
    expect(isRed(join(HOME, ".Trash") + "/")).toBe(true);
  });

  test("iCloud Drive is red, in both spellings macOS uses", () => {
    expect(isRed(join(HOME, "Library", "Mobile Documents"))).toBe(true);
    expect(isRed(join(HOME, "Library", "Mobile Documents", "com~apple~CloudDocs", "Drive", "Projects"))).toBe(true);
    expect(isRed(join(HOME, "Library", "Mobile Documents", "com~apple~CloudDocs", "Drive", "Projects", "a.txt"))).toBe(true);
  });

  test("Apple's own application data is red, and the spelling does not matter", () => {
    expect(isRed(join(HOME, "Library", "Application Support", "com.apple.Photos"))).toBe(true);
    expect(isRed(join(HOME, "Library", "Application Support", "com.apple.notes"))).toBe(true);
    expect(isRed(join(HOME, "Library", "Application Support", "com.apple.somethingelse"))).toBe(true);
    expect(isRed(join(HOME, "Library", "Application Support", "com.apple.photos"))).toBe(true);
    expect(isRed(join(HOME, "library", "application support", "com.apple.photos"))).toBe(true);
    expect(isRed(join(HOME, "Library", "Containers", "com.apple.Safari"))).toBe(true);
    expect(isRed(join(HOME, "Library", "Containers", "com.apple.safari"))).toBe(true);
  });

  test("a Time Machine snapshot is red", () => {
    expect(isRed("/Volumes/com.apple.TimeMachine.localsnapshots/Backups.backupdb")).toBe(true);
  });

  test("a third-party bundle identifier and an ordinary cache are not red", () => {
    expect(isRed(join(HOME, "Library", "Application Support", "com.example.myapp"))).toBe(false);
    expect(isRed(join(HOME, "Library", "Containers", "com.example.myapp"))).toBe(false);
    expect(isRed(join(HOME, "Library", "Caches", "com.brave.Browser"))).toBe(false);
    expect(isRed(join(HOME, ".gradle", "caches", "8.12"))).toBe(false);
  });
});

describe("HOME is protected whatever case it is spelled in", () => {
  test("HOME and its ancestors are recognised in any case", () => {
    expect(isHomeOrAncestor(HOME)).toBe(true);
    expect(isHomeOrAncestor(HOME.toLowerCase())).toBe(true);
    expect(isHomeOrAncestor(dirname(HOME))).toBe(true);
    expect(isHomeOrAncestor(dirname(HOME).toLowerCase())).toBe(true);
    expect(isHomeOrAncestor(join(HOME, "Downloads"))).toBe(false);
    expect(isHomeOrAncestor(join(HOME, "Downloads").toLowerCase())).toBe(false);
  });

  test("the real path guard refuses HOME spelled in another case", () => {
    expect(realGuard(HOME)).toEqual({ refused: "protected" });
    expect(realGuard(HOME.toLowerCase())).toEqual({ refused: "protected" });
    expect(realGuard(dirname(HOME).toLowerCase())).toEqual({ refused: "protected" });
    expect(realGuard("/")).toEqual({ refused: "protected" });
  });
});

describe("a rule cannot name the root of a mounted volume", () => {
  test("the volume root and a volume itself are refused", () => {
    expect(patternVerdict("/Volumes")).toMatchObject({ ok: false, kind: "protected" });
    expect(patternVerdict("/Volumes/*")).toMatchObject({ ok: false, kind: "protected" });
    expect(patternVerdict("/Volumes/Work")).toMatchObject({ ok: false, kind: "protected" });
  });

  test("a directory inside a volume is still allowed", () => {
    expect(patternVerdict("/Volumes/Work/cache")).toMatchObject({ ok: true });
    expect(patternVerdict("/Volumes/Work/node_modules")).toMatchObject({ ok: true });
  });
});

describe("a firmlink is not a symlink and does not stop the delete", () => {
  test.skipIf(process.platform !== "darwin")("a path under /tmp is not refused as symlinked", async () => {
    const dir = join(tmpdir(), "dustless-firmlink-probe");
    await mkdir(dir, { recursive: true });
    const guard = realGuard(dir);
    expect("refused" in guard).toBe(false);
    await rm(dir, { recursive: true, force: true });
  });
});

describe("the rules file only moves when XDG_CONFIG_HOME is absolute", () => {
  test("a relative XDG_CONFIG_HOME is ignored", () => {
    const prior = process.env["XDG_CONFIG_HOME"];
    try {
      process.env["XDG_CONFIG_HOME"] = "relative/config";
      expect(userRulesPath()).toBe(join(homedir(), ".config", "dustless", "rules.yaml"));
      process.env["XDG_CONFIG_HOME"] = "";
      expect(userRulesPath()).toBe(join(homedir(), ".config", "dustless", "rules.yaml"));
      process.env["XDG_CONFIG_HOME"] = join("/tmp", "dustless-absolute-config");
      expect(userRulesPath()).toBe(join("/tmp", "dustless-absolute-config", "dustless", "rules.yaml"));
    } finally {
      if (prior === undefined) delete process.env["XDG_CONFIG_HOME"];
      else process.env["XDG_CONFIG_HOME"] = prior;
    }
  });
});
