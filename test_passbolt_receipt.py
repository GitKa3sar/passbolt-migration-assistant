from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from passbolt_receipt import (
    ReceiptError,
    build_receipt,
    build_source_feedback,
    validate_receipt,
    write_receipt,
)


PLAN_DIGEST = "a" * 64
BATCH_ID = "11111111-1111-4111-8111-111111111111"


def preflight_evidence() -> dict[str, object]:
    return {
        "plan_digest": PLAN_DIGEST,
        "status": "passed",
        "destination_mode": "client_folders",
        "resource_format": "v4",
        "folder_format": "v4",
        "permission_mode": "inherited",
        "permission_entry_count": 0,
        "selected_count": 5,
        "create_count": 4,
        "duplicate_count": 1,
        "blocked_count": 0,
        "create_folder_count": 2,
        "create_shared_folder_count": 0,
        "reconcile_shared_folder_count": 0,
        "reuse_folder_count": 0,
        "shared_create_count": 0,
        "encrypted_secret_copy_count": 4,
        "required_client_count": 2,
        "mapped_client_count": 0,
        "checks": [
            {"id": "conflicts", "status": "passed"},
            {"id": "authenticated_identity", "status": "passed"},
        ],
    }


def migration_evidence() -> dict[str, object]:
    return {
        "plan_digest": PLAN_DIGEST,
        "destination_mode": "client_folders",
        "resource_format": "v4",
        "folder_format": "v4",
        "permission_mode": "inherited",
        "permission_entry_count": 0,
        "selected_count": 5,
        "planned_create_count": 4,
        "created_count": 4,
        "shared_created_count": 0,
        "encrypted_secret_copy_count": 4,
        "skipped_duplicate_count": 1,
        "created_folder_count": 2,
        "shared_created_folder_count": 0,
        "reconciled_shared_folder_count": 0,
        "reused_folder_count": 0,
        "verified_resource_count": 4,
        "verification_failed_count": 0,
        "journal_batch_id": BATCH_ID,
        "journal_status": "complete",
        "complete": True,
    }


class SourceFeedbackTests(unittest.TestCase):
    def test_summary_is_aggregated_without_source_identifiers(self) -> None:
        result = build_source_feedback(
            {
                "command": "source-summary",
                "inventory": {
                    "supported_files": 8,
                    "ignored_files": 3,
                    "issues": [
                        {
                            "reason_code": "unsupported_format",
                            "extension": ".bak",
                            "count": 2,
                        },
                        {
                            "reason_code": "unsupported_format",
                            "extension": "(senza estensione)",
                            "count": 1,
                        },
                        {
                            "reason_code": "legacy_xls_conversion",
                            "extension": ".xls",
                            "count": 1,
                        },
                    ],
                },
                "review": {
                    "selected_files": 4,
                    "analyzed_files": 4,
                    "candidate_count": 3,
                    "ready_count": 2,
                    "incomplete_count": 1,
                    "issues": [
                        {
                            "reason_code": "no_candidate",
                            "extension": ".txt",
                            "count": 1,
                        }
                    ],
                },
            }
        )
        serialized = json.dumps(result, ensure_ascii=False).lower()
        self.assertEqual(result["issue_occurrences"], 5)
        self.assertFalse(result["contains_source_identifiers"])
        self.assertNotIn("cliente-a", serialized)
        self.assertNotIn("documento.txt", serialized)
        self.assertNotIn("c:\\", serialized)

    def test_summary_rejects_unbounded_extension_text(self) -> None:
        with self.assertRaises(ReceiptError):
            build_source_feedback(
                {
                    "command": "source-summary",
                    "inventory": {
                        "supported_files": 0,
                        "ignored_files": 1,
                        "issues": [
                            {
                                "reason_code": "unsupported_format",
                                "extension": ".private-customer-filename",
                                "count": 1,
                            }
                        ],
                    },
                    "review": None,
                }
            )


