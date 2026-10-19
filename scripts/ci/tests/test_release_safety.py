"""Run the real release context/gated commands offline; never run a release build."""

import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
CONTEXT = "Determine build context"
VERSION = "Verify MARKETING_VERSION matches tag"
DUPLICATE = "Check for existing GitHub Release"
CREATE = "Create draft GitHub Release"
UPLOAD = "Upload to App Store Connect"


def expression(text, values):
    """Only the literal predicates used by the selected release steps/jobs."""
    if text.startswith('"') and text.endswith('"'):
        text = text[1:-1]  # YAML quotes are required for a leading ! predicate.
    if " || " in text:
        results = [expression(part, values) for part in text.split(" || ")]
        return any(results)
    if " && " in text:
        results = [expression(part, values) for part in text.split(" && ")]
        return all(results)
    if text.startswith("!"):
        return not expression(text[1:], values)
    call = re.fullmatch(r"(contains|startsWith)\((github\.ref), '([^']*)'\)", text)
    if call:
        value, search = values[call[2]].casefold(), call[3].casefold()
        return search in value if call[1] == "contains" else value.startswith(search)
    comparison = re.fullmatch(r"([\w.]+) (==|!=) '([^']*)'", text)
    if comparison:
        equal = values[comparison[1]].casefold() == comparison[3].casefold()
        return equal if comparison[2] == "==" else not equal
    raise ValueError(f"Unsupported release condition: {text}")


def selected_steps(source, names):
    """Reject missing/duplicate steps and unexpected keys instead of guessing YAML."""
    blocks = re.findall(r"^      - name: ([^\n]+)\n(.*?)(?=^      - name: |\Z)", source, re.M | re.S)
    selected = []
    for name, body in blocks:
        if name not in names:
            continue
        step = {"name": name, "env": {}}
        lines = iter(body.splitlines())
        for line in lines:
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            key = re.fullmatch(r"        (id|if|env|run): ?(.*)", line)
            if not key:
                raise ValueError(f"Unexpected release step structure: {line}")
            field, value = key.groups()
            if field == "env":
                if value:
                    raise ValueError("Expected block environment")
                # Environment blocks in the selected steps precede their run field.
                for line in lines:
                    binding = re.fullmatch(r"          (\w+): (.+)", line)
                    if binding:
                        step["env"][binding[1]] = binding[2]
                    else:
                        key = re.fullmatch(r"        run: (.*)", line)
                        if not key:
                            raise ValueError(f"Unexpected release environment: {line}")
                        field, value = "run", key[1]
                        break
            if field == "run":
                if value == "|":
                    script = []
                    for line in lines:
                        if line and not line.startswith("          ") and not line.lstrip().startswith("#"):
                            raise ValueError(f"Unexpected run block: {line}")
                        script.append(line[10:] if line.startswith("          ") else "")
                    step["run"] = "\n".join(script)
                else:
                    step["run"] = value
            else:
                step[field] = value
        if "run" not in step:
            raise ValueError(f"Missing run command: {name}")
        selected.append(step)
    if [step["name"] for step in selected] != names:
        raise ValueError("Selected release steps missing, duplicated, or reordered")
    return selected


def render(text, values):
    # Also renders the old inline expressions so baseline reds execute real commands.
    rendered = re.sub(r"\$\{\{ ([\w.]+) \}\}", lambda match: values[match[1]], text)
    if "${{" in rendered:
        raise ValueError("Unsupported release interpolation")
    return rendered


