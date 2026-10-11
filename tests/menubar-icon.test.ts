import { describe, expect, test } from "bun:test";
import { join } from "node:path";
import { inflateSync } from "node:zlib";

// The menu bar mark is an NSImage template (isTemplate = true): macOS uses only
// its alpha channel. An opaque background therefore paints a solid square in
// the menu bar, which is exactly what shipped before. Decode the PNG and assert
// the background is transparent, so it cannot regress unnoticed.
const ASSET = join(import.meta.dir, "..", "apps", "dustless-mac", "Assets", "MenuBarIcon.png");

type Png = { width: number; height: number; rgba: Uint8Array };

const readU32 = (b: Uint8Array, o: number): number =>
  (((b[o] ?? 0) << 24) | ((b[o + 1] ?? 0) << 16) | ((b[o + 2] ?? 0) << 8) | (b[o + 3] ?? 0)) >>> 0;

function decodePng(buf: Buffer): Png {
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  signature.forEach((byte, i) => {
    if (buf[i] !== byte) throw new Error("not a PNG");
  });

  let width = 0;
  let height = 0;
  let bitDepth = 0;
  let colorType = 0;
  let interlace = 0;
  const idat: Buffer[] = [];

  let off = 8;
  while (off + 8 <= buf.length) {
    const length = readU32(buf, off);
    const type = buf.toString("ascii", off + 4, off + 8);
    const data = buf.subarray(off + 8, off + 8 + length);
    if (type === "IHDR") {
      width = readU32(data, 0);
      height = readU32(data, 4);
      bitDepth = data[8] ?? 0;
      colorType = data[9] ?? 0;
      interlace = data[12] ?? 0;
    } else if (type === "IDAT") {
      idat.push(data);
    } else if (type === "IEND") {
      break;
    }
    off += 12 + length;
  }

  if (bitDepth !== 8 || interlace !== 0 || (colorType !== 2 && colorType !== 6)) {
    throw new Error(`unsupported PNG: depth=${bitDepth} colorType=${colorType} interlace=${interlace}`);
  }
  const channels = colorType === 6 ? 4 : 3;
  const raw = inflateSync(Buffer.concat(idat));
  const stride = width * channels;
  const rgba = new Uint8Array(width * height * 4);
  const prev = new Uint8Array(stride);

  let at = 0;
  for (let y = 0; y < height; y++) {
    const filter = raw[at++] ?? 0;
    const row = raw.subarray(at, at + stride);
    at += stride;
    const line = new Uint8Array(stride);
    for (let x = 0; x < stride; x++) {
      const left = x >= channels ? (line[x - channels] ?? 0) : 0;
      const up = prev[x] ?? 0;
      const upLeft = x >= channels ? (prev[x - channels] ?? 0) : 0;
      const value = row[x] ?? 0;
      let out: number;
      if (filter === 0) out = value;
      else if (filter === 1) out = value + left;
      else if (filter === 2) out = value + up;
      else if (filter === 3) out = value + ((left + up) >> 1);
      else {
        const p = left + up - upLeft;
        const pa = Math.abs(p - left);
        const pb = Math.abs(p - up);
        const pc = Math.abs(p - upLeft);
        out = value + (pa <= pb && pa <= pc ? left : pb <= pc ? up : upLeft);
      }
      line[x] = out & 0xff;
    }
    for (let x = 0; x < width; x++) {
      const s = x * channels;
      const d = (y * width + x) * 4;
      rgba[d] = line[s] ?? 0;
      rgba[d + 1] = line[s + 1] ?? 0;
      rgba[d + 2] = line[s + 2] ?? 0;
      rgba[d + 3] = channels === 4 ? (line[s + 3] ?? 0) : 255;
    }
    prev.set(line);
  }
  return { width, height, rgba };
}

const alphaAt = (png: Png, x: number, y: number): number => png.rgba[(y * png.width + x) * 4 + 3] ?? 0;

const png = decodePng(Buffer.from(await Bun.file(ASSET).bytes()));

describe("menu bar template image", () => {
  test("the four corners are fully transparent", () => {
    const corners = [
      alphaAt(png, 0, 0),
      alphaAt(png, png.width - 1, 0),
      alphaAt(png, 0, png.height - 1),
      alphaAt(png, png.width - 1, png.height - 1),
    ];
    expect(corners).toEqual([0, 0, 0, 0]);
  });

  test("the mark itself is drawn, not an empty frame", () => {
    let opaque = 0;
    for (let i = 3; i < png.rgba.length; i += 4) if ((png.rgba[i] ?? 0) > 200) opaque++;
    expect(opaque).toBeGreaterThan(20);
  });
});
