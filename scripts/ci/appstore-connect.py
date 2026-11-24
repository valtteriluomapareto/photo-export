#!/usr/bin/env python3
"""Prepare an uploaded build for App Review through the App Store Connect API.

Subcommands:
  whats-new VERSION   Print the store "What's New" text for VERSION, built from
                      photo-export/Models/ReleaseNotesCatalog.swift. Needs no credentials.
  prepare             Wait until App Store Connect has processed the uploaded build, find or
                      create the macOS App Store version, attach the build and fill the English
                      "What's New" from the catalog. Submission for review and release stay
                      manual.

`prepare` takes --version (a tag such as v1.2.3, or 1.2.3), --build (CFBundleVersion) and
optionally --catalog-ref, the git ref whose catalog to use (default: the v<version> tag), and
reads these environment variables:
  APP_STORE_APP_APPLE_ID               numeric Apple ID of the app record
  APP_STORE_CONNECT_API_KEY_BASE64     base64 of the AuthKey_<id>.p8 file
  APP_STORE_CONNECT_API_KEY_ID
  APP_STORE_CONNECT_API_ISSUER_ID

Standard library only; the ES256 token is signed with the openssl command line tool.
"""
import argparse
import base64
import http.client
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com"
REPO = Path(__file__).resolve().parents[2]
CATALOG_PATH = "photo-export/Models/ReleaseNotesCatalog.swift"
WHATS_NEW_LIMIT = 4000
# Apple accepts tokens that expire at most 20 minutes ahead; leave room for clock skew.
TOKEN_LIFETIME = 19 * 60
BUILD_TIMEOUT = 45 * 60
BUILD_POLL_INTERVAL = 30
# States in which the build and What's New of a version can still change.
EDITABLE_STATES = {
    "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED",
    "INVALID_BINARY",
}


class ConnectError(Exception):
    pass


# ── What's New from the release-note catalog ────────────────────────────────

# Comments are matched as their own tokens so labels or quotes inside them are skipped.
TOKEN = re.compile(r'//[^\n]*|/\*.*?\*/|(\w+):|"((?:[^"\\\n]|\\.)*)"', re.DOTALL)
UNSUPPORTED = (('"""', "multi-line strings"), ('#"', "raw strings"), ("\\(", "interpolation"))


def unescape(literal):
    def replace(match):
        escape = match.group(1)
        if escape.startswith("u{"):
            return chr(int(escape[2:-1], 16))
        return {"n": "\n", "t": "\t", "0": "\0"}.get(escape, escape)
    return re.sub(r"\\(u\{[0-9a-fA-F]+\}|.)", replace, literal)


def parse_catalog(text):
    """Return {version: {"summary", "bullets": [[title, body]], "learnMore"}}.

    The catalog holds only plain string literals joined with `+`, so each labelled field is
    the concatenation of the literals that follow its label. Anything else is refused rather
    than misread.
    """
    for marker, name in UNSUPPORTED:
        if marker in text:
            raise ConnectError(f"ReleaseNotesCatalog.swift uses {name}, which this script "
                               "can't read; use plain string literals joined with +.")
    notes, note, field = {}, None, None
    for match in TOKEN.finditer(text):
        label, literal = match.groups()
        if label is None and literal is None:
            continue
        if label is not None:
            field = label
            if label == "version":
                note = None
            elif note is not None and label == "title":
                note["bullets"].append(["", ""])
            continue
        value = unescape(literal)
        if field == "version":
            note = notes.setdefault(value, {"summary": "", "bullets": [], "learnMore": ""})
        elif note is None:
            continue
        elif field in ("summary", "learnMore"):
            note[field] += value
        elif field in ("title", "body") and note["bullets"]:
            note["bullets"][-1][0 if field == "title" else 1] += value
    return notes


def plain(markdown):
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r"\1 (\2)", markdown)
    text = re.sub(r"\*\*(.+?)\*\*", r"\1", text)
    return re.sub(r"`\s*([^`]*?)\s*`", r"\1", text).strip()


def whats_new(version, catalog_text):
    """Store text for VERSION, or None when the catalog has no entry for it."""
    note = parse_catalog(catalog_text).get(version)
    if note is None:
        return None
    if not note["summary"] or any(not title or not body for title, body in note["bullets"]):
        raise ConnectError(f"The {version} catalog entry has an empty summary, title or body; "
                           "this script reads only string literals.")
    parts = [plain(note["summary"])]
    parts += [f"• {plain(title)}\n{plain(body)}" for title, body in note["bullets"]]
    if note["learnMore"]:
        parts.append(plain(note["learnMore"]))
    text = "\n\n".join(parts)
    if len(text) > WHATS_NEW_LIMIT:
        raise ConnectError(f"What's New for {version} is {len(text)} characters; "
                           f"App Store Connect accepts at most {WHATS_NEW_LIMIT}.")
    return text


