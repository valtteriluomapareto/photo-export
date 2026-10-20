"""Keep the Xcode version in one file and the toolchain canary out of the merge gate."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[3]
WORKFLOWS = sorted((ROOT / ".github/workflows").glob("*.yml"))
CANARY = ROOT / ".github/workflows/toolchain-canary.yml"
SELECT = "scripts/ci/select-xcode.sh"
CHECK = "scripts/ci/check-built-app.sh"
TOOL = re.compile(r"\b(xcodebuild|xcrun|swift|plutil)\b")
SWITCH = re.compile(r"xcode-select\s+(-s|--?switch)\b")
# CI scripts that run Xcode tools, found from their contents so a new one is covered too.
XCODE_SCRIPTS = sorted(
    path.relative_to(ROOT).as_posix() for path in (ROOT / "scripts/ci").glob("*.sh")
    if path.name != "select-xcode.sh" and TOOL.search(path.read_text()))
# Anything that runs Xcode tools must come after the selection step in its job.
XCODE_USES = re.compile("|".join([TOOL.pattern, *map(re.escape, XCODE_SCRIPTS)]))
# The jobs that build with the pinned version; only the canary may name another one.
PINNED_JOBS = [("ci.yml", "app-validation"), ("release-direct.yml", "build-sign-notarize"),
               ("release-app-store.yml", "build-sign-upload")]


def jobs(source):
    """Map each job id to its text, from the top-level `jobs:` block."""
    body = source.split("\njobs:\n", 1)[1]
    parts = re.split(r"^  ([A-Za-z0-9_-]+):\n", body, flags=re.M)
    return dict(zip(parts[1::2], parts[2::2]))


class ToolchainWorkflowTests(unittest.TestCase):
    def test_no_workflow_pins_or_overrides_xcode_outside_the_version_file(self):
        for workflow in WORKFLOWS:
            source = workflow.read_text()
            for token in ["Xcode_", "XCODE_PATH", "DEVELOPER_DIR"]:
                with self.subTest(workflow=workflow.name, token=token):
                    self.assertNotIn(token, source)
            with self.subTest(workflow=workflow.name, token="xcode-select switch"):
                self.assertIsNone(SWITCH.search(source))

    def test_ci_scripts_never_override_the_selected_toolchain(self):
        self.assertIn("scripts/ci/build-app.sh", XCODE_SCRIPTS)
        self.assertIn("scripts/ci/upload-appstore-connect.sh", XCODE_SCRIPTS)
        for path in (ROOT / "scripts/ci").glob("*.sh"):
            if path.name == "select-xcode.sh":
                continue
            text = path.read_text()
            for token in ["DEVELOPER_DIR", "TOOLCHAINS"]:
                with self.subTest(script=path.name, token=token):
                    self.assertNotIn(token, text)
            with self.subTest(script=path.name, token="xcode-select switch"):
                self.assertIsNone(SWITCH.search(text))

    def test_pinned_jobs_take_the_version_from_the_file_and_only_the_canary_names_one(self):
        for workflow in WORKFLOWS:
            for job, text in jobs(workflow.read_text()).items():
                # Every mention, so a `run: |` block or another spelling cannot hide an argument.
                calls = [line.strip() for line in text.splitlines() if "select-xcode.sh" in line]
                if not calls:
                    continue
                with self.subTest(workflow=workflow.name, job=job):
                    if workflow == CANARY:
                        self.assertEqual(calls, [f"run: bash {SELECT} ${{{{ matrix.xcode }}}}"])
                    else:
                        self.assertIn((workflow.name, job), PINNED_JOBS)
                        self.assertEqual(calls, [f"run: bash {SELECT}"])
        for name, job in PINNED_JOBS:
            with self.subTest(workflow=name, job=job):
                self.assertIn(job, jobs((ROOT / ".github/workflows" / name).read_text()))

    def test_each_job_checks_the_app_it_ships_against_the_version_file(self):
        """No version argument outside the canary, and each release checks its shipped bundle."""
        expected = {
            ("ci.yml", "app-validation"): f"run: bash {CHECK}",
            ("release-direct.yml", "build-sign-notarize"): f'run: bash {CHECK} --app "${{APP_PATH}}"',
            ("release-app-store.yml", "build-sign-upload"):
                f'run: bash {CHECK} --app "${{ARCHIVE_PATH}}/Products/Applications/${{APP_NAME}}.app"',
            ("toolchain-canary.yml", "canary"): f"run: bash {CHECK} ${{{{ matrix.xcode }}}}",
        }
        for workflow in WORKFLOWS:
            for job, text in jobs(workflow.read_text()).items():
                calls = [line.strip() for line in text.splitlines() if "check-built-app.sh" in line]
                if calls:
                    with self.subTest(workflow=workflow.name, job=job):
                        self.assertEqual(calls, [expected.get((workflow.name, job))])

    def test_app_store_builds_check_altool_upload_support_before_archiving(self):
        text = jobs((ROOT / ".github/workflows/release-app-store.yml").read_text())["build-sign-upload"]
        check = text.find("      - name: Check altool upload support\n")
        self.assertNotEqual(check, -1)
        self.assertLess(text.find("      - name: Select Xcode\n"), check)
        self.assertLess(check, text.find("      - name: Archive\n"))
        self.assertNotIn("if:", text[check:text.find("      - name:", check + 10)])

    def test_shipped_apps_are_checked_before_they_are_packaged_or_uploaded(self):
        """The check sits after the step that produces the app and before anything ships it."""
        orders = {
            ("ci.yml", "app-validation"): ["Build Release", "Check built Release app"],
            ("release-direct.yml", "build-sign-notarize"): [
                "Export archive", "Check exported app", "Create DMG", "Notarize DMG"],
            ("release-app-store.yml", "build-sign-upload"): [
                "Archive", "Check archived app", "Export", "Prepare package",
                "Upload to App Store Connect"],
        }
        for (name, job), steps in orders.items():
            text = jobs((ROOT / ".github/workflows" / name).read_text())[job]
            positions = [text.find(f"      - name: {step}\n") for step in steps]
            with self.subTest(workflow=name, job=job):
                self.assertNotIn(-1, positions)
                self.assertEqual(positions, sorted(positions))

    def test_every_job_selects_xcode_before_using_it(self):
        checked = 0
        for workflow in WORKFLOWS:
            for job, text in jobs(workflow.read_text()).items():
                use = XCODE_USES.search(text)
                if use is None:
                    continue
                checked += 1
                with self.subTest(workflow=workflow.name, job=job):
                    select = text.find(SELECT)
                    self.assertNotEqual(select, -1)
                    self.assertLess(select, use.start())
        # ci.yml app-validation, both release jobs and the canary.
        self.assertGreaterEqual(checked, 4)

    def test_canary_cannot_gate_merges_and_keeps_the_test_step_contract(self):
        self.assertTrue(CANARY.exists())
        ci = ROOT / ".github/workflows/ci.yml"
        self.assertNotIn("toolchain-canary", ci.read_text())
        source = CANARY.read_text()
        for trigger in ["workflow_dispatch:", "schedule:", "pull_request:"]:
            with self.subTest(trigger=trigger):
                self.assertIn(trigger, source)
        self.assertIn("- .xcode-version", source)
        self.assertIn("- scripts/ci/select-xcode.sh", source)
        self.assertIn("fail-fast: false", source)
        self.assertRegex(source, r"\n    timeout-minutes: \d+\n")
        self.assertIn("bash scripts/ci/select-xcode.sh ${{ matrix.xcode }}", source)
        unit = source[source.index("      - name: Run Unit Tests (Debug, with coverage)"):]
        unit = unit[:unit.index("      - name:", 10)]
        self.assertIn("id: unit-tests", unit)
        self.assertIn('TEST_RUNNER_REQUIRE_SCOPE_TESTS: "1"', unit)
        self.assertIn("timeout-minutes: 15", unit)
        self.assertIn("name: TestResults-${{ matrix.xcode }}", source)
        self.assertIn("bash scripts/ci/check-built-app.sh ${{ matrix.xcode }}", source)
        self.assertIn("cancel-in-progress: ${{ github.event_name == 'pull_request' }}", source)


if __name__ == "__main__":
    unittest.main()
