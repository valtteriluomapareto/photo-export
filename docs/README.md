# Documentation Guide

This is the canonical map of where documentation lives in this repository. Other docs (root `README.md`, `CONTRIBUTING.md`, `AGENTS.md`) link here rather than restating the layout.

## Where docs live

| Audience | Location | Purpose |
| --- | --- | --- |
| End users | [`website/src/content/docs/`](../website/src/content/docs/) | Published to the project website. Install steps, feature explanations, roadmap. |
| Contributors | [`README.md`](../README.md), [`CONTRIBUTING.md`](../CONTRIBUTING.md) | Repo overview, build/test, contribution workflow. |
| AI agents | [`AGENTS.md`](../AGENTS.md) | Architecture, conventions, command reference. Tool-specific files (`CLAUDE.md`) are stubs that point here. |
| Maintainers | [`docs/project/`](project/) | Plans, release process, manual test guides. Decision records live in `archive/`. |
| Reference | [`docs/reference/`](reference/) | Long-lived material: best practices, persistence format, competitor research. |

## What to update when behavior changes

When a change is user-visible, update **both** the root README and the matching website page in the same PR:

| Change touches… | Update this website page | Also update |
| --- | --- | --- |
| Install / first-run / permissions | `getting-started.md` | `README.md` if commands changed |
| Export behavior, toggles, file naming | `features.md` and `export-icloud-photos.md` | `README.md` "Current Capabilities" |
| App architecture (managers, protocols, conventions) | `architecture.md` | `AGENTS.md` |
| Future work, scope changes | `roadmap.md` | — (roadmap is website-only) |
| Build, test, or release commands | — | `README.md`, `CONTRIBUTING.md`, `AGENTS.md` as applicable |

## Maintainer notes — active

Current process and open work:

- [`project/implementation-tasks.md`](project/implementation-tasks.md) — open work items
- [`project/release-process.md`](project/release-process.md) — how to cut a release (version bump, tag, publish)
- [`project/import-existing-backup-plan.md`](project/import-existing-backup-plan.md) — backup-import design notes (Phase 1 implemented)
- [`project/testing-improvement-plan.md`](project/testing-improvement-plan.md) — test coverage gaps and improvement plan
- [`project/edited-photos-manual-testing-guide.md`](project/edited-photos-manual-testing-guide.md) — manual test script for the edited-photos export modes
- [`project/plans/auto-sync-background-sync-plan.md`](project/plans/auto-sync-background-sync-plan.md) — proposed auto-sync and background-sync implementation
- [`project/plans/collections-export-plan.md`](project/plans/collections-export-plan.md) — proposed Favorites and Albums export implementation
- [`project/plans/screenshot-automation-plan.md`](project/plans/screenshot-automation-plan.md) — proposed automated App Store / website screenshot capture using a synthetic Photos library

## Maintainer notes — archive

Completed or superseded plans, kept as decision records:

- [`project/archive/app-store-plan.md`](project/archive/app-store-plan.md) — pre-launch Mac App Store plan (launched April 2026)
- [`project/archive/app-store-ci-plan.md`](project/archive/app-store-ci-plan.md) — App Store CI workflow plan
- [`project/archive/github-actions-publishing-plan.md`](project/archive/github-actions-publishing-plan.md) — direct-distribution release workflow plan
- [`project/archive/refactoring-plan.md`](project/archive/refactoring-plan.md) — refactoring decisions (Phases 1–4 complete)
- [`project/archive/support-edited-photos-export-plan.md`](project/archive/support-edited-photos-export-plan.md) — original three-mode edited-photos design (superseded)
- [`project/archive/edited-photos-p2-followups-plan.md`](project/archive/edited-photos-p2-followups-plan.md) — P2 polish layer on top of the original design (superseded)
- [`project/archive/edited-photos-modes-redesign-plan.md`](project/archive/edited-photos-modes-redesign-plan.md) — current two-mode redesign (shipped in 1.1.0)

## Reference material

- [`reference/swift-swiftui-best-practices.md`](reference/swift-swiftui-best-practices.md) — architecture and implementation guidance
- [`reference/persistence-store.md`](reference/persistence-store.md) — export record persistence format and behavior
- [`reference/competitors.md`](reference/competitors.md) — competitor app research for the comparison page

## Maintenance rules

- Prefer descriptive file names over generic names like `plan.md`.
- Move shipped or superseded plans into `project/archive/` and update the status header so it reads as a decision record.
- Keep this index in sync when adding, archiving, or removing plans — it is referenced from `AGENTS.md` and `CONTRIBUTING.md`.
- Future enhancements and roadmap live on the [project website](../website/src/content/docs/roadmap.md). Do not duplicate roadmap content here.
