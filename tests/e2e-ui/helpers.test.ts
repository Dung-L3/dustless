import { describe, expect, test } from "bun:test";
import { heroSize, size } from "../../src/ui/public/ui-helpers.js";

const KIB = 1024;
const MIB = KIB ** 2;
const GIB = KIB ** 3;

// The headline figure and the per-item figures are read as one promise by the
// user: "reclaimed space is measured, not estimated". If they disagree on the
// unit, the headline shows a number nothing else on the page would print.
describe("byte maths", () => {
  test("size() picks the same unit every time", () => {
    expect([900, 60 * KIB, 488 * KIB, 8 * MIB, 1.5 * GIB, 20 * GIB].map((bytes) => size("en", bytes))).toEqual([
      "900 B",
      "60 KB",
      "488 KB",
      "8 MB",
      "1.5 GB",
      "20 GB",
    ]);
  });

  test("the hero figure keeps the same unit as size() at every magnitude", () => {
    // The hero rounds harder than size() on purpose (1.50 GB, not 1.5 GB); the
    // unit must still be the one every other figure on the page would use.
    for (const bytes of [0, 900, 60 * KIB, 488 * KIB, 8 * MIB, 1.5 * GIB, 20 * GIB]) {
      const printed = size("en", bytes);
      const sizeUnit = printed.slice(printed.lastIndexOf(" ") + 1);
      expect({ bytes, heroUnit: heroSize(bytes).unit, sizeUnit }).toEqual({
        bytes,
        heroUnit: sizeUnit,
        sizeUnit,
      });
    }
  });

  test("a selection smaller than a megabyte is never rounded away to zero", () => {
    for (const bytes of [1, 900, 488 * KIB, MIB - 1]) {
      const hero = heroSize(bytes);
      const rendered = new Intl.NumberFormat("en", {
        minimumFractionDigits: hero.digits,
        maximumFractionDigits: hero.digits,
      }).format(hero.value);
      expect({ bytes, rendered: `${rendered} ${hero.unit}` }).toEqual({
        bytes,
        rendered: expect.stringMatching(/^(?!0\b)/),
      });
    }
  });
});