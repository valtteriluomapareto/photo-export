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


def steps(job_text):
    """The job's text before its first step, and its (step name, step text) pairs in order."""
    parts = re.split(r"^      - name: (.+)\n", job_text, flags=re.M)
    return parts[0], list(zip(parts[1::2], parts[2::2]))


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

    def test_only_the_pull_request_debug_build_and_the_canary_check_treat_warnings_as_errors(self):
        """Releases never set the switch, so a warning cannot block one."""
        expected = {("ci.yml", "app-validation", "Build Debug"),
                    ("toolchain-canary.yml", "canary", "Build Debug with warnings as errors")}
        found = set()
        for workflow in WORKFLOWS:
            source = workflow.read_text()
            for token in ["SWIFT_WARNINGS_AS_ERRORS", "SWIFT_TREAT_WARNINGS_AS_ERRORS"]:
                with self.subTest(workflow=workflow.name, token=token, part="workflow header"):
                    self.assertNotIn(token, source.split("\njobs:\n", 1)[0])
            for job, text in jobs(source).items():
                header, job_steps = steps(text)
                with self.subTest(workflow=workflow.name, job=job, part="job header"):
                    self.assertNotIn("WARNINGS_AS_ERRORS", header)
                for name, step in job_steps:
                    if "WARNINGS_AS_ERRORS" in step:
                        found.add((workflow.name, job, name))
                        with self.subTest(workflow=workflow.name, job=job, step=name):
                            self.assertIn('        env:\n          SWIFT_WARNINGS_AS_ERRORS: "1"\n', step)
                            self.assertIn("        run: bash scripts/ci/build-app.sh Debug\n", step)
                            self.assertNotIn("SWIFT_TREAT_WARNINGS_AS_ERRORS", step)
        self.assertEqual(found, expected)

    def test_canary_builds_debug_with_warnings_as_errors_last_after_a_good_debug_build(self):
        """After the normal builds, so a new warning never skips the tests or the Release build."""
        _, job_steps = steps(jobs(CANARY.read_text())["canary"])
        names = [name for name, _ in job_steps]
        self.assertIn("Build Debug with warnings as errors", names)
        self.assertEqual(names[names.index("Check built Release app") + 1],
                         "Build Debug with warnings as errors")
        step = dict(job_steps)["Build Debug with warnings as errors"]
        self.assertIn("        if: ${{ !cancelled() && steps.debug-build.outcome == 'success' }}\n",
                      step)
        # The id the condition names, or the step would always be skipped.
        self.assertIn("        id: debug-build\n", dict(job_steps)["Build Debug"])

    def test_failure_diagnostics_and_uploads_include_the_warnings_as_errors_log(self):
        for workflow in [ROOT / ".github/workflows/ci.yml", CANARY]:
            _, job_steps = steps(jobs(workflow.read_text())[
                "canary" if workflow == CANARY else "app-validation"])
            job_steps = dict(job_steps)
            for name in ["Print build and test failure diagnostics", "Upload test results"]:
                with self.subTest(workflow=workflow.name, step=name):
                    self.assertIn("debug-werror-build.log", job_steps[name])

    def test_no_project_or_xcconfig_build_setting_treats_warnings_as_errors(self):
        """Only build-app.sh's switch sets it, so the release builds never fail on a warning."""
        files = [ROOT / "photo-export.xcodeproj/project.pbxproj",
                 *(path for path in ROOT.rglob("*.xcconfig")
                   if not {".git", "build", "node_modules"} & set(path.parts))]
        for path in files:
            with self.subTest(file=path.relative_to(ROOT).as_posix()):
                self.assertNotIn("SWIFT_TREAT_WARNINGS_AS_ERRORS", path.read_text())
        self.assertTrue(files[0].exists())

    def test_exclusive_rename_probe_runs_on_the_schedule_and_dispatch_only(self):
        text = jobs(CANARY.read_text())["exclusive-rename-probe"]
        self.assertIn("    if: github.event_name != 'pull_request'\n", text)
        self.assertRegex(text, r"\n    timeout-minutes: \d+\n")
        self.assertIn("run: bash scripts/probe-exclusive-rename.sh\n", text)
        self.assertTrue((ROOT / "scripts/probe-exclusive-rename.sh").exists())


if __name__ == "__main__":
    unittest.main()
