# scripts/

Historical persistence fixture generation is offline development tooling, excluded from
normal CI. See [the fixture guide](../docs/project/historical-persistence-fixtures.md) for
pinned sources, the fresh-output command, and the immutable-byte policy.

Small development utilities for this project. CI-only steps live under [`ci/`](ci/) and are invoked from the GitHub Actions workflows in `.github/workflows/`.

## Top-level scripts

| Script | Purpose |
| --- | --- |
| [`bump-version.sh`](bump-version.sh) | Sets `MARKETING_VERSION` across all six build configs in `project.pbxproj`, commits, and tags `v<version>`. Use `--no-tag` to set the version without committing. Required step in [`docs/project/release-process.md`](../docs/project/release-process.md). |
| [`generate-app-icon.sh`](generate-app-icon.sh) | Generates a complete macOS `AppIcon.appiconset` from a single square master image. Source image lives in [`design/app-icon-master.jpeg`](../design/app-icon-master.jpeg). Run when the icon changes. |
| [`prepare-app-store-screenshot.py`](prepare-app-store-screenshot.py) | Pads a screenshot to a Mac App Store spec size and flattens transparency. Operates on [`design/app-store-screenshot.png`](../design/app-store-screenshot.png). Requires `pip install Pillow`. |
| [`screenshots/capture.sh`](screenshots/capture.sh) | Builds the app in screenshot mode (curated synthetic library, no personal photos), launches it at a requested window size, and captures the window via `screencapture -l<id>`. Outputs to `screenshots/<WxH>/NN-name.png`. Requires a one-time Screen Recording TCC grant on your terminal — see the script header. See [`docs/project/archive/screenshot-automation-plan.md`](../docs/project/archive/screenshot-automation-plan.md) for design. |
| [`screenshots/optimize-bundle.sh`](screenshots/optimize-bundle.sh) | Batch-resizes + re-encodes the stock photos under `photo-export/Resources/screenshots/` as JPEG at quality 85, capped at 1600px on the long edge. PNGs typically shrink to ~25% of their original size. Skips files that already have a `.jpg` / `.heic` sibling. Run after dropping new PNGs into the bundle. |
| [`xccov2lcov.sh`](xccov2lcov.sh) | Converts an `.xcresult` coverage bundle into `lcov.info` for tools that consume LCOV. Used by the coverage commands in [`README.md`](../README.md). |

## CI scripts (`scripts/ci/`)

These are wrappers around `xcodebuild` / signing / App Store Connect that the release workflows call. They are not meant to be run interactively unless you are reproducing a CI failure locally — they expect environment variables that the workflows inject.

The structural guards also run locally without signing credentials:

```bash
scripts/ci/test-guards.sh
python3 scripts/ci/check-read-only-photos.py
python3 scripts/ci/check-version.py
```

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
before it executes; it remains non-green. Release workflows, including main's direct
distribution dry run, are separate and unchanged. No branch-protection settings are
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

The regression-symbol guard uses the same lexical masking and matches complete `struct` and ordinary `func name(...)` declarations, rather than substring mentions. `test-guards.sh` covers clean inputs, missing files/declarations, suffix renames, and comment/string-only symbols before CI runs the real scans. When changing a guard, add a clean fixture and a violation fixture that asserts the intended diagnostic, not just a nonzero exit. Keep gate names synchronized with `docs/reference/architecture-conventions.md`; runtime ordering and cancellation still require the behavioral tests.

The version validator checks every `MARKETING_VERSION` assignment line in `project.pbxproj` for syntax, supported stable/prerelease format, and consistency. Empty/malformed assignments are errors even when other entries are valid. Both release workflows run it before signing; version-tag refs (including manual build-only dispatches) supply `--expected <full-version>`. Direct-distribution branch dry runs keep their `0.0.0-dev` context without comparing it to the app version. The validator never edits versions or creates tags; `bump-version.sh` remains the version mutation entry point. Its fixture tests run through `test-guards.sh`.

The release-safety fixtures also run through `test-guards.sh`. They extract the actual workflow context, version-check, duplicate-check and publication steps, then execute only those selected steps in disposable directories. A restricted command path stubs `gh release` and the App Store upload helper; no signing, credentials or network access is used. The event/ref/input matrix covers safe manual tag builds, explicit publication, beta versions, version mismatch and existing releases. Unexpected selected-step structure or expressions fail the test. Build-only workflow semantics are documented in [Release Process](../docs/project/release-process.md#dry-run).

The formatter fixtures execute the actual CI format-check block against disposable
Swift files. They verify warnings fail before the success message, explicit config
overrides conflicting auto-discovery, and test sources stay outside the app-source
scope. Only absence of the optional local `swift-format` tool skips these fixtures;
configuration and formatter failures are errors. CI installs/verifies the formatter
before running the guard suite. See the [matching local commands](../CONTRIBUTING.md#local-setup).

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
