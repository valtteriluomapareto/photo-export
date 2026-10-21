# Edited Photos Export — P2 UX Follow-ups

Date: 2026-04-25
Parent: `docs/project/support-edited-photos-export-plan.md`
Issue: https://github.com/valtteriluomapareto/photo-export/issues/13
PR: https://github.com/valtteriluomapareto/photo-export/pull/14

> **Status:** Implemented. All five P2 items shipped on the
> `issue-13-support-exporting-edited-photos` branch in commits following
> the design pass; see **Implementation status** below for file:line
> pointers and the post-implementation Codex review notes. The mode-specific
> design was later superseded by the
> [two-mode redesign](edited-photos-modes-redesign-plan.md); this is a historical
> implementation record.

## Implementation status

All five items landed. The post-implementation Codex review surfaced one
additional issue under #2 — `editedOnly` over a scope with no adjusted
assets was conflated with "already exported." Fixed before the commit by
introducing an `EnqueueOutcome` discriminated union so the toolbar can
say "no edited versions to export" distinct from "already exported."

| # | Status | Pointers |
|---|---|---|
| #1 | **Implemented** | `ExportToolbarView.swift` `progressIndicator` + `progressCountTooltip` |
| #2 | **Implemented** | `ExportManager.swift` `EnqueueOutcome` / `noApplicableCopy` + toolbar slot in `ExportToolbarView.swift`; clearing rules wired through `versionSelection` `didSet`, `cancelAndClear`, and every `startExport*` |
| #3 | **Implemented** | `ContentView.swift` `YearRow.completionBadge` / `MonthRow` mode-qualified rendering + `yearTotal` returns `Int?` to suppress the year badge while adjusted counts are still loading |
| #4 | **Implemented** | `ExportRecord.swift` `ExportVariantRecovery` enum with `editedResourceUnavailableMessage`, `isRecoverable`, `friendlyCopy`; `AssetDetailView.swift` renders the friendly copy in `.secondary` for known recoverable cases |
| #5 | **Implemented** | `ThumbnailView.swift` composed `accessibilityLabel`, `.contain` element, `.isButton` / `.isSelected` traits, macOS-neutral hint, `accessibilityHidden(true)` on decorative children |

Tests: 17 new test cases across `ExportVariantRecoveryTests`,
`EmptyRunMessageTests`, and the existing pipeline suites, all passing
(152 tests total).

## Context

Two Codex review passes on PR #14 surfaced five **P2** items that remained
unaddressed when the feature merged. Each is a polish/clarity issue rather than
a correctness or accessibility blocker. This document scopes the options for
each, picks a recommended approach, and flags the tradeoffs we want a second
opinion on before any of these are implemented.

The constraints we want to preserve from the parent plan:

- Progress and completion are **asset-based**, not file-based.
- Sidebar summaries for selections that need adjusted counts are **approximate**
  on purpose — recomputed from records, not cached separately.
- The store and pipeline contracts (record schema, error strings, mark APIs)
  are already shipped and have tests behind them. Where possible, P2 fixes
  should live in the view layer and not change the persisted contract.

## P2 #1 — Asset-based progress is under-labeled

**Current behavior.** `ExportToolbarView` shows `\(done)/\(total)` from
`totalJobsCompleted` / `totalJobsEnqueued`. In `originalAndEdited`, each
asset writes up to two files but counts once. A user watching the
destination directory will see six files appear while the toolbar reads
`3/10`.

**Options.**

- **A. Suffix with the unit ("3/10 assets")** — change the toolbar label
  text, no state change. Reads naturally; the unit is implicit but at least
  spelled out. Minimum diff.
- **B. Track and surface files written ("3/10 assets · 6 files")** — add
  `@Published private(set) var totalFilesWritten: Int` to `ExportManager`,
  increment in `markVariantExported` call sites. Show the file count as a
  secondary line under the asset count. Most informative.
