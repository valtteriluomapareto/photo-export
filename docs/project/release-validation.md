# Pre-release Photos validation

Run this on the **final version-bumped candidate before pushing its release tag**, including betas and stable promotions, and attach the evidence to the release issue or PR. Hermetic CI does not establish real authorization, iCloud delivery, rendered bytes, sandboxed bookmarks or removable volumes; keep CI results separate from this evidence. After distribution artifacts exist, also complete [release process step7](release-process.md#7-verify-distribution-artifacts).

## What to run

- **Core smoke** — every release. Pass or fail only; it cannot be skipped or deferred.
- **Triggered rows** — rows whose files changed since the candidate where that row last passed:

  ```bash
  scripts/release/validation_rows.py --base v<previous release> [--row-base ROW=<last-pass SHA>|never ...]
  ```

  Take the `--row-base` values from the previous release's evidence. A skipped or deferred row stays owed until it passes; a row with no recorded pass is `never`. A row marked *via hub only* lists the commits that touched the hub; the owner may exclude it with a recorded reason that names those commits.
- **Full matrix** — when the script reports it (entitlements, privacy manifest, build settings, release workflows or scripts, an unmapped app file), or when the validation machine's macOS major version changed since a row's last pass (`--macos-major-changed`).
- **Betas** may defer triggered rows; they stay owed for the stable release. A stable promotion is a new version-bump commit: run the core smoke on its DMG and every row the beta deferred.

Tiering makes small releases cheap; a long batch still triggers most rows, so releasing more often keeps validation short.

## Validation environment (one-time)

Use a dedicated macOS account with its own System Photo Library. A candidate must never read or edit the maintainer's primary library, Photos access permission and the launch-at-login registration are shared per bundle id, and the signed candidate shares the installed app's sandbox container.

Keep, outside the repository, a fixture manifest and unmodified reference copies with a `shasum -c` checksum file. Use unique stems, none ending in ` (N)`:

- One **core month** with a local JPEG and HEIC, an edited still with an obvious crop or color change, an edited MOV/MP4 with a known trim, and an unedited Live Photo.
- Favorites and a nested user album with known subsets; a small Shared Album when available.
- For import: one file whose extension differs from Photos' only by case (`.jpg` vs `.JPG`).
- Several **iCloud-only** originals. Turn on **Optimize Mac Storage**, then add them from another device; Photos usually keeps them nonlocal until opened. Each export downloads the one it uses, so replenish them and record how each was verified as nonlocal before the run.

Keep Photo Export's state and the first scratch destination between releases; the upgrade step needs both. To return to a fresh install (Terminal needs **App Management** or **Full Disk Access** to remove the container):

```bash
osascript -e 'quit app "Photo Export"'; killall -u "$USER" cfprefsd
defaults delete com.valtteriluoma.photo-export 2>/dev/null
rm -rf ~/Library/Containers/com.valtteriluoma.photo-export ~/Library/Application\ Support/com.valtteriluoma.photo-export
tccutil reset Photos com.valtteriluoma.photo-export
test ! -e ~/Library/Containers/com.valtteriluoma.photo-export && echo reset-ok
```

Also remove Photo Export from **System Settings → General → Login Items** if present.

## Candidate build

Validate a signed, notarized build of the candidate SHA made with the release toolchain: run the `release-direct` dry run on a branch at the candidate and download its artifacts (`release-process.md` step3 selects `CANDIDATE_SHA`). Allow for the CI and notarization wait.

```bash
BRANCH="validation/<version>"
git push origin "$CANDIDATE_SHA:refs/heads/$BRANCH"
gh workflow run release-direct.yml --ref "$BRANCH" -f dry_run=true
RUN_ID="$(gh run list --workflow release-direct.yml --branch "$BRANCH" --limit 1 --json databaseId --jq '.[0].databaseId')"
gh run watch "$RUN_ID" --exit-status
test "$(gh run view "$RUN_ID" --json headSha --jq .headSha)" = "$CANDIDATE_SHA" && echo candidate-ok
gh run download "$RUN_ID" -n dmg -n checksum -D "$EVIDENCE"
(cd "$EVIDENCE/dmg" && shasum -a 256 -c ../checksum/*.sha256)
git push origin --delete "$BRANCH"
```

Install the DMG in the validation account; About shows the candidate version (the DMG file is named `0.0.0-dev`). Record the header:

```bash
APP="/Applications/Photo Export.app"
/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist"
codesign -dv "$APP" 2>&1 | grep -E '^(Authority=Developer ID|TeamIdentifier)'
sw_vers -productVersion
```

A local unsigned build runs unsandboxed and cannot exercise the upgrade, bookmark or container behavior. It is acceptable only for a beta, with core steps 1 and 6 recorded as owed until a signed build passes them.

## Core smoke

Keep snapshots in an evidence folder outside the destination. An empty diff and no ` (N).` suffix prove no duplicates or overwrites:

```bash
snapshot() { (cd "$1" && find . -type f ! -name .DS_Store -print0 | sort -z | xargs -0 shasum -a 256) > "$2"; }
snapshot "$DEST" "$EVIDENCE/before.txt"   # … run the step …
snapshot "$DEST" "$EVIDENCE/after.txt"; diff "$EVIDENCE/before.txt" "$EVIDENCE/after.txt"; grep -E ' \([0-9]+\)\.' "$EVIDENCE/after.txt"
(cd "$DEST/<YYYY>/<MM>" && shasum -a 256 -c "$REFERENCES/originals.sha256")
mdls -name kMDItemDurationSeconds "$DEST/<YYYY>/<MM>/<edited video>"; file "$DEST/<YYYY>/<MM>/<edited video>"
```

1. **Upgrade in place.** The state must come from the latest shipped release; if it came from an unreleased candidate, install the shipped DMG, export the core month and Favorites, then continue. Install the candidate over it and launch: the destination resolves without a re-grant, exported months and Favorites show as exported before any run, and repeating both leaves the snapshot unchanged.
2. **Fresh install.** Reset, then launch: onboarding appears at full size, Photos access is granted from it, and a fresh destination A can be chosen.
3. **Defaults export of the core month to A.** Originals match the references; the edited still shows its edit and the edited video plays with its trimmed duration and real container; the Live Photo exports its still only.
4. **Favorites to A.** The fixture subset lands under `Collections/Favorites/`. Take the `before` snapshot of A.
5. **Repeat and relaunch.** Repeat the month and Favorites on A; quit and relaunch (A resolves without a re-grant and exported state shows before any run); repeat again. The snapshot is unchanged. Save **Help → Save Diagnostic Report…**.
6. **Include originals** to a fresh destination B. `_orig` companions match the references; edits stay at the natural stem; no suffixed names.

Target: about 20–30 minutes once the environment exists, excluding the CI wait.

## Triggered rows

Before each row, reset Auto Export, Include originals, HEIC conversion, video subfolders and Live Photo pairing to off and enable only what the row names. Use fresh destinations for option comparisons and the same destination for repeat checks.

| Row (script id) | Action | Expected observation |
| --- | --- | --- |
| Local originals / HEIC conversion (`local`) | On fresh destinations enable HEIC conversion, then conversion plus Include originals. | Conversion writes a decodable JPEG; adding Include originals retains `<name>_orig.HEIC`; JPEG input is unaffected. |
| Edited still and video (`edited`) | Include originals on, video subfolders on, fresh destination. | Edits at natural stems; `_orig` companions preserve unmodified bytes; standalone videos and companions share `videos/`. Verify container and duration, not just extension. |
| Selected preview edit/revert (`preview`) | Keep the edited still selected; edit and revert it in Photos, then change an unrelated fixture. | The preview follows the edit and the revert, keeping its image while the replacement loads; unrelated edits leave it stable. |
| iCloud-only delivery (`icloud`) | Export a verified nonlocal fixture with network available. | A nonempty original arrives, opens and matches its reference. Errors are failures to investigate. |
| Live Photo pairing (`livephoto`) | Pairing on with video subfolders on, fresh destination. | Still plus playable paired video at the same stem, adjacent in the month folder, outside `videos/`. |
| Collections (`collections`) | Export the nested-album subset and an available Shared Album. | Files under `Collections/Albums/<folder>/<album>/` and `Collections/Shared Albums/<album>/`; Shared Albums use served resources, without `_orig` or paired video. |
| Authorization / onboarding (`authorization`) | Deny, then use **Open System Settings** to grant Photos access and return without quitting. | Denial shows neutral instructions and the Settings action; returning moves to onboarding or the library without another prompt. If macOS forces a relaunch, record that path. |
| Cancel / resume (`cancel`) | Cancel an active iCloud download or edited-video render, then export again; pause a month export, then choose **Export Month** for it again. | Unfinished variants are not complete; the retry produces openable output and preserves completed files. Export Month resumes the paused work in order with its original settings and no duplicates. |
| Destination reconnect (`destination`) | During export to a removable drive, disconnect, reconnect and retry; repeat with a network share remount when available. | Missing storage is surfaced without false success; the same destination keeps its progress and writes only missing work. Record filesystem and mount paths. |
| Auto Export / relaunch (`autoexport`) | Enable one scope and launch at login; let it settle; add an unexported fixture in Photos, wait for its export, then log out and in. | The new fixture exports; after login the app starts in the menu bar and its progress survives; unchanged assets produce no files. |
| Import existing backup / record recovery (`import`) | On a fresh install, import a destination exported earlier (including the case-only extension fixture); then export the same scope. | Counts match the files on disk; the export writes only what is missing; nothing is overwritten or suffixed. |

## Evidence

Copy into the release issue or PR. Blank lines are incomplete. **A failed row blocks the tag.**

```text
Candidate: version / merged SHA / CI run
Build: signed dry-run run URL (head SHA checked) | unsigned fallback / DMG SHA-256 (checksum artifact verified) / macOS
Upgrade from: version / SHA that produced the state
iCloud fixtures: how each was verified nonlocal
Row mapping: <validation_rows.py output, including --row-base values>
Core smoke: upgrade / fresh install / defaults / Favorites / repeat + relaunch / originals — pass|fail, snapshot diffs
Triggered rows: <row> — pass|fail, observation
Excluded hub-only rows: <rows> — reason naming the hub commits; <owner>, <date>
Skipped or deferred rows: <row> — reason; accepted by <owner>, <date>
Failures and fixes:
Row baselines for next release: --row-base <row>=<last-pass SHA>|never … (passed, untriggered and excluded rows move to this candidate)
Decision: <ship|block>, <owner>, <date>
```

If the candidate changes, rebuild, rerun the core smoke and the rows its diff triggers, and never reuse evidence for a different commit. Verify the tag points at the validated SHA before pushing it. App Review fixes and retagged unpublished releases follow the same gate.