def read_catalog(ref=None):
    if ref is None:
        return (REPO / CATALOG_PATH).read_text(encoding="utf-8")
    print(f"Reading release notes at {ref}", flush=True)
    for command in (["git", "fetch", "--quiet", "--depth", "1", "origin", ref],
                    ["git", "show", f"FETCH_HEAD:{CATALOG_PATH}"]):
        result = subprocess.run(command, cwd=REPO, capture_output=True, text=True, timeout=120)
        if result.returncode != 0:
            raise ConnectError(f"Could not read the catalog at {ref}: {result.stderr.strip()}")
    return result.stdout


# ── API client ──────────────────────────────────────────────────────────────

def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_signature_to_raw(der):
    """Convert openssl's DER ECDSA signature into the 64-byte r||s form JWS uses."""
    if len(der) < 8 or der[0] != 0x30 or der[1] >= 0x80:
        raise ConnectError("openssl returned an unexpected signature.")
    index, parts = 2, []
    for _ in range(2):
        if der[index] != 0x02:
            raise ConnectError("openssl returned an unexpected signature.")
        length = der[index + 1]
        value = der[index + 2:index + 2 + length].lstrip(b"\0")
        if len(value) > 32:
            raise ConnectError("openssl returned an unexpected signature.")
        parts.append(value.rjust(32, b"\0"))
        index += 2 + length
    return b"".join(parts)


def make_token(key_path, key_id, issuer_id, now):
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    claims = b64url(json.dumps({"iss": issuer_id, "iat": int(now), "exp": int(now) + TOKEN_LIFETIME,
                                "aud": "appstoreconnect-v1"}).encode())
    signing_input = f"{header}.{claims}".encode()
    result = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(key_path)],
                            input=signing_input, capture_output=True, timeout=30)
    if result.returncode != 0:
        raise ConnectError("openssl could not sign the API token: "
                           + result.stderr.decode(errors="replace").strip())
    return f"{header}.{claims}.{b64url(der_signature_to_raw(result.stdout))}"


def error_details(body):
    try:
        errors = json.loads(body).get("errors", [])
    except (ValueError, AttributeError):
        return body[:500]
    return "; ".join(f"{e.get('title', '')}: {e.get('detail', '')}".strip(": ") for e in errors)


