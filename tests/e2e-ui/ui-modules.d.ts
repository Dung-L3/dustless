declare module "*/src/ui/public/i18n.js" {
  export const LANGUAGES: { code: string; label: string }[];
  export const STRINGS: Record<string, Record<string, string>>;
  export function createTranslator(code: string): (key: string, vars?: Record<string, unknown>) => string;
}