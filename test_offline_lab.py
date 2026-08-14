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

from offline_lab_setup import (
    LAB_MARKER,
    OfflineLabSetupError,
    create_offline_lab_workspace,
)
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


if __name__ == "__main__":
    unittest.main()
