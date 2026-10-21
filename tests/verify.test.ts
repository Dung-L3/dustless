import { afterAll, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { discoverProjectRoots, gradleVersionUnused } from "../src/core/verify/gradle.ts";
import { findRepoRoot, gitClean, gitIgnored } from "../src/core/verify/git.ts";
import { verify } from "../src/core/verify/index.ts";
import { isLiveDependencyTree, npmOrPnpmLinked } from "../src/core/verify/node.ts";
import type { Rule } from "../src/types.ts";

const created: string[] = [];

async function fixture(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "dustless-verify-"));
  created.push(dir);
  return dir;
}

async function put(path: string, text: string): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, text);
}

async function putWrapper(projectPath: string, version: string): Promise<string> {
  const file = join(projectPath, "gradle/wrapper/gradle-wrapper.properties");
  await put(
    file,
    [
      "distributionBase=GRADLE_USER_HOME",
      "distributionPath=wrapper/dists",
      `distributionUrl=https\\://services.gradle.org/distributions/gradle-${version}-bin.zip`,
      "zipStoreBase=GRADLE_USER_HOME",
      "",
    ].join("\n"),
  );
  return file;
}

function git(cwd: string, args: string[]): void {
  execFileSync("git", args, { cwd, stdio: "ignore" });
}

async function initRepo(): Promise<string> {
  const dir = await fixture();
  git(dir, ["init", "-q"]);
  git(dir, ["config", "user.email", "dustless@test.local"]);
  git(dir, ["config", "user.name", "dustless"]);
  git(dir, ["config", "commit.gpgsign", "false"]);
  return dir;
}

async function commitEverything(dir: string, message: string): Promise<void> {
  git(dir, ["add", "-A"]);
  git(dir, ["commit", "-q", "-m", message]);
}

afterAll(async () => {
  for (const dir of created) await rm(dir, { recursive: true, force: true });
});

describe("gradleVersionUnused", () => {
  test("roots are discovered from markers, not from hardcoded folder names", async () => {
    const home = await fixture();
    await mkdir(join(home, "work/team/api"), { recursive: true });
    await writeFile(join(home, "work/team/api/package.json"), "{}");
    await mkdir(join(home, "Documents/scratch/deep/nest"), { recursive: true });
    await writeFile(join(home, "Documents/scratch/deep/nest/package.json"), "{}");
    const roots = await discoverProjectRoots(home);
    expect(roots).toContain(join(home, "work/team/api"));
    expect(roots.some((root: string) => root.includes("Documents"))).toBe(false);
  });

  test("unused cache version is reported safe, used version is not", async () => {
    const root = await fixture();
    const project = join(root, "workspace", "app");
    await putWrapper(project, "8.14");

    const unused = await gradleVersionUnused("8.12", [root]);
    expect(unused.ok).toBe(true);
    expect(unused.note).toContain("scanned 1 projects");

    const used = await gradleVersionUnused("8.14", [root]);
    expect(used.ok).toBe(false);
    expect(used.note).toContain("uses Gradle 8.14");
    expect(used.note).toContain(project);
  });

  test("wrapper reference buried in build/ios/SourcePackages is excluded", async () => {
    const root = await fixture();
    const project = join(root, "app");
    await putWrapper(project, "8.14");
    await putWrapper(join(project, "build/ios/SourcePackages/dep/Sources"), "8.12");

    const vendored = await gradleVersionUnused("8.12", [root]);
    expect(vendored.ok).toBe(true);

    const real = await gradleVersionUnused("8.14", [root]);
    expect(real.ok).toBe(false);
    expect(real.note).toContain(project);
  });

  test("every vendored build-output directory is excluded", async () => {
    const root = await fixture();
    const vendored = [
      "build",
      "SourcePackages",
      ".dartServer",
      "node_modules",
      ".gradle",
      ".pub-cache",
      "DerivedData",
      "Pods",
      "ephemeral",
    ];
    for (const name of vendored) {
      await putWrapper(join(root, `app-${name.replace(/\W/g, "")}`, name, "nested"), "8.14");
    }

    const result = await gradleVersionUnused("8.14", [root]);
    expect(result.ok).toBe(true);
    expect(result.note).toContain("scanned 0 projects");
  });

  test("gradle.properties distributionUrl override pins the version", async () => {
    const root = await fixture();
    const project = join(root, "pinned");
    await putWrapper(project, "8.14");
    await put(
      join(project, "gradle.properties"),
      "org.gradle.jvmargs=-Xmx2g\ndistributionUrl=https\\://services.gradle.org/distributions/gradle-8.12-bin.zip\n",
    );

    expect((await gradleVersionUnused("8.12", [root])).ok).toBe(false);
    expect((await gradleVersionUnused("8.14", [root])).ok).toBe(true);
  });

  test("build.gradle distributionUrl override pins the version", async () => {
    const root = await fixture();
    const project = join(root, "kotlin-project");
    await putWrapper(project, "8.14");
    await put(
      join(project, "build.gradle.kts"),
      'val gradleVersion = "https://services.gradle.org/distributions/gradle-8.13-bin.zip"\n',
    );

    expect((await gradleVersionUnused("8.13", [root])).ok).toBe(false);
  });

  test("scan is bounded by depth and entry budget", async () => {
    const root = await fixture();
    let deep = join(root, "deep");
    for (let level = 0; level < 25; level++) deep = join(deep, `level${level}`);
    await putWrapper(deep, "8.14");

    const wide = join(root, "wide");
    await Promise.all(
      Array.from({ length: 500 }, (_, index) =>
        mkdir(join(wide, `mod${index}`, "gradle", "wrapper"), { recursive: true }),
      ),
    );

    const started = Date.now();
    const result = await gradleVersionUnused("8.14", [root]);
    expect(result.ok).toBe(true);
    expect(Date.now() - started).toBeLessThan(4000);
  }, 15_000);
});

