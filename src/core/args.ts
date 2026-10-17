/**
 * Argument reading, shared by the CLI and the `ram` subcommand.
 *
 * `opt()` used to return `argv[i + 1]` whatever it was, so a typo became a
 * delete: `apps --uninstall --confirm` passed `"--confirm"` as the app path and
 * `largefiles --delete --json` reported on a file named `--json`. A value that
 * starts with `--` is a *missing* value, and the caller turns that into a usage
 * error instead of silently falling back to a default.
 */
export type Args = {
  /** Every argument that is not a flag, in order. */
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