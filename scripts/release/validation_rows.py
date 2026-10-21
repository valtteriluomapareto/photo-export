#!/usr/bin/env python3
"""Decide which release-validation rows a candidate needs.

Every release runs the core smoke. Each other row in docs/project/release-validation.md
is required when the files its behavior depends on changed since the candidate where that
row last passed. Some changes require the full matrix: toolchain, signing, entitlements,
build settings, an app path this mapping does not know, or a new macOS major version on
the validation machine.

Usage:
  scripts/release/validation_rows.py --base v1.6.5 [--row-base ROW=REF ...]
      [--candidate HEAD] [--macos-major-changed]

`--base` is the default baseline for every row (normally the previous release tag);
`--row-base` overrides it for a row whose last pass is older, so skipped rows stay owed.
`--row-base ROW=never` marks a row that has no recorded pass.
"""

import argparse
import fnmatch
import re
import subprocess
import sys
from dataclasses import dataclass, field

ROWS = {
    "local": "Local originals / HEIC conversion",
    "edited": "Edited still and video",
    "preview": "Selected preview edit/revert",
    "icloud": "iCloud-only delivery",
    "livephoto": "Live Photo pairing",
    "collections": "Collections",
    "authorization": "Authorization / onboarding",
    "cancel": "Cancel / resume",
    "destination": "Destination reconnect",
    "autoexport": "Auto Export / relaunch",
    "import": "Import existing backup / record recovery",
}

PIPELINE = ("local", "edited", "icloud", "livephoto", "collections", "cancel")
PERSISTENCE = ("destination", "import", "autoexport", "cancel", "collections")
EVERY_ROW = tuple(ROWS)

