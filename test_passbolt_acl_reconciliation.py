from __future__ import annotations

import json
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
    build_acl_recovery_state,
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
            "additive_apply_available": True,
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
                }),
                ("acl_operation_applied", {
                    "operation_id": operation_id, "object_type": "resource", "object_id": "resource-id",
                    "permission_change_count": 1, "added_user_count": 1,
                }),
                ("acl_batch_completed", {
                    "object_type": "resource", "object_id": "resource-id", "resulting_acl_digest": DESIRED_DIGEST,
                    "applied_change_count": 1, "permission_change_count": 1, "added_user_count": 1, "recovered": False,
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


if __name__ == "__main__":
    unittest.main()
