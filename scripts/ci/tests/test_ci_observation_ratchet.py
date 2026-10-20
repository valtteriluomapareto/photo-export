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
    "    objectWillChange.send()\n"
    "  }\n"
    "}\n")
ROOT_VIEW = (
    "struct RootView: View {\n"
    "  @StateObject private var manager = Manager()\n"
    "  var body: some View {\n"
    "    Child().environmentObject(manager)\n"
    "  }\n"
    "}\n"
    "struct Child: View {\n"
    "  @EnvironmentObject private var manager: Manager\n"
    "  @ObservedObject var other: Manager\n"
    "  var body: some View { Text(\"x\") }\n"
    "}\n")
CEILING = (
    "# comment\n"
    "type|photo-export/Manager.swift|Manager\n"
    "external-publisher|photo-export/Manager.swift|1\n"
    "total|published|2\n"
    "total|environment-object|1\n"
    "total|environment-object-property|1\n"
    "total|state-object|1\n"
    "total|observed-object|1\n"
    "total|object-will-change|0\n")


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

    def assertPasses(self):
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def assertFails(self, *fragments):
        result = self.run_guard()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        for fragment in fragments:
            self.assertIn(fragment, result.stdout)
        return result

    def add_view(self, source):
        self.write("Views/Extra.swift", source)

    def test_counts_matching_the_ceiling_pass_and_are_printed(self):
        result = self.assertPasses()
        for line in (
                "ObservableObject types: 1", "external $publisher uses: 1",
                "@Published declarations: 2", ".environmentObject( calls: 1",
                "@EnvironmentObject properties: 1", "@StateObject properties: 1",
                "@ObservedObject properties: 1", "external objectWillChange uses: 0"):
            self.assertIn(line, result.stdout)

    def test_new_published_property_anywhere_fails(self):
        self.add_view("final class Other { @Published var x = 0 }\n")
        self.assertFails("@Published declarations rose from 2 to 3")

    def test_moving_a_total_between_files_passes(self):
        self.write("Manager.swift", MANAGER.replace("  @Published var count = 0\n", ""))
        self.add_view("final class Other { @Published var x = 0 }\n")
        self.assertPasses()

    def test_new_environment_object_call_fails(self):
        self.write("RootView.swift", ROOT_VIEW.replace(
            ".environmentObject(manager)",
            ".environmentObject(manager)\n      .environmentObject (other)"))
        self.assertFails(".environmentObject( calls rose from 1 to 2")

    def test_new_environment_object_property_fails(self):
        self.add_view("struct V: View {\n  @EnvironmentObject var m: Manager\n}\n")
        self.assertFails("@EnvironmentObject properties rose from 1 to 2")

    def test_new_state_object_property_fails(self):
        self.add_view("struct V: View {\n  @StateObject var m = Manager()\n}\n")
        self.assertFails("@StateObject properties rose from 1 to 2")

    def test_new_observed_object_property_fails(self):
        self.add_view("struct V: View {\n  @ObservedObject var m: Manager\n}\n")
        self.assertFails("@ObservedObject properties rose from 1 to 2")

    def test_external_object_will_change_fails_and_own_use_does_not(self):
        self.add_view(
            "func poke(_ m: Manager) {\n  m\n    .objectWillChange.send()\n}\n"
            "final class Own: ObservableObject {\n"
            "  func f() { self.objectWillChange.send(); self?.objectWillChange.send() }\n}\n")
        self.ceiling(CEILING + "type|photo-export/Views/Extra.swift|Own\n")
        self.assertFails("external objectWillChange uses rose from 0 to 1")

    def test_lower_total_asks_to_lower_the_ceiling(self):
        self.write("Manager.swift", MANAGER.replace("  @Published var count = 0\n", ""))
        self.assertFails(
            "@Published declarations fell from 2 to 1",
            "lower its total row in scripts/ci/observation-ratchet.txt")

    def test_new_observable_object_type_fails_even_across_lines(self):
        self.write(
            "Adapter.swift",
            "final class Adapter: NSObject,\n  ChangeObserving, ObservableObject\n{\n}\n")
        self.assertFails("photo-export/Adapter.swift: new ObservableObject type Adapter")

    def test_observable_object_extension_counts_as_a_type(self):
        self.write("Store.swift", "extension Store: ObservableObject {}\n")
        self.assertFails("photo-export/Store.swift: new ObservableObject type Store")

    def test_observable_object_protocol_counts_as_a_type(self):
        self.write("Providing.swift", "protocol Providing: AnyObject, ObservableObject {}\n")
        self.assertFails("photo-export/Providing.swift: new ObservableObject type Providing")

    def test_migrated_type_asks_to_remove_its_row(self):
        self.write("Manager.swift", MANAGER.replace(": ObservableObject", ""))
        self.assertFails(
            "photo-export/Manager.swift: Manager no longer conforms to ObservableObject",
            "remove its row from scripts/ci/observation-ratchet.txt")

    def test_new_external_publisher_use_fails_including_wrapped_receiver(self):
        self.write(
            "Adapter.swift",
            "func wire(_ manager: Manager) {\n  manager\n    .$count\n    .sink { _ in }\n}\n")
        self.assertFails("photo-export/Adapter.swift: external $publisher uses rose from 0 to 1")

    def test_lower_external_publisher_count_asks_to_lower_the_file_row(self):
        self.write("Manager.swift", MANAGER.replace("    other.$isRunning.sink { _ in }.store(in: &bag)\n", ""))
        self.assertFails(
            "photo-export/Manager.swift: external $publisher uses fell from 1 to 0",
            "lower its row in scripts/ci/observation-ratchet.txt")

    def test_own_and_optional_self_and_binding_projections_are_not_external(self):
        self.add_view(
            "final class Owner {\n"
            "  var p: AnyPublisher<Bool, Never> { $flag.combineLatest(self.$flag) }\n"
            "  func f() { sink { [weak self] in self?.$flag.send(true); self!.$flag.send(true) } }\n"
            "}\n"
            "struct V: View { var body: some View { Toggle(isOn: $model.flag) {} } }\n")
        self.assertPasses()

    def test_internal_receiver_split_across_lines_is_not_external(self):
        self.add_view(
            "final class Owner {\n"
            "  func f() {\n"
            "    self\n      .$flag.send(true)\n"
            "    sink { [weak self] in\n      self?\n        .objectWillChange.send()\n    }\n"
            "  }\n"
            "}\n")
        self.assertPasses()

    def test_comments_and_strings_are_ignored(self):
        self.write(
            "Notes.swift",
            "// final class Old: ObservableObject { @Published var x = 0 }\n"
            "/* manager.$count .environmentObject(x) @StateObject m.objectWillChange */\n"
            "let text = \"@Published @EnvironmentObject manager.$count .environmentObject(\"\n")
        self.assertPasses()

    def test_missing_total_row_fails(self):
        self.ceiling(CEILING.replace("total|state-object|1\n", ""))
        result = self.run_guard()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("missing total row for state-object", result.stderr)

    def test_malformed_ceiling_row_fails(self):
        self.ceiling(CEILING + "total|published\n")
        result = self.run_guard()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("observation-ratchet.txt:10: expected kind|key|value", result.stderr)

    def test_unknown_total_row_fails(self):
        self.ceiling(CEILING + "total|x|1\n")
        result = self.run_guard()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("unknown total 'x'", result.stderr)

    def test_duplicate_total_row_fails(self):
        self.ceiling(CEILING + "total|published|2\n")
        result = self.run_guard()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("duplicate total row for published", result.stderr)

    def test_unknown_ceiling_kind_fails(self):
        self.ceiling(CEILING + "published|photo-export/Manager.swift|2\n")
        result = self.run_guard()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("unknown kind 'published'", result.stderr)


if __name__ == "__main__":
    unittest.main()
