"""Exercise the App Store Connect preparation steps against an in-memory API."""
import base64
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import http.client
import subprocess
import urllib.error
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

    def test_comments_never_change_the_text(self):
        commented = CATALOG.replace(
            '"Faster **exports** and "',
            '"Faster **exports** and " // note: title: "ignored"\n'
            '        /* summary: "also ignored" */')
        self.assertEqual(connect.whats_new("2.0.0", commented),
                         connect.whats_new("2.0.0", CATALOG))

    def test_constructs_the_parser_cannot_read_fail_loudly(self):
        for construct in ('"""\n  multi\n  """', '#"raw"#', '"Version \\(appVersion)"'):
            with self.subTest(construct=construct), \
                    self.assertRaises(connect.ConnectError):
                connect.whats_new("1.9.0", CATALOG.replace('"Older."', construct))

    def test_a_field_that_is_not_a_literal_fails(self):
        with self.assertRaisesRegex(connect.ConnectError, "empty summary"):
            connect.whats_new("1.9.0", CATALOG.replace('"Older."', "Shared.summary"))

    def test_every_real_catalog_entry_renders_as_plain_text(self):
        catalog = connect.read_catalog()
        notes = connect.parse_catalog(catalog)
        self.assertGreater(len(notes), 3)
        for version in notes:
            with self.subTest(version=version):
                text = connect.whats_new(version, catalog)
                self.assertNotIn("**", text)
                self.assertNotIn("](", text)
                self.assertNotIn("`", text)

    def test_catalog_is_read_at_the_requested_ref(self):
        with tempfile.TemporaryDirectory() as temporary:
            origin, clone = Path(temporary) / "origin", Path(temporary) / "clone"
            def git(*args, cwd=origin):
                subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.com",
                                *args], cwd=cwd, check=True, capture_output=True)
            catalog = origin / connect.CATALOG_PATH
            catalog.parent.mkdir(parents=True)
            catalog.write_text("tagged")
            git("init", "-q", str(origin), cwd=temporary)
            git("add", ".")
            git("commit", "-qm", "tag")
            git("tag", "v2.0.0")
            catalog.write_text("main")
            git("commit", "-qam", "main")
            git("clone", "-q", f"file://{origin}", str(clone), cwd=temporary)
            with mock.patch.object(connect, "REPO", clone), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(connect.read_catalog("refs/tags/v2.0.0"), "tagged")
                self.assertEqual(connect.read_catalog(), "main")
                with self.assertRaisesRegex(connect.ConnectError, "v9.9.9"):
                    connect.read_catalog("refs/tags/v9.9.9")


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
                "iss": "issuer-1", "iat": 1_000, "exp": 2_140, "aud": "appstoreconnect-v1"})
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
    """Answers the App Store Connect paths the script uses and records every request.

    `builds` maps a build number to its processing states, one per lookup (the last
    repeats); None means the build is not visible yet.
    """

    def __init__(self, builds, versions=(), localizations=()):
        self.builds = {number: list(states) for number, states in builds.items()}
        self.versions = list(versions)
        self.localizations = list(localizations)
        self.requests = []

    @property
    def writes(self):
        return [request for request in self.requests if request[0] != "GET"]

    def get(self, path, params=None):
        self.requests.append(("GET", path, params))
        if path == "/v1/builds":
            assert params["filter[app]"] == "app-1"
            assert params["filter[preReleaseVersion.platform]"] == "MAC_OS"
            assert params["filter[preReleaseVersion.version]"] == "2.0.0"
            states = self.builds.get(params["filter[version]"], [None])
            state = states.pop(0) if len(states) > 1 else states[0]
            return [] if state is None else [
                {"id": f"build-{params['filter[version]']}",
                 "attributes": {"processingState": state}}]
        if path == "/v1/apps/app-1/appStoreVersions":
            assert params["filter[platform]"] == "MAC_OS"
            return [v for v in self.versions
                    if v["attributes"]["versionString"] == params["filter[versionString]"]]
        if path.endswith("/appStoreVersionLocalizations"):
            return self.localizations
        raise AssertionError(f"unexpected GET {path}")

    def post(self, path, body):
        self.requests.append(("POST", path, body))
        return {"id": "new-version", "attributes": body["data"]["attributes"]}

    def patch(self, path, body):
        self.requests.append(("PATCH", path, body))


def version(state, version_string="2.0.0"):
    return {"id": "version-id",
            "attributes": {"versionString": version_string, "appVersionState": state}}


def localization(identifier, locale):
    return {"id": identifier, "attributes": {"locale": locale, "whatsNew": None}}


class FakeTime:
    def __init__(self):
        self.now, self.sleeps = 0.0, []

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds

    def monotonic(self):
        return self.now


