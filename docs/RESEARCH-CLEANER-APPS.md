# Research: How modern disk-cleanup and space-reclaim apps are designed

**Purpose.** Design input for Dustless (`/Users/mac/Developer/dustless`). Dustless cross-verifies that nothing uses a cache before deleting it — a property no app in this survey has. That difference is called out explicitly in §3.

**Method.** Product pages, official vendor documentation, and review articles for each app listed below. Every non-obvious claim carries a URL. Facts only; marketing copy is quoted sparingly and marked as vendor copy. Where sources disagree, both are given. Anything I could not verify is listed in §6.

**Scope note on Dustless today.** Dustless is a native macOS app, not a web app: the SwiftUI app in `apps/dustless-mac` is the product, and its sidebar currently mixes *metrics*, *tier filters*, *actions*, and *settings* in one list (`SidebarView.swift:11-65`). Sections 2 and 3 are written to apply to it.

---

## 1. Comparison table

Legend: ✅ present · ◐ partial / conditional · ❌ absent · **unverified** = I could not confirm from an authoritative source.

| Dimension | CleanMyMac (MacPaw) | DaisyDisk | AppCleaner (FreeMacSoft) | BuhoCleaner (Dr.Buho) | CCleaner (Windows) | Windows Disk Cleanup | Storage Sense (Win 11) |
|---|---|---|---|---|---|---|---|
| **Top-level nav** | Left **sidebar of 5 modules**: Cleanup, Protection, Performance, Applications, My Clutter. Icons unlabelled with tooltips ([macworld](https://www.macworld.com/article/1993544/how-to-use-cleanmymac-x.html)) | No categories — a single disk overview list, then a sunburst map ([guide](https://daisydiskapp.com/guide/4/en/DisksOverview/)) | **None.** Single window: drag an app onto it ([FreeMacSoft](https://freemacsoft.net/appcleaner/)) | **unverified** (see §6). Sources describe a "Smart Scan" one-shot action ([cultofmac](https://www.cultofmac.com/news/buhocleaner)) | Left sidebar of modules (Quick Clean, Clean Clutter, Clean Browser, Find Duplicates, Analyze Photos, Uninstall Apps, Startup Manager, System Monitor) ([macworld](https://www.macworld.com/article/673271/best-mac-cleaner-tested-compared.html)) | **None.** Flat checkbox list of file categories ([HP](https://www.hp.com/us-en/tech-takes/software/how-to/how-to-use-disk-cleanup-windows-10.html)) | Settings page, no nav; one toggle + sub-options ([MS](https://support.microsoft.com/en-us/windows/experience/storage-filemanagement/manage-drive-space-with-storage-sense)) |
| **Primary screen** | Launch → **Smart Care** "Scan" → results as **5 tiles** (bytes reclaimable, threats, maintenance tasks, app updates, duplicates) ([Smart Care](https://macpaw.com/support/cleanmymac/knowledgebase/smart-care)) | Launch → **list of volumes with free-space gauges** (green ≥50% free, red = full) ([DisksOverview](https://daisydiskapp.com/guide/4/en/DisksOverview/)) | Empty window with a drop target ([FreeMacSoft](https://freemacsoft.net/appcleaner/)) | One-shot **Smart Scan** results ([cultofmac](https://www.cultofmac.com/news/buhocleaner)) | Module results per scan | Checkbox list; hover an item to read its description at the bottom of the dialog ([helpdeskgeek](https://helpdeskgeek.com/how-to-run-disk-cleanup-windows-10-11/)) | Banner shows free space; options are thresholds |
| **Headline number** | "Total data that can be safely removed to free disk space" per tile ([Smart Care](https://macpaw.com/support/cleanmymac/knowledgebase/smart-care)) | Free-space gauge per volume; the number under the gauge is space **left** ([DisksOverview](https://daisydiskapp.com/guide/4/en/DisksOverview/)) | Size of the selected app's leftovers | Junk found (amount) | Bytes selected to clean | Total recoverable shown in the dialog | Free space banner |
| **How items are listed** | Tiles per module; **Review** on a tile opens item detail ([macworld](https://www.macworld.com/article/1993544/how-to-use-cleanmymac-x.html)) | **Sunburst/petal map** — click to drill in; sidebar for details ([DeletingFiles](https://daisydiskapp.com/guide/4/en/DeletingFiles/)) | **Flat checkbox list of all related files** ([apeaksoft](https://www.apeaksoft.com/clear-data/appcleaner-review/)) | Category modules | Per-module checkbox list | Per-category checkbox row | Threshold settings |
| **Detail per item (default)** | Summary only; **Review** to expand ([macworld](https://www.macworld.com/article/1993544/how-to-use-cleanmymac-x.html)) | Segment size + **Quick Look preview** in sidebar; Cmd-click reveals in Finder ([Tips](https://daisydiskapp.com/guide/2/en/TipsAndTricks/)) | Name + path + size | Category summary | Category totals | Category size | N/A |
| **Deletion presentation** | Per-tile **Clean** button, one click, pre-checked. "Review" to deselect ([macworld](https://www.macworld.com/article/1993544/how-to-use-cleanmymac-x.html)) | **Collector** tray at the bottom: drop petals in, files stay intact until **Delete**; then a **5-second countdown** ([DeletingFiles](https://daisydiskapp.com/guide/4/en/DeletingFiles/)) | Checkboxes + **Remove** button ([apeaksoft](https://www.apeaksoft.com/clear-data/appcleaner-review/)) | One-click clean after scan | Checkboxes + clean | Checkboxes + **Delete Files** ([helpdeskgeek](https://helpdeskgeek.com/how-to-run-disk-cleanup-windows-10-11/)) | Deletion on a schedule; **no confirmation** ([MS](https://support.microsoft.com/en-us/windows/experience/storage-filemanagement/manage-drive-space-with-storage-sense)) |
| **Protected / ignored items** | "Our Safety Database … prevents cleaning errors" (vendor claim) ([Smart Care](https://macpaw.com/support/cleanmymac/knowledgebase/smart-care)) | Refuses `/System`, `/Library`, home folder, and consolidated petals ([DeletingFiles](https://daisydiskapp.com/guide/4/en/DeletingFiles/)) | Targets only files tied to the dropped app | **unverified** | Checkbox selection acts as the control | Only system-known categories | Only categories the user opts into |
| **Undo / recover** | **No undo** ([MPU Talk](https://talk.macpowerusers.com/t/experience-with-opinion-on-clean-my-mac/37478)) | **None** — bypasses Trash, no undo ([drbuho](https://www.drbuho.com/review/daisydisk-review)) | Not offered (files sent to Trash) | **unverified** | Registry backup for its registry module | Recycle Bin (recoverable) | Recycle Bin / online-only (recoverable) |
| **Background / automation** | Launch-at-login not required; menubar **CleanMyMac Menu** runs **even when the app isn't running** ([macworld](https://www.macworld.com/article/1993544/how-to-use-cleanmymac-x.html)) | Starred folders persist; no scheduler | **unverified** | Menubar monitor ([nektony](https://nektony.com/reviews/buhocleaner-vs-maccleaner-pro)) | Scheduled scan | Not itself (Storage Sense is) | **Run daily/weekly/monthly or on low disk space** ([MS](https://support.microsoft.com/en-us/windows/experience/storage-filemanagement/manage-drive-space-with-storage-sense)) |
| **Distribution** | **.dmg**, also Mac App Store (store build lacks some features) ([macworld](https://www.macworld.com/article/352922/cleanmymac-x-review-macos.html)); "Notarized by Apple"; listed at **320 MB** ([macpaw](https://macpaw.com/cleanmymac)) | **.dmg + Mac App Store**; **$9.99 one-time**, up to 5 Macs ([pricing](https://daisydiskapp.com/support/pricing)) | **Free, plain .zip** download, drag-to-Applications; **no installer, no account, no upsell** ([FreeMacSoft](https://freemacsoft.net/appcleaner/)) | .dmg, **lifetime $14.99** ([reviews.org](https://www.reviews.org/smart-home/best-cleaning-apps-for-mac/)) | **Installer + Microsoft Store (MSIX)** listing ([MS Store](https://apps.microsoft.com/detail/xpfcwp0sqwxm3v)); portable ≈16 MB ([askvg](https://www.askvg.com/download-ccleaner-slim-installer-and-portable-version/)) | Built into Windows; `cleanmgr` ([learn.microsoft.com](https://learn.microsoft.com/en-us/windows-server/storage/file-server/disk-cleanup)) | Built into Windows 11 |
| **Admin rights** | Notarized; **full features need Full Disk Access** to see some dirs ([DaisyDisk F.D.A. note](https://daisydiskapp.com/guide/4/en/FullDiskAccess/); [MacPaw on iCloud restriction](https://www.macworld.com/article/673271/best-mac-cleaner-tested-compared.html)) | Full Disk Access required for hidden space ([drbuho](https://www.drbuho.com/review/daisydisk-review)) | Asks for **username + password to confirm removal** ([apeaksoft](https://www.apeaksoft.com/clear-data/appcleaner-review/)) | **unverified** | Installer may need admin; portable doesn't ([askvg](https://www.askvg.com/download-ccleaner-slim-installer-and-portable-version/)) | Yes, UAC for system files | Runs unprivileged while signed in ([MS](https://support.microsoft.com/en-us/windows/experience/storage-filemanagement/manage-drive-space-with-storage-sense)) |

### Cloud "find and reclaim space" flows (comparable UX, not disk cleaners)

| App | Core verb | Safety model | Reversible? |
|---|---|---|---|
| **Google One storage manager** | Swipe right to mark for deletion, swipe left to keep; **Review** at top, then Delete ([Google One](https://support.google.com/googleone/answer/9312312?hl=en)) | Only offers the cleanup target **if you're over quota**; shows what you need to free | Photos → trash (30 days). Drive/Gmail → **permanent, not recoverable** ([Google One](https://support.google.com/googleone/answer/9312312?hl=en)) |
| **OneDrive Files On-Demand** | Right-click → **Free up space** (or "Always keep on this device") ([MS](https://support.microsoft.com/en-us/onedrive/save-disk-space-with-onedrive-files-on-demand-for-windows)) | Per-file tri-state; Storage Sense can flip online→offline after N days | Yes — **never deletes**; the file stays in OneDrive ([MS](https://support.microsoft.com/en-us/onedrive/save-disk-space-with-onedrive-files-on-demand-for-windows)) |
| **Dropbox** | Right-click → **Make online-only**; or **Manage hard drive space** tool: sort by size, check boxes, **Move to online-only**; confirmation shows freed amount ([Dropbox](https://help.dropbox.com/sync/make-files-online-only)) | Non-destructive by design | Yes — file remains in the cloud ([Dropbox](https://help.dropbox.com/sync/make-files-online-only)) |

**Source conflict (worth knowing):** Google says Drive/Gmail deletions are permanent, while Photos goes to trash for 30 days ([Google One](https://support.google.com/googleone/answer/9312312?hl=en)). OneDrive says a delete **removes it from all devices** but keeps a recycle-bin copy 30–93 days ([MS](https://support.microsoft.com/en-us/onedrive/save-disk-space-with-onedrive-files-on-demand-for-windows)). Dropbox's community threads are full of "set it to online-only and it didn't free up space" reports ([community](https://community.dropbox.com/en/discussion/655688/setting-folder-to-online-only-doesnt-free-up-local-space)) — the platform placeholders are a real failure mode users hit.

---

## 2. The information architecture the category has converged on

Across all seven apps, **top-level navigation is a left sidebar of modules, not a tab bar and not a wizard** — whenever the app has more than one kind of thing to do. CleanMyMac's sidebar is the canonical form ([macworld](https://www.macworld.com/article/1993544/how-to-use-cleanmymac-x.html)); CCleaner matches it ([macworld](https://www.macworld.com/article/673271/best-mac-cleaner-tested-compared.html)).

Two structural facts are near-universal:

**(a) A single dominant "scan everything" entry point.** CleanMyMac's Smart Care runs all five modules and returns five tiles ([Smart Care](https://macpaw.com/support/cleanmymac/knowledgebase/smart-care)); CCleaner's Quick Clean; BuhoCleaner's Smart Scan ([cultofmac](https://www.cultofmac.com/news/buhocleaner)); Storage Sense's automatic run ([MS](https://support.microsoft.com/en-us/windows/experience/storage-filemanagement/manage-drive-space-with-storage-sense)). Everything else in the sidebar is a *narrower* path to the same scan. Users arrive at the top item and are meant to be done in one press.

**(b) Results are shown as per-category tiles/rows with a per-category action, before any item list.** CleanMyMac: a `Clean` button and a separate `Review` button on each tile ([macworld](https://www.macworld.com/article/1993544/how-to-use-cleanmymac-x.html)). Disk Cleanup: a checkbox row per category ([helpdeskgeek](https://helpdeskgeek.com/how-to-run-disk-cleanup-windows-10-11/)). The detail list is always *behind* a second interaction. Nobody in this category shows a flat, exhaustive list of every file first.

### The category vocabulary

| Category | Who has it | Notes |
|---|---|---|
| **Cleanup / System junk / caches** | CleanMyMac "Cleanup"→System Junk ([My Tools](https://macpaw.com/support/cleanmymac/knowledgebase/my-tools)); Disk Cleanup "Temporary files" ([helpdeskgeek](https://helpdeskgeek.com/how-to-run-disk-cleanup-windows-10-11/)); Mac Cleaner "System Junk" ([apeaksoft](https://www.apeaksoft.com/clear-data/appcleaner-review/)) | **Universal.** The only category every single app has. |
| **Uninstall apps / leftovers** | CleanMyMac "Applications" ([My Tools](https://macpaw.com/support/cleanmymac/knowledgebase/my-tools)); AppCleaner (its entire purpose) ([FreeMacSoft](https://freemacsoft.net/appcleaner/)); CCleaner ([macworld](https://www.macworld.com/article/673271/best-mac-cleaner-tested-compared.html)) | Common in Mac apps. **Dustless does not have it and should not add it.** |
| **Large / old files** | CleanMyMac "My Clutter" ([My Tools](https://macpaw.com/support/cleanmymac/knowledgebase/my-tools)); DaisyDisk (its purpose) ([DisksOverview](https://daisydiskapp.com/guide/4/en/DisksOverview/)); Disk Cleanup "Large or unused files" ([MS](https://support.microsoft.com/en-us/windows/experience/storage-filemanagement/free-up-drive-space-in-windows)) | Near-universal, but it's a *visualizer*, not a cleaner. |
| **Trash / Recycle Bin** | CleanMyMac "Trash Bins" ([My Tools](https://macpaw.com/support/cleanmymac/knowledgebase/my-tools)); Disk Cleanup "Recycle Bin" ([helpdeskgeek](https://helpdeskgeek.com/how-to-run-disk-cleanup-windows-10-11/)); Storage Sense | Universal and it is **recoverable** — the one category users trust most. |
| **Duplicates** | CleanMyMac "Duplicate Finder" ([My Tools](https://macpaw.com/support/cleanmymac/knowledgebase/my-tools)); CCleaner; Cleaner One Pro ([macworld](https://www.macworld.com/article/673271/best-mac-cleaner-tested-compared.html)) | Common, and separately sold (Gemini). |
| **Malware / Privacy** | CleanMyMac "Protection" ([macworld](https://www.macworld.com/article/1993544/how-to-use-cleanmymac-x.html)); CCleaner | Common but **not a storage category** — it's what makes cleaners look like snake oil ([MPU Talk](https://talk.macpowerusers.com/t/experience-with-opinion-on-clean-my-mac/37478)). |
| **Performance / Maintenance / Startup** | CleanMyMac "Performance" ([macworld](https://www.macworld.com/article/1993544/how-to-use-cleanmymac-x.html)); CCleaner Startup Manager | Very common; the module users trust least. |
| **Cloud storage** | CleanMyMac "Cloud Cleanup" for iCloud/Drive/OneDrive/Dropbox ([concepts](https://macpaw.com/support/cleanmymac/knowledgebase/concepts-and-usage)); DaisyDisk cloud scan ([guide](https://daisydiskapp.com/guide/4/en/CloudScan/)); Cleaner One Pro's Dropbox scanner ([macworld](https://www.macworld.com/article/673271/best-mac-cleaner-tested-compared.html)) | Growing, and near-universally built on the **non-destructive** online-only model. |

### What is genuinely an outlier

- **DaisyDisk has no categories at all.** One map, one Collector, one Delete ([DeletingFiles](https://daisydiskapp.com/guide/4/en/DeletingFiles/)). It is the purest expression of "show me, let me choose." Macworld praises exactly this: "It does one job very well" ([macworld](https://www.macworld.com/article/673271/best-mac-cleaner-tested-compared.html)).
- **Storage Sense has no review step at all.** It deletes on a schedule with no per-run confirmation, and Microsoft even turns it **on without consent**, notifying you after the fact — "we may turn on Storage Sense to manage select temporary files, then notify you" ([MS](https://support.microsoft.com/en-us/windows/experience/storage-filemanagement/manage-drive-space-with-storage-sense)). This is the single most-criticised behaviour in the survey.
- **AppCleaner has no navigation because it has no scope** — one job, drag and drop ([FreeMacSoft](https://freemacsoft.net/appcleaner/)). Its simplicity is consistently treated as a virtue.
- **OnyX is the anti-pattern**: dozens of checkboxes and technical terminology, and reviewers call it "Intimidating" ([macworld](https://www.macworld.com/article/673271/best-mac-cleaner-tested-compared.html)).

### Convergence, stated plainly

**Sidebar of modules → scan → per-category result tiles with a per-category primary action → optional Review drill-down → one confirm.** Dustless already does the last four steps. The category norm it is missing is only the first: a named module axis users can navigate by.

---

## 3. Deliberate recommendations for Dustless

### R1 — Do **not** copy the category's module taxonomy. Tier is the axis. *(differs from category norm)*

**Evidence:** Every competitor's top-level axis is *what kind of thing* (junk / apps / privacy / performance). None of them has a risk axis. CleanMyMac needs five modules because it does five unrelated jobs including malware scanning ([macworld](https://www.macworld.com/article/1993544/how-to-use-cleanmymac-x.html)).

**Why Dustless should differ:** Dustless does exactly one job. Its four tiers (GREEN / YELLOW / BLOCKED / RED, `src/core/scan.ts:72-76`) are not a *sub*-taxonomy of junk — they are a verdict about *whether this specific finding is safe*, which is orthogonal to what the cache belongs to. Grouping by toolchain (Gradle, npm, Cargo) and then showing a badge per tier would force the user to learn 26 rule ids before they could act. Grouping by tier means the first question the UI answers is the only one that gates the destructive act: *can this be deleted safely?*

**Concretely:** the sidebar's top section becomes `Safe to delete`, `Review first`, `Locked (never deleted)` — each showing count and bytes. This is what `SidebarView.swift:19-24` already does; promote it from the second section to the entire navigation axis and move metrics into the header.

### R2 — The headline number must mean "bytes that passed verification and will be deleted if you press the button," and it must be *live to selection*. *(matches category, one sharpening)*

**Evidence:** CleanMyMac's headline is "Total data that can be safely removed to free disk space" ([Smart Care](https://macpaw.com/support/cleanmymac/knowledgebase/smart-care)) — the safety adjective is doing load-bearing work. Storage Sense's equivalent is a free-space banner ([MS](https://support.microsoft.com/en-us/windows/experience/storage-filemanagement/manage-drive-space-with-storage-sense)).

**Dustless sharpening:** recompute the hero figure as the user toggles YELLOW items off, and label it explicitly: the number is the *selected* total, not the scan total. Show the scan total as a separate, dimmer figure ("3.4 GB found · 611 MB selected") so the two are never confused — the Apple Storage panel's per-category breakdown is the precedent for showing both a total and a selected subset ([Apple Support](https://support.apple.com/guide/mac-help/find-and-delete-files-on-your-mac-syspf5a64aa6/mac)).

### R3 — Locked items get a real destination, not just a notice. *(differs from category norm)*

**Evidence:** The whole category's safety story is "we checked our database" — CleanMyMac's "Safety Database, built over years of experience" ([Smart Care](https://macpaw.com/support/cleanmymac/knowledgebase/smart-care)), DaisyDisk's refusal to accept `/System` into the Collector ([DeletingFiles](https://daisydiskapp.com/guide/4/en/DeletingFiles/)). In both cases the protected thing **disappears from the UI**. DaisyDisk gives no indication a folder exists that it won't let you delete.

**Why Dustless should differ:** BLOCKED is the product's differentiator and its most interesting output — it is the live verdict "I looked and could not prove this is unused." Hiding it throws away the evidence. Rendering it as a notice in the row is correct but passive.

**Concretely:** `Locked` is a full view, not a badge. Each locked finding shows **what verification was attempted and why it failed** — for Gradle, the concrete fact "project `/Users/x/repo` pins 8.12 in `gradle-wrapper.properties`". That is the proof that cross-verification works, and it converts a refusal into a feature. A user who sees *why* something is locked trusts the things that are unlocked; a user who just sees a lock does not.

### R4 — Prefer a reversible-trust model; permanent deletion is the thing reviewers punish. *(differs from category norm)*

**Evidence:** DaisyDisk is the category's most-praised UX and its most-cited flaw in the same breath — "no undo, no recovery from the Trash, it's just gone. Personally, this made me a bit more cautious and double-check everything before hitting delete" ([drbuho](https://www.drbuho.com/review/daisydisk-review)); Macworld's only listed DaisyDisk con is UI quirks, while the MPU forum's complaint is "no undo and no logs" ([MPU Talk](https://talk.macpowerusers.com/t/experience-with-opinion-on-clean-my-mac/37478)). Conversely, the categories that are reversible — Trash/Recycle Bin — are the ones nobody fears deleting.

**Why Dustless should differ:** A reversible trash doubles as proof the tool is safe, which is the entire positioning. But it's a real cost decision: toolchain caches can be tens of GB, and moving them to a volume's Trash doubles peak disk usage — exactly what you're trying to relieve.

**Recommendation:** make it **opt-in per tier, default OFF for GREEN** (those are verified regenerable; the cost isn't worth it), and default **ON for YELLOW** (those are the ones a user might regret, and they're the smaller set). State the trade-off in one line at the toggle. If you'd rather not carry a moving-to-trash path for multi-GB trees at all, then **do not pretend to**: ship permanent deletion and say so plainly in the confirm sheet, rather than implying reversibility.

### R5 — The confirm step must show the *decision*, not just the list. *(sharpening of category norm)*

**Evidence:** The category's weakest link. DaisyDisk's 5-second countdown is the whole safety story and it is a countdown, not a comprehension aid ([DeletingFiles](https://daisydiskapp.com/guide/4/en/DeletingFiles/)). Storage Sense has nothing ([MS](https://support.microsoft.com/en-us/windows/experience/storage-filemanagement/manage-drive-space-with-storage-sense)). Google One is the best of them and still deletes permanently with one tap after a Review step ([Google One](https://support.google.com/googleone/answer/9312312?hl=en)).

**Dustless advantage:** the confirm sheet can say things no competitor can, because it knows *why* each item is in its tier. For each selected item, one line of provenance: `"npm.cacache — verified regenerable, no verification required"` / `"android.ndk — rule requires ≥90 days, newest file is 0 days old"` / `"gradle 8.12 — BLOCKED, pinned by /Users/x/repo"`. Listing path + size only is a miss; the sheet should list path + size + the deciding reason. A user reviewing "why" is reviewing the tier system; a user reviewing paths is doing DaisyDisk's job and getting less safety for it.

### R6 — Keep automation minimal and non-destructive-by-default; do not ship unattended GREEN deletion. *(deliberately differs from Storage Sense)*

**Evidence:** Storage Sense's schedule is the category's most-copied idea and its most-damaging one — it deletes unattended, auto-enables itself on low disk, and its cloud option dehydrates files after 30 days by default ([MS](https://support.microsoft.com/en-us/windows/experience/storage-filemanagement/manage-drive-space-with-storage-sense)). It is also the reason a large share of the category is distrusted ([MPU Talk](https://talk.macpowerusers.com/t/experience-with-opinion-on-clean-my-mac/37478)).

**Recommendation:** offer **scan-and-notify only** — "3.4 GB is reclaimable, run `dustless scan`" — never scan-and-delete. This preserves the useful part (you learn your caches grew) and avoids the part that costs trust. The menubar presence already planned in `DustlessApp.swift:26-34` is the right home for it. Note that `--yes` already skips *confirmation* but never skips *verification* (README), so even the CLI automation stays inside the tier rules.

### R7 — Distribution should look like AppCleaner and DaisyDisk, not CleanMyMac.

**Evidence:** CleanMyMac is a **320 MB** notarized DMG with a subscription and a Store build that "lacks some features" ([macpaw](https://macpaw.com/cleanmymac); [macworld](https://www.macworld.com/article/352922/cleanmymac-x-review-macos.html)). AppCleaner is a **free .zip you drag to Applications**, with the site noting "You won't be prompted to buy anything while using it" ([apeaksoft](https://www.apeaksoft.com/clear-data/appcleaner-review/)); DaisyDisk is **$9.99 once** ([pricing](https://daisydiskapp.com/support/pricing)). Macworld's #1 CleanMyMac con is "Expensive compared to rivals" ([macworld](https://www.macworld.com/article/673271/best-mac-cleaner-tested-compared.html)).

**Recommendation:** keep the single-binary, no-installer, no-admin distribution. The app asking for no privileges and requiring no account is itself a safety signal the category rarely offers. Do not add a trial-limit ("cleaning is limited to a maximum of 500MB" is what CleanMyMac's free trial does, per [macworld](https://www.macworld.com/article/673271/best-mac-cleaner-tested-compared.html)) — gating the *destructive* action behind a purchase is the behaviour that produces the "it's a scam" reviews.

### R8 — Settings belong off the main navigation.

**Evidence:** CleanMyMac pushes automation into a separate Settings window with a left pane mirroring the module tree and per-module checkboxes to exclude from scanning ([Smart Care](https://macpaw.com/support/cleanmymac/knowledgebase/smart-care)); Storage Sense is entirely a Settings sub-page ([MS](https://support.microsoft.com/en-us/windows/experience/storage-filemanagement/manage-drive-space-with-storage-sense)); AppCleaner has no settings at all ([FreeMacSoft](https://freemacsoft.net/appcleaner/)).

**Recommendation:** in the Swift app, move `Launch at login` out of the sidebar's "Startup" section (`SidebarView.swift:43-65`) into a menu-bar-item-driven Settings window. A toggle in the nav list competes with the tier filters for attention and is the thing users change once and never again. If you keep exactly one thing in the main window besides tiers, make it "Rescan", not "Launch at login".

---

## 4. What these apps get wrong — the design brief

These are user complaints, so they outrank anything the apps do right.

1. **"It's a scam" / snake oil.** The loudest and oldest complaint in the category. r/macOS: *"It's a scam, and it doesn't even fix the one space problem that can actually happen to Macs"* ([thread](https://www.reddit.com/r/mac/comments/1ez1y9k/is_cleanmymac_a_legit_app_for_macs/)). MPU: *"a mix of legit features and snake oil"* ([thread](https://www.reddit.com/r/MacOS/comments/sm0n9x/thoughts_on_mac_cleaning_software/)). Macworld's CleanMyMac cons include "**Duplicates macOS built-in tools**" and "**Occasionally flags needed files**" ([macworld](https://www.macworld.com/article/673271/best-mac-cleaner-tested-compared.html)). *Design implication:* the number on the hero must be defensible and the reason must be inspectable. A bigger number with a vague justification is worse than a smaller number you can prove. This is Dustless's single strongest asset — R2/R5 exist to cash it in.

2. **No undo, no logs, no recovery.** Called out against DaisyDisk ([drbuho](https://www.drbuho.com/review/daisydisk-review)), against CleanMyMac ([MPU Talk](https://talk.macpowerusers.com/t/experience-with-opinion-on-clean-my-mac/37478)), against OnyX ([Setapp](https://setapp.com/app-reviews/best-appcleaner-alternative-for-mac)), and against CCleaner's registry cleaner ([Malwarebytes forums](https://forums.malwarebytes.com/topic/283533-registry-cleaner/)). *Design implication:* R4.

3. **Deletion is irreversible and silent.** CleanMyMac tiles are **pre-checked** — everything is selected before you look at it, and "Clean" is one click ([macworld](https://www.macworld.com/article/1993544/how-to-use-cleanmymac-x.html)). Storage Sense deletes unattended and may self-enable ([MS](https://support.microsoft.com/en-us/windows/experience/storage-filemanagement/manage-drive-space-with-storage-sense)). Google Drive/Gmail deletion is permanent with no recovery ([Google One](https://support.google.com/googleone/answer/9312312?hl=en)). *Design implication:* never default-select anything the user hasn't seen. Dustless's fail-closed apply (`src/core/apply.ts:71`) is already the right shape — surface that in the UI instead of pre-checking.

4. **Over-aggressive / wrong flags.** Avast: "can be overly aggressive… users should review settings and results carefully" ([macworld](https://www.macworld.com/article/673271/best-mac-cleaner-tested-compared.html)). AVG: the "Bad Photos" feature "functions on vague criteria" ([macworld](https://www.macworld.com/article/673271/best-mac-cleaner-tested-compared.html)). *Design implication:* a refusal that is explained beats a deletion that is correct. R3.

5. **Feature bloat and intimidation.** "Many tools unnecessary" (Parallels Toolbox), "Intimidating" (OnyX), "Dozens of checkboxes and technical terminology" ([Setapp](https://setapp.com/app-reviews/best-appcleaner-alternative-for-mac)), "Split into multiple apps" (MacCleaner Pro), "Clunky and dated interface" (CCleaner) — all [macworld](https://www.macworld.com/article/673271/best-mac-cleaner-tested-compared.html). The counter-example is DaisyDisk, whose entire pitch is not doing more ([macworld](https://www.macworld.com/article/673271/best-mac-cleaner-tested-compared.html)). *Design implication:* do not add categories. The temptation to add "Uninstall", "Duplicates", "Privacy" is precisely the failure mode the reviews describe.

6. **The claimed savings don't materialise.** Dropbox's own community is full of "set it to online-only and it didn't free up space" ([community](https://community.dropbox.com/en/discussion/655688/setting-folder-to-online-only-doesnt-free-up-local-space)); OneDrive users report the same ([learn.microsoft.com](https://learn.microsoft.com/en-us/answers/questions/3753306/freeing-up-space-in-one-drive-how-long-does-it-tak)). On macOS, DaisyDisk documents that deleting may not free space because APFS snapshots retain it ([DeletingFiles](https://daisydiskapp.com/guide/4/en/DeletingFiles/)). *Design implication:* Dustless already handles this honestly — `freed` is a volume delta and clamps to 0, and the README says so ([README](https://github.com/Dung-L3/dustless)). Keep it, and keep reading `freed` as "what actually happened", never as "what we deleted".

7. **Monetisation pressure and pop-ups.** Avast ships with "**Promotional opt-ins enabled**" ([macworld](https://www.macworld.com/article/673271/best-mac-cleaner-tested-compared.html)); Intego Washing Machine cons list "**Annoying pop-ups**" ([macworld](https://www.macworld.com/article/673271/best-mac-cleaner-tested-compared.html)); there's an entire Reddit thread on MacPaw's "lifetime" licensing ([thread](https://www.reddit.com/r/MacOS/comments/1h3puft/beware_of_macpaws_lifetime_scam_with_cleanmymac/)). *Design implication:* free, no account, no upsell surface. R7.

8. **The reporting you get is the reporting you want.** Multiple reviews single out missing or vague scheduling (Gemini "Needs a scheduling feature", OnyX "Scheduling feature… only function around specific days, hours, and minutes") and missing filters making sorting "tedious" (Gemini) — all [macworld](https://www.macworld.com/article/673271/best-mac-cleaner-tested-compared.html). *Design implication:* if you show 26 rule groups, sorting and filtering are load-bearing, not polish.

---

## 5. Screenshot descriptions — main screen, per app

Reconstructed from the cited documentation and review screenshots. Directions are relative to the window.

### CleanMyMac (Smart Care results)
- **Left:** narrow vertical sidebar, five unlabelled module icons top to bottom — Cleanup, Protection, Performance, Applications, My Clutter — tooltips on hover ([macworld](https://www.macworld.com/article/1993544/how-to-use-cleanmymac-x.html)).
- **Top-left of the content area:** a `Start Over` link, which prompts for confirmation before returning to the start screen ([Smart Care](https://macpaw.com/support/cleanmymac/knowledgebase/smart-care)).
- **Top-right:** a `Scan` button to begin ([Smart Care](https://macpaw.com/support/cleanmymac/knowledgebase/smart-care)).
- **Middle:** five equal **tiles**, one per module, arranged in a row/grid. Each tile carries a number (bytes reclaimable / threats found / maintenance tasks / app updates / duplicate files), a checkmark control in its **top-left corner** to include or skip that task, and two actions: `Review` (open detail) and a per-tile `Clean`/`Run` ([Smart Care](https://macpaw.com/support/cleanmymac/knowledgebase/smart-care)).
- **Bottom:** a single `Run` button that executes all selected tasks ([Smart Care](https://macpaw.com/support/cleanmymac/knowledgebase/smart-care)).
- **Module screen (Cleanup)** replaces the tiles with one tile per tool — System Junk, Trash Bins, Old Binaries, Logs — each again `Clean` + `Review` ([macworld](https://www.macworld.com/article/1993544/how-to-use-cleanmymac-x.html)).
- **Vibe:** rounded cards on a light gradient; green accent; generous padding. High polish, low density.

### DaisyDisk (disk overview)
- **Whole window:** a vertically scrolling list of mounted volumes, startup disk at the top ([DisksOverview](https://daisydiskapp.com/guide/4/en/DisksOverview/)).
- **Each row:** left = disk/folder name and its icon (click the icon to **star** the folder so it persists across launches); right = a **horizontal free-space gauge** plus a number below it showing space left, with used space in the tooltip ([DisksOverview](https://daisydiskapp.com/guide/4/en/DisksOverview/)).
- **Colour:** gauge is **green** when ≥ half the disk is empty, **red** when the disk is nearly full — the severity signal is the only colour on screen ([DisksOverview](https://daisydiskapp.com/guide/4/en/DisksOverview/)).
- **Action:** a `Scan` button next to each gauge; `Scan Folder…` for a single folder; drag-and-drop a disk or folder from Finder onto the window works too ([DisksOverview](https://daisydiskapp.com/guide/4/en/DisksOverview/)).
- **After scanning:** the window becomes a full-bleed **sunburst** of coloured "petals", one ring per directory level, area proportional to size. Selecting a petal opens a **right-hand sidebar** with Quick Look preview and details ([DeletingFiles](https://daisydiskapp.com/guide/4/en/DeletingFiles/); [Tips](https://daisydiskapp.com/guide/2/en/TipsAndTricks/)).
- **Bottom edge:** the **Collector** — a horizontal tray spanning the window's width. Drop petals in; they stack there intact. An `×` appears next to each name to pull one back out; clicking the tray expands it into a full list ([DeletingFiles](https://daisydiskapp.com/guide/4/en/DeletingFiles/)).
- **Bottom-right of the Collector:** the `Delete` button. Pressing it starts a **5-second countdown** with a `Cancel` ([DeletingFiles](https://daisydiskapp.com/guide/4/en/DeletingFiles/)).

### AppCleaner
- **Whole window:** nothing but a large empty drop area. The entire UI is drag-and-drop.
- **Empty state:** no list, no buttons, no sidebar. FreeMacSoft describes exactly one action: "Simply drop an application onto the AppCleaner window" ([FreeMacSoft](https://freemacsoft.net/appcleaner/)).
- **After dropping an app:** a **flat list of every file associated with that app**, one row per path, each with a **checkbox on the left**. No groups, no sizes emphasised, no icons beyond the default list row ([apeaksoft](https://www.apeaksoft.com/clear-data/appcleaner-review/)).
- **Action:** a single `Remove` button. Confirming prompts for **macOS username and password** ([apeaksoft](https://www.apeaksoft.com/clear-data/appcleaner-review/)).
- **After removal:** returns to the same empty drop area, ready for the next app ([apeaksoft](https://www.apeaksoft.com/clear-data/appcleaner-review/)).
- **Vibe:** stock macOS list styling, system font, no branding, no colour. The absence of design *is* the design.

### CCleaner (Windows)
- **Left:** a vertical sidebar of module entries — Quick Clean, Clean Clutter, Clean Browser, Find Duplicates, Analyze Photos, Uninstall Apps, Startup Manager, System Monitor — plus storage statistics ([macworld](https://www.macworld.com/article/673271/best-mac-cleaner-tested-compared.html)).
- **Middle:** the selected module's result as a **checkbox list**, one row per item, with a running total of bytes selected.
- **Top:** a header carrying the health/score area and the primary action button for the module.
- **Density:** high; macworld calls it "clunky and dated… less polished than competitors… not for beginners" ([macworld](https://www.macworld.com/article/673271/best-mac-cleaner-tested-compared.html)).
- **Visual language:** Windows-native chrome — `Segoe UI`, Win32 controls, checkboxes as the primary interaction idiom.

### Windows Disk Cleanup (`cleanmgr`)
- **Whole window:** a single dialog. A short instruction line at the top ("Drive: C: has been scanned…" style), then the list.
- **Middle:** a flat **checkbox list of file categories** — Temporary Internet Files, Downloaded Program Files, Temporary files, Thumbnails, Recycle Bin, Windows Error Reports, DirectX Shader Cache, Delivery Optimization Files ([HP](https://www.hp.com/us-en/tech-takes/software/how-to/how-to-use-disk-cleanup-windows-10.html)).
- **Bottom-left:** a `Clean up system files` button. Pressing it triggers a **second, deeper scan** and reveals additional categories (Windows Update Cleanup, Previous Windows installations, Windows upgrade log files) after a UAC prompt ([helpdeskgeek](https://helpdeskgeek.com/how-to-run-disk-cleanup-windows-10-11/)).
- **Bottom of the list area:** a description pane — hovering any category prints its explanation **below the list**, not in a tooltip ([helpdeskgeek](https://helpdeskgeek.com/how-to-run-disk-cleanup-windows-10-11/)).
- **Bottom-right:** `OK`, which then prompts `Delete Files` as a second confirmation ([helpdeskgeek](https://helpdeskgeek.com/how-to-run-disk-cleanup-windows-10-11/)).
- **Severity signalling:** none per-item. Risk is communicated only in prose — the docs warn that removing Previous Windows installations kills your rollback ability ([MS](https://support.microsoft.com/en-us/windows/experience/storage-filemanagement/manage-drive-space-with-storage-sense)).

### Storage Sense (Windows 11)
- **Location:** Settings → System → Storage → Storage Sense. A sub-page, not an app.
- **Top:** a single **toggle** labelled `Storage Sense`, set to On/Off.
- **Body:** a flat list of settings, each a labelled dropdown of time thresholds — `Run Storage Sense` (every day / week / month / during low free disk space), `Delete files in my recycle bin if they have been there for over:`, `Delete files in your Downloads folder if they haven't been opened for more than:`, `Content will become online-only if not opened for more than:` ([MS](https://support.microsoft.com/en-us/windows/experience/storage-filemanagement/manage-drive-space-with-storage-sense)).
- **There is no result screen, no item list, and no confirm button.** The cloud section only appears when signed in.
- **Severity signalling:** on the parent Storage page, the capacity bar **turns red** when low — and that red bar is also what Storage Sense uses as its trigger ([MS](https://support.microsoft.com/en-us/windows/experience/storage-filemanagement/manage-drive-space-with-storage-sense)).
- **Related:** the sibling **Cleanup recommendations** page is the manual counterpart and does show per-category rows with a `Clean up` button each ([MS](https://support.microsoft.com/en-us/windows/experience/storage-filemanagement/free-up-drive-space-in-windows)).

### Google One storage manager
- **Top:** a banner stating how much storage you need to clear to continue the service — shown **only when over quota** ([Google One](https://support.google.com/googleone/answer/9312312?hl=en)).
- **Left of the banner:** a `Usage details` disclosure, expanding to show per-service usage.
- **Body:** grouped by service — **Google Photos, Google Drive, Gmail, Trash** — under a `Clean up by service` heading.
- **Each item row:** thumbnail and name; the deletion affordance is a **swipe gesture** — swipe right to mark for deletion, swipe left to keep. This is mobile; on desktop it is checkbox selection ([Google One](https://support.google.com/googleone/answer/9312312?hl=en)).
- **Top-right:** a `Review` button, which is the review step, and only then `Delete` / `Move to trash`.
- **Notable:** the flow is gated on being over quota — an under-quota user is never shown the cleanup surface at all.

### OneDrive Files On-Demand (in Explorer)
- **Not a screen** — it is a per-file icon and a context-menu item.
- **Row states in File Explorer:** a **blue cloud icon** = online-only (no local space); a **green tick** = locally available (downloaded, takes space); a **green circle with white check** = always keep on this device ([MS](https://support.microsoft.com/en-us/onedrive/save-disk-space-with-onedrive-files-on-demand-for-windows)).
- **Action:** right-click → `Free up space` or `Always keep on this device` ([MS](https://support.microsoft.com/en-us/onedrive/save-disk-space-with-onedrive-files-on-demand-for-windows)).

### Dropbox (Manage hard drive space)
- **Reached from:** menubar/account icon → `Sync & storage` → `Available offline files` → `Manage hard drive space` ([Dropbox](https://help.dropbox.com/sync/make-files-online-only)).
- **Body:** a **sortable list of files** — sortable by size and by date last modified — each with a **checkbox on the left**.
- **Action:** a `Move to online-only` button. On completion a confirmation message states **how much storage was freed**, and the moved files are removed from the suggested list ([Dropbox](https://help.dropbox.com/sync/make-files-online-only)).
- **Also available:** right-click any file in the Finder Dropbox folder → `Make online-only`; and a global default under Preferences → Sync → `Default sync preference` = `Online-only` ([Dropbox](https://help.dropbox.com/sync/make-files-online-only)).

---

## 6. Could not verify

1. **BuhoCleaner's exact top-level navigation.** Every source describes a "Smart Scan" action and a set of modules (junk, large files, duplicates, startup, purgeable space — [nektony](https://nektony.com/reviews/best-mac-cleaning-software)) but I could not load the vendor's own product page or a screenshot with readable nav labels. **Not confirmed:** the literal sidebar item names, whether there is a sidebar at all, its deletion confirmation flow, and its safety/undo affordances. Treat the BuhoCleaner column as indicative only.
2. **CCleaner's current (v7) sidebar labels.** `ccleaner.com` returned 403 and the support site returned a CSS error to every fetch attempt. The module list above is the **Mac** edition as described by Macworld ([macworld](https://www.macworld.com/article/673271/best-mac-cleaner-tested-compared.html)); I did not verify the Windows edition's current labels, and beta coverage of a "CCleaner 7 redesign" ([betanews](https://betanews.com/article/ccleaner-7-debuts-with-redesigned-interface-and-smarter-cleanup-tools/)) also returned 403. The claim "CCleaner 7 debuts with redesigned interface" is **unverified** — I could only see the headline and slug.
3. **Exact installer sizes.** CleanMyMac's "320 MB" is MacPaw's own system-requirements figure ([macpaw](https://macpaw.com/cleanmymac)), not an independently measured download. CCleaner's ~16 MB portable is from a third-party download site ([askvg](https://www.askvg.com/download-ccleaner-slim-installer-and-portable-version/)). No measured figures for AppCleaner's .zip, BuhoCleaner's .dmg, or DaisyDisk's .dmg.
4. **CleanMyMac's Cleanup tile names beyond the four I saw.** Macworld names System Junk, Trash Bins, and old binaries/documents ([macworld](https://www.macworld.com/article/1993544/how-to-use-cleanmymac-x.html)); MacPaw's own tool table lists System Junk, Trash Bins, and Mail Attachments under Cleanup ([My Tools](https://macpaw.com/support/cleanmymac/knowledgebase/my-tools)). A fourth tile referred to as "Logs" appears in my research but I could not pin it to a primary source — **treat "Logs" as unverified.**
5. **Whether Storage Sense's self-enabling is on by default.** The docs contain two statements in tension: "Storage Sense is off by default" and "we may turn on Storage Sense to manage select temporary files, then notify you" ([MS](https://support.microsoft.com/en-us/windows/experience/storage-filemanagement/manage-drive-space-with-storage-sense)). Both are quoted above rather than resolved. Note also that `learn.microsoft.com/en-us/windows/configuration/storage/storage-sense` ([docs](https://learn.microsoft.com/en-us/windows/configuration/storage/storage-sense)) says "By default, Storage Sense is enabled" — a third statement, and a different page. **Unresolved conflict.**
6. **AppCleaner and BuhoCleaner background/automation features.** AppCleaner appears to have none; BuhoCleaner is described as having a "handy menu-bar monitor" by a competitor ([nektony](https://nektony.com/reviews/buhocleaner-vs-maccleaner-pro)) — a vendor-competitor claim I did not confirm from BuhoCleaner itself.
7. **The macOS TCC / Full Disk Access trap's prevalence.** Dustless's README documents that a missing Full Disk Access grant makes `~/Library/Caches` look *smaller*, so caches vanish from scan results entirely. Multiple third-party apps hit the same wall ([DaisyDisk](https://daisydiskapp.com/guide/4/en/FullDiskAccess/), [drbuho](https://www.drbuho.com/review/daisydisk-review)), but I found no source quantifying how often users misdiagnose this. Worth treating as a real support burden regardless — `doctor` already detects it.
