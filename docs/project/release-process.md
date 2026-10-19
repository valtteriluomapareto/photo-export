# Release Process

How to cut a new release of Photo Export.

Photo Export ships through two channels from the same tag: **GitHub Releases** (free, Developer ID signed) and the **Mac App Store** (paid, Apple Distribution signed). One semver, one tag, two distribution pipelines.

## Prerequisites

- Push access to the repository
- Apple Developer ID certificate and notarization secrets configured in the `direct-release` GitHub Environment
- For App Store: Apple Distribution certificate and App Store Connect API key configured in the `app-store-release` GitHub Environment

## Steps

### 1. Add a ReleaseNote entry for the new version

Edit `photo-export/Models/ReleaseNotesCatalog.swift` and append a `ReleaseNote(version: …)` for the version about to ship. The entry is what the in-app **What's New** sheet shows to users on first launch after the upgrade — title, summary, bullets, optional Learn-more link.

Forgetting this step is non-fatal: the sheet falls back to a generic "Photo Export has been updated to version X — see release notes on GitHub" message rather than showing stale per-version copy. But the in-app feature is more useful when it's actually maintained.

Keep older entries in the catalog — users skipping multiple releases see the combined set for everything between their last-seen version and the current bundle version.

Prepare the catalog and all intended release changes on a release branch. Include the notes, project version and website version in the reviewed PR. The bump helper leaves the Git index alone and never commits or tags.

### 2. Prepare the version and merge the release PR

```bash
git switch -c release/1.2.0 &&
scripts/bump-version.sh 1.2.0 --no-tag &&
python3 scripts/ci/check-version.py --expected 1.2.0 &&
git diff &&
git add photo-export/Models/ReleaseNotesCatalog.swift photo-export.xcodeproj/project.pbxproj website/src/layouts/MarketingLayout.astro &&
git commit -m "Prepare release 1.2.0" &&
git push -u origin HEAD &&
gh pr create --title "Prepare release 1.2.0" --body "Version and release notes for the candidate; Photos validation follows on the merged commit."
```

Follow the normal [contributor review workflow](../../CONTRIBUTING.md), including the three reviewers and green checks before merge. Never push the bump directly to protected `main`.

The helper updates every `MARKETING_VERSION` assignment and the homepage's structured-data `softwareVersion`. Preparation-only is the default; `--no-tag` remains an explicit compatible spelling. For `1.3.0-beta.1`, the bundle keeps the suffix while the website and release-note catalog use base `1.3.0`. Missing catalog entries require an explicit override. A same-version call still repairs website drift and never creates a tag.

### 3. Validate the exact merged candidate

After the release PR merges, select its merge commit while still on the release branch. Enter the merged PR number when prompted:

```bash
printf "Merged release PR number: "
read -r RELEASE_PR &&
CANDIDATE_SHA="$(gh pr view "$RELEASE_PR" --json mergeCommit --jq '.mergeCommit.oid')" &&
git fetch origin main &&
git merge-base --is-ancestor "$CANDIDATE_SHA" origin/main &&
git switch --detach "$CANDIDATE_SHA" &&
test -z "$(git status --porcelain)"
```

Stop if any command fails, the PR is unmerged, or the candidate is not clean. Verify the PR's current-head checks passed and its merge is the intended candidate. Keep `CANDIDATE_SHA` for the tag step; a later advance of `main` must not change the selected candidate.

Complete the [pre-release Photos validation](release-validation.md) against that exact clean, version-bumped merged commit: the core smoke plus the rows `scripts/release/validation_rows.py` reports, on the signed dry-run DMG built from that commit. It defines the tiers, the evidence record and when a row may be skipped or deferred.

If the candidate changes, land the change through a PR, select its merged commit, rebuild and repeat relevant checks. This gate applies to betas, stable promotions and code changes after App Review rejection. Create the tag only after the release decision is recorded.

### 4. Tag and push the approved candidate

Using the same shell and the approved `CANDIDATE_SHA` from step3:

```bash
test "$(git rev-parse HEAD)" = "$CANDIDATE_SHA" &&
test -z "$(git status --porcelain)" &&
python3 scripts/ci/check-version.py --expected 1.2.0 &&
git tag v1.2.0 "$CANDIDATE_SHA" &&
git push origin refs/tags/v1.2.0
```