class WaitForBuildTests(unittest.TestCase):
    def wait(self, api):
        clock = FakeTime()
        with contextlib.redirect_stdout(io.StringIO()):
            result = connect.wait_for_build(api, "app-1", "2.0.0", "42.1",
                                            clock.sleep, clock.monotonic)
        return result, clock.sleeps

    def test_waits_until_the_build_appears_and_is_processed(self):
        result, sleeps = self.wait(FakeApi({"42.1": [None, "PROCESSING", "VALID"]}))
        self.assertEqual(result["id"], "build-42.1")
        self.assertEqual(sleeps, [connect.BUILD_POLL_INTERVAL] * 2)

    def test_only_the_requested_build_counts(self):
        # An earlier build of the same version is already processed; the new one is not.
        api = FakeApi({"41.1": ["VALID"], "42.1": ["PROCESSING", "VALID"]})
        result, sleeps = self.wait(api)
        self.assertEqual(result["id"], "build-42.1")
        self.assertEqual(len(sleeps), 1)

    def test_failed_processing_stops_at_once(self):
        for state in ("FAILED", "INVALID"):
            with self.subTest(state=state), self.assertRaisesRegex(connect.ConnectError, state):
                self.wait(FakeApi({"42.1": ["PROCESSING", state]}))

    def test_gives_up_after_the_timeout(self):
        with self.assertRaisesRegex(connect.ConnectError, "last state: PROCESSING"):
            self.wait(FakeApi({"42.1": ["PROCESSING"]}))


class PrepareTests(unittest.TestCase):
    def prepare(self, api, catalog=CATALOG):
        output = io.StringIO()
        clock = FakeTime()
        with contextlib.redirect_stdout(output):
            connect.prepare(api, "app-1", "2.0.0", "42.1", catalog, clock.sleep, clock.monotonic)
        return output.getvalue()

    def test_existing_version_gets_the_build_and_english_whats_new(self):
        api = FakeApi({"42.1": ["PROCESSING", "VALID"]}, [version("PREPARE_FOR_SUBMISSION")],
                      [localization("loc-en", "en-US"), localization("loc-fi", "fi")])
        self.prepare(api)
        self.assertEqual(api.writes, [
            ("PATCH", "/v1/appStoreVersions/version-id/relationships/build",
             {"data": {"type": "builds", "id": "build-42.1"}}),
            ("PATCH", "/v1/appStoreVersionLocalizations/loc-en",
             {"data": {"type": "appStoreVersionLocalizations", "id": "loc-en",
                       "attributes": {"whatsNew": connect.whats_new("2.0.0", CATALOG)}}}),
        ])

    def test_missing_version_is_created_for_manual_release(self):
        api = FakeApi({"42.1": ["VALID"]}, [version("READY_FOR_DISTRIBUTION", "1.9.0")],
                      [localization("loc-en", "en-GB")])
        self.prepare(api)
        method, path, body = api.writes[0]
        self.assertEqual((method, path), ("POST", "/v1/appStoreVersions"))
        self.assertEqual(body["data"]["attributes"],
                         {"platform": "MAC_OS", "versionString": "2.0.0", "releaseType": "MANUAL"})
        self.assertEqual(body["data"]["relationships"]["app"]["data"]["id"], "app-1")
        self.assertEqual(api.writes[1][1], "/v1/appStoreVersions/new-version/relationships/build")
        self.assertEqual(api.writes[2][1], "/v1/appStoreVersionLocalizations/loc-en")

    def test_version_past_review_is_left_alone(self):
        for state in ("WAITING_FOR_REVIEW", "IN_REVIEW", "READY_FOR_DISTRIBUTION"):
            api = FakeApi({"42.1": ["VALID"]}, [version(state)])
            with self.subTest(state=state), self.assertRaisesRegex(connect.ConnectError, state):
                self.prepare(api)
            self.assertEqual(api.writes, [])

    def test_catalog_problems_stop_before_any_request(self):
        too_long = CATALOG.replace('"Older."', '"' + "x" * 4001 + '"').replace(
            '"2.0.0"', '"0.0.0"').replace('"1.9.0"', '"2.0.0"')
        api = FakeApi({"42.1": ["VALID"]}, [version("PREPARE_FOR_SUBMISSION")])
        with self.assertRaisesRegex(connect.ConnectError, "4001 characters"):
            self.prepare(api, catalog=too_long)
        self.assertEqual(api.requests, [])

    def test_missing_catalog_entry_still_attaches_the_build(self):
        api = FakeApi({"42.1": ["VALID"]}, [version("PREPARE_FOR_SUBMISSION")],
                      [localization("loc-en", "en-US")])
        output = self.prepare(api, catalog=CATALOG.replace('"2.0.0"', '"2.0.1"'))
        self.assertEqual([path for _, path, _ in api.writes],
                         ["/v1/appStoreVersions/version-id/relationships/build"])
        self.assertIn("fill What's New in App Store Connect by hand", output)


