---
title: Ideas
description: Ideas for future features and improvements.
---

Photo Export is intentionally focused. Below are ideas we're considering that would improve reliability, usability, and media support without turning the app into something larger than it needs to be. None of these are committed to a timeline.

## Recently shipped

- **Separate videos into a subfolder** — opt-in via Settings → Advanced → Organization → _Separate videos into a subfolder_. When on, standalone videos land in a `videos/` subfolder inside their placement (e.g. `2026/03/IMG_0001.JPG` next to `2026/03/videos/IMG_0002.MOV`) so a backup browser doesn't have to scroll past every video to find the photos. The paired video of a Live Photo stays next to its still — splitting the pair across folders would break on-disk Live Photo recognition. Default off. Applies to new exports only; videos already on disk stay where they are.
- **Live Photos** — opt-in via Settings → Advanced → _Export Live Photos as paired image + video_. When on, the paired video is written next to the still (e.g. `IMG_0001.HEIC` + `IMG_0001.MOV`) using whatever extension casing PhotoKit reports for that resource — typically `.MOV` on Apple hardware. Edited Live Photos write the rendered pair; with **Include originals** also on, `_orig` companions land alongside. Default off because Live Photo paired videos are typically 1–3 MB each and would roughly double disk usage for Live-Photo-heavy libraries. iCloud Shared Album Live Photos remain still-only — Apple doesn't expose their paired video.
- **Auto Export** — automatically back up new photos as they appear in Apple Photos, with per-scope (Timeline / Favorites / Albums) selection, retry-with-backoff for transient failures, and an Export Issues view for what didn't go through. See the [Auto Export guide](/photo-export/auto-export/).
- **Retry failed exports** — failures with matching Auto Export retry history can offer a per-row **Retry** button while Auto Export is enabled and destination records are ready. Other failures can be retried by starting a manual export. Transient Auto Export failures also retry automatically with backoff. See [failed exports and retry](/photo-export/auto-export/#failed-exports-and-retry).
- **Live library updates** — Photos changes refresh sidebar counts and the visible grid automatically. The grid updates in place, preserving a surviving selection; edits refresh thumbnails and the selected preview. See [library browsing](/photo-export/features/#library-browsing).

## Usability

- **Media filtering** — filter the library view by photos, videos, or both
- **Manual library refresh** — add an on-demand rescan control alongside the automatic updates already available
- **Search and filter** — find assets by name or date within the browser
- **Accessibility and polish** — broader VoiceOver coverage beyond the Auto Export status pill, and onboarding refinements
- **Ignore action in Export Issues** — suppress a known-unrecoverable failure (alongside the existing Retry action) so the list stays focused on what's actionable
- **Completion / failure notifications** — opt-in macOS notifications when an Auto Export run finishes or fails, plus a Dock badge for unresolved issues

## Reliability and performance

- **Concurrent export queue** — export multiple assets in parallel for faster throughput
- **Preflight destination checks** — verify permissions, mount status, and available space before starting
- **Stronger crash-resume** — more resilient recovery for long-running export sessions
- **Persistent month-level caching** — speed up sidebar loading for larger libraries

## Media support

- **iCloud originals** — detect remote-only assets and let users choose to download or skip
- **Metadata sidecars** — optionally export metadata alongside media files

## Bigger ideas

- **Flexible naming schemes** — configurable folder structures beyond year/month
- **SQLite-backed records** — replace JSONL storage if it becomes a bottleneck at scale
- **Multiple destinations** — export to more than one location with independent tracking
- **Localization** — support languages beyond English

Have an idea? [Open an issue on GitHub.](https://github.com/valtteriluomapareto/photo-export/issues)
