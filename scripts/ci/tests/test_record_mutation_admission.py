"""Check the real source guard against bounded writes and direct bypasses."""
import importlib.util
from pathlib import Path
import sys
import unittest

DIRECTORY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(DIRECTORY))
SPEC = importlib.util.spec_from_file_location('record_admission', DIRECTORY / 'check-record-mutation-admission.py')
GUARD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GUARD)


class RecordMutationAdmissionTests(unittest.TestCase):
    def test_direct_writers_are_rejected(self):
        for receiver in ['host.exportRecordStore', 'collectionStore', 'recordStoreRouter']:
            for method in ['bulkImportRecords', 'markVariantInProgress', 'markVariantFailed', 'configure', 'resetToEmpty']:
                self.assertEqual(len(GUARD.problems(f'{receiver}.{method}(value)')), 1)

    def test_admitted_batches_allow_nested_control_flow(self):
        for method in ['withMutationAdmission', 'withImportMutationAdmission']:
            source = f'try await store.{method}(placement: value) {{ if current {{ host.exportRecordStore.bulkImportRecords(rows) }} }}'
            self.assertEqual(GUARD.problems(source), [])
            self.assertEqual(len(GUARD.problems(source + '\ncollectionStore.upsertPlacement(p)')), 1)

    def test_admission_primitive_allows_nested_writes_only_inside_its_closure(self):
        for receiver in ['host.exportRecordStore', 'collectionStore']:
            source = f'{receiver}.mutationAdmission.perform {{ if current {{ {receiver}.bulkImportRecords(rows) }} }}'
            self.assertEqual(GUARD.problems(source), [])
            self.assertEqual(len(GUARD.problems(source + f'\n{receiver}.bulkImportRecords(rows)')), 1)

    def test_admission_primitive_lookalikes_and_text_do_not_authorize_writes(self):
        for expression in ['other.perform', 'mutationAdmission.performLater',
                           'mutationAdmission.other', 'notmutationAdmission.perform']:
            source = f'{expression} {{ collectionStore.bulkImportRecords(rows) }}'
            self.assertEqual(len(GUARD.problems(source)), 1)
        for text in ['// mutationAdmission.perform', 'let text = "mutationAdmission.perform"']:
            source = text + '\nif current { collectionStore.bulkImportRecords(rows) }'
            self.assertEqual(len(GUARD.problems(source)), 1)

    def test_comments_strings_and_unrelated_methods_are_ignored(self):
        self.assertEqual(GUARD.problems('// collectionStore.configure(x)\nlet text = "timelineStore.resetToEmpty()"\nother.configure(x)'), [])

    def test_owned_store_and_router_adapters_remain_compatible(self):
        self.assertEqual(GUARD.problems('timelineStore.markVariantFailed(x)', owned=True), [])