class FakeResponse(io.BytesIO):
    status = 200

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def http_error(code):
    return urllib.error.HTTPError("https://api", code, "error", {}, io.BytesIO(
        json.dumps({"errors": [{"title": "Problem", "detail": f"code {code}"}]}).encode()))


class ClientTests(unittest.TestCase):
    def send(self, method, outcomes):
        """Run one request whose attempts produce OUTCOMES; return (result, tokens, sleeps)."""
        tokens, sleeps, attempts = [], [], iter(outcomes)

        def urlopen(request, timeout):
            tokens.append(request.get_header("Authorization"))
            outcome = next(attempts)
            if isinstance(outcome, BaseException):
                raise outcome
            return FakeResponse(json.dumps(outcome).encode())
        counter = iter(range(100))
        client = connect.Client("key", "id", "issuer", sleep=sleeps.append)
        with mock.patch.object(connect.urllib.request, "urlopen", urlopen), \
                mock.patch.object(connect, "make_token",
                                  lambda *args: f"token-{next(counter)}"), \
                contextlib.redirect_stdout(io.StringIO()):
            result = client.request(method, "/v1/builds")
        return result, tokens, sleeps

    def test_server_errors_and_dropped_connections_are_retried_with_fresh_tokens(self):
        failures = [ConnectionResetError(), TimeoutError(), http.client.IncompleteRead(b"")]
        for failure in failures:
            with self.subTest(failure=type(failure).__name__):
                result, tokens, sleeps = self.send(
                    "GET", [http_error(503), failure, http_error(502), {"data": []}])
                self.assertEqual(result, {"data": []})
                self.assertEqual(tokens, [f"Bearer token-{n}" for n in range(4)])
                self.assertEqual(sleeps, [2, 4, 8])

    def test_client_errors_are_not_retried(self):
        with self.assertRaisesRegex(connect.ConnectError, "404: Problem: code 404"):
            self.send("GET", [http_error(404), {"data": []}])

    def test_creation_is_attempted_once(self):
        with self.assertRaisesRegex(connect.ConnectError, "503"):
            self.send("POST", [http_error(503), {"data": {}}])

    def test_retries_give_up_after_four_attempts(self):
        with self.assertRaisesRegex(connect.ConnectError, "failed with 503"):
            self.send("PATCH", [http_error(503)] * 4)


class CommandLineTests(unittest.TestCase):
    def test_prepare_names_a_missing_credential(self):
        stderr = io.StringIO()
        with mock.patch.dict(os.environ, {"APP_STORE_APP_APPLE_ID": "1"}, clear=True), \
                contextlib.redirect_stderr(stderr), contextlib.redirect_stdout(io.StringIO()):
            status = connect.main(["prepare", "--version", "2.0.0", "--build", "1.1"])
        self.assertEqual(status, 1)
        self.assertIn("APP_STORE_CONNECT_API_KEY_BASE64", stderr.getvalue())

    def test_release_notes_default_to_the_version_tag(self):
        key = base64.b64encode(b"key").decode()
        credentials = {"APP_STORE_APP_APPLE_ID": "1", "APP_STORE_CONNECT_API_KEY_BASE64": key,
                       "APP_STORE_CONNECT_API_KEY_ID": "id", "APP_STORE_CONNECT_API_ISSUER_ID": "i"}
        for extra, expected in (([], "refs/tags/v2.0.0"), (["--catalog-ref", "main"], "main")):
            with self.subTest(expected=expected), \
                    mock.patch.dict(os.environ, credentials, clear=True), \
                    mock.patch.object(connect, "read_catalog", return_value="") as read, \
                    mock.patch.object(connect, "prepare") as prepare, \
                    contextlib.redirect_stdout(io.StringIO()):
                status = connect.main(["prepare", "--version", "v2.0.0", "--build", "1.1", *extra])
            self.assertEqual(status, 0)
            read.assert_called_once_with(expected)
            self.assertEqual(prepare.call_args.args[1:4], ("1", "2.0.0", "1.1"))

    def test_tags_are_accepted_and_prereleases_refused(self):
        self.assertEqual(connect.store_version("v1.6.6"), "1.6.6")
        self.assertEqual(connect.store_version("1.6.6"), "1.6.6")
        for value in ("v1.7.0-beta.1", "1.7", "main"):
            with self.subTest(value=value), contextlib.redirect_stderr(io.StringIO()), \
                    self.assertRaises(SystemExit):
                connect.main(["prepare", "--version", value, "--build", "1.1"])


if __name__ == "__main__":
    unittest.main()
