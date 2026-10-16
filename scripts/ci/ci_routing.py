#!/usr/bin/env python3
"""Select CI areas from complete local Git comparisons; validate final job results."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

APP_PREFIXES = ("photo-export/", "photo-exportTests/", "photo-exportUITests/",
                "photo-export.xcodeproj/", "test-fixtures/")
APP_FILES = {".swiftlint.yml", ".swift-format.json"}
SHA = re.compile(r"[0-9a-fA-F]{40}(?:[0-9a-fA-F]{24})?\Z")


def classify_paths(paths):
    app = website = False
    for path in paths:
        if path.startswith("website/"):
            website = True
        elif path.startswith("scripts/ci/") or path.startswith(".github/"):
            app = website = True
        elif path.startswith(APP_PREFIXES) or path in APP_FILES or path.startswith("scripts/"):
            app = True
        else:
            # Unknown/shared inputs stay conservative, including root/maintainer docs.
            app = website = True
    return app, website


def git(repo, *arguments):
    return subprocess.run(["git", "-C", str(repo), *arguments], check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def commit_sha(value):
    if not isinstance(value, str) or not SHA.fullmatch(value):
        raise ValueError("event comparison must contain full commit SHA values")
    return value


def route(event_name, event, repo):
    if not isinstance(event, dict):
        raise ValueError("event payload must be an object")
    if event_name == "pull_request":
        try:
            base = commit_sha(event["pull_request"]["base"]["sha"])
            head = commit_sha(event["pull_request"]["head"]["sha"])
        except (KeyError, TypeError) as error:
            raise ValueError("pull_request event is missing base/head SHAs") from error
    elif event_name == "push":
        base = commit_sha(event.get("before"))
        head = commit_sha(event.get("after"))
    else:
        return True, True, "unrecognized event; validate both areas"
    git(repo, "rev-parse", "--is-inside-work-tree")
    if set(base) == {"0"} or set(head) == {"0"}:
        return True, True, "new/deleted ref; validate both areas"
    for sha in (base, head):
        result = subprocess.run(["git", "-C", str(repo), "rev-parse", "--verify", "--quiet", f"{sha}^{{commit}}"],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode == 1:
            return True, True, "comparison commit unavailable; validate both areas"
        result.check_returncode()
    if event_name == "pull_request":
        result = subprocess.run(["git", "-C", str(repo), "merge-base", base, head],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode == 1:
            return True, True, "no common ancestor; validate both areas"
        result.check_returncode()
        base = result.stdout.decode("ascii").strip()
    raw = git(repo, "diff", "--name-only", "-z", "--no-renames", base, head, "--")
    paths = [os.fsdecode(path) for path in raw.split(b"\0") if path]
    app, website = classify_paths(paths)
    return app, website, f"{len(paths)} changed paths ({event_name} comparison)"


def gate_passes(routing_result, selected, validation_result):
    return routing_result == "success" and (
        (selected == "true" and validation_result == "success")
        or (selected == "false" and validation_result == "skipped"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    routing = commands.add_parser("route")
    routing.add_argument("--event-name", default=os.environ.get("GITHUB_EVENT_NAME"))
    routing.add_argument("--event-path", type=Path, default=os.environ.get("GITHUB_EVENT_PATH"))
    routing.add_argument("--repo", type=Path, default=Path("."))
    routing.add_argument("--output", type=Path, default=os.environ.get("GITHUB_OUTPUT"))
    gate = commands.add_parser("check")
    gate.add_argument("routing_result")
    gate.add_argument("selected")
    gate.add_argument("validation_result")
    args = parser.parse_args()
    if args.command == "check":
        if not gate_passes(args.routing_result, args.selected, args.validation_result):
            print(f"CI result rejected: routing={args.routing_result!r}, selected={args.selected!r}, "
                  f"validation={args.validation_result!r}", file=sys.stderr)
            return 1
        print(f"CI result accepted: selected={args.selected}, validation={args.validation_result}")
        return 0
    if not args.event_name or not args.event_path:
        raise ValueError("event name and event path are required")
    event = json.loads(Path(args.event_path).read_text())
    app, website, reason = route(args.event_name, event, args.repo)
    if args.output:
        with args.output.open("a") as output:
            output.write(f"app={str(app).lower()}\nwebsite={str(website).lower()}\n")
    print(json.dumps({"app": app, "website": website, "reason": reason}))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"CI routing error: {error}", file=sys.stderr)
        sys.exit(2)
