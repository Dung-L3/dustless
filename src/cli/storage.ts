import { homedir } from "node:os";
import { resolve, sep } from "node:path";
import { homeAppDirs, listApps, uninstall } from "../core/apps/index.ts";
import type { UninstallReport } from "../core/apps/types.ts";
import { DEFAULT_MIN_SIZE, deleteLargeFile, findLargeFiles } from "../core/largefiles/index.ts";
import { writeOut } from "../core/output.ts";
import { bold, bytesOf, dim, errorOut, flag, opt, paint, required, say } from "./context.ts";

function appDirs(): string[] | undefined {
  if (process.env["DUSTLESS_UI_TESTING"] !== "1") return undefined;
  return homeAppDirs(homedir());
}

async function printUninstall(report: UninstallReport): Promise<number> {
  if (flag("json")) {
    await writeOut(`${JSON.stringify(report)}\n`);
    return report.summary.failed > 0 ? 1 : 0;
  }
  for (const o of report.outcomes) {
    const mark =
      o.status === "trashed"
        ? paint("32", "🗑")
        : o.status === "purged"
          ? paint("31", "🔥")
          : o.status === "skipped"
            ? paint("33", "⊘")
            : paint("31", "✖");
    say(`${mark} ${bytesOf(o.bytes).padStart(9)}  ${o.path}`);
    if (o.detail) say(`  ${dim(o.detail)}`);
  }
  say(
    `\n${paint("32", `🗑 ${report.summary.trashed}`)}  ${paint("31", `🔥 ${report.summary.purged}`)}  ${paint("33", `⊘ ${report.summary.skipped}`)}  ${paint("31", `✖ ${report.summary.failed}`)} · ${bold(`tổng ${bytesOf(report.summary.totalBytes)}`)}`,
  );
  return report.summary.failed > 0 ? 1 : 0;
}

export async function runApps(_rest: string[]): Promise<number> {
  const home = homedir();
  const confirm = flag("confirm");
  const purge = flag("purge");
  const trashDir = opt("trash-dir");

  if (flag("uninstall")) {
    const uninstallPath = required("uninstall", "dustless apps --uninstall <đường dẫn .app> --confirm");
    const apps = await listApps({ home, appDirs: appDirs() });
    const target = apps.find((a) => a.path === uninstallPath || resolve(a.path) === resolve(uninstallPath));
    if (!target) {
      if (flag("json")) {
        await writeOut(`${JSON.stringify({ error: "app not found in inventory", path: uninstallPath })}\n`);
      } else {
        errorOut(`✖ ứng dụng không có trong danh sách: ${uninstallPath}`);
      }
      return 1;
    }
    return await printUninstall(
      await uninstall({
        home,
        appPath: target.path,
        relatedPaths: target.relatedPaths,
        confirm,
        appDirs: appDirs(),
        purge,
        trashDir,
      }),
    );
  }

  const apps = await listApps({ home, appDirs: appDirs() });
  if (flag("json")) {
    await writeOut(`${JSON.stringify(apps)}\n`);
    return 0;
  }
  if (!apps.length) {
    say(dim("Không tìm thấy ứng dụng .app nào."));
    return 0;
  }
  say(bold(`\n${apps.length} ứng dụng`));
  for (const app of apps) {
    say(`${paint("36", app.name.padEnd(30))} ${bytesOf(app.bytes).padStart(9)}  ${dim(app.bundleId)}  ${app.path}`);
    if (app.relatedPaths.length) {
      say(`  ${dim("← dư:")} ${app.relatedPaths.map((p) => dim(p.replace(home, "~"))).join(", ")}`);
    }
  }
  return 0;
}

function sizeOpt(raw: string | undefined): number | undefined {
  if (raw === undefined) return undefined;
  const match = /^(\d+(?:\.\d+)?)\s*([bkmgt])?(?:i?b)?$/i.exec(raw.trim());
  const units: Record<string, number> = { "": 1, b: 1, k: 1024, m: 1024 ** 2, g: 1024 ** 3, t: 1024 ** 4 };
  if (!match) return Number.NaN;
  return Math.round(Number(match[1]) * (units[match[2]?.toLowerCase() ?? ""] ?? 1));
}

export async function runLargeFiles(): Promise<number> {
  const rawMinSize = flag("min-size") ? required("min-size", "dùng 200mb, 1gb hoặc số byte") : undefined;
  const minSize = sizeOpt(rawMinSize);
  if (minSize !== undefined && !Number.isFinite(minSize)) {
    if (flag("json")) {
      await writeOut(`${JSON.stringify({ error: "invalid --min-size", value: rawMinSize })}\n`);
    } else {
      errorOut(`✖ --min-size không hợp lệ: "${rawMinSize}" (dùng 200mb, 1gb hoặc số byte)`);
    }
    return 1;
  }
  const limitValue = flag("limit") ? required("limit", "số lớn nhất cần in") : undefined;
  const limit = Number(limitValue);

  if (flag("delete")) {
    const deletePath = required("delete", "dustless largefiles --delete <đường dẫn> --confirm");
    return await printUninstall(await deleteLargeFile({ path: deletePath, confirm: flag("confirm"), trashDir: opt("trash-dir") }));
  }

  if (!flag("json")) say(dim("Đang duyệt thư mục home…"));
  const started = Date.now();
  const files = await findLargeFiles({
    minSize,
    limit: Number.isInteger(limit) && limit > 0 ? limit : undefined,
  });
  if (flag("json")) {
    await writeOut(`${JSON.stringify(files)}\n`);
    return 0;
  }
  if (!files.length) {
    say(dim(`Không có tệp nào lớn hơn ${bytesOf(minSize ?? DEFAULT_MIN_SIZE)} trong thư mục home.`));
    return 0;
  }
  say(bold(`\n${files.length} tệp lớn nhất · quét trong ${Date.now() - started}ms`));
  for (const file of files) {
    say(
      `${paint("36", file.path.split(sep).pop()?.padEnd(30) ?? "")} ${bytesOf(file.size).padStart(9)}  ${dim(new Date(file.mtime).toISOString().slice(0, 10))}  ${file.path}`,
    );
  }
  return 0;
}
