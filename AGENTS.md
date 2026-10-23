# AGENTS.md

Guidance for AI coding agents working in this repository. Contributor workflow and
commands live in [`CONTRIBUTING.md`](CONTRIBUTING.md); the documentation map lives in
[`docs/README.md`](docs/README.md). Tool-specific files such as `CLAUDE.md` point here.

## Project Overview

macOS SwiftUI app that exports the Apple Photos library to local or external storage
in an organized folder hierarchy. Uses system frameworks only. Targets macOS 15;
CI and releases use the Xcode version in [`.xcode-version`](.xcode-version).

## Build & Test Commands

Use the commands and pinned tool setup in
[`CONTRIBUTING.md` → Local Setup](CONTRIBUTING.md#local-setup), including build, tests,
strict lint/format checks and the Debug onboarding preview. CI's Debug build treats
Swift compiler warnings as errors; that command is documented there too.

## Architecture

The contributor-facing role map, composition, data flow and module responsibilities
live in [`docs/reference/architecture-conventions.md`](docs/reference/architecture-conventions.md).
Read it before changing `ExportManager`, the queue, record stores or anything AutoSync
observes. Classify new code by the responsibilities in that reference, and use the
protocol seams when touching Photos, the filesystem or the export destination.

## Design Decisions Worth Knowing

Read the [design rationale](docs/reference/architecture-conventions.md#design-rationale)
for the two stores, selection/query boundary and edited-resource dispatch. The same
reference owns the [preview content
contract](docs/reference/architecture-conventions.md#preview-content-ownership),
[actor isolation policy](docs/reference/architecture-conventions.md#2-actor-isolation-policy)
and [destination identity
contract](docs/reference/architecture-conventions.md#destination-identity).

## Cross-Cutting Contracts

The canonical [architecture
reference](docs/reference/architecture-conventions.md#cross-cutting-contracts)
owns cancellation, actor isolation and AutoSync seam rules, plus the Host and forwarder
patterns. Follow its extension recipes rather than copying orchestration into views
or adding method bodies to `ExportManager+AutoSyncConformance.swift`.

The behavioral regression gates are the same in this guide, `CONTRIBUTING.md`, and the canonical
reference:

- `AutoSyncSeamCharacterizationTests`
- `AutoSyncSeamCharacterizationTests.autoSyncRunYieldsCanonicalSequence`
- `AutoSyncSeamCharacterizationTests.manualExportSupersedingAutoSyncYieldsCanonicalSequence`
- `ExportQueueStateSnapshotTests.teardownQueue_synchronouslyClearsManagerMirrors`
- `ExportQueueStateSnapshotTests.pauseResumeCancelStateSnapshot_canonicalTransitions`
- `ScreenshotPhotoLibraryServiceOverridesTests`
- `ImportIdempotencyTests`
- `ExportManagerRunExportTests.autoSyncRunFilterAlreadyExportedBeforeRetryCheck`
- `AmbiguousSameFolderTests.sameFolderForUnclearPickHoldsAutoExportUntilHistoryCheckEnds`
- `PublisherParityTests`
- `CollectionBackupImportTests.importAdoptsAlbumHistorySoExportsWriteNothing`
- `CollectionBackupImportTests.exportWipeImportRoundTripRestoresPlacements`
- `FileIOServiceTests.existingFileAtCommitIsNeverReplaced`
- `IdenticalFileAdoptionTests.lostRecordIdenticalFileIsAdopted`
- `IdenticalFileAdoptionTests.identicalAssetsKeepDistinctFilesAfterRecordLoss`
- `IdenticalFileAdoptionTests.missingFileReturnsAfterReconcile`

Run these without re-recording unless the new behavior has been explicitly audited. They are listed
once in `scripts/ci/regression-gates.txt`, which also pins containing-suite declarations to support
method-level gates; those pins are not additional behavioral gates. CI checks that this list names
every gate in the file and that every gate ran and passed.

## Documentation Layout

Use [`docs/README.md`](docs/README.md) to find the appropriate document. When changing
user-visible behavior, update the root README and the matching website page identified
in its ownership table. Keep the roadmap on the website.

## Workflow

Follow the [contributor PR workflow](CONTRIBUTING.md#pull-requests) for every PR unless
the user explicitly requests a different flow. It covers the issue plan, the three
reviewer roles, tests before production changes, the same reviewers' implementation
review, and merging only after CI passes for the current head. That workflow authorizes
the merge; do not ask for another confirmation unless an applicable approval rule
requires it.

A size-S PR whose sole purpose is performance, with behavior otherwise unchanged,
may use one Pragmatic Developer reviewer if count tests and existing regression gates
guard it and it changes no regression gate, existing parity row, persisted format,
never-overwrite rule, or filename-claim rule. That reviewer checks whether it works,
whether the gates and stated budgets pass, and whether it adds unnecessary complexity
or scope. The issue's recorded decisions serve as the plan; no separate plan review
is needed. Meaningful tests before production changes, resolved findings, recorded
review outcomes, and current-head green CI still apply. Explicit issue-level reviewer
or plan-first requirements take precedence. All other PRs retain the three-role flow.

If reviewer agents are unavailable, report that limitation instead of presenting
self-review as the requested independent review.

For releases, follow the [release process](docs/project/release-process.md) and its
candidate Photos validation requirements before creating and pushing a tag.

### Delegating to opencode / Kimi K2.6 (scout model)

The [opencode skill](.claude/skills/opencode/SKILL.md) owns model selection, suitable
scouting tasks, verification requirements and execution instructions. Read it when
using that tool.

## Key Conventions

The [development expectations](CONTRIBUTING.md#development-expectations) and
[Swift/SwiftUI guide](docs/reference/swift-swiftui-best-practices.md) own the general
coding conventions. In particular, keep Photos access read-only, track assets by
`PHAsset.localIdentifier`, and preserve the final commit's existing-file protections.
Use the architecture reference for the precise contracts and their documented limits.

Lint thresholds and exclusions live in [`.swiftlint.yml`](.swiftlint.yml); formatter
settings live in [`.swift-format.json`](.swift-format.json). Use the strict commands
from CONTRIBUTING, passing the formatter configuration explicitly.
