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


if __name__ == "__main__":
    unittest.main()
