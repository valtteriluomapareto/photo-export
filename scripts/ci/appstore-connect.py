#!/usr/bin/env python3
"""Prepare an uploaded build for App Review through the App Store Connect API.

Subcommands:
  whats-new VERSION          Print the store "What's New" text for VERSION, built from
                             photo-export/Models/ReleaseNotesCatalog.swift. Needs no credentials.
  wait-build                 Wait until App Store Connect has processed the uploaded build;
                             fail if processing fails or the build never appears.
  prepare-version            Find or create the macOS App Store version, attach the processed
                             build and fill the English "What's New" text from the catalog.
                             Submission for review and release stay manual.

The API subcommands take --version (CFBundleShortVersionString) and --build
(CFBundleVersion) and read these environment variables:
  APP_STORE_APP_APPLE_ID               numeric Apple ID of the app record
  APP_STORE_CONNECT_API_KEY_BASE64     base64 of the AuthKey_<id>.p8 file
  APP_STORE_CONNECT_API_KEY_ID
  APP_STORE_CONNECT_API_ISSUER_ID

Standard library only; the ES256 token is signed with the openssl command line tool.
"""
import argparse
import base64
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
CATALOG = Path(__file__).resolve().parents[2] / "photo-export/Models/ReleaseNotesCatalog.swift"
WHATS_NEW_LIMIT = 4000
TOKEN_LIFETIME = 20 * 60  # the maximum App Store Connect accepts
TOKEN_REFRESH_AFTER = 10 * 60
# States in which the build and What's New of a version can still change.
EDITABLE_STATES = {
    "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED",
    "INVALID_BINARY",
}


class ConnectError(Exception):
    pass


# ── What's New from the release-note catalog ────────────────────────────────

TOKEN = re.compile(r'(\w+):|"((?:[^"\\\n]|\\.)*)"')


def unescape(literal):
    def replace(match):
        escape = match.group(1)
        if escape.startswith("u{"):
            return chr(int(escape[2:-1], 16))
        return {"n": "\n", "t": "\t", "0": "\0"}.get(escape, escape)
    return re.sub(r"\\(u\{[0-9a-fA-F]+\}|.)", replace, literal)


def parse_catalog(text):
    """Return {version: {"summary", "bullets": [(title, body)], "learnMore"}}.

    The catalog holds only string literals joined with `+`, so each labelled field is the
    concatenation of the literals that follow its label.
    """
    code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("//"))
    notes, note, field = {}, None, None
    for match in TOKEN.finditer(code):
        label, literal = match.groups()
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


def whats_new(version, catalog_text=None):
    """Store text for VERSION, or None when the catalog has no entry for it."""
    if catalog_text is None:
        catalog_text = CATALOG.read_text(encoding="utf-8")
    note = parse_catalog(catalog_text).get(version)
    if note is None:
        return None
    parts = [plain(note["summary"])]
    parts += [f"• {plain(title)}\n{plain(body)}" for title, body in note["bullets"]]
    if note["learnMore"]:
        parts.append(plain(note["learnMore"]))
    text = "\n\n".join(part for part in parts if part)
    if len(text) > WHATS_NEW_LIMIT:
        raise ConnectError(f"What's New for {version} is {len(text)} characters; "
                           f"App Store Connect accepts at most {WHATS_NEW_LIMIT}.")
    return text


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
        self.token, self.token_time = None, 0.0

    def authorization(self):
        now = time.time()
        if self.token is None or now - self.token_time > TOKEN_REFRESH_AFTER:
            self.token, self.token_time = make_token(self.key_path, self.key_id, self.issuer_id,
                                                     now), now
        return f"Bearer {self.token}"

    def request(self, method, path, params=None, body=None):
        url = API + path + ("?" + urllib.parse.urlencode(params) if params else "")
        data = json.dumps(body).encode() if body is not None else None
        # Creation is not retried: a repeated POST could create twice.
        attempts = 1 if method == "POST" else 4
        for attempt in range(1, attempts + 1):
            request = urllib.request.Request(url, data=data, method=method, headers={
                "Authorization": self.authorization(), "Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(request, timeout=60) as response:
                    print(f"  {method} {path} -> {response.status}", flush=True)
                    payload = response.read()
                    return json.loads(payload) if payload else None
            except urllib.error.HTTPError as error:
                details = error_details(error.read().decode(errors="replace"))
                print(f"  {method} {path} -> {error.code} {details}", flush=True)
                if error.code not in (429, 500, 502, 503, 504) or attempt == attempts:
                    raise ConnectError(f"{method} {path} failed with {error.code}: {details}")
            except urllib.error.URLError as error:
                print(f"  {method} {path} -> {error.reason}", flush=True)
                if attempt == attempts:
                    raise ConnectError(f"{method} {path} failed: {error.reason}")
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


def wait_for_build(client, app_id, version, build, timeout, interval,
                   sleep=time.sleep, monotonic=time.monotonic):
    deadline = monotonic() + timeout
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
                               f"{int(timeout)} seconds (last state: {state or 'not visible'}). "
                               "Re-run this job once it shows as processed in App Store Connect.")
        sleep(interval)


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


def prepare_version(client, app_id, version, build, catalog_text=None):
    text = whats_new(version, catalog_text)
    found = find_build(client, app_id, version, build)
    state = found["attributes"].get("processingState") if found else None
    if state != "VALID":
        raise ConnectError(f"Build {version} ({build}) is {state or 'not visible'}; "
                           "run wait-build first.")
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
    for item in localizations:
        if item not in english:
            print(f"::warning::What's New for {item['attributes'].get('locale')} needs "
                  "filling by hand.", flush=True)
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


def run_api(arguments, temporary):
    app_id = environment("APP_STORE_APP_APPLE_ID")
    key_path = Path(temporary) / "AuthKey.p8"
    key_path.write_bytes(base64.b64decode(environment("APP_STORE_CONNECT_API_KEY_BASE64")))
    key_path.chmod(0o600)
    client = Client(key_path, environment("APP_STORE_CONNECT_API_KEY_ID"),
                    environment("APP_STORE_CONNECT_API_ISSUER_ID"))
    print(f"App {app_id}, version {arguments.version}, build {arguments.build}", flush=True)
    if arguments.command == "wait-build":
        wait_for_build(client, app_id, arguments.version, arguments.build,
                       arguments.timeout, arguments.interval)
    else:
        prepare_version(client, app_id, arguments.version, arguments.build)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    preview = commands.add_parser("whats-new", help="print What's New for a version")
    preview.add_argument("version")
    for name in ("wait-build", "prepare-version"):
        command = commands.add_parser(name)
        command.add_argument("--version", required=True, type=store_version)
        command.add_argument("--build", required=True)
        if name == "wait-build":
            command.add_argument("--timeout", type=float, default=45 * 60)
            command.add_argument("--interval", type=float, default=30)
    arguments = parser.parse_args(argv)
    try:
        if arguments.command == "whats-new":
            text = whats_new(arguments.version)
            if text is None:
                raise ConnectError(f"ReleaseNotesCatalog.swift has no {arguments.version} entry.")
            print(text)
            return 0
        with tempfile.TemporaryDirectory() as temporary:
            run_api(arguments, temporary)
        return 0
    except ConnectError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
