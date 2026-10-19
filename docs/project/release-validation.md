# Pre-release Photos validation

Run this on the **final version-bumped candidate before pushing its release tag**, including betas and stable promotions, and attach the evidence to the release issue or PR. Hermetic CI exercises contracts with fakes; it does not establish real authorization, iCloud delivery, rendered bytes, sandboxed bookmarks or removable volumes, so keep CI results separate from this evidence. After distribution artifacts exist, also complete the signed-channel checks in [the release process](release-process.md#7-verify-distribution-artifacts).

## What to run

- **Core smoke** — every release. Pass or fail only; it cannot be skipped or deferred.
- **Triggered rows** — the rows whose code changed since the candidate where that row last passed. Decide them with:

  ```bash
  scripts/release/validation_rows.py --base v<previous release> [--row-base ROW=<last-pass SHA> ...]
  ```

  A skipped or deferred row stays owed: next time pass `--row-base` with its last passing candidate. A row marked *via hub only* (reached only through a widely shared file such as `ExportManager.swift`) may be excluded with a recorded reason after reading the hub's diff.
- **Full matrix** — when the script reports it (entitlements, privacy manifest, build settings, release toolchain or signing, or an app file the mapping does not know) or when the validation machine's macOS major version changed since a row's last pass (`--macos-major-changed`).
- **Betas** may defer triggered rows; they stay owed for the stable release. Promoting the same SHA to stable needs only a diff assessment.

Tiering makes small releases cheap. A long batch of changes still triggers most rows, so releasing more often is what keeps validation short.

## Validation environment (one-time)

Use a dedicated macOS account with its own System Photo Library. A candidate must never read or edit the maintainer's primary library: Photos access permission is shared per bundle id, two copies of the app compete for the launch-at-login registration, and the signed candidate shares the installed app's sandbox container. Opening another library in Photos is not enough, because Photo Export reads the System Photo Library ([Apple's guidance](https://support.apple.com/en-us/104946)).

Keep, outside the repository, a fixture manifest (filenames, creation month, media kind, identifying features) and unmodified reference copies with checksums:

- One **core month** holding a local JPEG and HEIC, an edited still with an obvious crop or color change, an edited MOV/MP4 with a known trim, and an unedited Live Photo.
- Favorites and a nested user album with known subsets; a small Shared Album when available.
- Several **iCloud-only** originals. Keep them off this Mac with **Optimize Mac Storage** and re-verify before each run (an export usually downloads the asset).

Leave Photo Export's state in place between releases; the core smoke's upgrade step uses it. To return to a fresh install:

```bash
osascript -e 'quit app "Photo Export"'
rm -rf ~/Library/Containers/com.valtteriluoma.photo-export
rm -rf ~/Library/Application\ Support/com.valtteriluoma.photo-export   # unsigned builds
defaults delete com.valtteriluoma.photo-export 2>/dev/null; killall -u "$USER" cfprefsd
tccutil reset Photos com.valtteriluoma.photo-export
```

Also remove Photo Export from **System Settings → General → Login Items** if present.

## Candidate build

Validate the shipped binary: the signed, notarized dry-run DMG built by CI from the exact candidate (see [release process step3](release-process.md#3-validate-the-exact-merged-candidate)). Push the candidate to a branch, run **Actions → release-direct** on it with `dry_run: true`, and download the `dmg` artifact:

```bash
git push origin "$CANDIDATE_SHA:refs/heads/validation/<version>"
```

The DMG is named `0.0.0-dev`; About shows the candidate version. Install it in the validation account and record the header:

```bash
APP="/Applications/Photo Export.app"
shasum -a 256 path/to/downloaded.dmg
/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist"
codesign -dv "$APP" 2>&1 | grep -E '^(Authority=Developer ID|TeamIdentifier)'
sw_vers -productVersion
```

If a signed dry run cannot be produced, record why and build the candidate locally. That build runs unsandboxed (its state lives in `~/Library/Application Support/` and `~/Library/Preferences/`), so bookmark and container behavior are not validated:

```bash
xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build/ReleaseValidation CODE_SIGNING_ALLOWED=NO build
```

## Core smoke

Compare destinations with checksum snapshots; an empty diff and no ` (n).` suffix proves no duplicates or overwrites:

```bash
snapshot() { (cd "$1" && find . -type f ! -name .DS_Store -print0 | sort -z | xargs -0 shasum -a 256) > "$2"; }
snapshot "$DEST" before.txt   # … run the step …
snapshot "$DEST" after.txt; diff before.txt after.txt; grep -E ' \([0-9]+\)\.' after.txt
```

1. **Upgrade in place.** With the previous release's state still present (first time: install the previous release, export the core month and Favorites), install the candidate over it and launch. The destination resolves without a re-grant, exported months and Favorites show as exported before any run, and repeating both exports leaves the snapshot unchanged.
2. **Fresh install.** Reset, then launch: onboarding appears at full size, Photos access is granted from it, and a fresh scratch destination can be chosen.
3. **Defaults export of the core month.** Originals keep their bytes at natural filenames (checksums match the references); the edited still shows its edit and the edited video plays with its trimmed duration and real container; the Live Photo exports its still only.
4. **Include originals** to a second fresh destination. `_orig` companions match the references byte for byte; edits stay at the natural stem; no suffixed names.
5. **Favorites** to the first destination: the fixture subset lands under `Collections/Favorites/`.
6. **Repeat and relaunch.** Repeat the month and Favorites on the first destination; quit and relaunch (the destination resolves without a re-grant and exported state shows before any run); repeat again. The snapshot is unchanged. Save **Help → Save Diagnostic Report…**.

Target: about 20–30 minutes once the environment exists.

## Triggered rows

Before each row, reset Auto Export, Include originals, HEIC conversion, video subfolders and Live Photo pairing to off and enable only what the row names. Use fresh destinations for option comparisons and the same destination for repeat checks.

| Row (script id) | Action | Expected observation |
| --- | --- | --- |
| Local originals / HEIC conversion (`local`) | On fresh destinations enable HEIC conversion, then conversion plus Include originals. | Conversion writes a decodable JPEG; adding Include originals retains `<name>_orig.HEIC`; JPEG input is unaffected. |
| Edited still and video (`edited`) | Include originals on, video subfolders on, fresh destination. | Edits at natural stems; `_orig` companions preserve unmodified bytes; standalone videos and companions share `videos/`. Verify container and duration, not just extension. |
| Selected preview edit/revert (`preview`) | Keep the edited still selected; edit and revert it in Photos, then change an unrelated fixture. | The preview follows the edit and the revert, keeping its image while the replacement loads; unrelated edits leave it stable. |
| iCloud-only delivery (`icloud`) | Export a re-verified nonlocal fixture with network available. | A nonempty original arrives, opens and matches its reference. Errors are failures to investigate. |
| Live Photo pairing (`livephoto`) | Pairing on with video subfolders on, fresh destination. | Still plus playable paired video at the same stem, adjacent in the month folder, outside `videos/`. |
| Collections (`collections`) | Export the nested-album subset and an available Shared Album. | Files under `Collections/Albums/<folder>/<album>/` and `Collections/Shared Albums/<album>/`; Shared Albums use served resources, without `_orig` or paired video. |
| Authorization / onboarding (`authorization`) | Deny, then use **Open System Settings** to grant Photos access and return without quitting. | Denial shows neutral instructions and the Settings action; returning moves to onboarding or the library without another prompt. If macOS forces a relaunch, record that path. |
| Cancel / resume (`cancel`) | Cancel an active iCloud download or edited-video render, then export again; record the interrupted phase. | Unfinished variants are not complete; the retry produces openable output and preserves completed files. |
| Destination reconnect (`destination`) | During export to a removable drive, disconnect, reconnect and retry; repeat with a network share remount when available. | Missing storage is surfaced without false success; the same destination keeps its progress and writes only missing work. Record filesystem and mount paths. |
| Auto Export / relaunch (`autoexport`) | Enable one scope and launch at login; let it settle; add an unexported fixture in Photos, wait for its export, then log out and in. | The new fixture exports; after login the app starts in the menu bar and its progress survives; unchanged assets produce no files. |
| Import existing backup / record recovery (`import`) | On a fresh install, import a destination exported earlier; then export the same scope. | Counts match the files on disk; the export writes only what is missing; nothing is overwritten or suffixed. |

## Evidence

Copy into the release issue or PR. Blank lines are incomplete. **A failed row blocks the tag.**

```text
Candidate: version / merged SHA / CI run
Build: DMG SHA-256 / signing authority / macOS on the validation machine
Row mapping: <validation_rows.py output, including any --row-base values>
Core smoke: upgrade / fresh install / defaults / originals / Favorites / repeat + relaunch — pass|fail, snapshot diffs
Triggered rows: <row> — pass|fail, observation
Excluded hub-only rows: <row> — reason
Skipped or deferred rows: <row> — reason; accepted by <owner>, <date> (stays owed)
Failures and fixes:
Decision: <ship|block>, <owner>, <date>
```

If the candidate changes, rebuild and rerun the rows its diff triggers. Never reuse evidence for a different commit; verify the tag points at the validated SHA before pushing it. App Review fixes and retagged unpublished releases follow the same gate.

For deeper exercises, see the historical [edited-photo](archive/edited-photos-manual-testing-guide.md#group-a--default-mode) and [Favorites/nested-album](archive/collections-export-manual-testing-guide.md#2-favorites-export) guides; they do not override this page or current [feature behavior](../../website/src/content/docs/features.md).
