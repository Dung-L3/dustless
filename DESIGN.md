# Dustless design contract

Dustless is a quiet, premium macOS utility. It should feel like a precision instrument: calm surfaces, decisive actions, and no decoration that competes with the measurement.

## Principles

1. **One question per screen.** What am I looking at, what matters, what can I do next.
2. **Progressive disclosure.** Primary information is visible; paths, reasons and technical detail live one deliberate step deeper.
3. **Honest surfaces.** No invented scores, no decorative gradients, no fake progress. A measured value can be `—`; it cannot be made up.
4. **Safety is visible.** Destructive actions are red, named, and confirmed. Cancel leaves everything untouched.
5. **Motion explains change.** Animation shows where something came from or went; it never delays work.

## Visual language

### Palette (dark is the signature)

| Token | Dark | Role |
|---|---|---|
| `ink` | `#0B0C0D` | window background |
| `surface` | `#121416` | primary surface |
| `surfaceRaised` | `#181B1D` | cards and rows |
| `surfaceHover` | `#1F2326` | hover / selected row |
| `hairline` | white 8% | separators and edges |
| `textPrimary` | `#F2F4F2` | headings and values |
| `textSecondary` | `#A7ADA8` | labels and body support |
| `textMuted` | `#6F7671` | tertiary metadata |
| `accent` | `#8BD49C` | safe / primary action |
| `accentDeep` | `#5FAF72` | pressed accent |
| `warning` | `#E3B25C` | review / caution |
| `danger` | `#E06C75` | destructive only |
| `info` | `#7EA6C9` | network and neutral state |

Light mode keeps the same semantic roles on warm paper surfaces; it is a parallel token set, not an inversion of every colour.

### Type

System SF Pro only. It is the native macOS voice and avoids shipping a font.

| Role | Size / weight | Notes |
|---|---|---|
| Display | 32–38 / semibold | one per screen, tabular numerals for values |
| Screen title | 24–26 / semibold | sentence case |
| Section title | 15–17 / semibold | no decorative tracking |
| Body | 13 / regular | max readable line ~65 characters |
| Label | 11–12 / medium | secondary colour |
| Micro | 10–10.5 / medium | uppercase only for short eyebrows, tracking 0.6 |

Metrics use rounded, monospaced digits. All byte values use one byte formatter.

### Space and shape

- 4 / 8 / 12 / 16 / 24 / 32 pt rhythm.
- Page padding 24–28 pt; section gap 24 pt; card padding 16–20 pt.
- Radius: 16 outer card, 12 inner card, 10 row, 8 control, 999 pill.
- Elevation: one soft ambient shadow for floating sheets or popovers; no card drop shadows.
- Cards are separated by tone and spacing, not by a grid of borders.
- A raised surface gets an inner top highlight at white 6% and a hairline edge at white 8%.

### Components

- **Page header:** eyebrow optional, 24–26 pt title, one-line subtitle, one trailing action. Never two competing primary buttons.
- **Metric tile:** label, large tabular value, optional delta or age; no health score.
- **Surface card:** tonal fill, 16 radius, 16–20 padding, optional disclosure header.
- **List row:** 44–52 pt minimum; leading icon/checkbox, title, secondary line, trailing value and action. Hover raises tone; selected uses accent at 12%.
- **Status badge:** small capsule or dot + text; green safe, amber review, red destructive/blocked, blue neutral.
- **Primary button:** accent fill, dark text, 10 radius or pill for toolbar actions; pressed scales to 0.98; disabled uses 40% opacity.
- **Secondary button:** raised surface, hairline edge, primary text.
- **Destructive button:** danger fill or danger outline; never accent.
- **Search field:** raised surface, magnifier, clear button, 10 radius, 220–320 pt.
- **Empty state:** one icon, one sentence, one action. No illustration soup.
- **Error state:** plain sentence, retry, optional detail disclosure; never a raw code.
- **Confirmation:** one sheet, one decision. Show object, size, affected scope, running state, warning, cancel and one named destructive action.

### Motion

Native SwiftUI only. GSAP is not applicable to a native SwiftUI window; see `DESIGN-DECISIONS.md`.

| Token | Duration | Curve |
|---|---|---|
| `micro` | 140 ms | `.easeOut` |
| `control` | 180 ms | spring(stiffness 320, damping 28) |
| `section` | 240 ms | spring(stiffness 260, damping 30) |
| `sheet` | 300 ms | `.easeOut` |
| `stagger` | 24 ms per item, max 8 | capped |

- Respect Reduce Motion: opacity-only or no movement.
- Animate transform and opacity; never width/height or layout-triggering properties for entrance.
- A list that is filtering must not animate each pass; only first appearance and explicit add/remove.
- No continuous ambient animation. No looping glow.
- Numeric values update without a fake count-up; a subtle opacity/scale acknowledgement is enough.

## Screen rules

- **Sidebar:** grouped by job, not by data type. Workspace: Overview, Cleanup, Storage, Applications. System: Memory, Network. Settings is a footer utility. Active state is a soft accent pill behind the row.
- **Overview:** one hero number, three supporting measurements, one attention card, three largest findings, and four module shortcuts. No duplicate tier cards.
- **Cleanup:** tier pills live here, not in the sidebar. Search and select controls are secondary. The review action is pinned in the footer.
- **Storage:** volume cards first, then large files with search, sort and direct Trash action. Applications lives in its own module.
- **Applications:** one row per app, direct Uninstall, search/filter/sort, related-data summary. One confirmation sheet. Default is Trash.
- **Memory:** groups are the list; each eligible app has a direct graceful Quit action on the row. Expanding a group reveals per-process Stop and Force Stop. One in-flight action per item.
- **Network:** state summary, safe operations, then an Advanced disclosure. Every operation names its effect and asks once.
- **Settings:** grouped form; no decorative cards. Changes apply immediately.
- **Popover:** compact live status, one primary action, module shortcuts, AirDrop, Open/Settings/Quit.

## Accessibility

- Every interactive control has a label and a stable identifier.
- Keyboard focus is visible. Buttons respond to Space/Return.
- State is never conveyed by colour alone; badge text or icon accompanies it.
- Reduce Motion and Increase Contrast are respected.
- Long paths are truncated in the middle with full text in help, accessibility label and a copy/reveal context menu.