Stop on any failure. Use the full suffixed version for a beta. Push only the tag after the PR has merged; no direct main push or protection bypass is part of this flow. Both release workflows validate that the tag version matches every project configuration, including manual build-only runs on a tag. The optional automated tag-ancestry/status gate is not implemented; selecting the approved merged candidate and recording its checks/evidence remain release-owner responsibilities.

Pushing the `v*` tag triggers the **release-direct** workflow which:

1. Checks for an existing GitHub Release for this tag (fails early if one exists)
2. Builds a universal binary (Release, arm64 + x86_64)
3. Sets `CURRENT_PROJECT_VERSION` to the GitHub Actions run number
4. Signs with Developer ID Application certificate
5. Creates a styled DMG with drag-to-Applications installer
6. Notarizes the DMG with Apple and staples the ticket
7. Creates a **draft** GitHub Release with auto-generated notes
8. Attaches the DMG and SHA-256 checksum to the release

### 5. Review and publish the GitHub Release

1. Go to **Releases** on GitHub
2. Review the draft release — edit the notes if needed
3. Click **Publish release**

### 6. Submit to App Store

The same `v*` tag also triggers `release-app-store.yml`, which archives, signs, and uploads to App Store Connect automatically. Once the build appears in App Store Connect, submit for App Review manually.

If you ever need to archive locally (CI down, secret rotation, etc.):

```bash
xcodebuild archive \
  -project photo-export.xcodeproj \
  -scheme "photo-export" \
  -configuration Release \
  -archivePath ~/Desktop/PhotoExport-AppStore.xcarchive \
  CURRENT_PROJECT_VERSION=<next-build-number> \
  PRODUCT_BUNDLE_IDENTIFIER=com.valtteriluoma.photo-export-appstore \
  CODE_SIGN_STYLE=Manual \
  "CODE_SIGN_IDENTITY=Apple Distribution" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID"
```

Upload via Xcode Organizer (Distribute App > App Store Connect) or Transporter. Choose a build number greater than the last accepted build for that marketing version. A high manual number can make subsequent CI `run_number.run_attempt` values too low; compare them before uploading and coordinate any override. Deleting a GitHub tag or draft does not delete App Store Connect builds.

### 7. Verify distribution artifacts

**GitHub Release:**

The published DMG is a separate build from the validated dry run. On a separate machine or fresh user account, confirm:

- Gatekeeper accepts the app without warnings
- The version in About matches the release

