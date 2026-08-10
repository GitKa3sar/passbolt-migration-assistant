import json
import os
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest import mock

from passbolt_reconciliation import (
    acquire_journal_lease,
    build_recovery_state,
    CandidateProof,
    hash_client_destination_mapping,
    list_reconciliation_batches,
    ReconciliationJournal,
    ReconciliationJournalCorrupt,
    ReconciliationJournalBusy,
    ReconciliationJournalError,
    default_journal_root,
    hash_user_identifier,
    read_journal,
)


class ReconciliationJournalTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name) / "journals"
        self.user_id = "5b6f3df2-a40b-4ae5-9cc2-6f025cc19357"

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def create_journal(self) -> ReconciliationJournal:
        return ReconciliationJournal.create(
            app_version="0.12.5",
            server_origin="https://passbolt.example.test/",
            server_fingerprint="0123456789ABCDEF0123456789ABCDEF01234567",
            user_id_hash=hash_user_identifier(self.user_id),
            plan_digest="a" * 64,
            resource_format="v5",
            folder_format="v5",
            destination_mode="direct_folder",
            destination_folder_id="6ba7b810-9dad-41d1-80b4-00c04fd430c8",
            candidates=(
                CandidateProof("bbbbbbbbbbbbbbbb", "2" * 64),
                CandidateProof("aaaaaaaaaaaaaaaa", "1" * 64),
            ),
            root=self.root,
        )

    def test_round_trip_hash_chain_and_terminal_state(self) -> None:
        journal = self.create_journal()
        operation_id = str(uuid.uuid4())
        journal.append(
            "operation_intent",
            operation_id=operation_id,
            object_type="resource",
            action="create_resource",
            candidate_id="aaaaaaaaaaaaaaaa",
            destination_key_hash="3" * 64,
        )
        resource_id = str(uuid.uuid4())
        journal.append(
            "resource_created",
            operation_id=operation_id,
            resource_id=resource_id,
            candidate_id="aaaaaaaaaaaaaaaa",
            status="created_unshared",
        )
        journal.append(
            "batch_completed",
            created_folder_count=0,
            reconciled_folder_count=0,
            created_resource_count=1,
            shared_resource_count=0,
            skipped_duplicate_count=1,
        )

        snapshot = read_journal(journal.path)
        self.assertTrue(snapshot.complete)
        self.assertFalse(snapshot.requires_verification)
        self.assertFalse(snapshot.truncated_tail)
        self.assertEqual(snapshot.next_sequence, 4)
        self.assertEqual(snapshot.events[1]["previous_hash"], snapshot.events[0]["record_hash"])
        self.assertEqual(snapshot.events[2]["previous_hash"], snapshot.events[1]["record_hash"])
        self.assertEqual(snapshot.events[3]["previous_hash"], snapshot.events[2]["record_hash"])
        candidates = snapshot.events[0]["payload"]["candidates"]
        self.assertEqual(
            [candidate["candidate_id"] for candidate in candidates],
            ["aaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb"],
        )

    def test_journal_contains_no_identity_or_secret_values(self) -> None:
        journal = self.create_journal()
        raw = journal.path.read_text(encoding="utf-8")
        self.assertNotIn(self.user_id, raw)
        self.assertNotIn("password", raw.casefold())
        self.assertNotIn("passphrase", raw.casefold())
        self.assertNotIn("totp", raw.casefold())
        self.assertNotIn("private_key", raw.casefold())
        self.assertIn(hash_user_identifier(self.user_id), raw)

        sentinel = "SEGRETO-NON-DEVE-ESSERE-SCRITTO"
        with self.assertRaises(ReconciliationJournalError):
            journal.append(
                "operation_failed",
                operation_id=str(uuid.uuid4()),
                error_code="IMPORT_FAILED",
                outcome="unknown",
                password=sentinel,
            )
        self.assertNotIn(sentinel, journal.path.read_text(encoding="utf-8"))

    def test_authenticated_url_and_armored_material_are_rejected(self) -> None:
        with self.assertRaises(ReconciliationJournalError):
            ReconciliationJournal.create(
                app_version="0.12.5",
                server_origin="https://user:password@passbolt.example.test/",
                server_fingerprint="0123456789ABCDEF0123456789ABCDEF01234567",
                user_id_hash=hash_user_identifier(self.user_id),
                plan_digest="a" * 64,
                resource_format="v5",
                folder_format="v5",
                destination_mode="root",
                destination_folder_id=None,
                candidates=(),
                root=self.root,
            )

        journal = self.create_journal()
        with self.assertRaises(ReconciliationJournalError):
            journal.append(
                "operation_failed",
                operation_id=str(uuid.uuid4()),
                error_code="-----BEGIN PGP PRIVATE KEY BLOCK-----",
                outcome="unknown",
            )

    def test_truncated_tail_is_ignored_but_blocks_append(self) -> None:
        journal = self.create_journal()
        original_size = journal.path.stat().st_size
        with journal.path.open("ab") as stream:
            stream.write(b'{"schema_version":1,"sequence":1')
            stream.flush()
            os.fsync(stream.fileno())

        snapshot = read_journal(journal.path)
        self.assertTrue(snapshot.truncated_tail)
        self.assertTrue(snapshot.requires_verification)
        self.assertEqual(len(snapshot.events), 1)
        self.assertGreater(journal.path.stat().st_size, original_size)
        with self.assertRaises(ReconciliationJournalCorrupt):
            journal.append(
                "operation_intent",
                operation_id=str(uuid.uuid4()),
                object_type="folder",
                action="create_folder",
                destination_key_hash="4" * 64,
            )

    def test_complete_record_without_newline_is_treated_as_uncertain(self) -> None:
        journal = self.create_journal()
        journal.append(
            "operation_intent",
            operation_id=str(uuid.uuid4()),
            object_type="folder",
            action="create_folder",
            destination_key_hash="4" * 64,
        )
        raw = journal.path.read_bytes()
        self.assertTrue(raw.endswith(b"\n"))
        journal.path.write_bytes(raw[:-1])

        snapshot = read_journal(journal.path)
        self.assertTrue(snapshot.truncated_tail)
        self.assertEqual(len(snapshot.events), 1)

    def test_tampered_payload_is_rejected(self) -> None:
        journal = self.create_journal()
        lines = journal.path.read_bytes().splitlines()
        record = json.loads(lines[0].decode("utf-8"))
        record["payload"]["plan_digest"] = "b" * 64
        journal.path.write_bytes(
            json.dumps(record, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode(
                "utf-8"
            )
            + b"\n"
        )
        with self.assertRaises(ReconciliationJournalCorrupt):
            read_journal(journal.path)

    def test_malformed_middle_record_is_not_silently_salvaged(self) -> None:
        journal = self.create_journal()
        journal.append(
            "operation_intent",
            operation_id=str(uuid.uuid4()),
            object_type="resource",
            action="create_resource",
            candidate_id="aaaaaaaaaaaaaaaa",
        )
        lines = journal.path.read_bytes().splitlines(keepends=True)
        journal.path.write_bytes(lines[0] + b"not-json\n" + lines[1])
        with self.assertRaises(ReconciliationJournalCorrupt):
            read_journal(journal.path)

    def test_unknown_fields_and_invalid_transitions_are_rejected(self) -> None:
        journal = self.create_journal()
        with self.assertRaises(ReconciliationJournalError):
            journal.append(
                "operation_intent",
                operation_id=str(uuid.uuid4()),
                object_type="resource",
                action="create_resource",
                title="Portale reale",
            )
        with self.assertRaises(ReconciliationJournalError):
            journal.append(
                "resource_shared",
                operation_id=str(uuid.uuid4()),
                resource_id=str(uuid.uuid4()),
                candidate_id="aaaaaaaaaaaaaaaa",
                status="created_unshared",
            )

    def test_operation_flow_requires_matching_intent_and_closed_operations(self) -> None:
        journal = self.create_journal()
        with self.assertRaises(ReconciliationJournalError):
            journal.append(
                "resource_created",
                operation_id=str(uuid.uuid4()),
                resource_id=str(uuid.uuid4()),
                candidate_id="aaaaaaaaaaaaaaaa",
                status="created",
            )

        operation_id = str(uuid.uuid4())
        with self.assertRaises(ReconciliationJournalError):
            journal.append(
                "operation_intent",
                operation_id=operation_id,
                object_type="folder",
                action="create_resource",
                candidate_id="aaaaaaaaaaaaaaaa",
                destination_key_hash="4" * 64,
            )

        journal.append(
            "operation_intent",
            operation_id=operation_id,
            object_type="resource",
            action="create_resource",
            candidate_id="aaaaaaaaaaaaaaaa",
        )
        with self.assertRaises(ReconciliationJournalError):
            journal.append(
                "batch_completed",
                created_folder_count=0,
                reconciled_folder_count=0,
                created_resource_count=0,
                shared_resource_count=0,
                skipped_duplicate_count=0,
            )
        journal.append(
            "resource_created",
            operation_id=operation_id,
            resource_id=str(uuid.uuid4()),
            candidate_id="aaaaaaaaaaaaaaaa",
            status="created",
        )
        with self.assertRaises(ReconciliationJournalError):
            journal.append(
                "operation_failed",
                operation_id=operation_id,
                error_code="IMPORT_FAILED",
                outcome="confirmed",
            )

    def test_duplicate_json_keys_are_rejected_even_when_values_match(self) -> None:
        journal = self.create_journal()
        raw = journal.path.read_bytes()
        modified = raw.replace(b'"sequence":0', b'"sequence":0,"sequence":0', 1)
        self.assertNotEqual(modified, raw)
        journal.path.write_bytes(modified)
        with self.assertRaises(ReconciliationJournalCorrupt):
            read_journal(journal.path)

    def test_completed_journal_is_immutable(self) -> None:
        journal = self.create_journal()
        journal.append(
            "batch_completed",
            created_folder_count=0,
            reconciled_folder_count=0,
            created_resource_count=0,
            shared_resource_count=0,
            skipped_duplicate_count=2,
        )
        before = journal.path.read_bytes()
        with self.assertRaises(ReconciliationJournalError):
            journal.append(
                "operation_intent",
                operation_id=str(uuid.uuid4()),
                object_type="resource",
                action="create_resource",
                candidate_id="aaaaaaaaaaaaaaaa",
            )
        self.assertEqual(journal.path.read_bytes(), before)

    def test_default_root_uses_local_app_data(self) -> None:
        expected = self.root / "LocalAppData"
        with mock.patch.dict(os.environ, {"LOCALAPPDATA": str(expected)}):
            self.assertEqual(
                default_journal_root(),
                expected / "Passbolt Migration Assistant" / "Reconciliation",
            )

    def test_filename_and_batch_identity_are_bound(self) -> None:
        journal = self.create_journal()
        renamed = journal.path.with_name(f"batch-{uuid.uuid4()}.jsonl")
        journal.path.rename(renamed)
        with self.assertRaises(ReconciliationJournalCorrupt):
            read_journal(renamed)

    def test_authenticated_recovery_cycle_can_close_and_retry_an_operation(self) -> None:
        journal = self.create_journal()
        first_operation_id = str(uuid.uuid4())
        journal.append(
            "operation_intent",
            operation_id=first_operation_id,
            object_type="resource",
            action="create_resource",
            candidate_id="aaaaaaaaaaaaaaaa",
            destination_key_hash="3" * 64,
        )
        recovery_id = str(uuid.uuid4())
        journal.append(
            "operation_verified",
            recovery_id=recovery_id,
            operation_id=first_operation_id,
            object_type="resource",
            candidate_id="aaaaaaaaaaaaaaaa",
            destination_key_hash="3" * 64,
            resolution="not_applied",
        )
        journal.append(
            "recovery_verified",
            recovery_id=recovery_id,
            verification_digest="4" * 64,
            verified_operation_count=1,
            remote_success_count=0,
            retry_count=1,
        )
        retry_operation_id = str(uuid.uuid4())
        journal.append(
            "operation_intent",
            operation_id=retry_operation_id,
            object_type="resource",
            action="create_resource",
            candidate_id="aaaaaaaaaaaaaaaa",
            destination_key_hash="3" * 64,
        )
        journal.append(
            "resource_created",
            operation_id=retry_operation_id,
            resource_id=str(uuid.uuid4()),
            candidate_id="aaaaaaaaaaaaaaaa",
            status="created",
        )
        journal.append(
            "batch_completed",
            created_folder_count=0,
            reconciled_folder_count=0,
            created_resource_count=1,
            shared_resource_count=0,
            skipped_duplicate_count=1,
        )
        self.assertTrue(journal.read().complete)

    def test_recovery_cycle_requires_exact_counts(self) -> None:
        journal = self.create_journal()
        operation_id = str(uuid.uuid4())
        journal.append(
            "operation_intent",
            operation_id=operation_id,
            object_type="resource",
            action="create_resource",
            candidate_id="aaaaaaaaaaaaaaaa",
        )
        recovery_id = str(uuid.uuid4())
        resource_id = str(uuid.uuid4())
        journal.append(
            "operation_verified",
            recovery_id=recovery_id,
            operation_id=operation_id,
            object_type="resource",
            candidate_id="aaaaaaaaaaaaaaaa",
            resource_id=resource_id,
            resolution="remote_success",
        )
        with self.assertRaises(ReconciliationJournalError):
            journal.append(
                "batch_completed",
                created_folder_count=0,
                reconciled_folder_count=0,
                created_resource_count=1,
                shared_resource_count=0,
                skipped_duplicate_count=1,
            )
        with self.assertRaises(ReconciliationJournalError):
            journal.append(
                "recovery_verified",
                recovery_id=recovery_id,
                verification_digest="4" * 64,
                verified_operation_count=1,
                remote_success_count=1,
                retry_count=1,
            )

    def test_recovery_state_and_listing_are_secret_free_and_bounded(self) -> None:
        journal = self.create_journal()
        operation_id = str(uuid.uuid4())
        journal.append(
            "operation_intent",
            operation_id=operation_id,
            object_type="folder",
            action="create_folder",
            destination_key_hash="4" * 64,
            permission_mask_hash="5" * 64,
        )
        state = build_recovery_state(journal.read())
        self.assertEqual(state["batch_id"], journal.batch_id)
        self.assertEqual(state["operations"][0]["operation_id"], operation_id)
        serialized = json.dumps(state)
        self.assertNotIn("password", serialized.casefold())
        summaries = list_reconciliation_batches(self.root)
        self.assertEqual(len(summaries), 1)
        self.assertEqual(summaries[0].batch_id, journal.batch_id)
        self.assertEqual(summaries[0].status, "recovery_required")

    def test_truncated_journal_is_listed_but_never_built_for_recovery(self) -> None:
        journal = self.create_journal()
        with journal.path.open("ab") as stream:
            stream.write(b'{"schema_version":1')
            stream.flush()
            os.fsync(stream.fileno())
        snapshot = journal.read()
        self.assertTrue(snapshot.truncated_tail)
        with self.assertRaises(ReconciliationJournalCorrupt):
            build_recovery_state(snapshot)
        summaries = list_reconciliation_batches(self.root)
        self.assertEqual(summaries[0].status, "truncated")

    def test_client_mapping_hash_is_order_independent_but_destination_bound(self) -> None:
        first = [
            {"client": "Cliente Alfa", "folder_id": None},
            {
                "client": "Cliente Beta",
                "folder_id": "6ba7b810-9dad-41d1-80b4-00c04fd430c8",
            },
        ]
        self.assertEqual(
            hash_client_destination_mapping(first),
            hash_client_destination_mapping(list(reversed(first))),
        )
        changed = [dict(item) for item in first]
        changed[0]["folder_id"] = "a8098c1a-f86e-11da-bd1a-00112444be1e"
        self.assertNotEqual(
            hash_client_destination_mapping(first),
            hash_client_destination_mapping(changed),
        )

    def test_batch_lease_blocks_a_concurrent_recovery_until_released(self) -> None:
        journal = self.create_journal()
        first = acquire_journal_lease(journal)
        try:
            with self.assertRaises(ReconciliationJournalBusy):
                acquire_journal_lease(journal)
        finally:
            first.close()
        second = acquire_journal_lease(journal)
        second.close()


if __name__ == "__main__":
    unittest.main()
