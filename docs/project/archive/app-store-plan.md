# App Store Plan

Status: Launch completed; archived as the pre-launch decision record. The
README and website link to the live Mac App Store listing (commit `0c0b96c`), and
the App Store release workflow is in use. Follow the
[release process](../release-process.md) for current distribution steps. The
review status, pending work and launch checklist below are the historical
2026-03-31 snapshot, not the current App Store Connect state.

Written against the repository state on 2026-03-31.

App Store Connect status on 2026-03-31: the first submission has been uploaded manually and is waiting for App Review.

## Scope

This document is now a high-level status summary for the Mac App Store launch.

Detailed CI workflow planning lives in `app-store-ci-plan.md`.

## Historical status

- GitHub Releases remains the direct distribution channel.
- The Mac App Store channel now exists as a separate app with bundle ID `com.valtteriluoma.photo-export-appstore`.
- The first App Store build was submitted manually on 2026-03-31:
  - `MARKETING_VERSION`: `1.0.2`
  - `CURRENT_PROJECT_VERSION`: `2`
- The app is currently waiting for App Review in App Store Connect.
- App Store CI automation is planned separately and is not yet verified on GitHub Actions.

## Locked Decisions

- Mac App Store stays paid; GitHub Releases stays free.
- The App Store and GitHub channels use separate bundle IDs so they can coexist on the same Mac.
- Both channels share the same marketing version, but build numbers are independent.
- The first App Store submission is manual; CI automation comes after that.
- App Review submission and final release remain manual.

## Done

### Product and App Store setup

- App Store bundle ID has been registered.
- App Store Connect app record has been created.
- Apple Distribution certificate exists.
- Mac Installer Distribution certificate exists.
- A working App Store provisioning profile exists.
- The first App Store build has been archived and uploaded successfully.

### Engineering and release groundwork

- Direct distribution via GitHub Actions already ships.
- `release-direct.yml` sets `CURRENT_PROJECT_VERSION` at build time.
- `REGISTER_APP_GROUPS` has been set to `NO`.
- The `network.client` entitlement was validated as unnecessary and removed.
- The entitlements/privacy setup is in a good App Store state.
- Release process documentation covers the dual-channel model.

### App and website surface area

- The app contains website, privacy, and support links.
- The support page has real contact information.
- README and website copy were updated for the dual-channel model.
- The site currently presents the Mac App Store as not yet live, which is still correct while the app is in review.

## Still To Do

### Before launch is truly complete

- Wait for the App Review result.
- If Apple approves the build, release it manually in App Store Connect.
- Update the website and README from “coming soon” / pre-launch wording to the live App Store link once the app is released.

### If App Review rejects the build

- Address the rejection reason.
- Resubmit the same version with a higher build number if no semver bump is needed.
- If code changes are required after a public GitHub release, treat that as a normal follow-up release and bump versioning as needed.

### Follow-up work after the first launch

- Implement `release-app-store.yml` as described in `app-store-ci-plan.md`.
- Verify that App Store CI works on GitHub-hosted macOS runners before treating it as production-ready.

## Definition of Done

The App Store launch is fully done when all of the following are true:

- The current submission is approved or replaced by an approved submission.
- The app has been released manually in App Store Connect.
- The public website and README point to the live App Store listing.

The App Store automation work is separate from launch completion. It is a follow-up improvement, not a blocker for saying the first App Store launch shipped.
