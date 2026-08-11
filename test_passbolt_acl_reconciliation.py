from __future__ import annotations

import json
import os
import tempfile
import unittest
import uuid
from pathlib import Path

from passbolt_acl_reconciliation import (
    AclReconciliationJournal,
    ReconciliationJournalBusy,
    ReconciliationJournalCorrupt,
    ReconciliationJournalError,
    acquire_acl_journal_lease,
    archive_acl_batch,
    build_acl_recovery_state,
    describe_acl_batch,
    list_acl_batches,
    read_acl_batch,
)
from passbolt_import import _SessionAclCoordinator
from passbolt_reconciliation import hash_user_identifier


SERVER_ORIGIN = "https://passbolt.example.test"
SERVER_FINGERPRINT = "A" * 40
USER_ID = "user-id"
USER_HASH = hash_user_identifier(USER_ID)
SNAPSHOT_DIGEST = "1" * 64
DESIRED_DIGEST = "2" * 64
PLAN_DIGEST = "3" * 64


def create_journal(root: str | Path) -> AclReconciliationJournal:
    return AclReconciliationJournal.create(
        app_version="0.16.0",
        server_origin=SERVER_ORIGIN,
        server_fingerprint=SERVER_FINGERPRINT,
        user_id_hash=USER_HASH,
        object_type="resource",
        object_id="resource-id",
        object_state_digest=SNAPSHOT_DIGEST,
        desired_acl_digest=DESIRED_DIGEST,
        plan_digest=PLAN_DIGEST,
        desired_permissions=[
            {"aro": "User", "aro_foreign_key": "recipient-id", "type": 1}
        ],
        change_count=1,
        add_count=1,
        upgrade_count=0,
        root=root,
    )


def append_complete(journal: AclReconciliationJournal) -> None:
    operation_id = str(uuid.uuid4())
    common = {
        "operation_id": operation_id,
        "object_type": "resource",
        "object_id": "resource-id",
        "permission_change_count": 1,
        "added_user_count": 1,
    }
    journal.append("acl_operation_intent", **common)
    journal.append("acl_operation_applied", **common)
    journal.append(
        "acl_batch_completed",
        object_type="resource",
        object_id="resource-id",
        resulting_acl_digest=DESIRED_DIGEST,
        applied_change_count=1,
        permission_change_count=1,
        added_user_count=1,
        recovered=False,
    )


