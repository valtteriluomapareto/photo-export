#!/usr/bin/env python3
"""Generate additional immutable fixtures with unchanged, released store code.

Run manually, outside CI. Each release gets a detached scratch worktree; no app
entry point or Photos-library API is executed. Output must be a fresh directory.
The manifest fragment is additive: never replace the original record provenance.
"""

import argparse
import hashlib
import json
import platform
from pathlib import Path
import shutil
import subprocess
import tempfile

REPOSITORY = Path(__file__).resolve().parents[2]
MODELS = [
    "AutoExportLibraryScope", "AutoSyncDirtyState", "AutoSyncRetryState",
    "AutoSyncFailureCategory", "AutoSyncReason", "AutoSyncBlockedReason",
    "ExportRunContext", "ExportRunScope", "ExportRunFailureDetail", "ExportVariant",
    "ExportRecord", "ExportPlacement", "AssetDescriptor", "DestinationFingerprint",
    "DestinationSnapshot", "DestinationSafetyState",
]
PROTOCOLS = [
    "AutoSyncDirtyStateStore", "AutoSyncRetryStateStore", "AutoSyncRunSummaryStore",
    "AutoSyncPerDestinationTokenStore", "AutoSyncDestinationProviding",
    "DestinationSafetyConfirmationStore",
]
STORES = [
    "FileBackedAutoSyncDirtyStateStore", "FileBackedAutoSyncRetryStateStore",
    "FileBackedAutoSyncRunSummaryStore", "FileBackedAutoSyncPerDestinationTokenStore",
    "UserDefaultsAutoExportScopeStore", "FileBackedDestinationSafetyConfirmationStore",
]
RELEASES = {
    "v1.3.0": "63e3b0f7f934054781b96f68190900f00b316144",
    "v1.6.1": "93e0b8035f7b31c19ca89537be26ba77387068c0",
    "v1.6.5": "0b0eb9b786311a961f9051d14e2e93cb0ecca135",
}
JOURNAL = [
    "Models/AutoSyncRunJournal.swift", "Protocols/AutoSyncCurrentRunStore.swift",
    "Protocols/DirectoryFsyncing.swift",
    "AutoSync/Stores/FileBackedAutoSyncCurrentRunStore.swift",
]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def sources(tag):
    if tag == "v1.6.1":
        return JOURNAL
    folder = "Managers" if tag == "v1.3.0" else "AutoSync/Stores"
    paths = [f"Models/{name}.swift" for name in MODELS]
    paths += [f"Protocols/{name}.swift" for name in PROTOCOLS]
    paths += [f"{folder}/{name}.swift" for name in STORES]
    if tag == "v1.6.5":
        paths.remove(f"{folder}/FileBackedDestinationSafetyConfirmationStore.swift")
        paths += [
            "Destination/FileBackedDestinationSafetyConfirmationStore.swift",
            "Destination/ExportDestinationManager.swift", "Destination/DestinationIdentity.swift",
            "Protocols/ExportDestination.swift",
        ] + JOURNAL
    return paths


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists():
        parser.error("output must not exist; committed fixtures are immutable")
    runtime = {
        "toolchain": subprocess.check_output(["xcrun", "swiftc", "--version"], text=True).strip(),
        "hostRuntime": subprocess.check_output(["sw_vers"], text=True).strip(),
        "target": f"{platform.machine()}-apple-macos15.0",
    }
    with tempfile.TemporaryDirectory(prefix="photo-export-released-writers-") as temporary:
        scratch = Path(temporary)
        generated = scratch / "generated"
        generated.mkdir()
        generations = {}
        for tag, commit in RELEASES.items():
            actual = subprocess.check_output(
                ["git", "rev-parse", f"{tag}^{{commit}}"], cwd=REPOSITORY, text=True).strip()
            if actual != commit:
                raise RuntimeError(f"{tag} no longer resolves to its pinned release commit")
            checkout = scratch / tag
            subprocess.run(["git", "worktree", "add", "--detach", str(checkout), commit],
                           cwd=REPOSITORY, check=True)
            try:
                paths = sources(tag)
                source_hashes = {f"photo-export/{path}": digest(
                    (checkout / "photo-export" / path).read_bytes()) for path in paths}
                harness_names = (["current-run.swift"] if tag == "v1.6.1" else
                                 ["auxiliary-stores.swift"])
                defines = ["RELEASE_MODERN"] if tag == "v1.6.5" else []
                if tag == "v1.6.5":
                    harness_names.append("current-run.swift")
                harnesses = [Path(__file__).with_name(name) for name in harness_names]
                binary = scratch / f"writer-{tag}"
                subprocess.run(
                    ["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                     "-module-cache-path", str(scratch / "module-cache"),
                     "-target", runtime["target"],
                     *[str(checkout / "photo-export" / path) for path in paths],
                     *[str(path) for path in harnesses],
                     *[argument for define in defines for argument in ["-D", define]],
                     "-o", str(binary)], check=True)
                target = generated / tag / "auxiliary"
                subprocess.run([str(binary), str(target), str(scratch / f"state-{tag}")], check=True)
                files = {str(path.relative_to(target.parent)): digest(path.read_bytes())
                         for path in sorted(target.rglob("*")) if path.is_file()}
                if not files:
                    raise RuntimeError(f"{tag} produced no fixtures")
                generations[tag] = {
                    **runtime, "commit": commit,
                    "releaseURL": f"https://github.com/valtteriluomapareto/photo-export/releases/tag/{tag}",
                    "sources": source_hashes,
                    "harnesses": {path.name: digest(path.read_bytes()) for path in harnesses},
                    "defines": defines, "files": files,
                    "preferencesTransport": "Binary property list of only real writer values; bookmarks excluded",
                }
            finally:
                subprocess.run(["git", "worktree", "remove", str(checkout)], cwd=REPOSITORY, check=True)
        (generated / "auxiliary-generations.json").write_text(
            json.dumps(generations, indent=2, sort_keys=True) + "\n")
        shutil.copytree(generated, output)
    print(f"Created additional release-written fixtures at {output}")


if __name__ == "__main__":
    main()
