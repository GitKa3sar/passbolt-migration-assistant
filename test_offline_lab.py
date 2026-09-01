from __future__ import annotations

import json
import shutil
import tempfile
import unittest
import uuid
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path

from cryptography import x509

from offline_lab_acceptance import (
    OfflineAcceptanceError,
    STATEFUL_SCENARIOS,
    _acl_recovery_state,
    _profile_formats,
    _validate_progress,
)
from offline_lab_setup import (
    LAB_MARKER,
    OfflineLabSetupError,
    create_offline_lab_workspace,
)
from passbolt_integration_matrix import MANUAL_SCENARIOS
from passbolt_review import analyze_files


class OfflineLabSetupTests(unittest.TestCase):
    def setUp(self) -> None:
        self.workspace = (
            Path(tempfile.gettempdir())
            / f"passbolt-offline-lab-{uuid.uuid4().hex}"
        )

    def tearDown(self) -> None:
        if self.workspace.exists() and self.workspace.name.startswith(
            "passbolt-offline-lab-"
        ):
            shutil.rmtree(self.workspace)

    def test_workspace_contains_ephemeral_tls_and_synthetic_documents(self) -> None:
        result = create_offline_lab_workspace(self.workspace)

        self.assertEqual(result["status"], "OK")
        self.assertFalse(result["contains_real_credentials"])
        self.assertEqual(result["document_count"], 4)
        certificate_path = Path(result["certificate_path"])
        key_path = Path(result["tls_private_key_path"])
        dataset_root = Path(result["dataset_root"])
        self.assertTrue(certificate_path.is_file())
        self.assertTrue(key_path.is_file())
        self.assertTrue(dataset_root.is_dir())
        certificate = x509.load_pem_x509_certificate(certificate_path.read_bytes())
        san = certificate.extensions.get_extension_for_class(
            x509.SubjectAlternativeName
        ).value
        self.assertIn("localhost", san.get_values_for_type(x509.DNSName))
        self.assertGreater(certificate.not_valid_after_utc, datetime.now(timezone.utc))

    def test_generated_dataset_is_reviewable_and_never_serializes_passwords(self) -> None:
        result = create_offline_lab_workspace(self.workspace)
        dataset_root = Path(result["dataset_root"])
        relative_paths = [item["relative_path"] for item in result["documents"]]

        review = analyze_files(dataset_root, relative_paths)

        self.assertEqual(review.analyzed_files, 4)
        self.assertEqual(review.candidate_count, 5)
        self.assertTrue(all(candidate.status == "ready" for candidate in review.candidates))
        serialized = json.dumps(asdict(review), ensure_ascii=False)
        self.assertNotIn(LAB_MARKER, serialized)
        self.assertTrue(all(candidate.secret_mask == "********" for candidate in review.candidates))

    def test_workspace_outside_temp_is_rejected(self) -> None:
        outside = Path(__file__).resolve().parent / f"passbolt-offline-lab-{uuid.uuid4().hex}"
        with self.assertRaisesRegex(OfflineLabSetupError, "directory temporanea"):
            create_offline_lab_workspace(outside)

    def test_stateful_acceptance_covers_every_real_manual_scenario(self) -> None:
        self.assertEqual(STATEFUL_SCENARIOS, MANUAL_SCENARIOS)

    def test_stateful_profiles_keep_v5_folders_disabled(self) -> None:
        self.assertEqual(_profile_formats("v4"), ("v4", "v4"))
        self.assertEqual(_profile_formats("v5"), ("v5", "v4"))
        with self.assertRaisesRegex(OfflineAcceptanceError, "cartelle v4"):
            _profile_formats("auto")

    def test_stateful_progress_is_bounded_and_rejects_sensitive_fields(self) -> None:
        batch_id = "11111111-1111-4111-8111-111111111111"
        events: list[dict[str, object]] = []
        _validate_progress(
            {
                "type": "progress",
                "batch_id": batch_id,
                "event_type": "resource_verified",
                "payload": {
                    "candidate_id": "candidate-id",
                    "resource_id": "resource-id",
                    "metadata_match": True,
                    "content_match": True,
                    "destination_match": True,
                    "acl_match": True,
                },
            },
            batch_id,
            events,  # type: ignore[arg-type]
        )
        self.assertEqual(len(events), 1)
        with self.assertRaisesRegex(OfflineAcceptanceError, "sensibile"):
            _validate_progress(
                {
                    "type": "progress",
                    "batch_id": batch_id,
                    "event_type": "resource_verified",
                    "payload": {"password": "must-not-pass"},
                },
                batch_id,
                [],
            )

    def test_acl_recovery_state_contains_only_digest_bound_plan_data(self) -> None:
        plan = {
            "object": {"object_type": "resource", "object_id": "resource-id"},
            "object_state_digest": "1" * 64,
            "desired_acl_digest": "2" * 64,
            "plan_digest": "3" * 64,
            "desired_permissions": [
                {"aro": "User", "aro_foreign_key": "recipient-id", "type": 7}
            ],
            "change_count": 1,
            "counts": {"add": 1, "upgrade": 0, "downgrade": 0, "revoke": 0},
            "apply_mode": "additive",
            "password": "must-not-pass",
        }

        state = _acl_recovery_state(
            "22222222-2222-4222-8222-222222222222", plan
        )

        self.assertEqual(state["change_count"], 1)
        self.assertEqual(state["add_count"], 1)
        self.assertNotIn("password", state)
        self.assertNotIn("must-not-pass", json.dumps(state))


if __name__ == "__main__":
    unittest.main()
