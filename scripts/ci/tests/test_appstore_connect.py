"""Exercise the App Store Connect preparation steps against an in-memory API."""
import base64
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "appstore-connect.py"
SPEC = importlib.util.spec_from_file_location("appstore_connect", SCRIPT)
connect = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(connect)

CATALOG = r'''
/// A comment quoting ReleaseNote(version: "0.0.1", summary: "not an entry") is ignored.
enum ReleaseNotesCatalog {
  static let all: [ReleaseNote] = [
    ReleaseNote(
      version: "2.0.0",
      summary:
        "Faster **exports** and "
        + "fewer ` (1)` copies.",
      bullets: [
        ReleaseNote.Bullet(
          title: "Say \"hello\"",
          body: "See the [guide](https://example.com/guide) "
            + "for details."
        ),
        ReleaseNote.Bullet(title: "Second", body: "Two\u{2014}three."),
      ],
      learnMore: "Read the [notes](https://example.com/notes)."
    ),
    ReleaseNote(
      version: "1.9.0",
      summary: "Older.",
      bullets: [],
      learnMore: nil
    ),
  ]
}
'''


class WhatsNewTests(unittest.TestCase):
    def test_renders_plain_text_from_the_entry(self):
        self.assertEqual(connect.whats_new("2.0.0", CATALOG),
                         "Faster exports and fewer (1) copies.\n\n"
                         "• Say \"hello\"\nSee the guide (https://example.com/guide) for details.\n\n"
                         "• Second\nTwo—three.\n\n"
                         "Read the notes (https://example.com/notes).")
        self.assertEqual(connect.whats_new("1.9.0", CATALOG), "Older.")

    def test_missing_and_commented_versions_have_no_text(self):
        self.assertIsNone(connect.whats_new("3.0.0", CATALOG))
        self.assertIsNone(connect.whats_new("0.0.1", CATALOG))

    def test_text_over_the_store_limit_fails(self):
        long_entry = CATALOG.replace('"Older."', '"' + "x" * 4001 + '"')
        with self.assertRaisesRegex(connect.ConnectError, "4001 characters"):
            connect.whats_new("1.9.0", long_entry)

    def test_every_real_catalog_entry_renders_as_plain_text(self):
        notes = connect.parse_catalog(connect.CATALOG.read_text(encoding="utf-8"))
        self.assertGreater(len(notes), 3)
        for version, note in notes.items():
            with self.subTest(version=version):
                text = connect.whats_new(version)
                self.assertTrue(note["summary"])
                self.assertNotIn("**", text)
                self.assertNotIn("](", text)


class TokenTests(unittest.TestCase):
    def test_token_is_a_verifiable_es256_jwt(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            ec_key = subprocess.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey",
                                     "-noout"], capture_output=True, check=True).stdout
            (folder / "AuthKey.p8").write_bytes(subprocess.run(
                ["openssl", "pkcs8", "-topk8", "-nocrypt"], input=ec_key,
                capture_output=True, check=True).stdout)
            subprocess.run(["openssl", "ec", "-in", folder / "AuthKey.p8", "-pubout", "-out",
                            folder / "public.pem"], capture_output=True, check=True)
            token = connect.make_token(folder / "AuthKey.p8", "KEY123", "issuer-1", 1_000)

            header, claims, signature = token.split(".")
            decode = lambda part: base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))
            self.assertEqual(json.loads(decode(header)),
                             {"alg": "ES256", "kid": "KEY123", "typ": "JWT"})
            self.assertEqual(json.loads(decode(claims)), {
                "iss": "issuer-1", "iat": 1_000, "exp": 2_200, "aud": "appstoreconnect-v1"})
            raw = decode(signature)
            self.assertEqual(len(raw), 64)
            (folder / "signature.der").write_bytes(der_from_raw(raw))
            verified = subprocess.run(
                ["openssl", "dgst", "-sha256", "-verify", folder / "public.pem", "-signature",
                 folder / "signature.der"], input=f"{header}.{claims}".encode(),
                capture_output=True)
            self.assertEqual(verified.returncode, 0, verified.stdout + verified.stderr)

    def test_short_integers_are_left_padded(self):
        der = bytes([0x30, 0x25, 0x02, 0x01, 0x05, 0x02, 0x20]) + bytes(range(1, 33))
        self.assertEqual(connect.der_signature_to_raw(der),
                         bytes(31) + b"\x05" + bytes(range(1, 33)))


def der_from_raw(raw):
    def integer(value):
        value = value.lstrip(b"\0") or b"\0"
        if value[0] & 0x80:
            value = b"\0" + value
        return bytes([0x02, len(value)]) + value
    body = integer(raw[:32]) + integer(raw[32:])
    return bytes([0x30, len(body)]) + body


class FakeApi:
    """Answers the App Store Connect paths the script uses and records every write."""

    def __init__(self, builds, versions=(), localizations=()):
        self.builds = list(builds)  # one answer per build lookup; the last one repeats
        self.versions = list(versions)
        self.localizations = list(localizations)
        self.writes = []

    def get(self, path, params=None):
        if path == "/v1/builds":
            answer = self.builds.pop(0) if len(self.builds) > 1 else self.builds[0]
            return [] if answer is None else [
                {"id": "build-id", "attributes": {"processingState": answer}}]
        if path == "/v1/apps/app-1/appStoreVersions":
            return [v for v in self.versions
                    if v["attributes"]["versionString"] == params["filter[versionString]"]]
        if path.endswith("/appStoreVersionLocalizations"):
            return self.localizations
        raise AssertionError(f"unexpected GET {path}")

    def post(self, path, body):
        self.writes.append(("POST", path, body))
        return {"id": "new-version", "attributes": body["data"]["attributes"]}

    def patch(self, path, body):
        self.writes.append(("PATCH", path, body))