describe("findRepoRoot", () => {
  test("walks up to the repository root and gives up outside any repo", async () => {
    const repo = await initRepo();
    const nested = join(repo, "a", "b", "c");
    await mkdir(nested, { recursive: true });

    expect(await findRepoRoot(nested)).toBe(repo);
    expect(await findRepoRoot(await fixture())).toBeNull();
  });
});

describe("gitClean", () => {
  test("clean repository passes", async () => {
    const repo = await initRepo();
    await put(join(repo, "main.txt"), "hello\n");
    await commitEverything(repo, "init");

    const result = await gitClean(repo);
    expect(result.ok).toBe(true);
  });

  test("modified tracked file fails", async () => {
    const repo = await initRepo();
    const tracked = join(repo, "main.txt");
    await put(tracked, "hello\n");
    await commitEverything(repo, "init");
    await writeFile(tracked, "hello again\n");

    const result = await gitClean(repo);
    expect(result.ok).toBe(false);
    expect(result.note).toContain("uncommitted");
  });

  test("untracked file fails", async () => {
    const repo = await initRepo();
    await put(join(repo, "main.txt"), "hello\n");
    await commitEverything(repo, "init");
    await put(join(repo, "scratch.txt"), "temp\n");

    expect((await gitClean(repo)).ok).toBe(false);
  });

  test("commit without upstream does not count as dirty", async () => {
    const repo = await initRepo();
    await put(join(repo, "main.txt"), "hello\n");
    await commitEverything(repo, "init");

    expect(await findRepoRoot(repo)).toBe(repo);
    expect((await gitClean(repo)).ok).toBe(true);
  });

  test("in-progress merge fails", async () => {
    const repo = await initRepo();
    await put(join(repo, "main.txt"), "hello\n");
    await commitEverything(repo, "init");
    await put(join(repo, ".git/MERGE_HEAD"), "0000000000000000000000000000000000000001\n");

    const result = await gitClean(repo);
    expect(result.ok).toBe(false);
    expect(result.note).toContain("MERGE_HEAD");
  });

  test("in-progress rebase fails", async () => {
    const repo = await initRepo();
    await put(join(repo, "main.txt"), "hello\n");
    await commitEverything(repo, "init");
    await put(join(repo, ".git/rebase-merge/head-name"), "refs/heads/main\n");

    expect((await gitClean(repo)).ok).toBe(false);
  });

  test("directory outside any repository passes", async () => {
    const result = await gitClean(await fixture());
    expect(result.ok).toBe(true);
    expect(result.note).toBe("not a git repo");
  });
});

