# Pre-release Photos validation

Run this smoke on the **final version-bumped candidate before pushing its release tag**, including betas and stable promotions. Attach the evidence below to the release issue or PR. This guide defines required observations; it is not evidence of a completed run.

Hermetic tests exercise contracts with fakes. They do not establish real authorization, iCloud delivery, rendered bytes, or removable-volume behavior. Keep CI results separate from manual evidence. After distribution artifacts exist, complete the signed-channel checks in [the release process](release-process.md#7-verify-distribution-artifacts).

## Candidate and fixtures

Use an isolated macOS test account, dedicated Photos library, and scratch export folders. Confirm Photo Export displays the intended seeds before testing. Opening another library in Photos alone is insufficient: other apps use the System Photo Library, and iCloud Photos/Shared Albums require it ([Apple's guidance](https://support.apple.com/en-us/104946)). Use only test accounts/libraries for that setup; do not switch or edit a user's primary library.

Keep a small fixture manifest with filenames, creation month, media kind, and identifying features:

- Local unedited JPEG and HEIC, with unmodified reference files.
- Edited still with an obvious crop/color change and edited MOV/MP4 with a known trim/duration; retain unmodified references.
- Unedited Live Photo with still and motion resources.
- An iCloud-only original whose absence from local storage is verified on this machine. Record how; successful export alone does not prove this precondition. Otherwise mark the case **unexercised**.
- Favorites and a nested user album containing known subsets; a small Shared Album when available.

Use unique stems. Before **each matrix row**, reset Auto Export, Include originals, HEIC conversion, video subfolders, and Live Photo pairing to off; enable only the options that row specifies. Record setting changes. Use fresh scratch destinations for new-export option comparisons, then keep the same destination for each repeat/relaunch check. Do not publish private test media.

Include all intended candidate changes, release notes and the version bump in a reviewed PR. After green CI and merge, select that exact merged candidate and require a clean `git status --short` before building; record its SHA and create the tag at that SHA only after validation and the release decision. Keep the candidate checkout unchanged during the smoke. If it changes, rebuild the new candidate and repeat relevant checks. Build without screenshot overrides:

```bash
xcodebuild \
  -project photo-export.xcodeproj \
  -scheme "photo-export" \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build/ReleaseValidation \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Quit any installed copy and launch `build/ReleaseValidation/Build/Products/Release/Photo Export.app`. Record its path, executable checksum, configuration, bundle identifier/version, and `git rev-parse HEAD`; confirm About shows the candidate version. This unsigned build does not validate distribution signing, sandbox entitlements, or channel-specific permissions. Retain the later installed-artifact checks.

## Smoke matrix

`<name>` is the fixture's recorded stem; timeline paths use `<YYYY>/<MM>/`. For each row record **pass**, **fail**, or **unexercised**, with actual observations and evidence.

| Case | Action | Expected observation |
| --- | --- | --- |
| Local originals / HEIC conversion | Export the local month with defaults. On fresh destinations enable HEIC conversion, then conversion plus Include originals. | Defaults preserve original JPEG/HEIC bytes at natural filenames. Conversion writes a decodable JPEG; adding Include originals retains `<name>_orig.HEIC`. JPEG input is unaffected. |
| Edited still and video | Export with Include originals off, then on to a fresh destination; enable video subfolders on the latter run. | Natural-stem files show the edit and play the trimmed video. `_orig` companions preserve unmodified bytes. Standalone videos and companions share `videos/` when enabled. Verify actual container and duration, not just extension. |
| Selected preview edit/revert | Keep the edited still selected in Photo Export; edit and revert it in the dedicated Photos library without navigating away, then change an unrelated fixture. | The selected full-size preview follows the edited and reverted content, retaining its image while replacement loads. Unrelated edits leave the displayed selection stable. Record actual before/after content; synthetic image-request tests do not satisfy this row. |
| iCloud-only delivery | Export the verified nonlocal fixture with network available. | A nonempty original arrives, opens, and matches its unmodified reference. Download/render errors are failures to investigate. If the nonlocal precondition/network is unavailable, record unexercised. |
| Live Photo pairing | Export with pairing off, then on to a fresh destination; explicitly enable video subfolders for the latter. | Off writes the still only. On writes still plus playable paired video at the same stem, using the resource's extension. Both stay adjacent in the month folder, outside `videos/`. |
| Collections | Export known Favorites, nested-album, and available Shared Album subsets. | Correct placement counts and files under `Collections/Favorites/`, `Collections/Albums/<folder>/<album>/`, and `Collections/Shared Albums/<album>/`. Shared Albums use served reduced-quality resources; no `_orig` or paired-video promise. |
| Authorization denial / regrant | In the dedicated test account, keep the candidate running after denial. Use **Open System Settings** to reach **Privacy & Security → Photos**, enable access, then return without manually quitting. Follow and record any OS relaunch prompt. | Denial shows neutral instructions and the Settings action. If the process remains running, returning leaves the authorization pane for onboarding/library without another prompt. Verify fixture access/export. If macOS forces relaunch, record the running-process path as unexercised; fake authorization tests do not validate this OS behavior. Do not assume macOS offers Selected Photos controls. |
| Cancel / resume | Cancel an active iCloud download or edited-video render, then repeat export; record the interrupted phase. | Unfinished variants are not complete. Retry produces openable/playable output and preserves completed files. Mark a phase unexercised if no active operation could be interrupted. |
| Destination reconnect | During export to a scratch removable drive, disconnect, reconnect the same volume/folder, and retry. Exercise network remount too when available. | Missing storage is surfaced without false success. The same logical destination retains progress and writes missing work, preserving completed files. Record format, mount paths, and safety confirmation/regrant. |
| Auto Export / relaunch | Enable one fixture scope; let initial work settle. Add a previously unexported test fixture in Photos, wait for its change-triggered export, then quit/relaunch and repeat that scope. | The new fixture exports, the run finishes, and progress survives relaunch. Unchanged assets/settings produce no extra files. Record run/timing evidence; startup's initial scan alone does not satisfy this case. |

For each successful run, open outputs in Preview/QuickTime, check detail/export state against disk, and compare preserved originals to identified reference checksums. For rendered/conversion outputs compare visible content, dimensions, and playback/duration; byte equality is not required.

Repeat unchanged settings/scope on the **same destination**, then quit/relaunch and repeat again. Record counts and checksums: no duplicate suffix files, overwrites, or lost exported state. Do not reset records or use a fresh destination for this persistence check. Save **Help → Save Diagnostic Report…** after normal runs and failures; correlate variant/run records with disk. Record accepted fallback/missing-resource states explicitly and investigate unexpected fallbacks.

## Evidence and release decision

Copy this template into the release issue/PR and link restricted artifacts as appropriate. Blank rows are incomplete. **Failed cases block tag push.** Every unexercised case needs a reason, residual risk, and an explicit release-owner decision to defer or accept that coverage gap; it never counts as passed.

```text
Candidate version / intended tag:
Candidate commit / tag target commit:
App path / executable SHA-256:
Configuration / bundle identifier / About version:
macOS / hardware:
Test library / fixture manifest / iCloud-only verification:
Destination identity / filesystem / local, removable or network / mount paths:
CI run URL and head commit (hermetic evidence):

Case | settings + fixture IDs | pass/fail/unexercised | actual result + artifact
Local originals / HEIC conversion |
Edited still and video |
Selected preview edit/revert |
iCloud-only delivery |
Live Photo pairing |
Collections |
Authorization denial / regrant |
Cancel / resume (phase) |
Destination reconnect |
Auto Export / relaunch |
Repeat + relaunch counts/checksums / diagnostic report links:

Failures and linked fixes:
Each unexercised case: reason / residual risk / release-owner decision:
Candidate changes: diff assessment / cases rerun / new commit:
Release decision / responsible maintainer / date:
```

After candidate changes, rebuild and record the new commit/artifact plus relevant reruns. Version-only promotion still needs an explicit diff assessment and version verification; never silently reuse beta evidence for a different commit. Verify the intended tag points to the approved candidate before pushing. App Review fixes and retagged unpublished releases follow the same gate.

For deeper exercises, see historical [edited-photo Group A and B1](archive/edited-photos-manual-testing-guide.md#group-a--default-mode) and [Favorites/nested-album scenarios](archive/collections-export-manual-testing-guide.md#2-favorites-export). Their historical notes do not override this matrix or current [feature behavior](../../website/src/content/docs/features.md).