# (glob relative to the repository, rows). Every matching rule applies. `*` stays within
# one path component; `**` crosses components. Mixed-purpose folders list their files
# explicitly, so a new file there fails the completeness test until someone maps it.
RULES = [
    # Hub files (listed in HUBS) and other widely shared files.
    ("photo-export/Export/ExportManager.swift", EVERY_ROW),
    ("photo-export/App/photo_exportApp.swift", ("authorization", "destination", "autoexport")),
    ("photo-export/App/AppCore.swift", ("authorization", "destination", "autoexport")),
    ("photo-export/App/AppComposition.swift", ("authorization", "destination", "autoexport")),
    ("photo-export/PhotoLibrary/PhotoLibraryManager.swift",
     ("local", "edited", "preview", "icloud", "livephoto", "collections", "authorization",
      "autoexport")),
    ("photo-export/ContentView.swift", ("authorization", "destination")),
    ("photo-export/Export/VariantExporter.swift", PIPELINE),
    ("photo-export/Records/*.swift", PERSISTENCE),
    ("photo-export/Protocols/PhotoLibraryService.swift", PIPELINE + ("preview", "authorization")),
    ("photo-export/Models/ExportRecord.swift", PERSISTENCE),
    ("photo-export/Models/ExportVariant*.swift", PIPELINE + ("import",)),
    ("photo-export/Models/ExportPlacement.swift", ("collections", "import") + PERSISTENCE),
    # Export pipeline.
    ("photo-export/Export/ExportQueueCoordinator.swift", ("cancel", "autoexport")),
    ("photo-export/Export/ExportJobPlanner.swift", ("local", "cancel", "autoexport")),
    ("photo-export/Export/ExportSettingsSnapshot.swift", ("local", "edited", "livephoto")),
    ("photo-export/Export/ResourceSelection.swift", ("local", "edited", "icloud", "livephoto")),
    ("photo-export/Export/ProductionImageConverter.swift", ("local",)),
    ("photo-export/Export/ProductionMediaRenderer.swift", ("edited", "icloud", "cancel")),
    ("photo-export/Export/ProductionAssetResourceWriter.swift", ("local", "edited", "icloud")),
    ("photo-export/Export/ExportFilenamePolicy.swift", ("local", "livephoto", "import")),
    ("photo-export/Export/CollectionPathComponentPolicy.swift", ("collections",)),
    ("photo-export/Export/ExportMediaPathPolicy.swift", ("livephoto", "edited")),
    ("photo-export/Export/ExportPlacementResolver.swift", ("collections",)),
    ("photo-export/Export/FileIOService.swift", ("local", "cancel", "destination")),
    ("photo-export/Export/FinalNamePlanner.swift", ("local", "cancel", "destination")),
    ("photo-export/Export/ExportRecordsDirectoryCoordinator.swift", ("destination", "import")),
    ("photo-export/Export/ExportManager+AutoSyncConformance.swift", ("autoexport",)),
    ("photo-export/Export/ImportCoordinator.swift", ("import",)),
    ("photo-export/Export/ManualExportAvailability.swift", ("local", "collections")),
    ("photo-export/Export/BackupScanner.swift", ("import",)),
    ("photo-export/Export/BackupScanner+Collections.swift", ("import", "collections")),
    ("photo-export/Export/CollectionBackupPlanner.swift", ("import", "collections")),
    # Feature folders.
    ("photo-export/AutoSync/**", ("autoexport",)),
    ("photo-export/Destination/**", ("destination",)),
    ("photo-export/Views/Collections/**", ("collections",)),
    # Photo library.
    ("photo-export/PhotoLibrary/PhotoLibraryPersistentChangeAdapter.swift",
     ("autoexport", "preview")),
    ("photo-export/PhotoLibrary/ReconciliationScheduler.swift", ("autoexport",)),
    ("photo-export/PhotoLibrary/PhotoLibraryManager+AutoSyncPhotosAuthorization.swift",
     ("authorization", "autoexport")),
    ("photo-export/PhotoLibrary/CollectionCountCache.swift", ("collections",)),
    ("photo-export/PhotoLibrary/FullImageRequestBridge.swift", ("preview",)),
    ("photo-export/PhotoLibrary/DecodedThumbnailCache.swift", ("preview",)),
    ("photo-export/PhotoLibrary/ThumbnailPreheatRegistrations.swift", ("preview",)),
    # App lifecycle.
    ("photo-export/App/AppLifecycleCoordinator.swift", ("destination", "autoexport")),
    ("photo-export/App/LoginItemController.swift", ("autoexport",)),
    ("photo-export/App/SystemLoginItemService.swift", ("autoexport",)),
    # Models.
    ("photo-export/Models/AutoSync*.swift", ("autoexport",)),
    ("photo-export/Models/AutoExportLibraryScope.swift", ("autoexport",)),
    ("photo-export/Models/PhotoLibraryPersistentChangeEvent.swift", ("autoexport",)),
    ("photo-export/Models/ExportRun*.swift", ("autoexport", "cancel")),
    ("photo-export/Models/Destination*.swift", ("destination",)),
    ("photo-export/Models/EditedProducer.swift", ("edited",)),
    ("photo-export/Models/RenderActivity.swift", ("edited",)),
    ("photo-export/Models/ExportVideoLayout.swift", ("edited", "livephoto")),
    ("photo-export/Models/AssetDescriptor.swift", ("local", "livephoto", "edited")),
    ("photo-export/Models/AssetDetails.swift", ("preview",)),
    ("photo-export/Models/ExportIssue.swift", ("icloud", "autoexport")),
    ("photo-export/Models/PhotoCollectionDescriptor.swift", ("collections",)),
    ("photo-export/Models/LibrarySelection.swift", ("collections",)),
    # Protocols.
    ("photo-export/Protocols/AutoSync*.swift", ("autoexport",)),
    ("photo-export/Protocols/PhotoLibraryChangeProviding.swift", ("autoexport",)),
    ("photo-export/Protocols/LoginItemService.swift", ("autoexport",)),
    ("photo-export/Protocols/AssetResourceWriter.swift", ("local", "edited", "icloud")),
    ("photo-export/Protocols/PHAssetCacheControlling.swift", ("icloud", "autoexport")),
    ("photo-export/Protocols/MediaRenderer.swift", ("edited", "cancel")),
    ("photo-export/Protocols/ImageConverter.swift", ("local",)),
    ("photo-export/Protocols/FileSystemService.swift", ("local", "cancel", "destination")),
    ("photo-export/Protocols/AtomicFileReplacing.swift", PERSISTENCE),
    ("photo-export/Protocols/DirectoryFsyncing.swift", PERSISTENCE),
    ("photo-export/Protocols/JSONLRecordLogIO.swift", PERSISTENCE),
    ("photo-export/Protocols/ExportDestination.swift", ("destination",)),
    ("photo-export/Protocols/DestinationSafetyConfirmationStore.swift",
     ("destination", "autoexport")),
    ("photo-export/Protocols/ReconciliationFileChecking.swift", ("destination", "import")),
    ("photo-export/Protocols/BackupDirectoryReading.swift", ("import",)),
    # Views.
    ("photo-export/Views/Settings/OnboardingView.swift", ("authorization",)),
    ("photo-export/Views/Shared/FirstRunWindowSizing.swift", ("authorization",)),
    ("photo-export/Views/Shared/LibraryRootView.swift", ("authorization", "collections")),
    ("photo-export/Views/Shared/AssetDetailView.swift", ("preview",)),
    ("photo-export/Views/Shared/ThumbnailView.swift", ("preview",)),
    ("photo-export/ViewModels/AssetDetailImageLoader.swift", ("preview",)),
    ("photo-export/Views/Settings/AutoExportSettingsView.swift", ("autoexport",)),
    ("photo-export/Views/Shared/AutoSync*.swift", ("autoexport",)),
    ("photo-export/Views/Export/AutoSyncAwareExportButton.swift", ("autoexport",)),
    ("photo-export/Views/Export/DestinationStatusBanner.swift", ("destination",)),
    ("photo-export/Views/Export/ImportView.swift", ("import",)),
    ("photo-export/Views/Export/RecordStoreAlertHost.swift", ("import", "destination")),
    ("photo-export/Views/Settings/DestinationRecordRecoveryView.swift",
     ("import", "destination")),
]