class ReleaseSafetyTests(unittest.TestCase):
    def run_release(self, channel, event, ref, safety="", version="1.6.5", existing=False):
        source = (ROOT / f".github/workflows/release-{channel}.yml").read_text()
        names = [CONTEXT, VERSION, DUPLICATE, CREATE] if channel == "direct" else [CONTEXT, VERSION, UPLOAD]
        steps = selected_steps(source, names)
        self.assertEqual(steps[0].get("id"), "ctx")
        values = {"github.ref": ref, "github.event_name": event,
                  "github.event.inputs.dry_run": safety, "github.event.inputs.skip_upload": safety,
                  "github.run_number": "42", "github.run_attempt": "2", "github.token": "offline"}
        # Never load a secret or inherit a credential from the calling process.
        for binding in re.findall(r"\$\{\{ (secrets\.\w+) \}\}", source):
            values[binding] = "offline"
        job_conditions = re.findall(r"^    if: (.+)$", source, re.M)
        if len(job_conditions) > 1:
            raise ValueError("Unexpected multiple release job conditions")
        if job_conditions and not expression(job_conditions[0], values):
            return {}, [], [], None
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            project = root / "photo-export.xcodeproj/project.pbxproj"
            project.parent.mkdir()
            project.write_text(f"MARKETING_VERSION = {version};\n" * 6)
            validator = root / "scripts/ci/check-version.py"
            validator.parent.mkdir(parents=True)
            shutil.copyfile(ROOT / "scripts/ci/check-version.py", validator)
            binaries = root / "bin"
            binaries.mkdir()
            for name, target in {"python3": sys.executable, "grep": "/usr/bin/grep", "sed": "/usr/bin/sed"}.items():
                (binaries / name).symlink_to(target)
            stub = f"#!{sys.executable}\n" + '''import json, os, pathlib, sys
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
if name == "gh":
    assert args[:2] in (["release", "view"], ["release", "create"]), args
    assert args[2] == os.environ["GITHUB_REF"].removeprefix("refs/tags/"), args
    if args[1] == "view":
        assert len(args) == 3, args
    else:
        assert "--draft" in args and "--generate-notes" in args, args
        assert args[-2:] == [os.environ["DMG_PATH"], os.environ["CHECKSUM_FILE"]], args
else:
    assert name == "bash" and args == ["scripts/ci/upload-appstore-connect.sh"], args
with open(os.environ["CALL_LOG"], "a") as log:
    log.write(json.dumps([name, *args]) + "\\n")
sys.exit(1 if name == "gh" and args[1] == "view" and os.environ["EXISTING"] == "false" else 0)
'''
            for name in ("gh", "bash"):
                path = binaries / name
                path.write_text(stub)
                path.chmod(0o755)
            output, audit = root / "output", root / "calls"
            environment = {"PATH": str(binaries), "HOME": str(root), "GITHUB_OUTPUT": str(output),
                           "GITHUB_ENV": str(root / "environment"), "GITHUB_EVENT_NAME": event,
                           "GITHUB_REF": ref, "GITHUB_RUN_NUMBER": "42", "GITHUB_RUN_ATTEMPT": "2",
                           "CALL_LOG": str(audit), "EXISTING": str(existing).lower(), "APP_NAME": "Photo Export",
                           "DMG_PATH": str(root / "app.dmg"), "CHECKSUM_FILE": str(root / "app.sha256")}
            outputs, executed, failed = {}, [], None
            for step in steps:
                if "if" in step and not expression(step["if"], values):
                    continue
                bindings = {name: render(value, values) for name, value in step["env"].items()}
                result = subprocess.run(["/bin/bash", "--noprofile", "--norc", "-eo", "pipefail", "-c",
                                         render(step["run"], values)], cwd=root,
                                        env={**environment, **bindings}, text=True, capture_output=True)
                executed.append(step["name"])
                if result.returncode:
                    # Only expected validator/duplicate failures are allowed by callers.
                    failed = (step["name"], result.stdout + result.stderr)
                    break
                if step["name"] == CONTEXT:
                    outputs = dict(line.split("=", 1) for line in output.read_text().splitlines())
                    values.update({f"steps.ctx.outputs.{key}": value for key, value in outputs.items()})
            calls = [json.loads(line) for line in audit.read_text().splitlines()] if audit.exists() else []
            return outputs, calls, executed, failed

    def test_true_tag_dispatch_cannot_reach_publication_commands(self):
        for channel in ("direct", "app-store"):
            with self.subTest(channel=channel):
                _, calls, executed, failed = self.run_release(channel, "workflow_dispatch", "refs/tags/v1.6.5", "true")
                self.assertIsNone(failed)
                self.assertIn(VERSION, executed)
                self.assertEqual(calls, [], "Build-only reached a publication command")

    def test_event_ref_input_matrix(self):
        # Expected publication is literal, independent of the implementation's outputs.
        cases = [
            ("push", "refs/tags/v1.6.5", "", "1.6.5", True, True),
            ("push", "refs/tags/v1.7.0-beta.1", "", "1.7.0-beta.1", True, False),
            ("push", "refs/heads/main", "false", "1.6.5", False, False),
            ("workflow_dispatch", "refs/tags/v1.6.5", "false", "1.6.5", True, True),
            ("workflow_dispatch", "refs/tags/v1.7.0-beta.1", "false", "1.7.0-beta.1", True, False),
            ("workflow_dispatch", "refs/heads/main", "false", "1.6.5", False, True),
            ("workflow_dispatch", "refs/heads/feature/release-safety", "false", "1.6.5", False, True),
            ("workflow_dispatch", "refs/heads/main", "false", "1.7.0-beta.1", False, False),
            ("workflow_dispatch", "refs/tags/other", "false", "1.6.5", False, False),
            ("workflow_dispatch", "refs/pull/1/merge", "false", "1.6.5", False, False),
        ]
        for event in ("workflow_dispatch", "unexpected"):
            for ref in ("refs/heads/main", "refs/tags/v1.6.5"):
                for flag in ("true", "", "FALSE", "invalid") if event == "workflow_dispatch" else ("false",):
                    cases.append((event, ref, flag, "1.6.5", False, False))
        for event, ref, flag, version, direct, store in cases:
            for channel, publishes in (("direct", direct), ("app-store", store)):
                with self.subTest(channel=channel, event=event, ref=ref, flag=flag, version=version):
                    outputs, calls, _, failed = self.run_release(channel, event, ref, flag, version)
                    self.assertIsNone(failed)
                    mutation = [call for call in calls if call[:3] == ["gh", "release", "create"] or call[0] == "bash"]
                    self.assertEqual(bool(mutation), publishes, calls)
                    if channel == "direct":
                        self.assertEqual(outputs["version"], ref.removeprefix("refs/tags/v")
                                         if ref.startswith("refs/tags/v") else "0.0.0-dev")
                        if publishes:
                            self.assertEqual([call[2] for call in calls], ["view", "create"])
                            self.assertIn("--draft", mutation[0])
                            self.assertEqual("--prerelease" in mutation[0], "-" in version)
                    elif outputs:
                        self.assertEqual(outputs["version"], version)
                        self.assertEqual(outputs["build_number"], "42.2")

    def test_scheduled_run_stays_build_only_without_touching_releases(self):
        # Schedules carry no inputs; a stray "false" must not opt in to publication either.
        for channel in ("direct", "app-store"):
            for flag in ("", "false"):
                with self.subTest(channel=channel, flag=flag):
                    outputs, calls, _, failed = self.run_release(channel, "schedule", "refs/heads/main", flag)
                    self.assertIsNone(failed)
                    self.assertEqual(calls, [])
                    if channel == "direct":
                        self.assertEqual(
                            (outputs["is_dry_run"], outputs["should_create_release"], outputs["version"]),
                            ("true", "false", "0.0.0-dev"))

    def test_existing_release_blocks_creation_but_not_build_only(self):
        for flag in ("true", "false"):
            with self.subTest(flag=flag):
                _, calls, _, failed = self.run_release("direct", "workflow_dispatch", "refs/tags/v1.6.5", flag, existing=True)
                if flag == "true":
                    self.assertIsNone(failed)
                    self.assertEqual(calls, [])
                else:
                    self.assertEqual(failed[0], DUPLICATE)
                    self.assertIn("already exists", failed[1])
                    self.assertEqual(calls, [["gh", "release", "view", "v1.6.5"]])

    def test_store_prerelease_tag_skips_the_whole_job(self):
        for event in ("push", "workflow_dispatch"):
            for flag in ("true", "false", "", "invalid"):
                with self.subTest(event=event, flag=flag):
                    result = self.run_release("app-store", event, "refs/tags/v1.7.0-beta.1", flag, "1.7.0-beta.1")
                    self.assertEqual(result, ({}, [], [], None))

    def test_tag_version_mismatch_blocks_publication_even_in_build_only(self):
        for channel in ("direct", "app-store"):
            for event, flag in (("push", ""), ("workflow_dispatch", "true"), ("workflow_dispatch", "false")):
                with self.subTest(channel=channel, event=event, flag=flag):
                    _, calls, _, failed = self.run_release(channel, event, "refs/tags/v1.6.4", flag)
                    self.assertEqual(failed[0], VERSION)
                    self.assertIn("Version mismatch", failed[1])
                    self.assertEqual(calls, [])

    def test_unknown_structure_is_an_error(self):
        with self.assertRaises(ValueError):
            expression("success()", {})
        with self.assertRaises(KeyError):
            expression("steps.unknown.outputs.value == 'true'", {})
        with self.assertRaises(ValueError):
            selected_steps("      - name: Missing\n        run: true\n", [CONTEXT])
        with self.assertRaises(ValueError):
            render("${{ unsupported() }}", {})

    def test_selected_predicates_match_actions_case_insensitive_strings(self):
        # Actions string comparisons/functions ignore case; shell input checks do not.
        values = {"github.ref": "refs/tags/V1.7.0-BETA.1", "github.event_name": "PUSH",
                  "steps.ctx.outputs.should_upload": "TRUE"}
        for predicate, expected in [
            ("steps.ctx.outputs.should_upload == 'true'", True),
            ("github.event_name != 'push'", False),
            ("startsWith(github.ref, 'refs/tags/v')", True),
            ("contains(github.ref, 'beta')", True),
            ("contains(github.ref, 'stable')", False),
        ]:
            with self.subTest(predicate=predicate):
                self.assertEqual(expression(predicate, values), expected)


