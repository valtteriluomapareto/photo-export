#!/usr/bin/env python3
"""Offline fixture creation from exact released writers. Never run in PR CI."""

import argparse
import hashlib
import json
import platform
from pathlib import Path
import shutil
import subprocess
import tempfile

REPOSITORY = Path(__file__).resolve().parents[2]
RELEASES = {
    "v1.0.3": (
        "a85100a7b0c734a0f492f5d76f5317c6c599d38f",
        ["Models/ExportRecord.swift", "Managers/ExportRecordStore.swift"],
    ),
    "v1.6.5": (
        "0b0eb9b786311a961f9051d14e2e93cb0ecca135",
        [
            "Models/ExportRecord.swift", "Models/ExportVariant.swift",
            "Models/ExportPlacement.swift", "Models/AssetDescriptor.swift",
            "Models/ExportVideoLayout.swift",
            "Records/ExportRecordStore.swift", "Records/CollectionExportRecordStore.swift",
            "Records/JSONLRecordFile.swift", "Records/RecordStoreState.swift",
            "Records/ExportCompletionPolicy.swift", "Export/ExportFilenamePolicy.swift",
            "Export/ExportPlacementPathPolicy.swift",
            "App/AppDiagnostics.swift",
        ],
    ),
}


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="Fresh output directory")
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists():
        parser.error("output must not already exist; committed fixtures are immutable")
    toolchain = subprocess.check_output(["xcrun", "swiftc", "--version"], text=True).strip()
    host_runtime = subprocess.check_output(["sw_vers"], text=True).strip()
    target = f"{platform.machine()}-apple-macos15.0"
    with tempfile.TemporaryDirectory(prefix="historical-persistence-") as temporary:
        scratch = Path(temporary)
        fixtures = scratch / "fixtures"
        fixtures.mkdir()
        manifest = {"schemaVersion": 1, "toolchain": toolchain, "target": target,
                    "hostRuntime": host_runtime, "releases": {}}
        for tag, (commit, paths) in RELEASES.items():
            sources = scratch / tag
            sources.mkdir()
            hashes = {}
            compile_paths = []
            for relative in paths:
                original = f"photo-export/{relative}"
                data = subprocess.check_output(["git", "show", f"{commit}:{original}"], cwd=REPOSITORY)
                destination = sources / Path(relative).name
                destination.write_bytes(data)
                hashes[original] = sha256(data)
                compile_paths.append(str(destination))
            harness = Path(__file__).with_name(f"{tag}.swift")
            binary = sources / "generate"
            subprocess.run(
                ["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", "-target", target,
                 *compile_paths, str(harness), "-o", str(binary)], check=True,
            )
            fixture = fixtures / tag
            subprocess.run([str(binary), str(fixture)], check=True)
            files = {str(path.relative_to(fixture)): sha256(path.read_bytes())
                     for path in sorted(fixture.rglob("*")) if path.is_file()}
            if not files or not any(name.endswith(".json") for name in files):
                raise RuntimeError(f"{tag} did not produce a compacted snapshot")
            manifest["releases"][tag] = {
                "commit": commit,
                "releaseURL": f"https://github.com/valtteriluomapareto/photo-export/releases/tag/{tag}",
                "sources": hashes, "harnessSHA256": sha256(harness.read_bytes()), "files": files,
            }
        (fixtures / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        shutil.copytree(fixtures, output)
    print(f"Created historical-source fixtures at {output}")


if __name__ == "__main__":
    main()