# Files so central that almost every release touches them. A row reached only through a
# hub is reported separately, with the subjects of the commits that touched the hub; the
# release owner may exclude it with a recorded reason. A hub commit whose subject names a
# row's area (ROW_KEYWORDS) makes that row required. Rows reached through a non-hub file
# are always required.
HUBS = {
    "photo-export/Export/ExportManager.swift",
    "photo-export/App/photo_exportApp.swift",
    "photo-export/PhotoLibrary/PhotoLibraryManager.swift",
    "photo-export/ContentView.swift",
    "photo-export/Protocols/PhotoLibraryService.swift",
}

ROW_KEYWORDS = {
    "local": r"original|heic|jpe?g|convert|filename",
    "edited": r"edited|render|video|adjust",
    "preview": r"preview|thumbnail",
    "icloud": r"icloud|download|network",
    "livephoto": r"live photo|paired",
    "collections": r"album|favorite|collection",
    "authorization": r"authori[sz]|permission|onboarding|first.?run|welcome",
    "cancel": r"cancel|pause|resume|interrupt",
    "destination": r"destination|volume|remount|bookmark|drive",
    "autoexport": r"auto.?export|autosync|auto-sync|login",
    "import": r"import|backup|recover",
}

# Covered by the core smoke alone: changes here need no extra row.
CORE_ONLY = [
    "photo-export/App/AppEntry.swift",
    "photo-export/Assets.xcassets/**",
    "photo-export/Resources/**",
    "photo-export/Helpers/**",
    "photo-export/Views/Timeline/**",
    "photo-export/ViewModels/MonthViewModel.swift",
    "photo-export/ViewModels/TimelineSidebarCounts.swift",
    "photo-export/Models/ReleaseNote.swift",
    "photo-export/Models/ReleaseNotesCatalog.swift",
    "photo-export/Models/SettingsTab.swift",
    "photo-export/Models/ExportProgressState.swift",
    "photo-export/Models/ManualExportSummary.swift",
    "photo-export/PhotoLibrary/ScreenshotPhotoLibraryService.swift",
    "photo-export/App/AppDiagnostics.swift",
    "photo-export/Helpers/Logger+App.swift",
    "photo-export/App/DiagnosticReporter.swift",
    "photo-export/App/BodyInvalidationCounter.swift",
    "photo-export/App/WhatsNewState.swift",
    "photo-export/Views/Settings/AboutView.swift",
    "photo-export/Views/Settings/AdvancedSettingsView.swift",
    "photo-export/Views/Settings/SettingsRootView.swift",
    "photo-export/Views/Settings/WhatsNewView.swift",
    "photo-export/Views/Export/ExportIssueMetadataRequest.swift",
    "photo-export/Views/Export/ExportIssuesView.swift",
    "photo-export/Views/Export/ExportProgressBar.swift",
    "photo-export/Views/Export/ExportToolbarView.swift",
]

# Any change here requires the full matrix: it shapes or signs the shipped binary.
FULL_MATRIX_PATHS = [
    "photo-export/photo_export.entitlements",
    "photo-export/PrivacyInfo.xcprivacy",
    "photo-export/Project.xcconfig",
    "photo-export/**/Info.plist",
    "photo-export.xcodeproj/xcshareddata/**",
    "scripts/ci/archive-appstore.sh",
    "scripts/ci/export-appstore.sh",
    "scripts/ci/prepare-pkg.sh",
    "scripts/ci/install-provisioning-profile.sh",
    "scripts/ci/setup-keychain-appstore.sh",
    ".xcode-version",
    "scripts/ci/select-xcode.sh",
]

