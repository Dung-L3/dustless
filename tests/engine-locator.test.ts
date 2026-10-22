import { describe, expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

const ROOT = join(import.meta.dir, "..");
const LOCATOR = join(ROOT, "apps", "dustless-mac", "Sources", "DustlessKit", "Engine", "BinaryLocator.swift");
const BUNDLE = join(ROOT, "scripts", "bundle-macos.ts");
const locator = await readFile(LOCATOR, "utf8");
const bundle = await readFile(BUNDLE, "utf8");

describe("the engine locator cannot resolve to the app's own executable", () => {
  test("the search never includes the folder that holds the app's own binary", () => {
    expect(locator).not.toContain("Contents/MacOS");
    expect(locator).not.toContain("deletingLastPathComponent");
  });

  test("the roots are the resources, their bin folder and the bundle itself", () => {
    expect(locator).toContain('resources.appendingPathComponent("bin", isDirectory: true)');
    expect(locator).toContain("roots.append(bundleURL)");
    expect(locator).toContain("Bundle.main.executableURL");
  });

  test("the comparison is by real file identity, not by the spelling of the path", () => {
    expect(locator).toContain("systemFileNumber");
    expect(locator).toContain("systemNumber");
    expect(locator).toContain("resolvingSymlinksInPath");
    expect(locator).toContain("isOwnExecutable(candidate, own: context.ownExecutable)");
  });

  test("a missing engine names every path that was searched", () => {
    expect(locator).toContain("throw BinaryLocationError.notFound(candidates)");
    expect(locator).toContain("The dustless engine was not found. Searched:");
  });
});

describe("the bundle check proves the copied engine answers", () => {
  test("the copied engine is run after the copy and its version is compared", () => {
    expect(bundle).toContain('runEngine(bundledEngine, ["version"]');
    expect(bundle).toContain("the bundled engine did not answer");
    expect(bundle).toContain("but the app is");
  });
});
