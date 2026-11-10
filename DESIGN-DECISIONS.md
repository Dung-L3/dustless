# Design decisions

## 1. Native motion, not GSAP

Dustless is a native SwiftUI/AppKit macOS app. There is no React, DOM, SVG document, or WebView surface for GSAP to animate. GSAP cannot drive `NSWindow`, `NSView` or SwiftUI transitions directly, and moving the app into a WebView to use it would be a product rewrite with no user benefit. The motion system is built on SwiftUI `Animation`, `withAnimation`, `transition`, `matchedGeometryEffect`, `contentTransition`, and `TimelineView` only where a value needs deliberate interpolation. `Motion.swift` owns the duration/curve tokens and the Reduce Motion gate.

## 2. Applications is a top-level module

Application removal was buried under Storage → Advanced → Applications. The owner's job is application management, not a cache sub-feature. It becomes `Applications` in the sidebar with a direct row action, search, sort, running state and related-data totals. Storage keeps volumes and large files.

## 3. Tier selection moves to Cleanup

Safe / Review / Locked are context for the Cleanup screen, not global navigation. Sidebar tiers added badges and rows that duplicated the module. They move into a pill selector at the top of Cleanup. The sidebar keeps only jobs.

## 4. Uninstall defaults to Trash

The uninstaller keeps the existing engine safety gates: only `.app` bundles under `/Applications` or `~/Applications`, a safe bundle identifier, canonical paths, no system apps, no user documents. Related data is the engine's own bundle-id templates only. The default action moves everything to the Trash; permanent delete remains an explicit second choice inside the same confirmation sheet. Cancel runs nothing.

## 5. Related data is named, sized and optional

The engine reports related paths with a kind and measured size. The confirmation shows the app bundle, support, cache, preferences, logs, saved state, containers and other related items. Unknown or user-created data is not offered. A single checkbox controls related data; the app bundle is always included in the uninstall.

## 6. Memory group actions are graceful

A group represents one application, so its direct action is "Quit app" (`NSRunningApplication.terminate()`), not a file delete. Per-process Stop and Force Stop stay in the expanded group, where the target is explicit. A running app is never force-killed as part of an uninstall; if it does not quit, the uninstall is refused with the reason.

## 7. Values do not count up

The previous count-up animation briefly disagreed with the engine number. The hero value is the measured value from the first frame. A selection or refresh may acknowledge the change with a short opacity/scale transition, but a byte count is never animated through invented intermediate numbers.

## 8. One primary action per screen

The primary action lives in the page header or the pinned footer. Row actions are secondary. A screen never presents two filled buttons with the same weight.

## 9. Stagger is capped

List entrance uses at most eight items with a 24 ms stagger; later rows appear together. Filtering does not replay the entrance. This keeps large process and app lists responsive.

## 10. Sidebar width and grouping

Sidebar width is 232 pt. Workspace contains Overview, Cleanup, Storage and Applications; System contains Memory and Network. This is the maximum grouping that stays readable at the 940 pt minimum window width.

## 11. Uninstall has two named scopes

The default is **Remove application** and keeps every related item. **Remove application & selected data** reveals a per-item checklist; unchecked paths never reach the engine. A result that leaves related data is titled **Application removed**, not **Uninstalled**. A partial result keeps the remaining paths and offers a retry that runs against the original bundle identity only after the engine revalidates its templates and canonical paths. This preserves the safety default while making the scope visible.

## 12. Permission waiting is not a fake state

macOS does not expose whether a TCC prompt is visible to the app. After five seconds the scan shows **Waiting for access**, explicitly saying the system *may* be asking. A completed report with denied reads shows **Some folders could not be read** and links to Files & Folders. Dustless never claims that permission was granted, and never reports a complete scan when protected data could not be read.

## 13. Process actions state what they can prove

A protected process has no Stop/Force Stop control. A Stop result means the signal was accepted, not that the process exited; the list refresh is the proof. A Quit result is only success after the exact bundle-path instances disappear; a still-open app shows a warning instead of a checkmark. Force Stop remains a secondary, explicitly labelled action.
