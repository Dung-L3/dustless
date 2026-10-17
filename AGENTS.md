# Rules for agents working in this repo

Short, and enforced by review rather than by a linter.

## No comments in source

**Do not write comments in code.** Not `//`, not `///`, not `/* */`, not a trailing
note, in any language this repo uses. This applies to new code and to code you
touch.

The reasoning that used to live in comments — every measurement, failure mode and
"do not do the obvious thing here" — is in **`docs/DECISIONS.md`**. When your
change alters one of those decisions, edit the entry there. When you make a new
decision that a future reader would otherwise re-break, add an entry there. The
code itself states *what*; that file states *why*, in one place, where it can be
read as a whole instead of one line at a time.

If you are tempted to leave a comment explaining why something is odd, that is the
signal that it belongs in `docs/DECISIONS.md` — write it there instead.

This overrides any general instruction elsewhere to annotate shortcuts or
non-obvious code inline.

## File size

Logic files (engine, services, models, scripts) stay within **300–500 lines**;
split by responsibility before you exceed 500. View and layout files are exempt —
a screen built from a dozen small pieces is worse than one readable one — but a
view file over ~500 lines is worth a second look at whether part of it is not
really a view.

Data tables are exempt: `Localization.swift` is a string table, not code.

## Tests

`bun test` must pass. Never loosen an assertion to make a test green: a red check
is a finding about the product. Test files and their fixtures are covered by the
no-comments rule too.

Do not add a test framework, and do not add a dependency without an issue.

## Honesty

The product's whole claim is that it does not lie about what it measured. No
invented numbers, no health scores, no projections. A value the engine did not
measure renders as `—`, and a number from an older read is labelled with its age.