In the [validation account](release-validation.md#validation-environment-one-time), install the published DMG over the validated state and confirm the app relaunches, the destination resolves without a re-grant, and repeating an exported month writes no files.

**App Store:**

After App Review approval, release manually in App Store Connect. Verify via TestFlight or the published listing.

## Build numbers

Build numbers (`CURRENT_PROJECT_VERSION`) are independent per channel:

- **GitHub Releases**: `github.run_number` (auto-incrementing)
- **App Store**: `${GITHUB_RUN_NUMBER}.${GITHUB_RUN_ATTEMPT}` (for example `42.2` on the second attempt of run42)

The checked-in value in `project.pbxproj` stays at `1`. Both workflows override it at build time.

## Dry run

To test the GitHub workflow without creating a release:

1. Go to **Actions > release-direct** on GitHub
2. Click **Run workflow** from `main` with `dry_run: true`
3. Download the DMG artifact from the workflow run

The safe inputs default to true. A manual dispatch on a version tag also honors
`dry_run: true` (direct) or `skip_upload: true` (App Store): it cannot create a
GitHub Release or upload to App Store Connect. Direct build-only runs still sign,
notarize and upload Actions artifacts; App Store build-only runs still sign and
upload the package as an Actions artifact. These modes require signing secrets
and are not offline tests.

Only explicit `false` opts a manual run into publication. On a stable version tag,
direct distribution checks for an existing release and creates a new draft only
when none exists; the Store workflow uploads the build. A build-only direct tag
run may rebuild even if a release already exists. On a branch, direct distribution
retains its `0.0.0-dev` artifact version and never creates a release, while the
Store workflow may upload the project's stable version with `skip_upload: false`.
Prerelease tags skip the Store job for both push and dispatch; branch builds with
a prerelease project version also cannot upload to the Store. Direct prerelease
tag publication creates a draft marked as a prerelease.

Missing/invalid safety inputs, unsupported events and refs other than branches
or `v*` tags do not enable publication. Automatic version-tag pushes retain the
release behavior described above. To test these decisions offline without
signing, uploads or tag creation, run `scripts/ci/test-guards.sh`.

## Beta / pre-release tags

Use the same PR → merged candidate → Photos validation → explicit tag flow for betas. A beta may defer triggered validation rows; they stay owed for the stable release (see [release validation](release-validation.md#what-to-run)). In step2, prepare `scripts/bump-version.sh 1.3.0-beta.1 --no-tag` on its release branch. After merge and step3 validation, step4 uses `--expected 1.3.0-beta.1`, `git tag v1.3.0-beta.1 "$CANDIDATE_SHA"`, and `git push origin refs/tags/v1.3.0-beta.1`.

The accepted version format is strict semver with an optional pre-release suffix: `X.Y.Z` or `X.Y.Z-<identifier>` (e.g. `1.3.0-beta.1`, `1.3.0-rc.2`). The suffix activates the pre-release path automatically:

- **GitHub Releases** publishes the tag as a **pre-release** (marked unstable, not "Latest"). Testers download the DMG from the Releases page just like a stable build.
- **App Store Connect** upload is **skipped** — App Store Connect rejects hyphen-suffixed `CFBundleShortVersionString`, so betas ship through the direct-distribution channel only. Use TestFlight separately if you also want an App Store beta.
- **Catalog check** in `bump-version.sh` looks up the base `X.Y.Z` entry in `ReleaseNotesCatalog.swift`. Betas of the same release share the stable's release notes; you don't need a separate entry per beta.

Beta testers see the catalog's `1.3.0` entry in the What's New sheet (since `1.2.3 < 1.3.0 ≤ 1.3.0-beta.1`). When the stable `1.3.0` ships later, testers on `1.3.0-beta.1` will *not* re-fire the sheet (the comparison treats `1.3.0-beta.1` as newer-than `1.3.0` for the `shouldShow` gate). That's intentional — they've already seen the notes.

To promote a beta, prepare the bare version with `scripts/bump-version.sh 1.3.0 --no-tag` in a new PR. Merge it when green, select that merged candidate, and repeat step3's diff assessment and Photos validation before explicitly tagging `v1.3.0` at its approved SHA. A beta tag is not moved to the stable candidate.

The stable tag goes through both channels (GitHub Release + App Store) as usual.

## Handling App Review rejection

### Rejection is metadata/policy only (no code change)

1. Keep the draft (or published) GitHub Release and the existing tag
2. Fix the App Store metadata in App Store Connect
3. Resubmit the same build, or upload a new build from the same commit with a higher build number
4. Publish the draft GitHub Release whenever ready

### Rejection requires a code change

If the semver has been published in **either** distribution channel, use a new semver. An unpublished GitHub draft alone does not permit reusing an already published Store version. Existing Store builds also retain their build numbers.

For an unpublished candidate only, delete the existing draft if present (`gh release delete v1.2.0 --yes`), then remove the old remote tag and its local copy if present:

```bash
git push origin :refs/tags/v1.2.0
if git show-ref --verify --quiet refs/tags/v1.2.0; then git tag -d v1.2.0; fi
```

Prepare the correction on a branch and run `scripts/bump-version.sh 1.2.0 --no-tag` before committing, even if the project already has that version; it prepares files but **does not recreate the tag**. Include any resulting version/website changes in the reviewed correction PR. After green CI and merge, select that PR's exact clean merged commit and complete step3's validation/evidence. Then recreate and push explicitly, using that approved `CANDIDATE_SHA`:

```bash
test "$(git rev-parse HEAD)" = "$CANDIDATE_SHA" &&
test -z "$(git status --porcelain)" &&
python3 scripts/ci/check-version.py --expected 1.2.0 &&
git tag v1.2.0 "$CANDIDATE_SHA" &&
git push origin refs/tags/v1.2.0
```

A new draft is created and the new Store build can be submitted with a higher accepted build number. Do not move published tags or bypass candidate validation to repair an upload.

## Rollback

**Bad unpublished GitHub draft**: Use the unpublished-candidate recovery above, including a reviewed fix PR and validation of its exact merged candidate before recreating the tag. If either channel already published that semver, ship a new version.

**Bad published GitHub release**: Ship a patch version (preferred) or delete the release.

**Critical bug in a live App Store release**:

1. Remove the build from sale in App Store Connect immediately
2. Fix the bug, bump semver, complete pre-tag validation, then push the tag and submit a new build
3. Request expedited App Review if the bug is severe
4. The GitHub Release can go live immediately; the App Store fix is gated by review (typically 24-48h)
