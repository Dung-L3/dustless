import { mkdir, readFile, writeFile, rm } from "node:fs/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { join } from "node:path";

const run = promisify(execFile);
const BRAND = join(import.meta.dir, "..", "brand");
const OUT = join(import.meta.dir, "..", "dist", "icons");

const ICON_BASES = [16, 32, 128, 256, 512];
const ICO_SIZES = [16, 24, 32, 48, 64, 128, 256];

async function render(svg: string, size: number): Promise<string> {
  const tmp = join("/tmp", `dustless-icon-${size}`);
  await mkdir(tmp, { recursive: true });
  const svgPath = join(tmp, "icon.svg");
  await writeFile(svgPath, await readFile(svg));
  await run("qlmanage", ["-t", "-s", String(size), "-o", tmp, svgPath]);
  const raw = join(tmp, "icon.svg.png");
  const out = join(tmp, `icon-${size}.png`);
  await run("sips", ["-z", String(size), String(size), raw, "--out", out]);
  return out;
}

async function buildIcns(svg: string, target: string): Promise<void> {
  const set = join("/tmp", "dustless.iconset");
  await rm(set, { recursive: true, force: true });
  await mkdir(set, { recursive: true });
  for (const base of ICON_BASES) {
    const plain = await render(svg, base);
    await run("cp", [plain, join(set, `icon_${base}x${base}.png`)]);
    const retina = await render(svg, base * 2);
    await run("cp", [retina, join(set, `icon_${base}x${base}@2x.png`)]);
  }
  await run("iconutil", ["-c", "icns", set, "-o", target]);
}

type IcoEntry = { size: number; png: Buffer };

function packIco(entries: IcoEntry[]): Buffer {
  const header = Buffer.alloc(6 + entries.length * 16);
  header.writeUInt16LE(0, 0);
  header.writeUInt16LE(1, 2);
  header.writeUInt16LE(entries.length, 4);
  let offset = header.length;
  const bodies: Buffer[] = [];
  entries.forEach((entry, index) => {
    const at = 6 + index * 16;
    header.writeUInt8(entry.size >= 256 ? 0 : entry.size, at);
    header.writeUInt8(entry.size >= 256 ? 0 : entry.size, at + 1);
    header.writeUInt8(0, at + 2);
    header.writeUInt8(0, at + 3);
    header.writeUInt16LE(1, at + 4);
    header.writeUInt16LE(32, at + 6);
    header.writeUInt32LE(entry.png.length, at + 8);
    header.writeUInt32LE(offset, at + 12);
    offset += entry.png.length;
    bodies.push(entry.png);
  });
  return Buffer.concat([header, ...bodies]);
}

async function buildIco(svg: string, target: string): Promise<void> {
  const entries: IcoEntry[] = [];
  for (const size of ICO_SIZES) {
    const png = await render(svg, size);
    entries.push({ size, png: await readFile(png) });
  }
  await writeFile(target, packIco(entries));
}

async function buildPngSet(svg: string, dir: string): Promise<void> {
  await mkdir(dir, { recursive: true });
  for (const size of [256, 512, 1024]) {
    const png = await render(svg, size);
    await run("cp", [png, join(dir, `dustless-${size}.png`)]);
  }
}

await rm(OUT, { recursive: true, force: true });
await mkdir(OUT, { recursive: true });
const dark = join(BRAND, "icon.svg");
const light = join(BRAND, "icon-light.svg");
await buildIcns(dark, join(OUT, "dustless.icns"));
await buildIcns(light, join(OUT, "dustless-light.icns"));
await buildIco(dark, join(OUT, "dustless.ico"));
await buildPngSet(dark, join(OUT, "png"));
await buildPngSet(light, join(OUT, "png-light"));
console.log(`icons written to ${OUT}`);