PROJECT = "photo-export.xcodeproj/project.pbxproj"
# Project settings that both release pipelines override on the xcodebuild command line
# (release-direct.yml and scripts/ci/archive-appstore.sh), so the project's own values
# never reach a shipped build. A test keeps this list in sync with the pipelines.
PIPELINE_OVERRIDDEN_KEYS = (
    "CODE_SIGN_IDENTITY", "CODE_SIGN_STYLE", "DEVELOPMENT_TEAM", "OTHER_CODE_SIGN_FLAGS",
    "CURRENT_PROJECT_VERSION",
)
IGNORED_PROJECT_LINE = re.compile(
    r'^\s*"?(MARKETING_VERSION|' + "|".join(PIPELINE_OVERRIDDEN_KEYS) + r')(\[[^]]*\])?"?\s*=')
RELEASE_WORKFLOWS = ".github/workflows/release-*.yml"
# Whole release-workflow lines that cannot change the built binary: comments, trigger lines
# (which decide when a workflow runs, not what it builds), the concurrency group, pin bumps
# of the checkout/artifact actions, and echo/printf that only print (no redirection into
# $GITHUB_ENV, $GITHUB_OUTPUT or a file later steps read). Patterns match the whole line so
# a trigger-like prefix cannot hide a real change. Any other changed line requires the full
# matrix.
HARMLESS_WORKFLOW_LINE = re.compile(
    r"^\s*(#.*|(echo|printf)\b[^>]*|(on|push|tags|branches|schedule|concurrency):|"
    r"- (main|'v\*')|- cron: '[^']*'|group: [\w${}. -]*|"
    r"(- )?uses: actions/(checkout|upload-artifact|download-artifact)@([0-9a-f]{40}|v[0-9.]+)"
    r"( #.*)?|)\s*$")


def _regex(pattern):
    parts = []
    index = 0
    while index < len(pattern):
        if pattern.startswith("**/", index):
            parts.append("(?:.*/)?")
            index += 3
        elif pattern.startswith("**", index):
            parts.append(".*")
            index += 2
        elif pattern[index] == "*":
            parts.append("[^/]*")
            index += 1
        else:
            parts.append(re.escape(pattern[index]))
            index += 1
    return re.compile("^" + "".join(parts) + "$")


_RULES = [(_regex(pattern), rows) for pattern, rows in RULES]
_CORE_ONLY = [_regex(pattern) for pattern in CORE_ONLY]
_FULL_MATRIX = [_regex(pattern) for pattern in FULL_MATRIX_PATHS]


@dataclass
class Classification:
    rows: set = field(default_factory=set)
    core_only: bool = False
    full_matrix: bool = False
    outside_app: bool = False

    @property
    def unmapped(self):
        return not (self.rows or self.core_only or self.full_matrix or self.outside_app)


def classify(path):
    """Classifies one repository-relative path."""
    result = Classification()
    if any(regex.match(path) for regex in _FULL_MATRIX):
        result.full_matrix = True
        return result
    if not path.startswith("photo-export/"):
        result.outside_app = True
        return result
    for regex, rows in _RULES:
        if regex.match(path):
            result.rows.update(rows)
    result.core_only = any(regex.match(path) for regex in _CORE_ONLY)
    return result


@dataclass
class Assessment:
    rows: dict
    full_matrix_reasons: list
    unmapped: list
    named_rows: set = field(default_factory=set)

    def hub_only(self, row):
        """True when only hubs trigger `row` and no hub commit names its area."""
        paths = self.rows.get(row)
        return bool(paths) and all(p in HUBS for p in paths) and row not in self.named_rows


