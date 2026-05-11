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

### 2. Bump the version

```bash
scripts/bump-version.sh 1.2.0
```

This updates `MARKETING_VERSION` in `project.pbxproj` (all 6 build configs), commits, and creates a `v1.2.0` git tag.

To set the version without committing or tagging:

```bash
scripts/bump-version.sh 1.2.0 --no-tag
```

### 3. Push the tag

```bash
git push && git push origin v1.2.0
```

Pushing the `v*` tag triggers the **release-direct** workflow which:

1. Checks for an existing GitHub Release for this tag (fails early if one exists)
2. Builds a universal binary (Release, arm64 + x86_64)
3. Sets `CURRENT_PROJECT_VERSION` to the GitHub Actions run number
4. Signs with Developer ID Application certificate
5. Creates a styled DMG with drag-to-Applications installer
6. Notarizes the DMG with Apple and staples the ticket
7. Creates a **draft** GitHub Release with auto-generated notes
8. Attaches the DMG and SHA-256 checksum to the release

### 4. Review and publish the GitHub Release

1. Go to **Releases** on GitHub
2. Review the draft release — edit the notes if needed
3. Click **Publish release**

### 5. Submit to App Store

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

Upload via Xcode Organizer (Distribute App > App Store Connect) or Transporter.

### 6. Verify

**GitHub Release:**

Download the DMG on a separate machine (or fresh user account) and confirm:

- Gatekeeper accepts the app without warnings
- The app launches and core flows work
- The version in About matches the release

**App Store:**

After App Review approval, release manually in App Store Connect. Verify via TestFlight or the published listing.

## Build numbers

Build numbers (`CURRENT_PROJECT_VERSION`) are independent per channel:

- **GitHub Releases**: `github.run_number` (auto-incrementing)
- **App Store**: Previous App Store Connect build number + 1

The checked-in value in `project.pbxproj` stays at `1`. Both workflows override it at build time.

## Dry run

To test the GitHub workflow without creating a release:

1. Go to **Actions > release-direct** on GitHub
2. Click **Run workflow** from `main` with `dry_run: true`
3. Download the DMG artifact from the workflow run

## Beta / pre-release tags

For seeding a build to a small group of testers from `main` without committing the version as the public stable, push a pre-release tag instead of a stable one.

```bash
scripts/bump-version.sh 1.3.0-beta.1
git push && git push origin v1.3.0-beta.1
```

The accepted version format is strict semver with an optional pre-release suffix: `X.Y.Z` or `X.Y.Z-<identifier>` (e.g. `1.3.0-beta.1`, `1.3.0-rc.2`). The suffix activates the pre-release path automatically:

- **GitHub Releases** publishes the tag as a **pre-release** (marked unstable, not "Latest"). Testers download the DMG from the Releases page just like a stable build.
- **App Store Connect** upload is **skipped** — App Store Connect rejects hyphen-suffixed `CFBundleShortVersionString`, so betas ship through the direct-distribution channel only. Use TestFlight separately if you also want an App Store beta.
- **Catalog check** in `bump-version.sh` looks up the base `X.Y.Z` entry in `ReleaseNotesCatalog.swift`. Betas of the same release share the stable's release notes; you don't need a separate entry per beta.

Beta testers see the catalog's `1.3.0` entry in the What's New sheet (since `1.2.3 < 1.3.0 ≤ 1.3.0-beta.1`). When the stable `1.3.0` ships later, testers on `1.3.0-beta.1` will *not* re-fire the sheet (the comparison treats `1.3.0-beta.1` as newer-than `1.3.0` for the `shouldShow` gate). That's intentional — they've already seen the notes.

To promote a beta to stable, bump again with the bare version and re-tag:

```bash
scripts/bump-version.sh 1.3.0
git push && git push origin v1.3.0
```

The stable tag goes through both channels (GitHub Release + App Store) as usual.

## Handling App Review rejection

### Rejection is metadata/policy only (no code change)

1. Keep the draft (or published) GitHub Release and the existing tag
2. Fix the App Store metadata in App Store Connect
3. Resubmit the same build, or upload a new build from the same commit with a higher build number
4. Publish the draft GitHub Release whenever ready

### Rejection requires a code change

1. Delete the draft GitHub Release and the tag (if the GitHub Release was already published, the semver is burned — use a new semver instead)
2. Fix the issue on `main`
3. Re-run `bump-version.sh` with the same semver (or a new one if the old version was published)
4. Tag the new commit and push
5. A new draft GitHub Release is created; submit the new App Store build

## Rollback

**Bad GitHub draft**: Delete the draft release and the tag, fix the issue, then re-tag.

**Bad published GitHub release**: Ship a patch version (preferred) or delete the release.

**Critical bug in a live App Store release**:

1. Remove the build from sale in App Store Connect immediately
2. Fix the bug, bump semver, tag, and submit a new build
3. Request expedited App Review if the bug is severe
4. The GitHub Release can go live immediately; the App Store fix is gated by review (typically 24-48h)
