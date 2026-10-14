declare module "*/src/ui/public/i18n.js" {
  export const LANGUAGES: { code: string; label: string }[];
  export const STRINGS: Record<string, Record<string, string>>;
  export function createTranslator(code: string): (key: string, vars?: Record<string, unknown>) => string;
}

declare module "*/src/ui/public/ui-helpers.js" {
  export function size(lang: string, bytes: number): string;
  export function heroSize(bytes: number): { value: number; unit: string; digits: number };
}