class ReceiptTests(unittest.TestCase):
    def test_preflight_receipt_has_closed_sanitized_schema(self) -> None:
        receipt = build_receipt("preflight", preflight_evidence())
        validated = validate_receipt(receipt)
        self.assertEqual(validated["receipt_type"], "preflight")
        self.assertEqual(
            validated["compatibility_profile"],
            "passbolt-v4-v5-resource-preview",
        )
        self.assertEqual(validated["formats"], {"resource": "v4", "folder": "v4"})
        self.assertEqual(
            [item["id"] for item in validated["checks"]],
            ["authenticated_identity", "conflicts"],
        )

    def test_migration_receipt_requires_verified_closed_journal(self) -> None:
        receipt = build_receipt("migration", migration_evidence())
        self.assertEqual(receipt["status"], "verified")
        self.assertEqual(receipt["journal"], {"batch_id": BATCH_ID, "status": "complete"})
        self.assertNotIn("checks", receipt)

    def test_v5_resource_preflight_and_migration_receipts_are_supported(self) -> None:
        for receipt_type, evidence_factory in (
            ("preflight", preflight_evidence),
            ("migration", migration_evidence),
        ):
            evidence = evidence_factory()
            evidence["resource_format"] = "v5"

            receipt = validate_receipt(build_receipt(receipt_type, evidence))

            with self.subTest(receipt_type=receipt_type):
                self.assertEqual(
                    receipt["formats"], {"resource": "v5", "folder": "v4"}
                )
                self.assertEqual(
                    receipt["compatibility_profile"],
                    "passbolt-v4-v5-resource-preview",
                )

    def test_blocked_preflight_can_record_unavailable_capability(self) -> None:
        evidence = preflight_evidence()
        evidence["status"] = "blocked"
        evidence["resource_format"] = "unavailable"
        evidence["folder_format"] = "unavailable"
        evidence["checks"][0]["status"] = "blocked"

        receipt = build_receipt("preflight", evidence)

        self.assertEqual(receipt["status"], "blocked")
        self.assertEqual(receipt["formats"]["resource"], "unavailable")
        self.assertEqual(receipt["formats"]["folder"], "unavailable")

    def test_migration_receipt_rejects_uncertain_or_partial_result(self) -> None:
        for field, value in (
            ("complete", False),
            ("journal_status", "verification_required"),
            ("verification_failed_count", 1),
            ("verified_resource_count", 3),
            ("created_count", 3),
        ):
            evidence = migration_evidence()
            evidence[field] = value
            with self.subTest(field=field), self.assertRaises(ReceiptError):
                build_receipt("migration", evidence)

    def test_receipts_reject_out_of_scope_formats(self) -> None:
        invalid_formats = (
            ("preflight", preflight_evidence, "auto", "v4"),
            ("preflight", preflight_evidence, "v6", "v4"),
            ("preflight", preflight_evidence, None, "v4"),
            ("preflight", preflight_evidence, "v4", "auto"),
            ("preflight", preflight_evidence, "v5", "v5"),
            ("preflight", preflight_evidence, "v5", None),
            ("migration", migration_evidence, "unavailable", "v4"),
            ("migration", migration_evidence, "v5", "unavailable"),
        )
        for (
            receipt_type,
            evidence_factory,
            resource_format,
            folder_format,
        ) in invalid_formats:
            evidence = evidence_factory()
            evidence["resource_format"] = resource_format
            evidence["folder_format"] = folder_format
            with self.subTest(
                receipt_type=receipt_type,
                resource_format=resource_format,
                folder_format=folder_format,
            ), self.assertRaises(ReceiptError):
                build_receipt(receipt_type, evidence)

    def test_receipts_reject_recursive_sensitive_fields(self) -> None:
        evidence = preflight_evidence()
        evidence["checks"][0]["password"] = "must-not-serialize"
        with self.assertRaises(ReceiptError):
            build_receipt("preflight", evidence)

    def test_validator_rejects_out_of_scope_formats_with_valid_digest(self) -> None:
        from passbolt_receipt import _digest_document

        for field, value in (
            ("resource", "auto"),
            ("resource", "v6"),
            ("folder", "auto"),
            ("folder", "v5"),
        ):
            evidence = preflight_evidence()
            evidence["resource_format"] = "v5"
            receipt = build_receipt("preflight", evidence)
            receipt["formats"][field] = value
            receipt.pop("receipt_digest")
            receipt["receipt_digest"] = _digest_document(receipt)

            with self.subTest(field=field, value=value), self.assertRaises(
                ReceiptError
            ):
                validate_receipt(receipt)

    def test_tampering_invalidates_receipt_digest(self) -> None:
        receipt = build_receipt("preflight", preflight_evidence())
        receipt["counts"]["create_count"] = 3
        with self.assertRaises(ReceiptError):
            validate_receipt(receipt)

    def test_closed_receipt_rejects_invalid_content_even_with_new_digest(self) -> None:
        receipt = build_receipt("preflight", preflight_evidence())
        receipt["counts"]["password_count"] = 1
        receipt.pop("receipt_digest")
        from passbolt_receipt import _digest_document

        receipt["receipt_digest"] = _digest_document(receipt)
        with self.assertRaises(ReceiptError):
            validate_receipt(receipt)

        for receipt_type, field, value in (
            ("preflight", "create_count", 3),
            ("migration", "verified_resource_count", 3),
            ("migration", "verification_failed_count", 1),
        ):
            evidence = (
                preflight_evidence()
                if receipt_type == "preflight"
                else migration_evidence()
            )
            receipt = build_receipt(receipt_type, evidence)
            receipt["counts"][field] = value
            receipt.pop("receipt_digest")
            receipt["receipt_digest"] = _digest_document(receipt)
            with self.subTest(receipt_type=receipt_type, field=field), self.assertRaises(
                ReceiptError
            ):
                validate_receipt(receipt)

    def test_atomic_export_does_not_echo_destination_or_sensitive_values(self) -> None:
        receipt = build_receipt("migration", migration_evidence())
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "ricevuta.json"
            result = write_receipt(receipt, destination)
            written = json.loads(destination.read_text(encoding="utf-8"))
        serialized = json.dumps({"result": result, "receipt": written}).lower()
        self.assertTrue(result["written"])
        self.assertNotIn("destination", result)
        for forbidden in (
            "password",
            "passphrase",
            "fingerprint",
            "session_id",
            "username",
            "candidate_id",
            "resource_id",
            "folder_id",
        ):
            self.assertNotIn(forbidden, serialized)


if __name__ == "__main__":
    unittest.main()