- **C. Switch the primary number to file-based** — biggest change; couples
  toolbar progress to a different mental model than sidebar progress
  (which is asset-based). Likely to confuse users who already understand
  the existing UI.
- **D. Mode-aware label** — show "3/10 assets" only when
  `versionSelection == .originalAndEdited`; keep the bare number in
  single-variant modes. Reduces clutter for the default case but adds
  conditional rendering branching.

**Recommendation: A**, with the asset-count label always shown. We leave
file count for a future iteration if users still report confusion. Cheap,
doesn't grow surface area.

**Open question for review.** Is option B worth the extra publisher and
the very small risk of double-counts (e.g. an `_edited` write that fails
the move and gets re-attempted)? My read is no — A is enough.

**Final recommendation (post-Codex).** Keep A. Add a tooltip on the
toolbar count saying _"Asset count. The current filename below may be
either the original or the edited file for this asset."_ — covers the
"why doesn't this match the file count?" question without adding a
publisher. Codex pointed out that B's "file written" semantic is
slipperier than it looks (temp write vs atomic move vs record mark vs
retry-after-failed-move) and not worth defining for cosmetic UI.
Note the existing 60 pt count `Text` frame in
`ExportToolbarView.swift:166` may need widening to fit
"3/10 assets".

## P2 #2 — `Export All` is silent when nothing is left to do

**Current behavior.** A user with a fully exported library who clicks
**Export All** sees `startExportAll()` enqueue zero jobs;
`totalJobsEnqueued` stays at 0; the progress indicator stays hidden
because `hasProgress = total > 0`. The button looks like it did nothing.

**Options.**

