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
    # Hubs: shared by many rows (see HUBS).
    ("photo-export/Export/ExportManager.swift", EVERY_ROW),
    ("photo-export/App/photo_exportApp.swift", ("authorization", "destination", "autoexport")),
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
    ("photo-export/Export/ExportPathPolicy.swift", ("collections",)),
    ("photo-export/Export/ExportPlacementPathPolicy.swift", ("livephoto", "edited")),
    ("photo-export/Export/ExportPlacementResolver.swift", ("collections",)),
    ("photo-export/Export/FileIOService.swift", ("local", "cancel", "destination")),
    ("photo-export/Export/ExportRecordsDirectoryCoordinator.swift", ("destination", "import")),
    ("photo-export/Export/ExportManager+AutoSyncConformance.swift", ("autoexport",)),
    ("photo-export/Export/ImportCoordinator.swift", ("import",)),
    ("photo-export/Export/BackupScanner.swift", ("import",)),
    # Feature folders.
    ("photo-export/AutoSync/**", ("autoexport",)),
    ("photo-export/Destination/**", ("destination",)),
    ("photo-export/Views/Collections/**", ("collections",)),
    # Photo library.
    ("photo-export/PhotoLibrary/PhotoLibraryPersistentChangeAdapter.swift",
     ("autoexport", "preview")),
    ("photo-export/PhotoLibrary/ReconciliationScheduler.swift", ("autoexport",)),
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
# hub is reported separately: the release owner may exclude it with a recorded reason
# (for example "ExportManager change only renames a log message"); rows reached through
# a non-hub file are always required.
HUBS = {
    "photo-export/Export/ExportManager.swift",
    "photo-export/App/photo_exportApp.swift",
    "photo-export/PhotoLibrary/PhotoLibraryManager.swift",
    "photo-export/ContentView.swift",
    "photo-export/Export/VariantExporter.swift",
    "photo-export/Protocols/PhotoLibraryService.swift",
}

# Covered by the core smoke alone: changes here need no extra row.
CORE_ONLY = [
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

# Any change here requires the full matrix.
FULL_MATRIX_PATHS = [
    "photo-export/photo_export.entitlements",
    "photo-export/PrivacyInfo.xcprivacy",
    "photo-export/Project.xcconfig",
    "photo-export/**/Info.plist",
    ".xcode-version",
]

PROJECT = "photo-export.xcodeproj/project.pbxproj"
VERSION_ONLY = re.compile(r"^\s*(MARKETING_VERSION|CURRENT_PROJECT_VERSION)\s*=")
RELEASE_WORKFLOWS = ".github/workflows/release-*.yml"
TOOLCHAIN_OR_SIGNING = re.compile(
    r"XCODE_PATH|Xcode_|xcode-select|DEVELOPER_DIR|CODE_SIGN|DEVELOPMENT_TEAM|"
    r"ExportOptions|exportOptions|signingStyle|signingCertificate|teamID|notarytool",
    re.IGNORECASE)


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

    def hub_only(self, row):
        """True when every path triggering `row` is a hub."""
        return bool(self.rows.get(row)) and all(path in HUBS for path in self.rows[row])


def assess(paths, project_diff, workflow_diffs=None, macos_major_changed=False):
    """Maps changed paths to rows and lists reasons the full matrix is required.

    `project_diff` holds the +/- lines of the project.pbxproj diff; `workflow_diffs` maps a
    changed release workflow to its +/- lines.
    """
    rows = {}
    reasons = []
    unmapped = []
    for path in sorted(set(paths)):
        if path == PROJECT:
            changed = [
                line[1:] for line in project_diff
                if line[:1] in "+-" and line[1:].strip() and not VERSION_ONLY.match(line[1:])
            ]
            if changed:
                reasons.append(f"{PROJECT} changes build settings: {changed[0].strip()}")
            continue
        if fnmatch.fnmatchcase(path, RELEASE_WORKFLOWS):
            lines = (workflow_diffs or {}).get(path, [])
            hits = [line for line in lines if TOOLCHAIN_OR_SIGNING.search(line)]
            if hits:
                reasons.append(f"{path} changes the toolchain or signing: {hits[0][1:].strip()}")
            continue
        found = classify(path)
        if found.full_matrix:
            reasons.append(f"{path} changed")
        elif found.unmapped:
            unmapped.append(path)
            reasons.append(f"{path} is not mapped to any row")
        for row in found.rows:
            rows.setdefault(row, []).append(path)
    if macos_major_changed:
        reasons.append("the validation machine's macOS major version changed")
    return Assessment(rows=rows, full_matrix_reasons=reasons, unmapped=unmapped)


def _git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True, check=True).stdout


def assess_git(base, candidate, macos_major_changed=False):
    spec = f"{base}..{candidate}"
    paths = _git("diff", "--name-only", "-M", spec).split()
    project = _git("diff", "-U0", spec, "--", PROJECT).splitlines()
    project = [line for line in project if not line.startswith(("+++", "---"))]
    workflows = {}
    for path in paths:
        if fnmatch.fnmatchcase(path, RELEASE_WORKFLOWS):
            lines = _git("diff", "-U0", spec, "--", path).splitlines()
            workflows[path] = [line for line in lines if not line.startswith(("+++", "---"))]
    return assess(paths, project, workflows, macos_major_changed)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--base", required=True, help="default baseline, e.g. the previous tag")
    parser.add_argument("--row-base", action="append", default=[], metavar="ROW=REF",
                        help="older baseline for a row whose last pass predates --base")
    parser.add_argument("--candidate", default="HEAD")
    parser.add_argument("--macos-major-changed", action="store_true")
    args = parser.parse_args(argv)

    bases = {row: args.base for row in ROWS}
    for item in args.row_base:
        row, _, ref = item.partition("=")
        if row not in ROWS or not ref:
            parser.error(f"unknown row in --row-base {item!r}; rows: {', '.join(ROWS)}")
        bases[row] = ref

    results = {}
    for base in sorted(set(bases.values())):
        results[base] = assess_git(base, args.candidate, args.macos_major_changed)

    print("Core smoke: required")
    reasons = sorted({reason for result in results.values() for reason in result.full_matrix_reasons})
    for row, title in ROWS.items():
        result = results[bases[row]]
        paths = result.rows.get(row)
        if result.full_matrix_reasons:
            print(f"{title} (since {bases[row]}): TRIGGERED - full matrix")
        elif paths and result.hub_only(row):
            print(f"{title} (since {bases[row]}): TRIGGERED via hub only - "
                  f"{', '.join(sorted(paths))} (may be excluded with a recorded reason)")
        elif paths:
            direct = sorted(path for path in paths if path not in HUBS)
            print(f"{title} (since {bases[row]}): TRIGGERED - {', '.join(direct)}")
        else:
            print(f"{title} (since {bases[row]}): not triggered")
    if reasons:
        print("Full matrix: REQUIRED")
        for reason in reasons:
            print(f"  - {reason}")
    else:
        print("Full matrix: not required")
    return 0


if __name__ == "__main__":
    sys.exit(main())
