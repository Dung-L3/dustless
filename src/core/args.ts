export type Args = {
  positional: string[];
  flag: (name: string) => boolean;
  opt: (name: string) => string | undefined;
};

export function args(argv: string[]): Args {
  const at = (name: string): number => argv.indexOf(`--${name}`);
  return {
    positional: argv.filter((arg) => !arg.startsWith("--")),
    flag: (name) => at(name) >= 0,
    opt: (name) => {
      const found = at(name);
      if (found < 0) return undefined;
      const value = argv[found + 1];
      return value === undefined || value.startsWith("--") ? undefined : value;
    },
  };
}