class ReleaseIsolationTests(unittest.TestCase):
    def test_pending_tag_push_has_separate_group_from_main_dispatch_and_other_tags(self):
        source = (ROOT / ".github/workflows/release-direct.yml").read_text()
        block = re.search(r"^concurrency:\n(.*?)(?=^\S)", source, re.M | re.S)[1]
        group = re.findall(r"^  group: (.+)$", block, re.M)
        self.assertEqual(len(group), 1)
        self.assertEqual(re.findall(r"^  cancel-in-progress: (.+)$", block, re.M), ["false"])
        def key(event, ref):
            return render(group[0], {"github.event_name": event, "github.ref": ref}).casefold()
        push_tag = key("push", "refs/tags/v1.6.5")
        for event, ref in [("push", "refs/heads/main"), ("push", "refs/tags/v1.6.6"),
                           ("workflow_dispatch", "refs/tags/v1.6.5"),
                           ("workflow_dispatch", "refs/heads/main"),
                           ("schedule", "refs/heads/main")]:
            with self.subTest(event=event, ref=ref):
                self.assertNotEqual(push_tag, key(event, ref))
        self.assertEqual(push_tag, key("push", "refs/tags/v1.6.5"))
        self.assertEqual(push_tag, key("PUSH", "refs/tags/V1.6.5"))

    @staticmethod
    def triggers(name, source=None):
        source = source if source is not None else (ROOT / f".github/workflows/{name}").read_text()
        # One block-style top-level `on:`; flow or quoted forms are unexpected structure.
        if re.findall(r"^(?:on|'on'|\"on\"|true):.*$", source, re.M) != ["on:"]:
            raise ValueError(f"Unexpected trigger structure in {name}")
        block = re.search(r"^on:\n(.*?)(?=^[^\s#])", source, re.M | re.S)[1]
        events = re.findall(r"^  (\S+):", block, re.M)
        def section(event):
            found = re.search(rf"^  {event}:\n(.*?)(?=^  [^\s#]|\Z)", block, re.M | re.S)
            return [line.strip() for line in found[1].splitlines()
                    if line.strip() and not line.strip().startswith("#")] if found else []
        return events, section

    def test_release_workflows_never_start_from_branch_pushes_or_untrusted_events(self):
        for name, expected in [("release-direct.yml", {"push", "schedule", "workflow_dispatch"}),
                               ("release-app-store.yml", {"push", "workflow_dispatch"})]:
            with self.subTest(workflow=name):
                events, section = self.triggers(name)
                self.assertEqual(section("push"), ["tags:", "- 'v*'"],
                                 "Pushes to branches must not start signing or notarization")
                self.assertEqual(set(events), expected)
                self.assertEqual(len(events), len(expected))

    def test_comment_cannot_hide_a_branch_trigger(self):
        source = (ROOT / ".github/workflows/release-direct.yml").read_text()
        hidden = source.replace("      - 'v*'\n", "      - 'v*'\n  # note\n    branches:\n      - main\n", 1)
        _, section = self.triggers("release-direct.yml", hidden)
        self.assertIn("branches:", section("push"))
        # A column-0 comment must not end the `on:` block early either.
        reordered = "on:\n  workflow_dispatch:\n  push:\n    tags:\n      - 'v*'\n# note\n    branches:\n      - main\njobs:\n"
        _, section = self.triggers("release-direct.yml", reordered)
        self.assertIn("branches:", section("push"))

    def test_direct_dry_run_is_scheduled_and_dispatch_defaults_to_build_only(self):
        _, section = self.triggers("release-direct.yml")
        crons = [line for line in section("schedule") if line.startswith("- cron:")]
        self.assertEqual(len(crons), 1)
        self.assertRegex(crons[0], r"^- cron: '(\S+ ){4}\S+'$")
        dispatch = section("workflow_dispatch")
        self.assertIn("dry_run:", dispatch)
        self.assertEqual(dispatch[dispatch.index("dry_run:"):].count("default: true"), 1)

    def test_generated_password_is_masked_before_use_and_environment_export(self):
        workflow = (ROOT / ".github/workflows/release-direct.yml").read_text()
        direct = selected_steps(workflow, ["Create temporary keychain"])[0]
        values = {binding: "b2ZmbGluZQ==" for binding in re.findall(r"\$\{\{ (secrets\.\w+) \}\}", workflow)}
        bodies = {"direct": render(direct["run"], values),
                  "app-store": (ROOT / "scripts/ci/setup-keychain-appstore.sh").read_text()}
        password = "00000000-1111-2222-3333-444444444444"
        for channel, body in bodies.items():
            with self.subTest(channel=channel), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                binaries = root / "bin"
                binaries.mkdir()
                for name, target in {"base64": "/usr/bin/base64", "tr": "/usr/bin/tr",
                                     "awk": "/usr/bin/awk", "rm": "/bin/rm"}.items():
                    (binaries / name).symlink_to(target)
                stub = f"#!{sys.executable}\n" + '''import os, pathlib, sys
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
allowed = {"create-keychain", "set-keychain-settings", "unlock-keychain", "list-keychains",
           "default-keychain", "import", "set-key-partition-list", "find-identity", "find-certificate"}
valid = (name == "uuidgen" and not args or name == "security" and args and args[0] in allowed
         or name == "xcrun" and args[:2] == ["notarytool", "store-credentials"])
if not valid:
    pathlib.Path(os.environ["UNEXPECTED"]).write_text(repr([name, *args]))
    sys.exit(97)
if name == "uuidgen":
    print(os.environ["FAKE_PASSWORD"])
elif os.environ["FAKE_PASSWORD"] in args:
    print("PASSWORD_USE")
    path = pathlib.Path(os.environ["GITHUB_ENV"])
    if path.exists() and "KEYCHAIN_PASSWORD=" in path.read_text():
        print("PASSWORD_EXPORTED_BEFORE_USE")
elif name == "security" and args[0] == "find-identity":
    print('  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Mac Installer Distribution: Offline"')
'''
                for name in ("uuidgen", "security", "xcrun"):
                    path = binaries / name
                    path.write_text(stub)
                    path.chmod(0o755)
                environment = {"PATH": str(binaries), "RUNNER_TEMP": str(root),
                               "GITHUB_ENV": str(root / "environment"), "FAKE_PASSWORD": password,
                               "UNEXPECTED": str(root / "unexpected")}
                environment.update({name: "b2ZmbGluZQ==" for name in (
                    "CERTIFICATE_P12_BASE64", "CERTIFICATE_PASSWORD", "APPLE_ID",
                    "APPLE_APP_SPECIFIC_PASSWORD", "APPLE_TEAM_ID",
                    "APPLE_DISTRIBUTION_CERTIFICATE_P12_BASE64", "APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD",
                    "MAC_INSTALLER_DISTRIBUTION_CERTIFICATE_P12_BASE64",
                    "MAC_INSTALLER_DISTRIBUTION_CERTIFICATE_PASSWORD")})
                result = subprocess.run(["/bin/bash", "--noprofile", "--norc", "-euo", "pipefail", "-c", body],
                                        env=environment, cwd=root, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse((root / "unexpected").exists(), "An unexpected command was invoked")
                lines = result.stdout.splitlines()
                mask = f"::add-mask::{password}"
                self.assertIn(mask, lines)
                self.assertLess(lines.index(mask), lines.index("PASSWORD_USE"))
                self.assertNotIn("PASSWORD_EXPORTED_BEFORE_USE", lines)
                self.assertEqual([line for line in lines if password in line], [mask])
                self.assertNotIn(password, result.stderr)
                exported = dict(line.split("=", 1) for line in (root / "environment").read_text().splitlines())
                self.assertEqual(exported["KEYCHAIN_PASSWORD"], password)
                # Pin immediate registration, before any command (including an early export).
                after_uuid = body.split('KEYCHAIN_PASSWORD="$(uuidgen)"', 1)[1]
                first_command = next(line.strip() for line in after_uuid.splitlines()
                                     if line.strip() and not line.lstrip().startswith("#"))
                self.assertEqual(first_command, 'echo "::add-mask::${KEYCHAIN_PASSWORD}"')


if __name__ == "__main__":
    unittest.main()
