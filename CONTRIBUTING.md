# Contributing to Photo Export

Photo Export is a small macOS project. Prefer focused pull requests, clear reasoning, and documentation that stays accurate after the change lands.

## Before You Start

- Search existing issues and pull requests before starting similar work.
- Open an issue or draft pull request before making a large feature or architecture change.
- Keep each pull request scoped to one concern when possible.

## Local Setup

Requirements:

- macOS 15.0+
- Xcode at or above the version in [`.xcode-version`](.xcode-version) (CI and releases use exactly that version)

Open the project:

```bash
open photo-export.xcodeproj
```

Build from the command line:

```bash
xcodebuild \
  -project photo-export.xcodeproj \
  -scheme "photo-export" \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run tests:

```bash
xcodebuild \
  -project photo-export.xcodeproj \
  -scheme "photo-export" \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

CI pins **SwiftLint 0.65.1** and **swift-format 603.0.0** with SHA256-verified downloads. Use those versions for matching strict diagnostics. On macOS15+ arm64 with Command Line Tools installed, the same installer can prepare a local temporary session:

```bash
SWIFT_TOOLS_DIR="$(mktemp -d)"
RUNNER_TEMP="$SWIFT_TOOLS_DIR" GITHUB_PATH="$SWIFT_TOOLS_DIR/paths" bash scripts/ci/install-swift-tools.sh
while IFS= read -r tool_bin; do export PATH="$tool_bin:$PATH"; done < "$SWIFT_TOOLS_DIR/paths"
swiftlint version
swift-format --version
```

The installer checks both hashes and exact versions before publishing paths; it has no Homebrew/latest fallback. Installed binaries remain in the temporary session directory. Other platforms can install the same tagged tools from their upstream sources; the CI installer targets its macOS arm64 image. Update pins/checksums and the installer fixtures deliberately when upgrading. Download provenance is recorded in [`install-swift-tools.sh`](scripts/ci/install-swift-tools.sh).

Run the same enforcing style checks as CI from the repository root:

```bash
swiftlint --strict
swift-format lint --strict --configuration .swift-format.json --recursive photo-export
```

The formatter uses two-space indentation and 100 columns, preserving the style
previously applied by its defaults. `.swift-format.json` must be passed explicitly;
automatic discovery uses a different filename. To apply formatting, run
`swift-format format --configuration .swift-format.json --recursive --in-place photo-export`
and review the diff. The formatter check covers app sources only.

Run all static CI guards and their fixture tests locally:

```bash
scripts/ci/run-guards.sh
```