- **A. Transient inline message in the progress slot** — when an
  `Export All` (or month/year) run completes with 0 jobs enqueued, set a
  short-lived `@Published var emptyRunMessage: String?` (e.g. "Everything
  in this destination is already exported"). Show it in the same toolbar
  area as the progress bar; clear after ~6 s or on the next click.
  No alerts, no sheets, no modal interruption.
- **B. Alert on empty Export All** — `.alert(...)` with the message. More
  intrusive than warranted for a routine click; we'd be training users to
  dismiss alerts.
- **C. Eagerly disable Export All when nothing is pending** — needs
  a "do I have any unexported asset across the whole library" check that
  doesn't exist yet. Implementing it correctly under the
  `originalAndEdited` selection would also need adjusted-count totals
  loaded for every year. Expensive; spreads complexity for a small win.
- **D. Persistent "✓ Up to date" pill** — shown when no queue is active
  and the most recent Export All produced no work. Information-rich, but
  the "status" is harder to keep in sync (especially if records get
  bulk-imported, the destination changes, or new Photos arrive).

**Recommendation: A**. Smallest UI change, no new heuristics, and it
addresses the precise complaint ("the click looked dead"). We can revisit
D later as a polish layer if A proves insufficient.

**Open question for review.** Is the message-in-progress-slot composition
visually OK alongside an empty progress bar, or does it need its own
small banner row outside the toolbar? I think the toolbar slot is fine
because the bar is hidden when there is no progress — but I'd like a
second eye on this.

**Final recommendation (post-Codex).** Keep A, but with three precisions:

1. **Replace** the entire progress HStack contents with the message
   when there's no active work; do not render an empty bar plus the
   message. The progress view is already conditioned on
   `hasProgress = total > 0`
   (`ExportToolbarView.swift:156`), so this is a small structural
   tweak.
2. **Scope-specific copy.** A user clicking "Export Month" who gets a
   library-wide message will feel mismatched. Three messages:
   - `"This month is already exported."`
   - `"This year is already exported."`
   - `"Everything in this destination is already exported."`
   The triggering call (`startExportMonth/Year/All`) sets a tagged
   message; the toolbar renders whichever applies.
3. **Clearing rules.** Clear `emptyRunMessage` on: any new
   `startExport*` call, destination change, version selection change,
   `cancelAndClear`, or after ~6 s. Otherwise the "already exported"
   text can persist past a destination switch and confuse the user.

Codex also flagged that `startExportAll()` enumerates years
asynchronously before deciding nothing is left, so the message will
land a moment after the click. That's acceptable — set the message at
the end of the enqueue scan, no special UI needed.

## P2 #3 — `editedOnly` sidebar can show "100% / ✓" while most of the library is unexported

**Current behavior.** Under `editedOnly`, `YearRow.yearTotal` sums adjusted
counts. A year with 10 000 photos and 50 edits, all 50 exported, renders
the green seal. Codex flagged this as misleading — strictly correct under
the mode's definition, but the icon implies "year fully backed up".

**Options.**

- **A. Tooltip on year/month rows** — `.help(...)` describing the count
  shape under the active selection, e.g. "Edited versions: 50 of 50
  exported. 9 950 unedited assets are not part of this selection." Solves
  it for users who hover but is invisible by default.
- **B. Inline mode tag next to the badge** — show a small `(edited)` next
  to the percent or check when the active selection is `editedOnly`. Same
  for `(originals + edited)` etc. Visible at a glance, mildly noisy.
- **C. Sidebar header banner** — a single `Text("Showing edited versions")`
  above the list that adopts the active selection. Sets context once;
  doesn't disambiguate per-row badges if user scrolls a long list and the
  banner falls offscreen.
- **D. Distinct icon per mode** — replace `checkmark.seal.fill` with
  `wand.and.stars` (or similar) under `editedOnly`. Distinctive but adds
  icon vocabulary without obvious payoff.

**Recommendation: A + C.** Tooltips are cheap and load-bearing for power
users who want detail. The sidebar header banner is a one-line change
that sets context for everyone without being noisy. Inline `(edited)`
labels (B) are more visually intrusive for a permanent state and we can
add them in a future polish if A + C is not enough.

**Open question for review.** Is C worth doing alone if it can scroll
offscreen? Or is the per-row tooltip strong enough on its own? Codex's
take here would be useful.

**Final recommendation (post-Codex).** **Switch to A + a restrained B**,
not A + C. Codex's argument: the misleading signal lives on the row
itself (the same green seal means two different things depending on
selection), so the per-row badge is what needs to change. A header
banner can scroll offscreen and a tooltip is invisible until hover.

Concrete shape:

- In `editedOnly`, render the row's count as `"50/50 edited"` and the
  full-completion icon paired with a small `"edited"` text suffix or a
  modified glyph (e.g. `checkmark.seal.fill` + caption `edited`). Same
  treatment in `originalAndEdited` would be over-decoration since the
  badge there means "all required variants done" which already covers
  unedited assets — leave that mode unchanged.
- Keep the tooltip from option A as the long-form explanation.

Codex also caught a real bug while reviewing: `YearRow.yearTotal`
under `editedOnly` sums `adjustedCountsByMonth.values` and treats `nil`
as `0` (`ContentView.swift:320`), but adjusted counts load lazily per
month row (`ContentView.swift:76`). On a freshly-opened year, the
denominator is understated, so the badge can briefly show `100%`
even when months haven't reported in. Track this as a related defect:
either suppress year-level completion until *all* twelve months'
adjusted counts have loaded, or change `yearTotal` to return `nil`
(neutral state) when any month is still pending.

## P2 #4 — `"Edited resource unavailable"` reads like a hard, user-fixable failure

**Current behavior.** The pipeline records `.lastError =
"Edited resource unavailable"` for an adjusted asset whose
`.fullSizePhoto` / `.fullSizeVideo` resource cannot be fetched.
`AssetDetailView` renders `"Edited failed: Edited resource unavailable"`
in red. The exporter does enable network access on the resource fetch,
so a future run can succeed; the message doesn't convey that.

**Options.**

- **A. UI-side translation** — recognize the exact `lastError` string in
  `AssetDetailView` and render a softer, retry-aware variant (e.g.
  "Edited version unavailable from Photos. The next export will try
  again.") in `.secondary` color rather than red. Mirrors how we already
  handle `ExportVariantRecovery.interruptedMessage`. Persisted record
  contract unchanged.
- **B. Add a recoverability flag to `ExportVariantRecord`** — schema
  change. Pure-cost: forces a migration test pass we don't need.
- **C. Centralise on a `ExportVariantRecovery` enum of well-known
  recoverable failures** — promote the magic strings into named constants
  used by both pipeline and view. View reads the constant, switches on
  it, picks copy and color. Cleanest, scales for future recoverable
  cases without schema work.

**Recommendation: C.** It promotes the existing `interruptedMessage`
constant into a small enum and treats `"Edited resource unavailable"` as
a second member. View-side rendering picks softer color and clearer copy
based on the enum case. No persistence change.

**Open question for review.** Should we go further and treat *all* `.failed`
edited variants as "will retry"? Pipeline already retries on the next
export run. The downside is hiding genuine permanent failures (e.g.
Photos returns an unhelpful framework error) under "will retry"
optimism. I lean against — keep retry-soft messaging only for the cases
we have explicit names for.

**Final recommendation (post-Codex).** Keep C, with one wording
nuance: avoid implying user action *or* guaranteed recovery. Codex
flagged that "Edited resource unavailable" is sometimes transient (an
iCloud full-size render that hasn't materialised) and sometimes
persistent (PhotoKit just doesn't expose one), so soft styling
shouldn't bury the fact that the edit is still not backed up. Suggested
copy:

> "Edited version was not provided by Photos. Future exports will
> try again."

Render in `.secondary` color (not red), but keep the row visible and
keep the asset's overall completion state as "incomplete in this
selection" (it must not count toward `bothDone` in `sidebarSummary`).

Confirmed: do **not** make all `.failed` edited variants
retry-soft — only the cases we have explicit names for in the
`ExportVariantRecovery` enum.

## P2 #5 — VoiceOver: thumbnail tile is fragmented

**Current behavior.** A `ThumbnailView` contains an image, optional
not-yet-exported dot, optional video badge, and optional selection ring.
With my P1 fix the dot has `.accessibilityLabel("Not yet exported")`,
but VoiceOver still walks the children separately. A user gets
"image, not yet exported, video" as three reads instead of one coherent
"Photo, March 5 2025, not yet exported".

**Options.**

- **A. `.accessibilityElement(children: .combine)`** on the tile —
  SwiftUI default pattern. SwiftUI joins children's labels in document
  order. Minimum diff; relies on existing labels to be readable.
- **B. `.accessibilityElement(children: .ignore)` plus a custom
  `.accessibilityLabel`** — full control, builds a single composed
  string from asset metadata (date, mediaType, exported state, selection
  state). Best UX, more code, more state branches.
- **C. A + an `.accessibilityHint`** — combine children, then add a hint
  describing the action ("Double-tap to view details"). Improves
  discoverability of behaviour.

**Recommendation: B + C.** The composed label is worth the extra few
lines because the natural-order concatenation in A produces awkward
phrasing ("image, not yet exported"). A custom label can read "Photo
from March 5 2025, not yet exported" and feels professional. Adding a
hint is one line of extra code.

**Open question for review.** Is hand-rolling the label worth it given
that asset date formatting is the only nontrivial bit, or is option A
"good enough"? Codex's preference here would be useful — accessibility
expectations vary by app polish level.

**Final recommendation (post-Codex).** B + C remains right, but extend
to **B + C + traits**:

- Compose a single label per tile that includes media kind, date (if
  available), video duration (if applicable), exported state, and
  selection state. Handle nil dates gracefully ("Photo, not yet
  exported").
- Set `.accessibilityAddTraits(.isButton)` so VoiceOver announces it
  as actionable, and `.isSelected` when `isSelected` is true.
- Hint copy must be macOS-neutral: `"Open details"` or `"View asset
  details"` — not `"Double-tap to open"`, which is iOS-touch wording.
- For `.failed` thumbnail state, the existing in-tile **Retry** button
  (`ThumbnailView.swift:40-43`) must not be hidden by an aggressive
  `.accessibilityElement(children: .ignore)`. Either combine children
  *into the label* but keep the button independently accessible, or
  use `.contain` and add a custom action mirroring the button.

## Cross-cutting concerns

- **Related defect found during the Codex review.**
  `YearRow.yearTotal` under `editedOnly` sums
  `adjustedCountsByMonth.values` while adjusted counts load lazily per
  month row, so any not-yet-loaded month contributes `0` to the
  denominator. On a freshly-opened year the year row can flash a
  green seal at "100%" before the months report in. Suppress the
  year-level completion icon until all twelve months' adjusted counts
  have loaded, or treat any `nil` as "not ready" and return a neutral
  state. Worth fixing as part of #3.

- **Tests.** Each item below should land with at least one test.
  - #1: Update `ExportToolbarView` snapshot/test if any; otherwise none
    needed (string-only change).
  - #2: Add a test in `ExportPipelineTests` that `Export All`,
    `Export Year`, and `Export Month` against an already-complete
    library each publish the correct scope-tagged `emptyRunMessage`
    and clear it on the next non-empty enqueue, on destination change,
    on version-selection change, and on `cancelAndClear`.
  - #3: Add a `sidebarSummary` test under `editedOnly` asserting the
    new mode-qualified rendering inputs (e.g. that `monthSummary`
    returns a tagged "edited" status the view can pick up). Add a
    regression test for the `nil`-treated-as-`0` defect on
    `yearTotal`.
  - #4: Add a table-driven `ExportVariantRecoveryTests` case asserting
    the enum maps each recoverable error to the expected UI copy and
    color.
  - #5: Skim `photo-exportUITests/` to see if VoiceOver/accessibility
    tests are set up; otherwise leave manual and document the
    expected VoiceOver readout in code comments.

- **Docs.** Items #2, #3, #4 may want a one-line note in
  `website/src/content/docs/features.md`. None requires changes to the
  parent plan.

- **Terminology hygiene (Codex flag).** As polish accretes around
  versions, copy keeps growing. Stick to **"originals"** and
  **"edited versions"** in user-facing text. Never expose "variant"
  outside code. Resist adding a third axis (file count) unless real
  users repeatedly stumble.

- **Sequencing.** Items are independent. #2 and #3 are highest leverage
  per user-visible weight. #5 is highest accessibility win. #4 is small.
  #1 is a pure label tweak.

## Recommended cuts

If we want a single follow-up commit that addresses the highest-impact
items without growing scope:

| # | Option | Why |
|---|---|---|
| #1 | A + tooltip | Cheap label tweak; tooltip covers "where are the missing files?" |
| #2 | A, scope-tagged + clearing rules | Removes the dead-click; scope copy avoids mismatch |
| #3 | A + restrained B + the `yearTotal` `nil` defect | Per-row qualifier where the misleading signal actually lives, plus a real bug fix |
| #4 | C, with copy that doesn't promise recovery | Reuses the existing recovery enum, no schema work |
| #5 | B + C + traits + retry-button-aware grouping | Composed AX label, button trait, selected trait, macOS-neutral hint |

**Codex's "ship three" pick.** If forced to choose three for a single
follow-up release: **#2, #3, #5**. Defer #1 and #4. Include #1
opportunistically if touching the toolbar anyway (the diff is tiny).
This sequence prioritises clear feedback (#2), correct sidebar
semantics (#3 plus the accidental defect), and the biggest
accessibility win (#5). #4 is small and can ride a later commit.