class AclJournalTests(unittest.TestCase):
    def test_create_read_and_recovery_state_are_secret_free(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            journal = create_journal(temporary)
            snapshot = journal.read()
            self.assertFalse(snapshot.complete)
            state = build_acl_recovery_state(journal.batch_id, temporary)
            self.assertEqual(state["object_id"], "resource-id")
            self.assertEqual(state["desired_permissions"][0]["aro_foreign_key"], "recipient-id")
            encoded = journal.path.read_text(encoding="utf-8")
            self.assertNotIn("password", encoded.casefold())
            self.assertNotIn("BEGIN PGP", encoded)

    def test_restrictive_counts_and_mode_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            journal = AclReconciliationJournal.create(
                app_version="0.17.0",
                server_origin=SERVER_ORIGIN,
                server_fingerprint=SERVER_FINGERPRINT,
                user_id_hash=USER_HASH,
                object_type="folder",
                object_id="folder-id",
                object_state_digest=SNAPSHOT_DIGEST,
                desired_acl_digest=DESIRED_DIGEST,
                plan_digest=PLAN_DIGEST,
                desired_permissions=[],
                change_count=2,
                add_count=0,
                upgrade_count=0,
                downgrade_count=1,
                revoke_count=1,
                apply_mode="restrictive",
                root=temporary,
            )
            state = build_acl_recovery_state(journal.batch_id, temporary)
            self.assertEqual(state["downgrade_count"], 1)
            self.assertEqual(state["revoke_count"], 1)
            self.assertEqual(state["apply_mode"], "restrictive")
            operation_id = str(uuid.uuid4())
            operation = {
                "operation_id": operation_id,
                "object_type": "folder",
                "object_id": "folder-id",
                "permission_change_count": 2,
                "added_user_count": 0,
                "removed_user_count": 1,
                "restrictive_change_count": 2,
            }
            journal.append("acl_operation_intent", **operation)
            journal.append("acl_operation_applied", **operation)
            journal.append(
                "acl_batch_completed",
                object_type="folder",
                object_id="folder-id",
                resulting_acl_digest=DESIRED_DIGEST,
                applied_change_count=2,
                permission_change_count=2,
                added_user_count=0,
                removed_user_count=1,
                restrictive_change_count=2,
                destructive_actions_performed=True,
                recovered=False,
            )
            self.assertTrue(journal.read().complete)

    def test_partial_or_incoherent_restrictive_metadata_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = dict(
                app_version="0.17.0",
                server_origin=SERVER_ORIGIN,
                server_fingerprint=SERVER_FINGERPRINT,
                user_id_hash=USER_HASH,
                object_type="resource",
                object_id="resource-id",
                object_state_digest=SNAPSHOT_DIGEST,
                desired_acl_digest=DESIRED_DIGEST,
                plan_digest=PLAN_DIGEST,
                desired_permissions=[],
                change_count=1,
                add_count=0,
                upgrade_count=0,
                root=temporary,
            )
            with self.assertRaises(ReconciliationJournalError):
                AclReconciliationJournal.create(
                    **base, downgrade_count=0, revoke_count=1
                )
            with self.assertRaises(ReconciliationJournalError):
                AclReconciliationJournal.create(
                    **base,
                    downgrade_count=0,
                    revoke_count=1,
                    apply_mode="additive",
                )

    def test_complete_batch_is_terminal_and_listed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            journal = create_journal(temporary)
            append_complete(journal)
            self.assertTrue(journal.read().complete)
            summary = list_acl_batches(temporary)[0]
            self.assertEqual(summary.status, "complete")
            with self.assertRaises(ReconciliationJournalError):
                journal.append(
                    "acl_recovery_verified",
                    recovery_id=str(uuid.uuid4()),
                    resolution="remote_success",
                    remote_acl_digest=DESIRED_DIGEST,
                    recovery_plan_digest="4" * 64,
                )

    def test_safe_details_expose_counts_but_not_identity_or_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            journal = create_journal(temporary)
            details = describe_acl_batch(journal.batch_id, temporary)
            self.assertEqual(details.status, "recovery_required")
            self.assertEqual(details.object_id, "resource-id")
            self.assertEqual(details.add_count, 1)
            self.assertEqual(details.apply_mode, "additive")
            serialized = json.dumps(details.__dict__)
            self.assertNotIn(SERVER_ORIGIN, serialized)
            self.assertNotIn(SERVER_FINGERPRINT, serialized)
            self.assertNotIn(USER_HASH, serialized)
            self.assertNotIn("recipient-id", serialized)
            self.assertNotIn(temporary, serialized)

    def test_archiving_requires_exact_status_confirmation_and_lease(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            journal = create_journal(temporary)
            with self.assertRaises(ReconciliationJournalError):
                archive_acl_batch(
                    journal.batch_id,
                    expected_status="complete",
                    confirmation=f"ARCHIVIA ACL {journal.batch_id}",
                    root=temporary,
                )
            with self.assertRaises(ReconciliationJournalError):
                archive_acl_batch(
                    journal.batch_id,
                    expected_status="recovery_required",
                    confirmation=f"ARCHIVIA {journal.batch_id}",
                    root=temporary,
                )
            lease = acquire_acl_journal_lease(journal)
            try:
                with self.assertRaises(ReconciliationJournalBusy):
                    archive_acl_batch(
                        journal.batch_id,
                        expected_status="recovery_required",
                        confirmation=f"ARCHIVIA ACL {journal.batch_id}",
                        root=temporary,
                    )
            finally:
                lease.close()

            result = archive_acl_batch(
                journal.batch_id,
                expected_status="recovery_required",
                confirmation=f"ARCHIVIA ACL {journal.batch_id}",
                root=temporary,
            )
            archived = (
                Path(temporary)
                / "Archive"
                / "recovery_required"
                / journal.path.name
            )
            self.assertEqual(result.previous_status, "recovery_required")
            self.assertFalse(journal.path.exists())
            self.assertTrue(archived.is_file())
            self.assertEqual(read_acl_batch(journal.batch_id, archived.parent).batch_id, journal.batch_id)

    def test_complete_truncated_and_corrupt_journals_are_preserved_by_status(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            completed = create_journal(temporary)
            append_complete(completed)
            complete_result = archive_acl_batch(
                completed.batch_id,
                expected_status="complete",
                confirmation=f"ARCHIVIA ACL {completed.batch_id}",
                root=temporary,
            )
            self.assertEqual(complete_result.previous_status, "complete")

            truncated = create_journal(temporary)
            with truncated.path.open("ab") as handle:
                handle.write(b'{"partial"')
                handle.flush()
                os.fsync(handle.fileno())
            truncated_result = archive_acl_batch(
                truncated.batch_id,
                expected_status="truncated",
                confirmation=f"ARCHIVIA ACL {truncated.batch_id}",
                root=temporary,
            )
            self.assertEqual(truncated_result.previous_status, "truncated")

            corrupt_id = str(uuid.uuid4())
            corrupt_path = Path(temporary) / f"acl-batch-{corrupt_id}.jsonl"
            corrupt_path.write_bytes(b"not-json\n")
            corrupt_details = describe_acl_batch(corrupt_id, temporary)
            self.assertEqual(corrupt_details.status, "corrupt")
            self.assertIsNone(corrupt_details.object_id)
            corrupt_result = archive_acl_batch(
                corrupt_id,
                expected_status="corrupt",
                confirmation=f"ARCHIVIA ACL {corrupt_id}",
                root=temporary,
            )
            self.assertEqual(corrupt_result.previous_status, "corrupt")
            for status, path in (
                ("complete", completed.path),
                ("truncated", truncated.path),
                ("corrupt", corrupt_path),
            ):
                self.assertTrue(
                    (Path(temporary) / "Archive" / status / path.name).is_file()
                )

    def test_hash_tampering_is_detected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            journal = create_journal(temporary)
            lines = journal.path.read_text(encoding="utf-8").splitlines()
            record = json.loads(lines[0])
            record["payload"]["object_id"] = "tampered-resource"
            journal.path.write_text(json.dumps(record) + "\n", encoding="utf-8")
            with self.assertRaises(ReconciliationJournalCorrupt):
                journal.read()

    def test_truncated_tail_is_not_automatically_recoverable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            journal = create_journal(temporary)
            with journal.path.open("ab") as handle:
                handle.write(b'{"partial"')
            self.assertTrue(read_acl_batch(journal.batch_id, temporary).truncated_tail)
            with self.assertRaises(ReconciliationJournalError):
                build_acl_recovery_state(journal.batch_id, temporary)

    def test_sensitive_fields_and_restrictive_counts_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(ReconciliationJournalError):
                AclReconciliationJournal.create(
                    app_version="0.16.0",
                    server_origin=SERVER_ORIGIN,
                    server_fingerprint=SERVER_FINGERPRINT,
                    user_id_hash=USER_HASH,
                    object_type="resource",
                    object_id="resource-id",
                    object_state_digest=SNAPSHOT_DIGEST,
                    desired_acl_digest=DESIRED_DIGEST,
                    plan_digest=PLAN_DIGEST,
                    desired_permissions=[],
                    change_count=2,
                    add_count=1,
                    upgrade_count=0,
                    password="must-not-be-written",
                    root=temporary,
                )

    def test_exclusive_recovery_lease(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            journal = create_journal(temporary)
            lease = acquire_acl_journal_lease(journal)
            try:
                with self.assertRaises(ReconciliationJournalBusy):
                    acquire_acl_journal_lease(journal)
            finally:
                lease.close()
            second = acquire_acl_journal_lease(journal)
            second.close()

    def test_failed_operation_can_be_verified_and_retried(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            journal = create_journal(temporary)
            first_operation = str(uuid.uuid4())
            journal.append(
                "acl_operation_intent",
                operation_id=first_operation,
                object_type="resource",
                object_id="resource-id",
                permission_change_count=1,
                added_user_count=1,
            )
            journal.append(
                "acl_operation_failed",
                operation_id=first_operation,
                object_type="resource",
                object_id="resource-id",
                error_code="ACL_APPLY_FAILED",
                outcome="unknown",
                http_status=500,
            )
            journal.append(
                "acl_recovery_verified",
                recovery_id=str(uuid.uuid4()),
                resolution="not_applied",
                remote_acl_digest=SNAPSHOT_DIGEST,
                recovery_plan_digest="4" * 64,
            )
            retry_operation = str(uuid.uuid4())
            journal.append(
                "acl_operation_intent",
                operation_id=retry_operation,
                object_type="resource",
                object_id="resource-id",
                permission_change_count=1,
                added_user_count=1,
            )
            self.assertEqual(journal.read().events[-1]["payload"]["operation_id"], retry_operation)


class AclCoordinatorTests(unittest.TestCase):
    def _opened(self, coordinator: _SessionAclCoordinator) -> None:
        coordinator.observe(
            "session-open",
            {
                "ok": True,
                "result": {
                    "session_id": "session-id",
                    "base_url": SERVER_ORIGIN,
                    "server_fingerprint": SERVER_FINGERPRINT,
                    "user": {"id": USER_ID},
                },
            },
        )

    @staticmethod
    def _plan() -> dict[str, object]:
        return {
            "command": "acl-plan",
            "session_id": "session-id",
            "plan_id": "plan-id",
            "object": {"object_type": "resource", "object_id": "resource-id"},
            "object_state_digest": SNAPSHOT_DIGEST,
            "desired_acl_digest": DESIRED_DIGEST,
            "directory_state_digest": "4" * 64,
            "plan_digest": PLAN_DIGEST,
            "desired_permissions": [
                {"aro": "User", "aro_foreign_key": "recipient-id", "type": 1}
            ],
            "change_count": 1,
            "counts": {"add": 1, "upgrade": 0, "downgrade": 0, "revoke": 0},
            "apply_available": True,
            "additive_apply_available": True,
            "apply_mode": "additive",
            "confirmation_required": "APPLICA ACL 1 33333333",
        }

    def test_apply_is_bound_to_observed_plan_and_closes_journal(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            coordinator = _SessionAclCoordinator(temporary)
            self._opened(coordinator)
            coordinator.observe("session-acl-plan", {"ok": True, "result": self._plan()})
            request = {
                "session_id": "session-id",
                "plan_id": "plan-id",
                "object_state_digest": SNAPSHOT_DIGEST,
                "desired_acl_digest": DESIRED_DIGEST,
                "directory_state_digest": "4" * 64,
                "plan_digest": PLAN_DIGEST,
                "confirmation": "APPLICA ACL 1 33333333",
            }
            bridge_request = dict(request)
            batch_id = coordinator.start_apply(request, bridge_request)
            operation_id = str(uuid.uuid4())
            for event_type, payload in (
                ("acl_operation_intent", {
                    "operation_id": operation_id, "object_type": "resource", "object_id": "resource-id",
                    "permission_change_count": 1, "added_user_count": 1,
                    "removed_user_count": 0, "restrictive_change_count": 0,
                }),
                ("acl_operation_applied", {
                    "operation_id": operation_id, "object_type": "resource", "object_id": "resource-id",
                    "permission_change_count": 1, "added_user_count": 1,
                    "removed_user_count": 0, "restrictive_change_count": 0,
                }),
                ("acl_batch_completed", {
                    "object_type": "resource", "object_id": "resource-id", "resulting_acl_digest": DESIRED_DIGEST,
                    "applied_change_count": 1, "permission_change_count": 1, "added_user_count": 1,
                    "removed_user_count": 0, "restrictive_change_count": 0,
                    "destructive_actions_performed": False, "recovered": False,
                }),
            ):
                coordinator.persist_progress({
                    "type": "progress", "batch_id": batch_id,
                    "event_type": event_type, "payload": payload,
                })
            envelope = coordinator.finish_apply({"ok": True, "result": {"complete": True}})
            self.assertEqual(envelope["result"]["acl_batch_id"], batch_id)
            self.assertTrue(read_acl_batch(batch_id, temporary).complete)

    def test_failed_apply_returns_batch_for_guided_recovery(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            coordinator = _SessionAclCoordinator(temporary)
            self._opened(coordinator)
            coordinator.observe("session-acl-plan", {"ok": True, "result": self._plan()})
            request = {
                "session_id": "session-id", "plan_id": "plan-id",
                "object_state_digest": SNAPSHOT_DIGEST, "desired_acl_digest": DESIRED_DIGEST,
                "directory_state_digest": "4" * 64,
                "plan_digest": PLAN_DIGEST, "confirmation": "APPLICA ACL 1 33333333",
            }
            bridge_request = dict(request)
            batch_id = coordinator.start_apply(request, bridge_request)
            envelope = coordinator.finish_apply({
                "ok": False,
                "error": {"code": "ACL_APPLY_FAILED", "message": "safe failure"},
            })
            self.assertEqual(envelope["error"]["details"]["acl_batch_id"], batch_id)
            self.assertEqual(list_acl_batches(temporary)[0].status, "recovery_required")

    def test_restrictive_plan_is_journaled_with_all_counts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            coordinator = _SessionAclCoordinator(temporary)
            self._opened(coordinator)
            plan = self._plan()
            plan.update({
                "change_count": 2,
                "counts": {"add": 0, "upgrade": 0, "downgrade": 1, "revoke": 1},
                "additive_apply_available": False,
                "apply_mode": "restrictive",
                "confirmation_required": "CONFERMO RIDUZIONE ACL 2 1 33333333",
            })
            coordinator.observe("session-acl-plan", {"ok": True, "result": plan})
            request = {
                "session_id": "session-id", "plan_id": "plan-id",
                "object_state_digest": SNAPSHOT_DIGEST,
                "desired_acl_digest": DESIRED_DIGEST,
                "directory_state_digest": "4" * 64,
                "plan_digest": PLAN_DIGEST,
                "confirmation": "CONFERMO RIDUZIONE ACL 2 1 33333333",
            }
            bridge_request = dict(request)
            batch_id = coordinator.start_apply(request, bridge_request)
            state = build_acl_recovery_state(batch_id, temporary)
            self.assertEqual(state["downgrade_count"], 1)
            self.assertEqual(state["revoke_count"], 1)
            self.assertEqual(state["apply_mode"], "restrictive")
            coordinator.abandon()


if __name__ == "__main__":
    unittest.main()
