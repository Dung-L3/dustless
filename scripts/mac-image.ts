import { readFile, rm, mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fail, run } from "./lib.ts";

export type ImageFacts = {
  width: number;
  height: number;
  distinct: number;
  transparent: number;
  opaque: number;
  grayscale: boolean;
  hasAlpha: boolean;
};

export async function readImageFacts(path: string): Promise<ImageFacts> {
  const described = await run("sips", ["-g", "all", path]);
  if (described.code !== 0) fail(`could not read the image ${path}: ${described.stderr.trim()}`);
  const text = `${described.stdout}\n${described.stderr}`;
  const width = Number(/pixelWidth:\s*(\d+)/.exec(text)?.[1] ?? "0");
  const height = Number(/pixelHeight:\s*(\d+)/.exec(text)?.[1] ?? "0");
  const hasAlpha = /hasAlpha:\s*yes/.test(text);
  const dir = await mkdtemp(join(tmpdir(), "dustless-image-"));
  try {
    const bmp = join(dir, "image.bmp");
    const converted = await run("sips", ["-s", "format", "bmp", path, "--out", bmp]);
    if (converted.code !== 0) fail(`could not decode the image ${path}: ${converted.stderr.trim()}`);
    const data = await readFile(bmp);
    if (data.length < 54 || data.readUInt16LE(0) !== 0x4d42) fail(`${path} did not decode into a bitmap`);
    const offset = data.readUInt32LE(10);
    const bitmapWidth = Math.abs(data.readInt32LE(18));
    const bitmapHeight = Math.abs(data.readInt32LE(22));
    const bits = data.readUInt16LE(28);
    const bytes = bits / 8;
    if (bytes !== 3 && bytes !== 4) fail(`${path} decoded into an unsupported ${bits} bit bitmap`);
    const pixels = bitmapWidth * bitmapHeight;
    const distinct = new Set<string>();
    let transparent = 0;
    let opaque = 0;
    let grayscale = true;
    for (let index = 0; index < pixels; index++) {
      const at = offset + index * bytes;
      if (at + bytes > data.length) break;
      const blue = data[at] ?? 0;
      const green = data[at + 1] ?? 0;
      const red = data[at + 2] ?? 0;
      const alpha = bytes === 4 ? (data[at + 3] ?? 255) : 255;
      distinct.add(`${red},${green},${blue},${alpha}`);
      if (alpha < 255) transparent += 1;
      if (alpha === 255) opaque += 1;
      if (red !== green || green !== blue) grayscale = false;
    }
    return {
      width: width || bitmapWidth,
      height: height || bitmapHeight,
      distinct: distinct.size,
      transparent,
      opaque,
      grayscale,
      hasAlpha,
    };
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}