class Client:
    def __init__(self, key_path, key_id, issuer_id, sleep=time.sleep):
        self.key_path, self.key_id, self.issuer_id = key_path, key_id, issuer_id
        self.sleep = sleep

    def request(self, method, path, params=None, body=None):
        url = API + path + ("?" + urllib.parse.urlencode(params) if params else "")
        data = json.dumps(body).encode() if body is not None else None
        # Creation is not retried: a repeated POST could create twice.
        attempts = 1 if method == "POST" else 4
        for attempt in range(1, attempts + 1):
            # A fresh token per request, so a long wait never outlives one.
            token = make_token(self.key_path, self.key_id, self.issuer_id, time.time())
            request = urllib.request.Request(url, data=data, method=method, headers={
                "Authorization": f"Bearer {token}", "Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(request, timeout=60) as response:
                    payload = response.read()
                    print(f"  {method} {path} -> {response.status}", flush=True)
                    return json.loads(payload) if payload else None
            except urllib.error.HTTPError as error:
                details = error_details(error.read().decode(errors="replace"))
                print(f"  {method} {path} -> {error.code} {details}", flush=True)
                if error.code not in (429, 500, 502, 503, 504) or attempt == attempts:
                    raise ConnectError(f"{method} {path} failed with {error.code}: {details}")
            except (OSError, http.client.HTTPException) as error:
                # URLError, dropped connections and read timeouts.
                print(f"  {method} {path} -> {error!r}", flush=True)
                if attempt == attempts:
                    raise ConnectError(f"{method} {path} failed: {error!r}")
            self.sleep(2 ** attempt)
        raise AssertionError("unreachable")

    def get(self, path, params=None):
        return self.request("GET", path, params)["data"]

    def post(self, path, body):
        return self.request("POST", path, body=body)["data"]

    def patch(self, path, body):
        return self.request("PATCH", path, body=body)


# ── Steps ───────────────────────────────────────────────────────────────────

def find_build(client, app_id, version, build):
    builds = client.get("/v1/builds", {
        "filter[app]": app_id, "filter[version]": build,
        "filter[preReleaseVersion.version]": version,
        "filter[preReleaseVersion.platform]": "MAC_OS", "limit": "2"})
    return builds[0] if builds else None


def wait_for_build(client, app_id, version, build, sleep=time.sleep, monotonic=time.monotonic):
    deadline = monotonic() + BUILD_TIMEOUT
    while True:
        found = find_build(client, app_id, version, build)
        state = found["attributes"].get("processingState") if found else None
        print(f"Build {version} ({build}): {state or 'not visible yet'}", flush=True)
        if state == "VALID":
            return found
        if state in ("FAILED", "INVALID"):
            raise ConnectError(f"App Store Connect could not process build {version} ({build}): "
                               f"{state}. Apple's email to the account holder names the cause.")
        if monotonic() >= deadline:
            raise ConnectError(f"Build {version} ({build}) was not processed within "
                               f"{BUILD_TIMEOUT // 60} minutes (last state: "
                               f"{state or 'not visible'}). Re-run this job once it shows as "
                               "processed in App Store Connect.")
        sleep(BUILD_POLL_INTERVAL)


def version_state(record):
    attributes = record["attributes"]
    return attributes.get("appVersionState") or attributes.get("appStoreState") or "UNKNOWN"


def find_or_create_version(client, app_id, version):
    existing = client.get(f"/v1/apps/{app_id}/appStoreVersions", {
        "filter[platform]": "MAC_OS", "filter[versionString]": version, "limit": "2"})
    if existing:
        record = existing[0]
        state = version_state(record)
        print(f"App Store version {version} exists: {state}", flush=True)
        if state not in EDITABLE_STATES:
            raise ConnectError(f"App Store version {version} is {state}, so its build can't "
                               "change. Ship the fix as a new version.")
        return record
    print(f"Creating App Store version {version} (released manually after approval)", flush=True)
    try:
        return client.post("/v1/appStoreVersions", {"data": {
            "type": "appStoreVersions",
            "attributes": {"platform": "MAC_OS", "versionString": version, "releaseType": "MANUAL"},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})
    except ConnectError as error:
        raise ConnectError(f"{error}\nAnother macOS version may already be in preparation; "
                           "App Store Connect allows one at a time.") from error


def prepare(client, app_id, version, build, catalog_text,
            sleep=time.sleep, monotonic=time.monotonic):
    # Checked before waiting, so a catalog problem fails in seconds and before any write.
    text = whats_new(version, catalog_text)
    found = wait_for_build(client, app_id, version, build, sleep, monotonic)
    record = find_or_create_version(client, app_id, version)
    print(f"Attaching build {build} to version {version}", flush=True)
    client.patch(f"/v1/appStoreVersions/{record['id']}/relationships/build",
                 {"data": {"type": "builds", "id": found["id"]}})
    if text is None:
        print(f"::warning::ReleaseNotesCatalog.swift has no {version} entry; "
              "fill What's New in App Store Connect by hand.", flush=True)
        return
    localizations = client.get(f"/v1/appStoreVersions/{record['id']}/appStoreVersionLocalizations")
    english = [item for item in localizations
               if item["attributes"].get("locale", "").startswith("en")]
    if not english:
        raise ConnectError(f"Version {version} has no English localization to fill.")
    for item in english:
        print(f"Setting What's New ({item['attributes']['locale']}, {len(text)} characters)",
              flush=True)
        client.patch(f"/v1/appStoreVersionLocalizations/{item['id']}", {"data": {
            "type": "appStoreVersionLocalizations", "id": item["id"],
            "attributes": {"whatsNew": text}}})
    print(f"Version {version} is ready to submit for review in App Store Connect.", flush=True)


# ── Entry point ─────────────────────────────────────────────────────────────

def environment(name):
    value = os.environ.get(name, "")
    if not value:
        raise ConnectError(f"Required environment variable {name} is not set.")
    return value


def store_version(value):
    """Accept a tag (v1.2.3) or a version (1.2.3); the store takes only stable versions."""
    version = value.removeprefix("v")
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise argparse.ArgumentTypeError(
            f"{value!r} is not a stable X.Y.Z version; App Store Connect rejects pre-releases")
    return version


def run_prepare(arguments, temporary):
    app_id = environment("APP_STORE_APP_APPLE_ID")
    key_path = Path(temporary) / "AuthKey.p8"
    key_path.write_bytes(base64.b64decode(environment("APP_STORE_CONNECT_API_KEY_BASE64")))
    key_path.chmod(0o600)
    client = Client(key_path, environment("APP_STORE_CONNECT_API_KEY_ID"),
                    environment("APP_STORE_CONNECT_API_ISSUER_ID"))
    print(f"App {app_id}, version {arguments.version}, build {arguments.build}", flush=True)
    catalog_ref = arguments.catalog_ref or f"refs/tags/v{arguments.version}"
    prepare(client, app_id, arguments.version, arguments.build, read_catalog(catalog_ref))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    preview = commands.add_parser("whats-new", help="print What's New for a version")
    preview.add_argument("version", type=store_version)
    command = commands.add_parser("prepare", help="prepare the App Store version for review")
    command.add_argument("--version", required=True, type=store_version)
    command.add_argument("--build", required=True)
    command.add_argument("--catalog-ref")
    arguments = parser.parse_args(argv)
    try:
        if arguments.command == "whats-new":
            text = whats_new(arguments.version, read_catalog())
            if text is None:
                raise ConnectError(f"ReleaseNotesCatalog.swift has no {arguments.version} entry.")
            print(text)
            return 0
        with tempfile.TemporaryDirectory() as temporary:
            run_prepare(arguments, temporary)
        return 0
    except ConnectError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