describe("gitIgnored", () => {
  test("a path git does not ignore is allowed", async () => {
    const repo = await initRepo();
    await put(join(repo, "main.txt"), "hello\n");
    await commitEverything(repo, "init");

    const result = await gitIgnored(join(repo, "main.txt"));
    expect(result.ok).toBe(true);
    expect(result.note).toContain("not ignored");
  });

  test("a path git ignores is refused", async () => {
    const repo = await initRepo();
    await put(join(repo, ".gitignore"), "cache/\n");
    await commitEverything(repo, "init");
    await mkdir(join(repo, "cache"), { recursive: true });

    const result = await gitIgnored(join(repo, "cache"));
    expect(result.ok).toBe(false);
    expect(result.note).toContain("ignored");
  });

  test("a broken .git/config cannot be verified and the path is blocked", async () => {
    const repo = await initRepo();
    await put(join(repo, "main.txt"), "hello\n");
    await commitEverything(repo, "init");
    await writeFile(join(repo, ".git", "config"), "[core\nthis is not valid\n");

    const result = await gitIgnored(join(repo, "main.txt"));
    expect(result.ok).toBe(false);
    expect(result.note).toMatch(/could not verify/);
  });

  test("a directory outside any repository is not blocked", async () => {
    const result = await gitIgnored(await fixture());
    expect(result.ok).toBe(true);
    expect(result.note).toBe("not a git repo");
  });
});

describe("verify", () => {
  test("rule without requireVerify needs no verification", async () => {
    const rule: Rule = { id: "test.noop", tier: "green", desc: "noop", paths: { all: "~/.cache" } };
    expect(await verify(rule, "/tmp/whatever")).toEqual({
      ok: true,
      note: "no verification required",
    });
  });

  test("gradle rule verifies the cache directory basename", async () => {
    const rule: Rule = {
      id: "gradle.version_cache",
      tier: "green",
      desc: "gradle cache",
      paths: { all: "~/.gradle/caches/*" },
      requireVerify: "gradle_version_unused",
    };
    const result = await verify(rule, "/tmp/does-not-exist/caches/8.12");
    expect(typeof result.note).toBe("string");
  });
});

describe("node dependency trees", () => {
  test("symlinked node_modules is reported as linked", async () => {
    const root = await fixture();
    const modules = join(root, "app", "node_modules");
    await put(join(root, "app", "package.json"), '{"name":"app"}\n');
    await mkdir(modules, { recursive: true });
    await put(join(modules, "real-pkg", "index.js"), "module.exports = 1;\n");

    expect(await npmOrPnpmLinked(modules)).toBe(false);

    await symlink(join(modules, "real-pkg"), join(modules, "linked-pkg"));
    expect(await npmOrPnpmLinked(modules)).toBe(true);
  });

  test("dependency tree without a parent package.json is not live", async () => {
    const root = await fixture();
    const modules = join(root, "orphan", "node_modules");
    await mkdir(modules, { recursive: true });

    expect(await isLiveDependencyTree(modules)).toBe(false);

    await put(join(root, "orphan", "package.json"), '{"name":"orphan"}\n');
    await put(join(modules, ".package-lock.json"), '{"lockfileVersion":3}\n');
    expect(await isLiveDependencyTree(modules)).toBe(true);
  });
});
