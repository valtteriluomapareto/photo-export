"""Run the real observation ratchet guard against disposable app-source skeletons."""

import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest


CI_DIRECTORY = pathlib.Path(__file__).resolve().parents[1]
GUARD = CI_DIRECTORY / "check-observation-ratchet.py"

MANAGER = (
    "final class Manager: ObservableObject {\n"
    "  @Published private(set) var isRunning = false\n"
    "  @Published var count = 0\n"
    "  var runningPublisher: AnyPublisher<Bool, Never> { $isRunning.eraseToAnyPublisher() }\n"
    "  func wire(_ other: Coordinator) {\n"
    "    other.$isRunning.sink { _ in }.store(in: &bag)\n"
    "    self.$count.sink { _ in }.store(in: &bag)\n"
    "  }\n"
    "}\n")
ROOT_VIEW = (
    "struct RootView: View {\n"
    "  var body: some View {\n"
    "    Text(\"x\").environmentObject(manager)\n"
    "  }\n"
    "}\n")
CEILING = (
    "# comment\n"
    "type|photo-export/Manager.swift|Manager\n"
    "published|photo-export/Manager.swift|2\n"
    "external-publisher|photo-export/Manager.swift|1\n"
    "environment-object|photo-export/RootView.swift|1\n")


class ObservationRatchetGuardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.ci = self.root / "scripts/ci"
        self.ci.mkdir(parents=True)
        shutil.copy(GUARD, self.ci / GUARD.name)
        shutil.copy(CI_DIRECTORY / "swift_source.py", self.ci / "swift_source.py")
        self.app = self.root / "photo-export"
        self.app.mkdir()
        self.write("Manager.swift", MANAGER)
        self.write("RootView.swift", ROOT_VIEW)
        self.ceiling(CEILING)

    def write(self, name, source):
        path = self.app / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source)

    def ceiling(self, text):
        (self.ci / "observation-ratchet.txt").write_text(text)

    def run_guard(self):
        return subprocess.run(
            [sys.executable, "-B", str(self.ci / GUARD.name), str(self.root)],
            capture_output=True, text=True)

    def assertFails(self, *fragments):
        result = self.run_guard()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        for fragment in fragments:
            self.assertIn(fragment, result.stdout)
        return result

    def test_counts_matching_the_ceiling_pass_and_are_printed(self):
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("ObservableObject types: 1", result.stdout)
        self.assertIn("@Published declarations: 2", result.stdout)
        self.assertIn("external $publisher uses: 1", result.stdout)
        self.assertIn(".environmentObject( calls: 1", result.stdout)

    def test_new_published_property_fails(self):
        self.write("Manager.swift", MANAGER.replace(
            "  @Published var count = 0\n",
            "  @Published var count = 0\n  @Published var extra = 0\n"))
        self.assertFails("photo-export/Manager.swift: @Published declarations rose from 2 to 3")

    def test_published_in_a_file_without_a_ceiling_fails(self):
        self.write("Views/Other.swift", "final class Other { @Published var x = 0 }\n")
        self.assertFails("photo-export/Views/Other.swift: @Published declarations rose from 0 to 1")

    def test_new_observable_object_type_fails_even_across_lines(self):
        self.write(
            "Adapter.swift",
            "final class Adapter: NSObject,\n  ChangeObserving, ObservableObject\n{\n}\n")
        self.assertFails(
            "photo-export/Adapter.swift: new ObservableObject type Adapter")

    def test_observable_object_extension_counts_as_a_type(self):
        self.write("Store.swift", "extension Store: ObservableObject {}\n")
        self.assertFails("photo-export/Store.swift: new ObservableObject type Store")

    def test_new_external_publisher_use_fails_including_wrapped_receiver(self):
        self.write(
            "Adapter.swift",
            "func wire(_ manager: Manager) {\n  manager\n    .$count\n    .sink { _ in }\n}\n")
        self.assertFails(
            "photo-export/Adapter.swift: external $publisher uses rose from 0 to 1")

    def test_owning_type_and_binding_projections_are_not_external(self):
        self.write(
            "Owner.swift",
            "struct Owner: View {\n"
            "  @Published var flag = false\n"
            "  var p: AnyPublisher<Bool, Never> { $flag.combineLatest(self.$flag) }\n"
            "  var body: some View { Toggle(isOn: $model.flag) {} }\n"
            "}\n")
        self.ceiling(CEILING + "published|photo-export/Owner.swift|1\n")
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_new_environment_object_call_fails(self):
        self.write("RootView.swift", ROOT_VIEW.replace(
            ".environmentObject(manager)",
            ".environmentObject(manager)\n      .environmentObject (other)"))
        self.assertFails(
            "photo-export/RootView.swift: .environmentObject( calls rose from 1 to 2")

    def test_comments_and_strings_are_ignored(self):
        self.write(
            "Notes.swift",
            "// final class Old: ObservableObject { @Published var x = 0 }\n"
            "/* manager.$count .environmentObject(x) */\n"
            "let text = \"@Published manager.$count .environmentObject(\"\n")
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_lower_count_asks_to_lower_the_ceiling(self):
        self.write("Manager.swift", MANAGER.replace("  @Published var count = 0\n", ""))
        self.assertFails(
            "photo-export/Manager.swift: @Published declarations fell from 2 to 1",
            "lower its row in scripts/ci/observation-ratchet.txt")

    def test_migrated_type_asks_to_remove_its_row(self):
        self.write("Manager.swift", MANAGER.replace(": ObservableObject", ""))
        self.assertFails(
            "photo-export/Manager.swift: Manager no longer conforms to ObservableObject",
            "remove its row from scripts/ci/observation-ratchet.txt")

    def test_malformed_ceiling_row_fails(self):
        self.ceiling(CEILING + "published|photo-export/Manager.swift\n")
        result = self.run_guard()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("observation-ratchet.txt:6: expected kind|path|value", result.stderr)

    def test_unknown_ceiling_kind_fails(self):
        self.ceiling(CEILING + "observable|photo-export/Manager.swift|1\n")
        result = self.run_guard()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("unknown kind 'observable'", result.stderr)


if __name__ == "__main__":
    unittest.main()