def version(state, version_string="2.0.0"):
    return {"id": "version-id",
            "attributes": {"versionString": version_string, "appVersionState": state}}


def localization(identifier, locale):
    return {"id": identifier, "attributes": {"locale": locale, "whatsNew": None}}


class WaitForBuildTests(unittest.TestCase):
    def wait(self, api, timeout=600):
        now = [0.0]
        sleeps = []

        def sleep(seconds):
            sleeps.append(seconds)
            now[0] += seconds
        with contextlib.redirect_stdout(io.StringIO()):
            result = connect.wait_for_build(api, "app-1", "2.0.0", "42.1", timeout, 30,
                                            sleep=sleep, monotonic=lambda: now[0])
        return result, sleeps

    def test_waits_until_the_build_appears_and_is_processed(self):
        result, sleeps = self.wait(FakeApi([None, "PROCESSING", "VALID"]))
        self.assertEqual(result["id"], "build-id")
        self.assertEqual(sleeps, [30, 30])

    def test_failed_processing_stops_at_once(self):
        for state in ("FAILED", "INVALID"):
            with self.subTest(state=state), self.assertRaisesRegex(connect.ConnectError, state):
                self.wait(FakeApi(["PROCESSING", state]))

    def test_gives_up_after_the_timeout(self):
        with self.assertRaisesRegex(connect.ConnectError, "last state: PROCESSING"):
            self.wait(FakeApi(["PROCESSING"]), timeout=90)


class PrepareVersionTests(unittest.TestCase):
    def prepare(self, api, catalog=CATALOG):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            connect.prepare_version(api, "app-1", "2.0.0", "42.1", catalog)
        return output.getvalue()

    def test_existing_version_gets_the_build_and_english_whats_new(self):
        api = FakeApi(["VALID"], [version("PREPARE_FOR_SUBMISSION")],
                      [localization("loc-en", "en-US"), localization("loc-fi", "fi")])
        output = self.prepare(api)
        self.assertEqual(api.writes, [
            ("PATCH", "/v1/appStoreVersions/version-id/relationships/build",
             {"data": {"type": "builds", "id": "build-id"}}),
            ("PATCH", "/v1/appStoreVersionLocalizations/loc-en",
             {"data": {"type": "appStoreVersionLocalizations", "id": "loc-en",
                       "attributes": {"whatsNew": connect.whats_new("2.0.0", CATALOG)}}}),
        ])
        self.assertIn("::warning::What's New for fi", output)

    def test_missing_version_is_created_for_manual_release(self):
        api = FakeApi(["VALID"], [version("READY_FOR_DISTRIBUTION", "1.9.0")],
                      [localization("loc-en", "en-GB")])
        self.prepare(api)
        method, path, body = api.writes[0]
        self.assertEqual((method, path), ("POST", "/v1/appStoreVersions"))
        self.assertEqual(body["data"]["attributes"],
                         {"platform": "MAC_OS", "versionString": "2.0.0", "releaseType": "MANUAL"})
        self.assertEqual(body["data"]["relationships"]["app"]["data"]["id"], "app-1")
        self.assertEqual(api.writes[1][1], "/v1/appStoreVersions/new-version/relationships/build")

    def test_version_past_review_is_left_alone(self):
        for state in ("WAITING_FOR_REVIEW", "IN_REVIEW", "READY_FOR_DISTRIBUTION"):
            api = FakeApi(["VALID"], [version(state)])
            with self.subTest(state=state), self.assertRaisesRegex(connect.ConnectError, state):
                self.prepare(api)
            self.assertEqual(api.writes, [])

    def test_unprocessed_build_stops_before_any_write(self):
        api = FakeApi(["PROCESSING"], [version("PREPARE_FOR_SUBMISSION")])
        with self.assertRaisesRegex(connect.ConnectError, "run wait-build first"):
            self.prepare(api)
        self.assertEqual(api.writes, [])

    def test_missing_catalog_entry_still_attaches_the_build(self):
        api = FakeApi(["VALID"], [version("PREPARE_FOR_SUBMISSION")],
                      [localization("loc-en", "en-US")])
        output = self.prepare(api, catalog=CATALOG.replace('"2.0.0"', '"2.0.1"'))
        self.assertEqual([path for _, path, _ in api.writes],
                         ["/v1/appStoreVersions/version-id/relationships/build"])
        self.assertIn("fill What's New in App Store Connect by hand", output)


class CommandLineTests(unittest.TestCase):
    def test_api_commands_name_a_missing_credential(self):
        stderr = io.StringIO()
        with mock.patch.dict(os.environ, {"APP_STORE_APP_APPLE_ID": "1"}, clear=True), \
                contextlib.redirect_stderr(stderr), contextlib.redirect_stdout(io.StringIO()):
            status = connect.main(["prepare-version", "--version", "2.0.0", "--build", "1.1"])
        self.assertEqual(status, 1)
        self.assertIn("APP_STORE_CONNECT_API_KEY_BASE64", stderr.getvalue())

    def test_tags_are_accepted_and_prereleases_refused(self):
        self.assertEqual(connect.store_version("v1.6.6"), "1.6.6")
        self.assertEqual(connect.store_version("1.6.6"), "1.6.6")
        for value in ("v1.7.0-beta.1", "1.7", "main"):
            with self.subTest(value=value), contextlib.redirect_stderr(io.StringIO()), \
                    self.assertRaises(SystemExit):
                connect.main(["wait-build", "--version", value, "--build", "1.1"])


if __name__ == "__main__":
    unittest.main()
