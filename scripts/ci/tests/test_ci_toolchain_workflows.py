"""Keep the Xcode version in one file and the toolchain canary out of the merge gate."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[3]
WORKFLOWS = sorted((ROOT / ".github/workflows").glob("*.yml"))
CANARY = ROOT / ".github/workflows/toolchain-canary.yml"
# Anything that runs Xcode tools must come after the selection step in its job.
XCODE_USES = re.compile(
    r"xcodebuild|xcrun|build-app\.sh|run-unit-tests\.sh|archive-appstore\.sh|export-appstore\.sh")


def jobs(source):
    """Map each job id to its text, from the top-level `jobs:` block."""
    body = source.split("\njobs:\n", 1)[1]
    parts = re.split(r"^  ([A-Za-z0-9_-]+):\n", body, flags=re.M)
    return dict(zip(parts[1::2], parts[2::2]))


class ToolchainWorkflowTests(unittest.TestCase):
    def test_no_workflow_pins_or_overrides_xcode_outside_the_version_file(self):
        for workflow in WORKFLOWS:
            source = workflow.read_text()
            for token in ["Xcode_", "xcode-select -s", "XCODE_PATH", "DEVELOPER_DIR"]:
                with self.subTest(workflow=workflow.name, token=token):
                    self.assertNotIn(token, source)

    def test_every_job_selects_xcode_before_using_it(self):
        checked = 0
        for workflow in WORKFLOWS:
            for job, text in jobs(workflow.read_text()).items():
                use = XCODE_USES.search(text)
                if use is None:
                    continue
                checked += 1
                with self.subTest(workflow=workflow.name, job=job):
                    select = text.find("scripts/ci/select-xcode.sh")
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


if __name__ == "__main__":
    unittest.main()