def assess(paths, project_diff, workflow_diffs=None, macos_major_changed=False,
           hub_subjects=(), deleted=()):
    """Maps changed paths to rows and lists reasons the full matrix is required.

    `project_diff` holds the +/- lines of the project.pbxproj diff; `workflow_diffs` maps a
    changed release workflow to its +/- lines; `hub_subjects` are the subjects of commits
    that touched a hub; `deleted` paths no longer exist at the candidate, so an unmapped
    deleted path cannot ship unknown code and does not require the full matrix.
    """
    rows = {}
    reasons = []
    unmapped = []
    for path in sorted(set(paths)):
        if path == PROJECT:
            changed = [
                line[1:] for line in project_diff
                if line[:1] in "+-" and line[1:].strip()
                and not IGNORED_PROJECT_LINE.match(line[1:])
            ]
            if changed:
                reasons.append(f"{PROJECT} changes build settings: {changed[0].strip()}")
            continue
        if fnmatch.fnmatchcase(path, RELEASE_WORKFLOWS):
            lines = (workflow_diffs or {}).get(path, [])
            hits = [line for line in lines if not HARMLESS_WORKFLOW_LINE.match(line[1:])]
            if hits:
                reasons.append(f"{path} changes the release build: {hits[0][1:].strip()}")
            continue
        found = classify(path)
        if found.full_matrix:
            reasons.append(f"{path} changed")
        elif found.unmapped:
            unmapped.append(path)
            if path not in deleted:
                reasons.append(f"{path} is not mapped to any row")
        for row in found.rows:
            rows.setdefault(row, []).append(path)
    if macos_major_changed:
        reasons.append("the validation machine's macOS major version changed")
    named = {
        row for row, pattern in ROW_KEYWORDS.items()
        if any(re.search(pattern, subject, re.IGNORECASE) for subject in hub_subjects)
    }
    return Assessment(rows=rows, full_matrix_reasons=reasons, unmapped=unmapped, named_rows=named)


class GitError(Exception):
    pass


def _git(*args):
    result = subprocess.run(["git", *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise GitError(f"git {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout


def _diff_lines(spec, path):
    lines = _git("diff", "-U0", "--no-renames", spec, "--", path).splitlines()
    return [line for line in lines if line[:1] in "+-" and not line.startswith(("+++", "---"))]


def hub_commits(base, candidate):
    """`<sha> <subject>` for commits in the range that touched a hub."""
    return _git("log", "--format=%h %s", f"{base}..{candidate}", "--", *sorted(HUBS)).splitlines()


def assess_git(base, candidate, macos_major_changed=False):
    spec = f"{base}..{candidate}"
    paths = [p for p in _git("diff", "--name-only", "--no-renames", "-z", spec).split("\0") if p]
    workflows = {
        path: _diff_lines(spec, path)
        for path in paths if fnmatch.fnmatchcase(path, RELEASE_WORKFLOWS)
    }
    deleted = [
        p for p in _git("diff", "--name-only", "--no-renames", "--diff-filter=D", "-z", spec)
        .split("\0") if p
    ]
    subjects = [line.split(" ", 1)[-1] for line in hub_commits(base, candidate)]
    return assess(paths, _diff_lines(spec, PROJECT), workflows, macos_major_changed, subjects,
                  deleted)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--base", required=True, help="default baseline, e.g. the previous tag")
    parser.add_argument("--row-base", action="append", default=[], metavar="ROW=REF",
                        help="older baseline for a row whose last pass predates --base, "
                        "or 'never' for a row with no recorded pass")
    parser.add_argument("--candidate", default="HEAD")
    parser.add_argument("--macos-major-changed", action="store_true")
    args = parser.parse_args(argv)

    bases = {row: args.base for row in ROWS}
    for item in args.row_base:
        row, _, ref = item.partition("=")
        if row not in ROWS or not ref:
            parser.error(f"unknown row in --row-base {item!r}; rows: {', '.join(ROWS)}")
        bases[row] = ref

    try:
        results = {
            base: assess_git(base, args.candidate, args.macos_major_changed)
            for base in sorted(set(bases.values()) - {"never"})
        }
        hubs = {base: hub_commits(base, args.candidate) for base in results}
    except GitError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    print("Core smoke: required")
    for row, title in ROWS.items():
        base = bases[row]
        if base == "never":
            print(f"{title} (never passed): TRIGGERED - no recorded pass")
            continue
        result = results[base]
        paths = result.rows.get(row)
        if result.full_matrix_reasons:
            print(f"{title} (since {base}): TRIGGERED - full matrix")
        elif paths and result.hub_only(row):
            print(f"{title} (since {base}): TRIGGERED via hub only - "
                  f"{', '.join(sorted(paths))} (may be excluded with a recorded reason)")
            for commit in hubs[base]:
                print(f"    {commit}")
        elif paths:
            direct = sorted(path for path in paths if path not in HUBS) or sorted(paths)
            print(f"{title} (since {base}): TRIGGERED - {', '.join(direct)}")
        else:
            print(f"{title} (since {base}): not triggered")
    affected = {base: result.full_matrix_reasons for base, result in results.items()
                if result.full_matrix_reasons}
    if not affected:
        print("Full matrix: not required")
    for base, reasons in sorted(affected.items()):
        print(f"Full matrix: REQUIRED for rows since {base}")
        for reason in reasons:
            print(f"  - {reason}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