The runner names every check, continues after independent failures, and returns nonzero
if any check fails. See [the guard guide](scripts/README.md#ci-scripts-scriptsci)
for the inventory. Builds, Swift linters, result-bundle audits and release checks use
their separate commands.

Docs website setup:

```bash
cd website
npm install
npm run dev
```

## Development Expectations

- Keep SwiftUI views thin. Move side effects and business logic into managers or view models.
- Avoid adding runtime dependencies unless there is a clear project-level reason.
- Add or update tests for bug fixes and behavior changes where practical.
- Use `os.Logger` for production logging.
- Preserve the no-overwrite export behavior and the `PHAsset.localIdentifier` tracking model.
- Keep Photos access read-only. Run `scripts/ci/test-guards.sh` and `python3 scripts/ci/check-read-only-photos.py` before changing Photos integration; see [`scripts/README.md`](scripts/README.md) for the guard's scope and limitations.

## Developing new features

The app's export pipeline went through a multi-phase architecture refactor in May 2026 that established three cross-cutting contracts (cancellation, actor isolation, AutoSync seam) plus a Host-protocol pattern for `ExportManager`'s collaborators. Before adding a new export entry point, placement kind, variant, collaborator, or `@Published` property AutoSync should observe:

1. Read [`docs/reference/architecture-conventions.md`](docs/reference/architecture-conventions.md) — the canonical home for the contracts, the canonical `start*` entry-point shape, and the "to add a new X, touch these files" recipes.
2. If your change touches the queue, AutoSync surface, record stores, the final file commit or its name planning, or the screenshot photo library service, the following **regression-gate tests** must pass *without re-recording* unless you have explicitly audited the new behavior:
   - `AutoSyncSeamCharacterizationTests` — pins the AutoSync emission sequence.
   - `AutoSyncSeamCharacterizationTests.autoSyncRunYieldsCanonicalSequence` — pins the AutoSync run's state sequence.
   - `AutoSyncSeamCharacterizationTests.manualExportSupersedingAutoSyncYieldsCanonicalSequence` — pins a manual export superseding an AutoSync run.
   - `ExportQueueStateSnapshotTests.teardownQueue_synchronouslyClearsManagerMirrors` — pins synchronous coordinator→manager mirrors.
   - `ExportQueueStateSnapshotTests.pauseResumeCancelStateSnapshot_canonicalTransitions` — pins toolbar state transitions.
   - `ScreenshotPhotoLibraryServiceOverridesTests` — pins screenshot-mode override coverage.
   - `ImportIdempotencyTests` — pins import idempotency.
   - `ExportManagerRunExportTests.autoSyncRunFilterAlreadyExportedBeforeRetryCheck` — pins the already-exported check before retry eligibility.
   - `AmbiguousSameFolderTests.sameFolderForUnclearPickHoldsAutoExportUntilHistoryCheckEnds` — pins that Auto Export waits for, then runs after, the history check that "Same Folder" starts.
   - `CollectionBackupImportTests.importAdoptsAlbumHistorySoExportsWriteNothing` — pins that exporting albums, shared albums and Favorites again, manually or from Auto Export, after Import Existing Backup writes nothing for files already there, against a no-import control that does write.
   - `CollectionBackupImportTests.exportWipeImportRoundTripRestoresPlacements` — pins that an import restores the album placements an export created, by id and folder, and that the second export writes, copies and moves nothing, under unedited originals, Edited mode, Include Originals, a paired Live Photo and flat videos.
   - `FileIOServiceTests.existingFileAtCommitIsNeverReplaced` — pins that the final commit never replaces a file that appears at the final name, on both commit paths.
   - `IdenticalFileAdoptionTests.lostRecordIdenticalFileIsAdopted` — pins that re-exporting after lost history records an identical existing file instead of writing a ` (1)` copy.
   - `IdenticalFileAdoptionTests.identicalAssetsKeepDistinctFilesAfterRecordLoss` — pins that two byte-identical assets keep one file each after lost history, in either order.
   - `IdenticalFileAdoptionTests.missingFileReturnsAfterReconcile` — pins that a deleted file's name stays reserved for its record, so Import Existing Backup drops that record and the next export writes the file back at its own name.

   The list lives in `scripts/ci/regression-gates.txt`; CI fails if this list misses a gate from it or if a gate is skipped.
3. New collaborator extracted from `ExportManager`? Use the Host-protocol pattern documented in the conventions file (narrow protocol, IUO init, weak host, synchronous mirror sinks). Do not duplicate `@Published` state on the manager.

The deeper architecture map (what each type does) lives at [`website/src/content/docs/architecture.md`](website/src/content/docs/architecture.md). For agent-specific quick reference (build commands, design decisions, conventions), [`AGENTS.md`](AGENTS.md) is the richest single source — humans are welcome to read it too.

## Reference material

- **Architecture conventions** (cancellation, actor isolation, AutoSync seam, Host/forwarder patterns, regression gates, extension recipes): [`docs/reference/architecture-conventions.md`](docs/reference/architecture-conventions.md)
- **Architecture map** (what each type does, friendly version): [`website/src/content/docs/architecture.md`](website/src/content/docs/architecture.md)
- **Style and Swift/SwiftUI patterns**: [`docs/reference/swift-swiftui-best-practices.md`](docs/reference/swift-swiftui-best-practices.md)
- **Persistence details**: [`docs/reference/persistence-store.md`](docs/reference/persistence-store.md)
- **Agent quick reference** (also useful for humans): [`AGENTS.md`](AGENTS.md)

## Documentation Ownership

Where each kind of doc lives, and which page to update for which kind of change, is documented in [`docs/README.md`](docs/README.md). Read that before opening a PR that changes user-visible behavior — there is a "what to update when behavior changes" table.

If a change affects setup, behavior, limitations, or project structure, update the relevant docs in the same pull request.

## Pull Requests

Agent-authored PRs follow the repository's three-reviewer workflow:

1. Post the implementation plan on the relevant GitHub issue, including scope, compatibility, and validation.
2. Have three subagents review it as Senior Architect, Senior Tester, and Pragmatic Developer. The Pragmatic Developer keeps the solution practical and challenges unnecessary complexity.
3. Update the issue plan from the feedback before implementing.
4. Write or update meaningful tests before changing production code whenever practical. For bug fixes, demonstrate that the regression test fails against the previous implementation for the expected behavioral reason, then apply the fix and rerun the relevant checks. Briefly explain exceptions in the issue or PR when a meaningful failing test is impractical, such as documentation-only changes; avoid tests that merely mirror the implementation or prose.
5. Reuse the same three agents to review the implementation, resolve actionable findings, and record the review outcomes.
6. Push and open the PR. Merge after CI passes for its current head commit and actionable findings are resolved, unless the user requests a different flow.

Triage a red post-merge main run with an issue or revert before merging another PR. A red scheduled release dry run gets an issue but does not block merges (see [the release process](docs/project/release-process.md#dry-run)).

Include the following in your pull request description:

- what changed
- why it changed
- how you tested it
- whether documentation was updated

For UI changes, include a screenshot or short recording when practical.

## Automation Dependencies

External GitHub Actions are pinned to upstream commit SHAs with version comments. Dependabot proposes weekly Action updates and website npm updates; routine minor/patch website updates are grouped, while major updates remain separate. Maintainers review these PRs and merge only after current-head CI passes. No automatic merging is enabled.

CI selects app and website validation by changed area. The existing `build-and-test`
and `website` check names remain conclusive result gates, including when unrelated
validation is skipped. Shared/unknown paths select both. See the [routing rules and
local tests](scripts/README.md#ci-area-routing); release workflow triggers are unchanged.

Main branch protection requires the final `build-and-test` and `website` checks,
both from GitHub Actions (app ID `15368`). Conditional validator jobs and release
workflows are not required checks. Pending, failed or cancelled required results
block the normal protected merge path.

Branch freshness is deliberately loose (`strict=false`): a PR may have an older
base without rebasing solely because main advanced. Its current head must still
pass CI. Administrator enforcement remains disabled (`enforce_admins=false`), so
GitHub allows administrators to bypass protection. Ordinary work, including
agents acting as administrators, follows the review and current-head CI workflow
above. An emergency bypass requires explicit human instruction, a recorded reason
and a follow-up plan on the PR; it is not an automatic response to failing CI.
See the [read-only protection recheck](scripts/README.md#main-branch-protection)
when auditing or changing this mutable repository setting.

The macOS test job publishes [advisory app-area coverage](scripts/README.md#advisory-coverage-summary)
to its log and step summary. Coverage percentages do not gate merges; the tests and
builds remain authoritative, and the xcresult artifact remains available for inspection.

When updating a pin manually, verify the commit and its `action.yml` in the upstream repository, retain the version comment, and preserve workflow permissions, triggers, environments, and release controls. For website dependency updates, commit both `website/package.json` and `website/package-lock.json` as applicable and run the website format, lint, and validation commands. App runtime dependencies remain unchanged.

## Release and Project Notes

Before pushing a release tag, follow the [release process](docs/project/release-process.md), including the [real-Photos candidate validation](docs/project/release-validation.md). Record skipped or deferred rows explicitly; passing hermetic CI does not replace that evidence.

Longer-lived project notes live under [`docs/`](docs/README.md). Keep the repo root reserved for the files people expect in an open source project.

### UI behavior test strategy

Keep combinatorial rules in pure policy tests and use the existing native `NSHostingView`
behavior tests for SwiftUI bindings and rendered actions. Platform services use injected
fakes; login-item tests never change System Settings and volume tests use isolated
notification centers, preferences and temporary folders. No view-inspection or snapshot
package is required.

The dedicated CI XCUITest onboarding/navigation smoke remains deferred in
[issue #108](https://github.com/valtteriluomapareto/photo-export/issues/108).
The current desktop host has not produced an interactive window during the #177 capture
validation, so this batch cannot validate that automation. Hosted/policy tests do not
claim native launch or desktop navigation coverage. The default shared-scheme command
runs unit/hosted tests; the UI-test target remains excluded.
