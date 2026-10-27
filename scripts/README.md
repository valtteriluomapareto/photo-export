# scripts/

Historical persistence fixture generation is offline development tooling, excluded from
normal CI. See [the fixture guide](../docs/project/historical-persistence-fixtures.md) for
pinned sources, the fresh-output command, and the immutable-byte policy.

Small development utilities for this project. CI-only steps live under [`ci/`](ci/) and are invoked from the GitHub Actions workflows in `.github/workflows/`.

## Top-level scripts

| Script | Purpose |
| --- | --- |
| [`bump-version.sh`](bump-version.sh) | Prepares `MARKETING_VERSION` and website version changes for a reviewed PR. Never stages, commits or tags. Required step in [`docs/project/release-process.md`](../docs/project/release-process.md). |
| [`generate-app-icon.sh`](generate-app-icon.sh) | Generates a complete macOS `AppIcon.appiconset` from a single square master image. Source image lives in [`design/app-icon-master.jpeg`](../design/app-icon-master.jpeg). Run when the icon changes. |
| [`probe-exclusive-rename.sh`](probe-exclusive-rename.sh) | Creates small APFS, HFS+, ExFAT and FAT32 disk images in a temporary folder and records, for each, whether the volume advertises an exclusive rename and whether `renamex_np(RENAME_EXCL)` keeps an existing file's bytes; fails if any volume replaced them. `--folder <dir>` probes an existing folder's volume (an SMB share) in a hidden subfolder it removes. Runs weekly in the toolchain canary; results are in [architecture-conventions § Final file commit boundary](../docs/reference/architecture-conventions.md#final-file-commit-boundary). |
| [`release/validation_rows.py`](release/validation_rows.py) | Lists which [pre-release Photos validation](../docs/project/release-validation.md) rows a candidate needs: the rows whose files changed since each row last passed, and whether the full matrix is required. Every app file must map to a row or the core smoke; `scripts/ci/test-guards.sh` runs its tests, including that completeness check. |
| [`prepare-app-store-screenshot.py`](prepare-app-store-screenshot.py) | Pads a screenshot to a Mac App Store spec size and flattens transparency. Operates on [`design/app-store-screenshot.png`](../design/app-store-screenshot.png). Requires `pip install Pillow`. |
| [`screenshots/capture.sh`](screenshots/capture.sh) | Builds the app in screenshot mode (curated synthetic library, no personal photos), launches it at a requested window size, and captures the window via `screencapture -l<id>`. Outputs to `screenshots/<WxH>/NN-name.png`. Requires a one-time Screen Recording TCC grant on your terminal — see the script header. See [`docs/project/archive/screenshot-automation-plan.md`](../docs/project/archive/screenshot-automation-plan.md) for design. |
| [`screenshots/optimize-bundle.sh`](screenshots/optimize-bundle.sh) | Batch-resizes + re-encodes the stock photos under `photo-export/Resources/screenshots/` as JPEG at quality 85, capped at 1600px on the long edge. PNGs typically shrink to ~25% of their original size. Skips files that already have a `.jpg` / `.heic` sibling. Run after dropping new PNGs into the bundle. |
| [`xccov2lcov.sh`](xccov2lcov.sh) | Converts an `.xcresult` coverage bundle into `lcov.info` for tools that consume LCOV. Used by the coverage commands in [`README.md`](../README.md). |

## Export measurements

The single measurement tool captures numeric export events or replays saved numeric and
legacy completion logs. For a real export, quit Photo Export first, then run:

```bash
scripts/perf/collect-export-measurements.sh --app "/path/to/Photo Export.app" \
  --label local --cache-state cold --runs 1
```

The tool starts its filtered log subscriber before launching the supplied app with
`--export-measurements` and `--export-watchdog`. You choose the Photos selection and
settings and start the export to a **fresh disposable destination**. Reusing an already
exported destination measures skipping. Do not delete your real export history. The tool
never starts exports or changes settings, uploads nothing, and leaves the app open.
Ctrl-C saves partial results and stops only its own log/caffeinate processes.

Capture cold and warm runs separately with `--cache-state cold` or `--cache-state warm`.
Record run order and use the same workload, power/network conditions and settings for
before/after comparisons. A warm run needs **at least 30 seconds between its first and
last completion**; shorter windows remain visible but are marked unsuitable for comparison.
The T0 warm window of about 2 seconds is too short. Never combine cold and warm medians or
staging shares. For T1's HEIC conversion workload, turn **Convert HEIC to JPEG** on before
starting the export; each numeric run records the actual setting. Older captures and
legacy completion logs report HEIC conversion as **unknown**, without inferring it from a
label; unknown settings also make a run unsuitable for comparison. Use `--cache-state unknown` if the source/cache conditions are not known.

The output directory contains `summary.md`, `results.json`, and sanitized `events.ndjson`.
Use `--output /new/folder` to choose a new location; existing paths are refused. The
report includes build/version metadata when capturing live, and omits filenames, Photos
identifiers and destination paths. Per-run asset ordinals are not Photos identifiers.

Each run reports independently:

- Distinct committed assets divided by the **first-to-last-completion** window.
  Preparation and the first asset's write precede this window; keep the denominator
  unchanged for comparisons.
- Staging share: summed physical copy/resource/render/conversion await times divided by
  summed job wall time. This includes producer suspension and retries, excludes directory
  repair and cleanup, and is **not CPU time** or main-thread stall time.
- Main-thread turns strictly above 16, 33 and 100 ms, counted cumulatively.

Choose complete, uninterrupted exports. These are observed timings, without sequence
checks or run seals that certify completeness. An unfinished capture retains its observed
metrics. Automatic runs are labeled separately and do not satisfy the manual run count.

Replay a numeric capture without launching the app (keep its original report for build
metadata):

```bash
scripts/perf/collect-export-measurements.sh --replay /capture/events.ndjson \
  --session <UUID-from-results.json> --label local --cache-state cold --output /new/replay
```

Replay legacy completion logs through the same tool, one file per export run. Their
staging, HEIC setting and main-thread counts are unavailable; the raw identifiers and
paths in those logs are not copied into the output. Capture compact logs in UTC and
isolate each run's `VariantExporter` completion lines using its start/end times.

```bash
scripts/perf/collect-export-measurements.sh --completion-log run-1.log run-2.log \
  --label local --cache-state warm --runs 2 --output /new/legacy-report
```

`--completion-log -` reads one run from stdin. The separate
`scripts/perf/run-main-thread-bench.sh` runs optimized Debug samples using scratch-only
fakes and prints `BENCH` medians; it does not establish real Photos/NAS throughput or
staging percentages.

## CI scripts (`scripts/ci/`)

These are wrappers around `xcodebuild` / signing / App Store Connect that the release workflows call. They are not meant to be run interactively unless you are reproducing a CI failure locally — they expect environment variables that the workflows inject.

The structural guards also run locally without signing credentials:

```bash
scripts/ci/run-guards.sh
```

[`run-guards.sh`](ci/run-guards.sh) runs guard fixture self-tests, export IO boundaries, read-only Photos,
source-comment plan references, test waits, test scratch state, the observation ratchet,
persistence value sets, project versions, regression-gate symbols/documentation,
destination-identity keying and strict app-and-test formatting (using the pinned Swift tools described below).
It names each check, continues after independent failures and reports all failed checks
before returning nonzero. CI keeps invoking these guards individually. SwiftLint,
Xcode selection, built-app checks, result-bundle gate audits and release credential checks
use their own commands and prerequisites.

The release archive steps retain complete sanitized output in dedicated
`photo-export-direct-archive.log` and `photo-export-appstore-archive.log` files under
`RUNNER_TEMP`, uploaded as `release-direct-archive-log` and
`release-appstore-archive-log` even when archiving fails. The combined archive stdout/stderr
passes through [`sanitize-release-log.py`](ci/sanitize-release-log.py) before `tee` or the
30-line console tail. It redacts known inherited release credentials, including the
keychain password exported by setup; multiline values and chunk boundaries are handled.
Sanitization failures stop the archive step without a raw-output fallback. Artifacts
include only the explicit log file, excluding setup output and credential files.

`check-export-io-boundaries.py` rejects direct FileManager, URL filesystem probes and
PHAsset fetches in export execution and destination preparation. Explicit filesystem,
resource-writer/render, validation and import/history adapters retain their platform calls;
folder-picker identity probes are exempt only inside their two named functions. The check
is lexical and complements worker-thread tests; PhotoKit job metadata still uses the
library-service seam until its dedicated reader lands.

`check-test-waits.py` rejects wall-clock `< deadline` waits in `photo-exportTests/`
(outside the allow-listed anti-hang backstops in `TestHelpers/`) and requires every
test file that calls `eventually(` to declare a `.timeLimit(`. Waits re-check progress
and rely on the test's time limit, because CI's congested main actor makes fixed
deadlines measure scheduler load rather than progress (#277). It is lexical, like the
other structural guards.

`check-test-scratch.py` keeps test state inside `TestScratch`
(`photo-exportTests/TestHelpers/TestScratch.swift`), whose per-run root under
`$TMPDIR/photo-export-tests/` is removed when the test process exits. The hosted test
process shares the app's identity, so outside that file the guard rejects, across line
breaks: `UserDefaults(suiteName:` (also via `.init`), `UserDefaults.standard`,
`UserDefaults()`, `.temporaryDirectory`, `NSTemporaryDirectory(`,
`.itemReplacementDirectory`, `.applicationSupportDirectory`, `.cachesDirectory` and the
no-argument `ExportRecordStore()` / `CollectionExportRecordStore()`, and the shipping
compositions (`AppComposition.production`, `.screenshot`, `.forLaunch`, qualified or
called through a leading dot anywhere, such as `.production(` or
`.screenshot(windowSize:`), which hold the app's own preferences, Application Support
folder and PhotoKit, and `PhotoExportApp(`, `PhotoExportApp.init(`, `PhotoExportApp.main`
or a typed `: PhotoExportApp = .init`, which compose the real app. Build a core from a
composition with `TestScratch` roots and fakes. Use
`TestScratch.defaults(_:)` for a fresh suite, `TestScratch.suiteName(_:)` with
`TestScratch.defaults(suiteName:)` when two objects share or reopen one suite, and
`TestScratch.directory(_:)` for folders. A test that must exercise the real path keeps the
construct and marks it with a `// test-scratch: allow <reason>` comment on the line where
the use starts or the line above. It is lexical, like the other guards.

`check-observation-ratchet.py` holds the app's remaining `ObservableObject`-era
patterns to the ceilings in [`ci/observation-ratchet.txt`](ci/observation-ratchet.txt)
while types move to `@Observable`
([`docs/reference/observation-migration-recipe.md`](../docs/reference/observation-migration-recipe.md)).
Per file under `photo-export/` it checks `ObservableObject` conformances (by type name,
including protocols and extensions, across line breaks) and `$property` publishers reached
through another object (`manager.$identity`; the owner's own `$property`, `self.$property` and
`self?.$property` are not counted). As repository totals, so moving a use between files
passes, it checks `@Published`, `environmentObject(` calls with or without a leading
dot, `@EnvironmentObject`, `@StateObject` and `@ObservedObject` properties, and
`objectWillChange` reached through another object. Wrapper attributes also count when
qualified, such as `@Combine.Published` or `@SwiftUI.StateObject`. It fails when a count
rises or an unlisted type or file appears, and also when a count falls or a type stops
conforming: lower or remove the row in the same change, so
the ceiling cannot creep back up. Expose a named `AnyPublisher` accessor on the owning type
instead of a new external `$property`. It is lexical, like the other guards: qualified
wrapper names are matched by their final token without resolving imports or types.

`check-persistence-doc.py` compares the "Record-store value sets" table in
[`docs/reference/persistence-store.md`](../docs/reference/persistence-store.md) with the
Swift types its rows name; add a new persisted value to the table in the same change.
Static members on `ExportVariantReason` other than `static let x = Self(rawValue: "...")`
constants fail until the guard is taught about them.

### Removing leaked test files

Test runs before `TestScratch` left tens of thousands of preference plists and temporary
folders behind: in `~/Library/Preferences` and the shell `$TMPDIR` for unsigned
command-line runs, and in the app's container for signed Xcode runs. To clear them once by
hand, quit Photo Export and make sure no test run is active. The shared folders are matched
only by the name prefixes those tests used; the container, which only the app and its tests
write to, by any UUID-suffixed name. Temporary entries younger than an hour are kept, and
`photo-export-tests` is left to `TestScratch`'s own sweep.

```bash
CONTAINER=~/Library/Containers/com.valtteriluoma.photo-export/Data
UUID='[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}'
SUFFIX="-([A-Za-z0-9_-]*-)?$UUID"
PREFS='(test|ExportSettingsCapture|ProducerOwnership|StableId|DestinationRecovery|ExportDestinationTests|IssuePresentation|DestId|ManualFeedbackView|FinalCommit|DestinationStop|RemountIntegration|CollectionObservation|VolumeLifecycle|ImportFailure|ManualSummary|AlertRecovery|ExportMonthResume)'
TEMPS='(FakeExportDest|EditedModeTest|VideoRenderTest|ExportPipelineTest|EmptyRunTest|BSV|BSMatchTest|BSSizeTest|ExportManagerRunExport|ExportManagerImport|ExportManagerPause|JSONL|JSONLRollback|CollectionStore|ExportRecordStoreQuery|SidebarMultiSelect|SafetyMonitor|QueueAcrossModes|ExportFolder|VariantExporter|ExportAllAlbums|CrossStoreInd|AdapterStore|EditedFallback|ReuseSource|ReuseSourceAlbum|ImportRec|ImportIdempotency|ExportQueueSnapshot|AutoSyncSeam|AutoSyncMidRun|RemountRecords|RemountIntegration|GridSelection|AssetDetailLifecycle|RecordStoreRouter|DiagnosticReporter)'
```

Count first; drop `| wc -l` to review the names:

```bash
find -E ~/Library/Preferences -maxdepth 1 -type f -regex ".*/$PREFS$SUFFIX\.plist" | wc -l
find -E "$CONTAINER/Library/Preferences" -maxdepth 1 -type f -regex ".*-$UUID\.plist" | wc -l
find -E "$TMPDIR" -mindepth 1 -maxdepth 1 -mmin +60 -regex ".*/$TEMPS$SUFFIX(\.[a-z]+)?" | wc -l
find -E "$CONTAINER/tmp" -mindepth 1 -maxdepth 1 -mmin +60 -regex ".*/([^/]*-)?$UUID(\.[a-z]+)?" | wc -l
```

Then stop `cfprefsd`, so it cannot write cached suites back, and delete with the same
matches. The folders go through `-exec rm -rf {} +`, because `find -delete` cannot remove a
non-empty folder; like `-delete`, it avoids the "argument list too long" failure a shell
glob hits at this many files.

```bash
killall -u "$USER" cfprefsd
find -E ~/Library/Preferences -maxdepth 1 -type f -regex ".*/$PREFS$SUFFIX\.plist" -delete
find -E "$CONTAINER/Library/Preferences" -maxdepth 1 -type f -regex ".*-$UUID\.plist" -delete
find -E "$TMPDIR" -mindepth 1 -maxdepth 1 -mmin +60 -regex ".*/$TEMPS$SUFFIX(\.[a-z]+)?" \
  -exec rm -rf {} +
find -E "$CONTAINER/tmp" -mindepth 1 -maxdepth 1 -mmin +60 -regex ".*/([^/]*-)?$UUID(\.[a-z]+)?" \
  -exec rm -rf {} +
```

### Xcode version and toolchain canary

`.xcode-version` is the one place the CI and release Xcode version is set.
`select-xcode.sh` selects `/Applications/Xcode_<version>.app` from it (or from its first
argument) and fails rather than falling back: it rejects a set `DEVELOPER_DIR`, requires
`xcode-select -p` to be the resolved app and `xcodebuild -version` to report exactly that
version, and lists the installed Xcodes. `ci.yml`, both release workflows and the canary
call it before any Xcode tool; `test_ci_toolchain_workflows.py` rejects a hard-coded Xcode
path, `xcode-select -s`, `XCODE_PATH` or `DEVELOPER_DIR` in any workflow. Changing the file
or the script changes the shipped toolchain, so `validation_rows.py` requires the full
release matrix for both.

`build-app.sh <Debug|Release>` and `run-unit-tests.sh` are the build and test commands that
`app-validation` and the canary share. They write `debug-build.log`, `release-build.log`,
`test.log`, `test-start.marker` and `TestResults.xcresult` to the current directory, where the
diagnostics, coverage and regression-gate steps read them.

`SWIFT_WARNINGS_AS_ERRORS=1` makes `build-app.sh` fail on any Swift warning in the app target
(the test target is not compiled there) and log to `debug-werror-build.log`. `app-validation`
turns it on for its Debug build on the Xcode named in `.xcode-version`; the canary runs it as a
last step; releases never set it. Locally: `SWIFT_WARNINGS_AS_ERRORS=1 bash scripts/ci/build-app.sh Debug`.

`toolchain-canary.yml` builds and tests on other toolchains than `.xcode-version` (one lane per
version, each naming its runner label) weekly, on demand, and on pull requests that change the version file
or these scripts. One lane runs the next Xcode; another runs on `macos-15`, the oldest macOS the
app supports, so a build made with the 26 SDK is tested where macOS 15 users run it. Its
`exclusive-rename-probe` job runs `probe-exclusive-rename.sh` on `macos-26` and `macos-15`,
weekly and on demand only; it needs no Xcode. On pull requests, `test-guards.sh` checks that
the script and its embedded Python parse and runs its `--folder` mode on a temporary folder.

`check-built-app.sh [--app <path>] [<version>]` prints a built app's `DTXcode`, SDK,
`LSMinimumSystemVersion` and `ITSAppUsesNonExemptEncryption` values. It fails if the app is
missing, was built by another Xcode than `.xcode-version` (or the canary's lane version), or lacks
`ITSAppUsesNonExemptEncryption = false`, without which App Store Connect asks the encryption
question for every build. It runs after the Release build in `app-validation`, on the exported app
before the DMG in `release-direct`, and on the archived app before packaging and upload in
`release-app-store`. The canary is not part of the merge gate, so a red lane reports what
a bump would break without blocking work. A lane that stays queued means no runner has its
label; GitHub cancels it after 24 hours, and that is not a toolchain result.

### CI area routing

`ci/ci_routing.py` selects validation using complete local Git history, without an API
file-list limit. Pull requests compare their merge base to the event's head commit;
main pushes compare event `before` to `after` (including all pushed commits). Moves
are treated as a deletion plus addition so both owners are considered. Comparison
history missing from a fork checkout, new/deleted refs, unrelated histories, or an
unknown event select both areas. Malformed events and Git errors fail routing.

| Changed paths | Validation |
| --- | --- |
| `website/**` | Linux website checks |
| App sources/tests/project, `test-fixtures/**`, Swift lint/format config, non-CI `scripts/**` | macOS app checks |
| `.github/**`, `scripts/ci/**`, unknown/shared paths (including root/maintainer docs) | Both |
| Mixed changes | Union of the affected areas |
| Empty comparison | Neither expensive validator |

The workflow itself has no path filter. `website-validation` and `app-validation`
run conditionally; the existing `website` and `build-and-test` check names are Linux
result gates that require successful routing plus exactly selected/success or
unselected/skipped. Missing outputs, failed/cancelled validators, and unexpectedly
skipped selected validators cannot pass. An overall cancelled run may cancel the gate
before it executes; it remains non-green. Release workflows, including the weekly scheduled
direct-distribution dry run, are separate and unchanged. No branch-protection settings are
changed by routing.

Run the real-Git routing matrix and result-gate truth table locally:

```bash
python3 -B -m unittest discover -s scripts/ci/tests -p test_ci_routing.py
```

These tests also run in the Linux routing job on every CI run, even website-only work.

### Main branch protection

The repository setting requires the conclusive `build-and-test` and `website`
checks from GitHub Actions (app ID `15368`). Require these final gates rather than
the conditional `app-validation` / `website-validation` jobs: an unrelated area
must finish with a successful final gate after its validator is skipped. Pending,
failed and cancelled required results block the normal protected merge path.

The configured freshness policy is `strict=false` (an older base is allowed;
current-head CI is still required). `enforce_admins=false` retains administrator
bypass for emergencies. The [contributor workflow](../CONTRIBUTING.md#automation-dependencies)
requires explicit human instruction, a recorded reason and follow-up for a bypass;
agents and administrators use ordinary green-CI merges for normal work.

These are live settings, not settings applied by a workflow. Recheck without
changing protection:

```bash
gh api repos/valtteriluomapareto/photo-export/branches/main/protection
gh api repos/valtteriluomapareto/photo-export/rulesets
```

Verify `required_status_checks.checks` contains both names bound to `app_id: 15368`,
`required_status_checks.strict` and `enforce_admins.enabled` match the policy above,
and unrelated protection/rulesets are preserved. The existing review requirement
has zero required approvals; preserve its object when updating settings rather
than replacing it with `null`, which would remove the PR requirement. For a policy
change, record fresh before/after API evidence and rerun the routing/result tests.

### Required destination scope tests

CI sets `TEST_RUNNER_REQUIRE_SCOPE_TESTS=1` on the unit-test step; xcodebuild forwards
it to the test process as `REQUIRE_SCOPE_TESTS`. The ungated
`RequiredDestinationScopeTests.requiredDestinationScopeTestsCanRun` fails if the
real temporary-folder security-scope probe rejects access, which would otherwise
skip 19 destination-identity regression tests. Local runs without the flag retain
the existing probe-based skips on affected macOS versions. To enforce the CI
requirement locally:

```bash
TEST_RUNNER_REQUIRE_SCOPE_TESTS=1 xcodebuild -project photo-export.xcodeproj \
  -scheme "photo-export" -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

### Advisory coverage summary

After the macOS unit-test step, `ci/coverage_summary.py` reads the existing xcresult
using `xcrun xccov view --report --json`. It prints a table to the job log and appends
the same Markdown to the GitHub step summary. The exact `Photo Export.app` target and
Swift files inside the checked-out app source root are included; test targets and
generated files outside that root are excluded. Totals sum covered/executable lines,
not file percentages. Unlisted sources are not inferred as zero coverage.

The report is advisory: no percentage threshold changes CI status. Failed, skipped,
or cancelled test outcomes label available counts as partial; missing/malformed
results explain why coverage is unavailable. Reporting errors cannot override the
test/build failure, and the original xcresult artifact upload remains available.

```bash
python3 -B scripts/ci/coverage_summary.py --result-bundle TestResults.xcresult \
  --source-root "$PWD/photo-export" --test-outcome success
python3 -B -m unittest discover -s scripts/ci/tests -p 'test_ci_*.py'
```

For offline reproduction, use `--report-json` with the recorded fixture described in
[`ci/tests/fixtures/README.md`](ci/tests/fixtures/README.md). CI-tool tests run in the
Linux routing job as well as the existing guard test runner.

The Photos guard rejects exact PhotoKit change/creation request and `performChanges` identifiers in production Swift sources. It ignores nested comments and ordinary/raw/multiline string literals (including interpolation bodies), preserves source line numbers, and fails on missing/empty input. It has no inline bypass marker. This is a lexical tripwire: aliases, dynamic calls, and code inside string interpolation need review; it does not replace Swift compilation or behavioral tests. Python 3 is required; only its standard library is used. Self-tests invoke the real scanners against temporary fixtures and preserve the existing destination-keying self-test.

The regression gates are listed once, in `ci/regression-gates.txt`. Each row is `<test file>|<gate|pin>|<declaration>`, where the declaration is `struct SuiteName` (a suite gate, or a pin: a suite listed only because it holds method gates) or `func SuiteName.methodName` (a method gate). Text from `#` to the end of a line is a comment. CI checks the list twice:

- **Symbols and docs.** `ci/check-regression-gates.sh` uses the same lexical masking and matches complete `struct` and ordinary `func name(...)` declarations, rather than substring mentions; a method row also requires its suite's `struct`. It then checks that the gate table in `docs/reference/architecture-conventions.md` §Regression gates and the gate lists in `AGENTS.md` and `CONTRIBUTING.md` name every listed gate and pinned suite in backticks within those sections. Only that direction is checked, so other names in the sections never fail it.
- **Results.** After the unit tests pass, `ci/check-regression-gates-ran.py --result-bundle TestResults.xcresult` reads `xcrun xcresulttool get test-results tests` and checks that every gate ran and was not skipped. Every `Test Case` and `Arguments` node under a gate must report `Passed`; `Skipped`, `Failed`, `Expected Failure`, `unknown` or a missing result fails it, and results on other node types are ignored. A suite gate also needs at least one test case. Suites match on `nodeIdentifier`, then the last `nodeIdentifierURL` segment, and only then the display name. A method gate matches test-case identifiers (or, without one, the `nodeIdentifierURL` path) starting with `SuiteName/methodName(`, so every argument case and repetition counts. A pin only needs its suite present. A failing `xcresulttool`, unreadable JSON or a malformed list fails the check. `--json-file` reads a pre-dumped copy of that JSON instead. A gate that returns early without recording an issue still reports Passed, which no result-bundle check can detect.

`test-guards.sh` covers clean inputs, missing files/declarations, suffix renames, comment/string-only symbols, doc drift, and the result check against output trimmed from a real result bundle (see the docstring in `ci/tests/test_regression_gates_ran.py`), and checks the list parser, which `check-regression-gates.sh` also uses through `check-regression-gates-ran.py --print-rows`. When changing a guard, add a clean fixture and a violation fixture that asserts the intended diagnostic, not just a nonzero exit. To add, rename or remove a gate, update the list file and the three docs in the same PR; runtime ordering and cancellation still require the behavioral tests.

The version validator checks every `MARKETING_VERSION` assignment line in `project.pbxproj` for syntax, supported stable/prerelease format, and consistency. Empty/malformed assignments are errors even when other entries are valid. Both release workflows run it before signing; version-tag refs (including manual build-only dispatches) supply `--expected <full-version>`. Direct-distribution branch dry runs keep their `0.0.0-dev` context without comparing it to the app version. The validator never edits versions or creates tags; `bump-version.sh` remains the version mutation entry point. Its fixture tests run through `test-guards.sh`.

The release-safety fixtures also run through `test-guards.sh`. They extract the actual workflow context, version-check, duplicate-check and publication steps, then execute only those selected steps in disposable directories. A restricted command path stubs `gh release` and the App Store upload helper; no signing, credentials or network access is used. The event/ref/input matrix covers safe manual tag builds, explicit publication, beta versions, version mismatch and existing releases. Unexpected selected-step structure or expressions fail the test. Build-only workflow semantics are documented in [Release Process](../docs/project/release-process.md#dry-run).

The formatter fixtures execute the actual CI format-check block and copied
`ci/check-swift-format.sh` helper against disposable app and unit-test sources. They
verify a warning in either tree fails before the success message and that explicit
configuration overrides conflicting auto-discovery for both trees. SwiftLint's
real-config fixtures likewise require app and test violations to fail, while keeping
the template UI-test target out of scope. Absence of either optional local tool
skips only its corresponding fixtures; configuration and tool failures are errors.
CI installs and verifies both tools before running the guard suite. See the [matching local commands](../CONTRIBUTING.md#local-setup).

| Script | Used by workflow |
| --- | --- |
| `archive-appstore.sh` | `release-app-store.yml` |
| `export-appstore.sh` | `release-app-store.yml` |
| `prepare-pkg.sh` | `release-app-store.yml` |
| `setup-keychain-appstore.sh` | `release-app-store.yml` |
| `install-provisioning-profile.sh` | `release-app-store.yml` |
| `upload-appstore-connect.sh` | `release-app-store.yml` |
| `cleanup-appstore.sh` | `release-app-store.yml` (always runs) |

## Design assets

Marketing source files live in [`design/`](../design/), not in the repo root:

- `app-icon-master.jpeg` — square master image for the app icon
- `app-store-screenshot.png` — current Mac App Store hero screenshot

## Source-comment reference guard

Run `python3 -B scripts/ci/check-no-plan-refs.py` from the repository root. App Swift
comments must describe current reasons, with links to maintained references when needed,
rather than development labels such as `Phase 3`, `pre-Phase-0a`, `Plan §` or `item 5`.
The guard checks line and nested block comments, including references split across adjacent
doc-comment lines, and ignores string literals and explicit extended regex literals
(`#/.../#`, including extra hashes). Bare slash regex literals are outside this narrow
lexer's supported syntax. It shares `swift_source.py` boundaries
with the other lexical guards; interpolation inside strings is masked, not parsed as code.
Missing/empty source trees and malformed input fail explicitly.

`test_no_plan_refs.py` exercises the real CLI on disposable sources; `test-guards.sh`
discovers those fixtures with the other guard tests. CI also runs the guard explicitly
with a verbose result group.
