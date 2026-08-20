from __future__ import annotations

import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from dataclasses import asdict
from pathlib import Path
from unittest import mock

from passbolt_import import (
    ImportPreparationError,
    _acl_reconciliation_archive_result,
    _acl_reconciliation_describe_result,
    _acl_reconciliation_list_result,
    _bridge_line_exchange,
    _prepare_recovery_context,
    _reconciliation_archive_result,
    _reconciliation_describe_result,
    _reconciliation_list_result,
    _selected_candidates,
    _session_bridge_request,
    execute_import,
    extract_resources,
    verify_integrity,
)
from passbolt_review import analyze_files
from passbolt_reconciliation import (
    CandidateProof,
    ReconciliationJournal,
    ReconciliationJournalError,
    hash_permission_configuration,
    hash_user_identifier,
    read_journal,
)
from passbolt_acl_reconciliation import AclReconciliationJournal


def write_encrypted_xlsx(path: Path, document_password: str, credential_password: str) -> None:
    from msoffcrypto.format.ooxml import OOXMLFile
    from openpyxl import Workbook

    plaintext = io.BytesIO()
    workbook = Workbook()
    sheet = workbook.active
    sheet.append(["Titolo", "Username", "Password", "Host"])
    sheet.append(["VPN protetta", "vpn-user", credential_password, "vpn.example.test"])
    workbook.save(plaintext)
    workbook.close()
    plaintext.seek(0)
    try:
        with path.open("wb") as encrypted_output:
            OOXMLFile(plaintext).encrypt(document_password, encrypted_output)
    finally:
        plaintext.close()


class ImportPreparationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        (self.root / "Cliente Alfa").mkdir()
        self.source = self.root / "Cliente Alfa" / "portale.txt"
        self.secret = "Segreto-importazione-123"
        self.source.write_text(
            "Titolo: Portale clienti\n"
            "URL: https://example.test\n"
            "Utente: mario.rossi\n"
            f"Password: {self.secret}\n",
            encoding="utf-8",
        )
        review = analyze_files(self.root, ["Cliente Alfa/portale.txt"])
        self.candidate = asdict(review.candidates[0])
        self.request = {
            key: self.candidate[key]
            for key in (
                "candidate_id",
                "source_relative_path",
                "source_sha256",
                "client",
                "title",
                "username",
                "uri",
            )
        }
        self.request["source_at_root"] = False

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_integrity_result_never_serializes_secret(self) -> None:
        result = verify_integrity(self.root, [self.request])

        self.assertTrue(result["verified"])
        self.assertEqual(result["verified_candidate_count"], 1)
        self.assertFalse(result["secrets_serialized"])
        self.assertNotIn(self.secret, json.dumps(result))

    def test_integrity_stops_parsing_after_all_selected_candidates_are_found(self) -> None:
        from passbolt_review import _records_for_file as real_records_for_file

        self.source.write_text(
            "Titolo: Primo accesso\n"
            "Utente: primo-utente\n"
            "Password: primo-segreto\n\n"
            "Titolo: Secondo accesso\n"
            "Utente: secondo-utente\n"
            "Password: secondo-segreto\n",
            encoding="utf-8",
        )
        review = analyze_files(self.root, ["Cliente Alfa/portale.txt"])
        first = asdict(review.candidates[0])
        request = {
            key: first[key]
            for key in (
                "candidate_id",
                "source_relative_path",
                "source_sha256",
                "client",
                "title",
                "username",
                "uri",
            )
        }
        request["source_at_root"] = False

        def guarded_records(
            path: Path,
            extension: str,
            *,
            file_password: str | None = None,
            source_mapping_profile: object | None = None,
        ):
            iterator = iter(
                real_records_for_file(
                    path,
                    extension,
                    file_password=file_password,
                    source_mapping_profile=source_mapping_profile,
                )
            )
            yield next(iterator)
            raise AssertionError("Il parser ha proseguito oltre i candidati richiesti")

        with mock.patch("passbolt_import._records_for_file", side_effect=guarded_records):
            result = verify_integrity(self.root, [request])

        self.assertEqual(result["verified_candidate_count"], 1)
        self.assertEqual(result["candidate_ids"], [request["candidate_id"]])

    def test_candidate_selection_exceeds_previous_batch_cap(self) -> None:
        requests = []
        for index in range(64):
            candidate = dict(self.request)
            candidate["candidate_id"] = f"{index:016x}"
            requests.append(candidate)

        selected = _selected_candidates(requests)

        self.assertEqual(len(selected), 64)
        self.assertEqual(selected[-1].candidate_id, "000000000000003f")

    def test_integrity_revalidates_a_large_single_file_batch(self) -> None:
        source = self.root / "Cliente Alfa" / "lotto-indicizzato.csv"
        rows = ["nome,username,password,url"]
        rows.extend(
            f"Accesso {index},utente-{index},segreto-{index},https://host-{index}.test"
            for index in range(512)
        )
        source.write_text("\n".join(rows) + "\n", encoding="utf-8")
        review = analyze_files(self.root, ["Cliente Alfa/lotto-indicizzato.csv"])
        requests = []
        for reviewed in review.candidates:
            candidate = asdict(reviewed)
            request = {
                key: candidate[key]
                for key in (
                    "candidate_id",
                    "source_relative_path",
                    "source_sha256",
                    "client",
                    "title",
                    "username",
                    "uri",
                )
            }
            request["source_at_root"] = False
            requests.append(request)

        result = verify_integrity(self.root, requests)

        self.assertEqual(result["verified_candidate_count"], 512)
        self.assertEqual(result["verified_source_count"], 1)
        self.assertEqual(len(result["candidate_ids"]), 512)

    def test_invalid_progress_terminates_bridge_before_a_final_response(self) -> None:
        progress = {
            "type": "progress",
            "batch_id": "0cd2d92f-17f2-4d64-aeaa-a27fc8ec42fc",
            "event_type": "operation_failed",
            "payload": {"password": "must-never-be-persisted"},
        }

        class FakeProcess:
            def __init__(self) -> None:
                self.stdin = io.BytesIO()
                self.stdout = io.BytesIO(
                    (json.dumps(progress, separators=(",", ":")) + "\n").encode(
                        "utf-8"
                    )
                )
                self.killed = False

            def poll(self) -> int | None:
                return 1 if self.killed else None

            def kill(self) -> None:
                self.killed = True

        process = FakeProcess()

        def reject_progress(_: object) -> None:
            raise ReconciliationJournalError("Evento rifiutato.")

        with self.assertRaisesRegex(ImportPreparationError, "registro locale"):
            _bridge_line_exchange(  # type: ignore[arg-type]
                process,
                {"command": "session-import"},
                progress_handler=reject_progress,  # type: ignore[arg-type]
            )
        self.assertTrue(process.killed)

    def test_secret_is_reextracted_only_for_immediate_handoff(self) -> None:
        resources, source_count = extract_resources(
            self.root, [self.request], include_secrets=True
        )

        self.assertEqual(source_count, 1)
        self.assertEqual(resources[0]["password"], self.secret)
        self.assertEqual(resources[0]["candidate_id"], self.request["candidate_id"])

    def test_custom_source_mapping_is_revalidated_for_secret_handoff(self) -> None:
        source = self.root / "Cliente Alfa" / "vendor-export.csv"
        secret = "segreto-mappato-solo-in-memoria"
        source.write_text(
            "display_label,account_name,credential_value,target_endpoint\n"
            f"Portale vendor,utente-vendor,{secret},https://vendor.test\n",
            encoding="utf-8",
        )
        profile = {
            "schema_version": 1,
            "name": "Export vendor",
            "fields": {
                "title": ["display_label"],
                "username": ["account_name"],
                "secret": ["credential_value"],
                "uri": ["target_endpoint"],
            },
        }
        reviewed = asdict(
            analyze_files(
                self.root,
                ["Cliente Alfa/vendor-export.csv"],
                source_mapping_profile=profile,
            ).candidates[0]
        )
        request = {
            key: reviewed[key]
            for key in (
                "candidate_id",
                "source_relative_path",
                "source_sha256",
                "client",
                "title",
                "username",
                "uri",
                "source_mapping_digest",
                "source_mapping_profile",
            )
        }
        request["source_at_root"] = False

        integrity = verify_integrity(self.root, [request])
        resources, source_count = extract_resources(
            self.root, [request], include_secrets=True
        )

        self.assertTrue(integrity["verified"])
        self.assertEqual(source_count, 1)
        self.assertEqual(resources[0]["password"], secret)
        self.assertNotIn(secret, json.dumps(reviewed))

    def test_custom_source_mapping_digest_tampering_is_rejected(self) -> None:
        source = self.root / "Cliente Alfa" / "mapped.env"
        source.write_text(
            "ACCOUNT_NAME=utente\nCREDENTIAL_VALUE=segreto\n",
            encoding="utf-8",
        )
        profile = {
            "schema_version": 1,
            "name": "Export env",
            "fields": {
                "title": [],
                "username": ["account_name"],
                "secret": ["credential_value"],
                "uri": [],
            },
        }
        reviewed = asdict(
            analyze_files(
                self.root,
                ["Cliente Alfa/mapped.env"],
                source_mapping_profile=profile,
            ).candidates[0]
        )
        reviewed["source_at_root"] = False
        reviewed["source_mapping_profile"]["name"] = "Profilo alterato"

        with self.assertRaisesRegex(ImportPreparationError, "profilo"):
            _selected_candidates([reviewed])

    def test_edited_metadata_is_imported_while_original_review_stays_verified(self) -> None:
        edited = dict(self.request)
        edited.update(
            {
                "reviewed_client": self.request["client"],
                "reviewed_source_at_root": self.request["source_at_root"],
                "reviewed_title": self.request["title"],
                "reviewed_username": self.request["username"],
                "reviewed_uri": self.request["uri"],
                "client": "Cliente Corretto",
                "title": "Titolo corretto",
                "username": "utente-corretto",
                "uri": "10.20.30.40",
                "password_overridden": False,
            }
        )

        resources, _ = extract_resources(self.root, [edited], include_secrets=True)

        self.assertEqual(resources[0]["title"], "Titolo corretto")
        self.assertEqual(resources[0]["username"], "utente-corretto")
        self.assertEqual(resources[0]["uri"], "10.20.30.40")
        self.assertEqual(resources[0]["password"], self.secret)

    def test_password_override_is_used_only_when_explicitly_supplied(self) -> None:
        edited = dict(self.request)
        edited["password_overridden"] = True
        replacement = "Password-corretta-in-memoria"

        resources, _ = extract_resources(
            self.root,
            [edited],
            include_secrets=True,
            secret_overrides={edited["candidate_id"]: replacement},
        )

        self.assertEqual(resources[0]["password"], replacement)
        with self.assertRaisesRegex(ImportPreparationError, "password modificate"):
            extract_resources(self.root, [edited], include_secrets=True)

    def test_missing_source_password_can_be_completed_in_review(self) -> None:
        incomplete_source = self.root / "Cliente Alfa" / "router.txt"
        incomplete_source.write_text(
            "Titolo: Router\nUsername: admin\nIndirizzo IP: 192.168.1.1\nPassword:\n",
            encoding="utf-8",
        )
        review = analyze_files(self.root, ["Cliente Alfa/router.txt"])
        candidate = asdict(review.candidates[0])
        request = {
            key: candidate[key]
            for key in (
                "candidate_id",
                "source_relative_path",
                "source_sha256",
                "client",
                "title",
                "username",
                "uri",
            )
        }
        request["source_at_root"] = False
        request["password_overridden"] = True

        resources, _ = extract_resources(
            self.root,
            [request],
            include_secrets=True,
            secret_overrides={request["candidate_id"]: "password-aggiunta"},
        )

        self.assertEqual(resources[0]["password"], "password-aggiunta")
        self.assertEqual(resources[0]["uri"], "192.168.1.1")

    def test_persistent_session_readiness_verifies_without_secrets(self) -> None:
        bridge_request, resources = _session_bridge_request(
            self.root,
            {
                "command": "session-readiness",
                "session_id": "session-id",
                "resource_format": "v5",
                "destination_mode": "client_mapping",
                "folder_format": "auto",
                "client_destination_mapping": [
                    {"client": "Cliente Alfa", "folder_id": "folder-alpha-id"}
                ],
                "permission_mode": "custom",
                "permission_template": [
                    {"aro": "Group", "aro_foreign_key": "group-id", "type": 7}
                ],
                "candidates": [self.request],
            },
        )

        self.assertEqual(bridge_request["command"], "session-readiness")
        self.assertEqual(bridge_request["session_id"], "session-id")
        self.assertEqual(bridge_request["permission_mode"], "custom")
        self.assertEqual(bridge_request["permission_template"][0]["type"], 7)
        self.assertEqual(resources, [])
        self.assertNotIn(self.secret, json.dumps(bridge_request))

    def test_persistent_permission_catalog_command_requires_no_sources_or_secrets(self) -> None:
        bridge_request, resources = _session_bridge_request(
            self.root,
            {"command": "session-permissions", "session_id": "session-id"},
        )
        self.assertEqual(
            bridge_request,
            {"command": "session-permissions", "session_id": "session-id"},
        )
        self.assertEqual(resources, [])

    def test_persistent_acl_catalog_is_source_free_and_read_only(self) -> None:
        bridge_request, resources = _session_bridge_request(
            self.root,
            {
                "command": "session-acl-catalog",
                "session_id": "session-id",
                "candidates": [self.request],
                "passphrase": "must-not-pass",
                "mfa_totp": "123456",
            },
        )
        self.assertEqual(
            bridge_request,
            {"command": "session-acl-catalog", "session_id": "session-id"},
        )
        self.assertEqual(resources, [])
        serialized = json.dumps(bridge_request)
        self.assertNotIn(self.secret, serialized)
        self.assertNotIn("must-not-pass", serialized)
        self.assertNotIn("123456", serialized)

    def test_persistent_acl_plan_only_forwards_closed_read_only_payload(self) -> None:
        bridge_request, resources = _session_bridge_request(
            self.root,
            {
                "command": "session-acl-plan",
                "session_id": "session-id",
                "object_type": "resource",
                "object_id": "resource-id",
                "desired_permissions": [
                    {
                        "aro": "User",
                        "aro_foreign_key": "recipient-id",
                        "type": 7,
                        "password": "must-not-pass",
                        "armored_key": "-----BEGIN PGP PRIVATE KEY BLOCK-----",
                    }
                ],
                "candidates": [self.request],
                "passphrase": "key-passphrase",
                "mfa_totp": "123456",
                "confirmation": "APPLICA",
            },
        )
        self.assertEqual(
            bridge_request,
            {
                "command": "session-acl-plan",
                "session_id": "session-id",
                "object_type": "resource",
                "object_id": "resource-id",
                "desired_permissions": [
                    {
                        "aro": "User",
                        "aro_foreign_key": "recipient-id",
                        "type": 7,
                    }
                ],
            },
        )
        self.assertEqual(resources, [])
        serialized = json.dumps(bridge_request)
        self.assertNotIn(self.secret, serialized)
        self.assertNotIn("must-not-pass", serialized)
        self.assertNotIn("PRIVATE KEY", serialized)
        self.assertNotIn("key-passphrase", serialized)
        self.assertNotIn("123456", serialized)
        self.assertNotIn("APPLICA", serialized)

    def test_persistent_acl_apply_only_forwards_digest_bound_payload(self) -> None:
        bridge_request, resources = _session_bridge_request(
            self.root,
            {
                "command": "session-acl-apply",
                "session_id": "session-id",
                "plan_id": "plan-id",
                "object_state_digest": "1" * 64,
                "desired_acl_digest": "2" * 64,
                "directory_state_digest": "4" * 64,
                "plan_digest": "3" * 64,
                "confirmation": "APPLICA ACL 1 33333333",
                "desired_permissions": [{"password": "must-not-pass"}],
                "private_key": "must-not-pass",
                "mfa_totp": "123456",
            },
        )
        self.assertEqual(
            bridge_request,
            {
                "command": "session-acl-apply",
                "session_id": "session-id",
                "plan_id": "plan-id",
                "object_state_digest": "1" * 64,
                "desired_acl_digest": "2" * 64,
                "directory_state_digest": "4" * 64,
                "plan_digest": "3" * 64,
                "confirmation": "APPLICA ACL 1 33333333",
            },
        )
        self.assertEqual(resources, [])
        self.assertNotIn("must-not-pass", json.dumps(bridge_request))

    def test_acl_recovery_bridge_rebuilds_context_from_local_journal(self) -> None:
        journal_root = self.root / "acl-journals"
        journal = AclReconciliationJournal.create(
            app_version="0.16.0",
            server_origin="https://passbolt.example.test",
            server_fingerprint="A" * 40,
            user_id_hash=hash_user_identifier("user-id"),
            object_type="folder",
            object_id="folder-id",
            object_state_digest="1" * 64,
            desired_acl_digest="2" * 64,
            plan_digest="3" * 64,
            desired_permissions=[
                {"aro": "Group", "aro_foreign_key": "group-id", "type": 7}
            ],
            change_count=1,
            add_count=0,
            upgrade_count=1,
            root=journal_root,
        )
        bridge_request, resources = _session_bridge_request(
            self.root,
            {
                "command": "session-acl-recovery-readiness",
                "session_id": "session-id",
                "acl_batch_id": journal.batch_id,
                "desired_permissions": [{"password": "must-not-pass"}],
            },
            None,
            journal_root,
        )
        self.assertEqual(bridge_request["acl_batch_id"], journal.batch_id)
        self.assertEqual(
            bridge_request["acl_recovery_state"]["desired_permissions"],
            [{"aro": "Group", "aro_foreign_key": "group-id", "type": 7}],
        )
        self.assertEqual(resources, [])
        self.assertNotIn("must-not-pass", json.dumps(bridge_request))

    def test_persistent_session_import_hands_off_secrets_without_auth_data(self) -> None:
        bridge_request, resources = _session_bridge_request(
            self.root,
            {
                "command": "session-import",
                "session_id": "session-id",
                "resource_format": "v4",
                "destination_mode": "root",
                "folder_format": "auto",
                "permission_mode": "custom",
                "permission_template": [
                    {"aro": "User", "aro_foreign_key": "recipient-id", "type": 1}
                ],
                "candidates": [self.request],
                "create_candidate_ids": [self.request["candidate_id"]],
                "plan_digest": "digest",
                "confirmation": "IMPORTA 1",
            },
        )

        self.assertEqual(bridge_request["command"], "session-import")
        self.assertEqual(resources[0]["password"], self.secret)
        self.assertEqual(bridge_request["resources"][0]["password"], self.secret)
        self.assertEqual(bridge_request["permission_mode"], "custom")
        self.assertEqual(bridge_request["permission_template"][0]["aro"], "User")
        self.assertNotIn("passphrase", bridge_request)
        self.assertNotIn("mfa_totp", bridge_request)

    def test_persistent_import_hands_off_edited_password(self) -> None:
        edited = dict(self.request)
        edited["password_overridden"] = True
        replacement = "Password-corretta-in-memoria"
        bridge_request, resources = _session_bridge_request(
            self.root,
            {
                "command": "session-import",
                "session_id": "session-id",
                "resource_format": "v5",
                "destination_mode": "root",
                "folder_format": "auto",
                "candidates": [edited],
                "create_candidate_ids": [edited["candidate_id"]],
                "secret_overrides": [
                    {"candidate_id": edited["candidate_id"], "password": replacement}
                ],
                "plan_digest": "digest",
                "confirmation": "IMPORTA 1",
            },
        )

        self.assertEqual(resources[0]["password"], replacement)
        self.assertEqual(bridge_request["resources"][0]["password"], replacement)

    def test_protected_xlsx_password_is_reused_but_never_forwarded_to_bridge(self) -> None:
        encrypted_path = self.root / "Cliente Alfa" / "protetto.xlsx"
        relative_path = "Cliente Alfa/protetto.xlsx"
        document_password = "Password-file-Excel-import"
        credential_password = "Password-risorsa-Passbolt"
        write_encrypted_xlsx(encrypted_path, document_password, credential_password)
        review = analyze_files(
            self.root,
            [relative_path],
            file_passwords={relative_path: document_password},
        )
        candidate = asdict(review.candidates[0])
        request = {
            key: candidate[key]
            for key in (
                "candidate_id",
                "source_relative_path",
                "source_sha256",
                "client",
                "title",
                "username",
                "uri",
                "source_password_required",
            )
        }
        request["source_at_root"] = False
        password_entries = [
            {"relative_path": relative_path, "password": document_password}
        ]

        with self.assertRaisesRegex(ImportPreparationError, "password dei file Excel"):
            verify_integrity(self.root, [request])
        verified = verify_integrity(
            self.root,
            [request],
            source_file_passwords={relative_path: document_password},
        )
        self.assertTrue(verified["verified"])

        readiness_request, readiness_resources = _session_bridge_request(
            self.root,
            {
                "command": "session-readiness",
                "session_id": "session-id",
                "candidates": [request],
                "source_file_passwords": password_entries,
            },
        )
        self.assertEqual(readiness_resources, [])
        self.assertNotIn("source_file_passwords", readiness_request)
        self.assertNotIn(document_password, json.dumps(readiness_request))

        import_request, import_resources = _session_bridge_request(
            self.root,
            {
                "command": "session-import",
                "session_id": "session-id",
                "candidates": [request],
                "create_candidate_ids": [request["candidate_id"]],
                "source_file_passwords": password_entries,
                "plan_digest": "digest",
                "confirmation": "IMPORTA 1",
            },
        )
        self.assertEqual(import_resources[0]["password"], credential_password)
        self.assertNotIn("source_file_passwords", import_request)
        self.assertNotIn(document_password, json.dumps(import_request))

    def test_persistent_coordinator_reuses_one_authenticated_bridge(self) -> None:
        fake_bridge = self.root / "fake_session_bridge.py"
        fake_bridge.write_text(
            """import json
import sys

session_id = "test-session-id"
plan_digest = "d" * 64
operation_id = "9db7dd10-9f94-458a-af2f-102936db06a7"
resource_id = "35c7ddd2-a27b-4481-8f4c-5fd6033603f7"
for raw in sys.stdin:
    request = json.loads(raw)
    command = request.get("command")
    if command == "session-open":
        assert request.get("passphrase") == "key-passphrase"
        assert request.get("mfa_totp") == "654321"
        result = {
            "session_id": session_id,
            "authentication": "GPGAuth + TOTP",
            "base_url": "https://pass.example.test",
            "server_fingerprint": "A" * 40,
            "user": {"id": "f5bb3e91-2a72-4e38-8603-b983e868be22"},
        }
    elif command == "session-readiness":
        assert request.get("session_id") == session_id
        assert "passphrase" not in request and "mfa_totp" not in request
        assert "resources" not in request
        result = {
            "session_id": session_id,
            "command": "readiness",
            "can_import": True,
            "plan_digest": plan_digest,
            "resource_format_selected": "v5",
            "folder_format_selected": None,
            "destination_mode": "root",
            "destination_folder_id": None,
        }
    elif command == "session-import":
        assert request.get("session_id") == session_id
        assert "passphrase" not in request and "mfa_totp" not in request
        assert request["resources"][0]["password"] == "Segreto-importazione-123"
        batch_id = request["reconciliation_batch_id"]
        candidate_id = request["candidates"][0]["candidate_id"]
        progress = [
            {
                "type": "progress",
                "batch_id": batch_id,
                "event_type": "operation_intent",
                "payload": {
                    "operation_id": operation_id,
                    "object_type": "resource",
                    "action": "create_resource",
                    "candidate_id": candidate_id,
                },
            },
            {
                "type": "progress",
                "batch_id": batch_id,
                "event_type": "resource_created",
                "payload": {
                    "operation_id": operation_id,
                    "resource_id": resource_id,
                    "candidate_id": candidate_id,
                    "status": "created",
                },
            },
            {
                "type": "progress",
                "batch_id": batch_id,
                "event_type": "resource_verified",
                "payload": {
                    "resource_id": resource_id,
                    "candidate_id": candidate_id,
                    "metadata_match": True,
                    "content_match": True,
                    "destination_match": True,
                    "acl_match": True,
                },
            },
            {
                "type": "progress",
                "batch_id": batch_id,
                "event_type": "batch_completed",
                "payload": {
                    "created_folder_count": 0,
                    "reconciled_folder_count": 0,
                    "created_resource_count": 1,
                    "shared_resource_count": 0,
                    "skipped_duplicate_count": 0,
                    "verified_resource_count": 1,
                },
            },
        ]
        for envelope in progress:
            print(json.dumps(envelope), flush=True)
        result = {
            "session_id": session_id,
            "command": "import",
            "created_count": 1,
            "verification_status": "verified",
            "verified_resource_count": 1,
            "verification_results": [{
                "candidate_id": candidate_id,
                "resource_id": resource_id,
                "status": "verified",
                "metadata_match": True,
                "content_match": True,
                "destination_match": True,
                "acl_match": True,
            }],
        }
    elif command == "session-close":
        result = {"session_id": session_id, "command": "session-close", "closed": True}
    else:
        raise AssertionError(command)
    print(json.dumps({"ok": True, "result": result}), flush=True)
    if command == "session-close":
        break
""",
            encoding="utf-8",
        )
        requests = [
            {
                "command": "session-open",
                "base_url": "https://pass.example.test",
                "expected_server_fingerprint": "A" * 40,
                "private_key_path": "C:/private.asc",
                "passphrase": "key-passphrase",
                "mfa_totp": "654321",
            },
            {
                "command": "session-readiness",
                "session_id": "test-session-id",
                "resource_format": "v5",
                "destination_mode": "root",
                "folder_format": "auto",
                "candidates": [self.request],
            },
            {
                "command": "session-import",
                "session_id": "test-session-id",
                "resource_format": "v5",
                "destination_mode": "root",
                "folder_format": "auto",
                "candidates": [self.request],
                "create_candidate_ids": [self.request["candidate_id"]],
                "plan_digest": "d" * 64,
                "confirmation": "IMPORTA 1",
            },
            {"command": "session-close", "session_id": "test-session-id"},
        ]
        session_input = b"\xef\xbb\xbf" + "".join(
            json.dumps(request, separators=(",", ":")) + "\n" for request in requests
        ).encode("utf-8")
        completed = subprocess.run(
            [
                sys.executable,
                str(Path(__file__).with_name("passbolt_import.py")),
                "--session",
                "--root",
                str(self.root),
                "--node",
                sys.executable,
                "--crypto-script",
                str(fake_bridge),
            ],
            input=session_input,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
            check=False,
            env={**os.environ, "LOCALAPPDATA": str(self.root / "localappdata")},
        )

        self.assertEqual(completed.returncode, 0, completed.stderr.decode("utf-8"))
        responses = [json.loads(line) for line in completed.stdout.splitlines()]
        progress_responses = [
            response for response in responses if response.get("type") == "progress"
        ]
        final_responses = [response for response in responses if "ok" in response]
        self.assertEqual(len(progress_responses), 4)
        self.assertEqual(len(final_responses), 4)
        self.assertTrue(all(response["ok"] for response in final_responses))
        self.assertEqual(final_responses[0]["result"]["session_id"], "test-session-id")
        self.assertEqual(final_responses[2]["result"]["created_count"], 1)
        self.assertEqual(
            final_responses[2]["result"]["reconciliation_status"], "complete"
        )
        batch_id = final_responses[2]["result"]["reconciliation_batch_id"]
        journal_files = list(
            (self.root / "localappdata" / "Passbolt Migration Assistant" / "Reconciliation").glob(
                "batch-*.jsonl"
            )
        )
        self.assertEqual(len(journal_files), 1)
        snapshot = read_journal(journal_files[0])
        self.assertEqual(snapshot.batch_id, batch_id)
        self.assertTrue(snapshot.complete)
        self.assertEqual(
            [event["event_type"] for event in snapshot.events],
            [
                "batch_started",
                "operation_intent",
                "resource_created",
                "resource_verified",
                "batch_completed",
            ],
        )
        serialized_journal = journal_files[0].read_text(encoding="utf-8")
        self.assertNotIn(self.secret, serialized_journal)
        self.assertNotIn("key-passphrase", serialized_journal)
        self.assertNotIn("654321", serialized_journal)
        serialized_responses = completed.stdout.decode("utf-8")
        self.assertNotIn(self.secret, serialized_responses)
        self.assertNotIn("key-passphrase", serialized_responses)
        self.assertNotIn("654321", serialized_responses)

    def test_interrupted_import_keeps_incomplete_journal_for_verification(self) -> None:
        fake_bridge = self.root / "interrupted_session_bridge.py"
        fake_bridge.write_text(
            """import json
import sys

session_id = "interrupted-session-id"
for raw in sys.stdin:
    request = json.loads(raw)
    command = request.get("command")
    if command == "session-open":
        result = {
            "session_id": session_id,
            "base_url": "https://pass.example.test",
            "server_fingerprint": "B" * 40,
            "user": {"id": "59a882e6-4909-4db0-ab84-91093461c777"},
        }
        print(json.dumps({"ok": True, "result": result}), flush=True)
    elif command == "session-readiness":
        result = {
            "session_id": session_id,
            "plan_digest": "e" * 64,
            "resource_format_selected": "v5",
            "folder_format_selected": None,
            "destination_mode": "root",
            "destination_folder_id": None,
        }
        print(json.dumps({"ok": True, "result": result}), flush=True)
    elif command == "session-import":
        event = {
            "type": "progress",
            "batch_id": request["reconciliation_batch_id"],
            "event_type": "operation_intent",
            "payload": {
                "operation_id": "2f42a04b-bf31-4095-a492-573fb3e091ba",
                "object_type": "resource",
                "action": "create_resource",
                "candidate_id": request["candidates"][0]["candidate_id"],
            },
        }
        print(json.dumps(event), flush=True)
        raise SystemExit(0)
""",
            encoding="utf-8",
        )
        requests = [
            {
                "command": "session-open",
                "base_url": "https://pass.example.test",
                "expected_server_fingerprint": "B" * 40,
                "private_key_path": "C:/private.asc",
                "passphrase": "key-passphrase",
                "mfa_totp": "654321",
            },
            {
                "command": "session-readiness",
                "session_id": "interrupted-session-id",
                "resource_format": "v5",
                "destination_mode": "root",
                "folder_format": "v5",
                "candidates": [self.request],
            },
            {
                "command": "session-import",
                "session_id": "interrupted-session-id",
                "resource_format": "v5",
                "destination_mode": "root",
                "folder_format": "v5",
                "candidates": [self.request],
                "create_candidate_ids": [self.request["candidate_id"]],
                "plan_digest": "e" * 64,
                "confirmation": "IMPORTA 1",
            },
        ]
        completed = subprocess.run(
            [
                sys.executable,
                str(Path(__file__).with_name("passbolt_import.py")),
                "--session",
                "--root",
                str(self.root),
                "--node",
                sys.executable,
                "--crypto-script",
                str(fake_bridge),
            ],
            input="".join(
                json.dumps(request, separators=(",", ":")) + "\n"
                for request in requests
            ).encode("utf-8"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
            check=False,
            env={
                **os.environ,
                "LOCALAPPDATA": str(self.root / "interrupted-localappdata"),
            },
        )

        self.assertEqual(completed.returncode, 0, completed.stderr.decode("utf-8"))
        responses = [json.loads(line) for line in completed.stdout.splitlines()]
        progress_responses = [
            response for response in responses if response.get("type") == "progress"
        ]
        final_responses = [response for response in responses if "ok" in response]
        self.assertEqual(len(progress_responses), 1)
        self.assertEqual(progress_responses[0]["event_type"], "operation_intent")
        self.assertEqual(len(final_responses), 3)
        self.assertTrue(final_responses[0]["ok"])
        self.assertTrue(final_responses[1]["ok"])
        self.assertFalse(final_responses[2]["ok"])
        details = final_responses[2]["error"]["details"]
        self.assertEqual(details["reconciliation_status"], "verification_required")
        journal_files = list(
            (
                self.root
                / "interrupted-localappdata"
                / "Passbolt Migration Assistant"
                / "Reconciliation"
            ).glob("batch-*.jsonl")
        )
        self.assertEqual(len(journal_files), 1)
        snapshot = read_journal(journal_files[0])
        self.assertEqual(snapshot.batch_id, details["reconciliation_batch_id"])
        self.assertFalse(snapshot.complete)
        self.assertTrue(snapshot.requires_verification)
        self.assertEqual(snapshot.events[-1]["event_type"], "operation_intent")
        self.assertNotIn(self.secret, journal_files[0].read_text(encoding="utf-8"))

    def test_authenticated_recovery_reuses_same_journal_and_reextracts_secret(self) -> None:
        local_app_data = self.root / "recovery-localappdata"
        journal_root = (
            local_app_data
            / "Passbolt Migration Assistant"
            / "Reconciliation"
        )
        user_id = "59a882e6-4909-4db0-ab84-91093461c777"
        first_operation_id = "2f42a04b-bf31-4095-a492-573fb3e091ba"
        journal = ReconciliationJournal.create(
            app_version="0.12.5",
            server_origin="https://pass.example.test",
            server_fingerprint="C" * 40,
            user_id_hash=hash_user_identifier(user_id),
            plan_digest="d" * 64,
            resource_format="v4",
            folder_format="none",
            destination_mode="root",
            destination_folder_id=None,
            candidates=(
                CandidateProof(
                    self.request["candidate_id"],
                    self.request["source_sha256"],
                ),
            ),
            root=journal_root,
        )
        journal.append(
            "operation_intent",
            operation_id=first_operation_id,
            object_type="resource",
            action="create_resource",
            candidate_id=self.request["candidate_id"],
            destination_key_hash="1" * 64,
        )

        recovery_id = "6ed40c1f-361c-4d09-8064-eb3938e7262c"
        recovery_digest = "e" * 64
        fake_bridge = self.root / "recovery_session_bridge.py"
        fake_bridge.write_text(
            """import json
import sys

session_id = "recovery-session-id"
for raw in sys.stdin:
    request = json.loads(raw)
    command = request.get("command")
    if command == "session-open":
        result = {
            "session_id": session_id,
            "base_url": "https://pass.example.test",
            "server_fingerprint": "C" * 40,
            "user": {"id": "59a882e6-4909-4db0-ab84-91093461c777"},
        }
    elif command == "session-recovery-readiness":
        batch_id = request["reconciliation_batch_id"]
        candidate_id = request["candidates"][0]["candidate_id"]
        recovery_id = "6ed40c1f-361c-4d09-8064-eb3938e7262c"
        progress = [
            {
                "type": "progress",
                "batch_id": batch_id,
                "event_type": "operation_verified",
                "payload": {
                    "recovery_id": recovery_id,
                    "operation_id": "2f42a04b-bf31-4095-a492-573fb3e091ba",
                    "object_type": "resource",
                    "candidate_id": candidate_id,
                    "destination_key_hash": "1" * 64,
                    "resolution": "not_applied",
                },
            },
            {
                "type": "progress",
                "batch_id": batch_id,
                "event_type": "recovery_verified",
                "payload": {
                    "recovery_id": recovery_id,
                    "verification_digest": "f" * 64,
                    "verified_operation_count": 1,
                    "remote_success_count": 0,
                    "retry_count": 1,
                },
            },
        ]
        for envelope in progress:
            print(json.dumps(envelope), flush=True)
        result = {
            "command": "recovery-readiness",
            "session_id": session_id,
            "reconciliation_batch_id": batch_id,
            "recovery_id": recovery_id,
            "recovery_plan_digest": "e" * 64,
            "resource_candidate_ids": [candidate_id],
            "verified_operation_count": 1,
            "remote_success_count": 0,
            "retry_action_count": 1,
            "can_recover": True,
        }
    elif command == "session-recovery-import":
        assert request["resources"][0]["password"] == "Segreto-importazione-123"
        batch_id = request["reconciliation_batch_id"]
        candidate_id = request["candidates"][0]["candidate_id"]
        operation_id = "8affecb7-00cc-47d4-9487-2e9a6f66ff53"
        resource_id = "031fad27-c6c4-46e7-bc9a-9237f5c1cb46"
        progress = [
            {
                "type": "progress",
                "batch_id": batch_id,
                "event_type": "operation_intent",
                "payload": {
                    "operation_id": operation_id,
                    "object_type": "resource",
                    "action": "create_resource",
                    "candidate_id": candidate_id,
                    "destination_key_hash": "1" * 64,
                },
            },
            {
                "type": "progress",
                "batch_id": batch_id,
                "event_type": "resource_created",
                "payload": {
                    "operation_id": operation_id,
                    "resource_id": resource_id,
                    "candidate_id": candidate_id,
                    "status": "created",
                },
            },
            {
                "type": "progress",
                "batch_id": batch_id,
                "event_type": "batch_completed",
                "payload": {
                    "created_folder_count": 0,
                    "reconciled_folder_count": 0,
                    "created_resource_count": 1,
                    "shared_resource_count": 0,
                    "skipped_duplicate_count": 0,
                },
            },
        ]
        for envelope in progress:
            print(json.dumps(envelope), flush=True)
        result = {
            "command": "recovery-import",
            "session_id": session_id,
            "reconciliation_batch_id": batch_id,
            "created_count": 1,
            "complete": True,
        }
    elif command == "session-close":
        result = {"session_id": session_id, "command": command, "closed": True}
    else:
        raise AssertionError(command)
    print(json.dumps({"ok": True, "result": result}), flush=True)
    if command == "session-close":
        break
""",
            encoding="utf-8",
        )
        requests = [
            {
                "command": "session-open",
                "base_url": "https://pass.example.test",
                "expected_server_fingerprint": "C" * 40,
                "private_key_path": "C:/private.asc",
                "passphrase": "key-passphrase",
                "mfa_totp": "654321",
            },
            {
                "command": "session-recovery-readiness",
                "session_id": "recovery-session-id",
                "reconciliation_batch_id": journal.batch_id,
                "candidates": [self.request],
            },
            {
                "command": "session-recovery-import",
                "session_id": "recovery-session-id",
                "reconciliation_batch_id": journal.batch_id,
                "recovery_id": recovery_id,
                "recovery_plan_digest": recovery_digest,
                "resource_candidate_ids": [self.request["candidate_id"]],
                "candidates": [self.request],
                "confirmation": "RECUPERA 1",
            },
            {"command": "session-close", "session_id": "recovery-session-id"},
        ]
        completed = subprocess.run(
            [
                sys.executable,
                str(Path(__file__).with_name("passbolt_import.py")),
                "--session",
                "--root",
                str(self.root),
                "--node",
                sys.executable,
                "--crypto-script",
                str(fake_bridge),
            ],
            input="".join(
                json.dumps(request, separators=(",", ":")) + "\n"
                for request in requests
            ).encode("utf-8"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
            check=False,
            env={**os.environ, "LOCALAPPDATA": str(local_app_data)},
        )
        self.assertEqual(completed.returncode, 0, completed.stderr.decode("utf-8"))
        responses = [json.loads(line) for line in completed.stdout.splitlines()]
        self.assertEqual(len(responses), 4)
        self.assertTrue(all(response["ok"] for response in responses))
        self.assertEqual(
            responses[2]["result"]["reconciliation_status"], "complete"
        )
        snapshot = read_journal(journal.path)
        self.assertTrue(snapshot.complete)
        self.assertEqual(
            [event["event_type"] for event in snapshot.events],
            [
                "batch_started",
                "operation_intent",
                "operation_verified",
                "recovery_verified",
                "operation_intent",
                "resource_created",
                "batch_completed",
            ],
        )
        serialized = journal.path.read_text(encoding="utf-8") + completed.stdout.decode(
            "utf-8"
        )
        self.assertNotIn(self.secret, serialized)
        self.assertNotIn("key-passphrase", serialized)
        self.assertNotIn("654321", serialized)

    def test_recovery_rejects_changed_candidate_proofs_before_bridge(self) -> None:
        journal = ReconciliationJournal.create(
            app_version="0.12.5",
            server_origin="https://pass.example.test",
            server_fingerprint="D" * 40,
            user_id_hash=hash_user_identifier(
                "59a882e6-4909-4db0-ab84-91093461c777"
            ),
            plan_digest="d" * 64,
            resource_format="v4",
            folder_format="none",
            destination_mode="root",
            destination_folder_id=None,
            candidates=(
                CandidateProof(
                    self.request["candidate_id"], self.request["source_sha256"]
                ),
            ),
            root=self.root / "proof-journals",
        )
        changed = dict(self.request)
        changed["source_sha256"] = "0" * 64
        with self.assertRaises(ImportPreparationError):
            _prepare_recovery_context(
                self.root,
                {
                    "reconciliation_batch_id": journal.batch_id,
                    "candidates": [changed],
                },
                self.root / "proof-journals",
            )

    def test_recovery_requires_the_original_permission_configuration(self) -> None:
        template = [
            {"aro": "Group", "aro_foreign_key": "group-recipient-id", "type": 7}
        ]
        journal_root = self.root / "permission-recovery-journals"
        journal = ReconciliationJournal.create(
            app_version="0.14.0",
            server_origin="https://pass.example.test",
            server_fingerprint="D" * 40,
            user_id_hash=hash_user_identifier(
                "59a882e6-4909-4db0-ab84-91093461c777"
            ),
            plan_digest="d" * 64,
            resource_format="v4",
            folder_format="none",
            destination_mode="root",
            destination_folder_id=None,
            candidates=(
                CandidateProof(
                    self.request["candidate_id"], self.request["source_sha256"]
                ),
            ),
            permission_mode="custom",
            permission_configuration_hash=hash_permission_configuration(
                "custom", template
            ),
            root=journal_root,
        )
        with self.assertRaisesRegex(
            ImportPreparationError, "permessi configurati non corrispondono"
        ):
            _prepare_recovery_context(
                self.root,
                {
                    "reconciliation_batch_id": journal.batch_id,
                    "candidates": [self.request],
                    "permission_mode": "inherited",
                    "permission_template": [],
                },
                journal_root,
            )
        state, _ = _prepare_recovery_context(
            self.root,
            {
                "reconciliation_batch_id": journal.batch_id,
                "candidates": [self.request],
                "permission_mode": "custom",
                "permission_template": template,
            },
            journal_root,
        )
        self.assertEqual(state["permission_mode"], "custom")

    def test_reconciliation_management_protocol_exposes_no_paths_or_secrets(self) -> None:
        journal_root = self.root / "management-journals"
        journal = ReconciliationJournal.create(
            app_version="0.13.0",
            server_origin="https://pass.example.test",
            server_fingerprint="D" * 40,
            user_id_hash=hash_user_identifier(
                "59a882e6-4909-4db0-ab84-91093461c777"
            ),
            plan_digest="d" * 64,
            resource_format="v4",
            folder_format="none",
            destination_mode="root",
            destination_folder_id=None,
            candidates=(
                CandidateProof(
                    self.request["candidate_id"], self.request["source_sha256"]
                ),
            ),
            root=journal_root,
        )

        listing = _reconciliation_list_result(journal_root)
        self.assertEqual(listing["batches"][0]["batch_id"], journal.batch_id)
        self.assertNotIn("candidate_ids", listing["batches"][0])
        details = _reconciliation_describe_result(
            {"batch_id": journal.batch_id}, journal_root
        )
        self.assertEqual(details["candidate_ids"], [self.request["candidate_id"]])
        serialized = json.dumps({"listing": listing, "details": details})
        self.assertNotIn(str(journal_root), serialized)
        self.assertNotIn(self.secret, serialized)

        archived = _reconciliation_archive_result(
            {
                "batch_id": journal.batch_id,
                "expected_status": "recovery_required",
                "confirmation": f"ARCHIVIA {journal.batch_id}",
            },
            journal_root,
        )
        self.assertFalse(archived["deleted"])
        self.assertEqual(archived["previous_status"], "recovery_required")

    def test_acl_journal_management_protocol_exposes_no_identity_paths_or_secrets(self) -> None:
        journal_root = self.root / "acl-management-journals"
        journal = AclReconciliationJournal.create(
            app_version="0.18.0",
            server_origin="https://pass.example.test",
            server_fingerprint="E" * 40,
            user_id_hash=hash_user_identifier(
                "59a882e6-4909-4db0-ab84-91093461c777"
            ),
            object_type="folder",
            object_id="folder-id",
            object_state_digest="1" * 64,
            desired_acl_digest="2" * 64,
            plan_digest="3" * 64,
            desired_permissions=[
                {"aro": "Group", "aro_foreign_key": "group-id", "type": 7}
            ],
            change_count=1,
            add_count=0,
            upgrade_count=1,
            downgrade_count=0,
            revoke_count=0,
            apply_mode="additive",
            root=journal_root,
        )

        listing = _acl_reconciliation_list_result(journal_root)
        self.assertEqual(listing["batches"][0]["batch_id"], journal.batch_id)
        self.assertEqual(listing["batches"][0]["apply_mode"], "additive")
        details = _acl_reconciliation_describe_result(
            {"batch_id": journal.batch_id}, journal_root
        )
        self.assertEqual(details["object_id"], "folder-id")
        serialized = json.dumps({"listing": listing, "details": details})
        self.assertNotIn(str(journal_root), serialized)
        self.assertNotIn("pass.example.test", serialized)
        self.assertNotIn("group-id", serialized)
        self.assertNotIn(self.secret, serialized)

        archived = _acl_reconciliation_archive_result(
            {
                "batch_id": journal.batch_id,
                "expected_status": "recovery_required",
                "confirmation": f"ARCHIVIA ACL {journal.batch_id}",
            },
            journal_root,
        )
        self.assertFalse(archived["deleted"])
        self.assertEqual(archived["previous_status"], "recovery_required")

    def test_changed_source_is_rejected(self) -> None:
        self.source.write_text(
            self.source.read_text(encoding="utf-8") + "\nNota: modificato\n",
            encoding="utf-8",
        )

        with self.assertRaisesRegex(ImportPreparationError, "cambiato"):
            verify_integrity(self.root, [self.request])

    def test_change_during_read_is_rejected(self) -> None:
        from passbolt_review import _records_for_file as real_records_for_file

        def changing_records(
            path: Path,
            extension: str,
            *,
            file_password: str | None = None,
            source_mapping_profile: object | None = None,
        ):
            records = list(
                real_records_for_file(
                    path,
                    extension,
                    file_password=file_password,
                    source_mapping_profile=source_mapping_profile,
                )
            )
            path.write_text(
                path.read_text(encoding="utf-8") + "\nNota: cambio concorrente\n",
                encoding="utf-8",
            )
            return records

        with mock.patch(
            "passbolt_import._records_for_file", side_effect=changing_records
        ):
            with self.assertRaisesRegex(ImportPreparationError, "durante la lettura"):
                verify_integrity(self.root, [self.request])

    def test_reviewed_metadata_mismatch_is_rejected(self) -> None:
        changed = dict(self.request)
        changed["title"] = "Titolo alterato"

        with self.assertRaisesRegex(ImportPreparationError, "metadati"):
            verify_integrity(self.root, [changed])

    def test_path_traversal_is_rejected(self) -> None:
        changed = dict(self.request)
        changed["source_relative_path"] = "../portale.txt"

        with self.assertRaisesRegex(ImportPreparationError, "verificato"):
            verify_integrity(self.root, [changed])

    def test_execute_hands_secrets_to_bridge_stdin_not_arguments(self) -> None:
        node = self.root / "node.exe"
        script = self.root / "passbolt_crypto.mjs"
        node.write_bytes(b"placeholder")
        script.write_text("// placeholder", encoding="utf-8")
        bridge_result = {
            "ok": True,
            "result": {"created_count": 1, "complete": True},
        }

        def fake_run(arguments: list[str], **kwargs: object) -> subprocess.CompletedProcess:
            self.assertEqual(arguments, [str(node.resolve()), str(script.resolve())])
            self.assertNotIn(self.secret, " ".join(arguments))
            self.assertNotIn("654321", " ".join(arguments))
            stdin_document = json.loads(bytes(kwargs["input"]).decode("utf-8"))
            self.assertEqual(stdin_document["resources"][0]["password"], self.secret)
            self.assertEqual(stdin_document["mfa_totp"], "654321")
            self.assertEqual(stdin_document["resource_format"], "v5")
            self.assertEqual(stdin_document["destination_mode"], "client_folders")
            self.assertEqual(stdin_document["folder_format"], "v5")
            self.assertEqual(stdin_document["destination_folder_id"], "folder-parent-id")
            self.assertEqual(
                stdin_document["client_destination_mapping"],
                [{"client": "Cliente Alfa", "folder_id": "folder-alpha-id"}],
            )
            return subprocess.CompletedProcess(
                arguments,
                0,
                stdout=json.dumps(bridge_result).encode("utf-8"),
                stderr=b"",
            )

        execution_request = {
            "base_url": "https://pass.example.test",
            "expected_server_fingerprint": "A" * 40,
            "private_key_path": "C:/private.asc",
            "passphrase": "key-passphrase",
            "mfa_totp": "654321",
            "resource_format": "v5",
            "destination_mode": "client_folders",
            "folder_format": "v5",
            "destination_folder_id": "folder-parent-id",
            "client_destination_mapping": [
                {"client": "Cliente Alfa", "folder_id": "folder-alpha-id"}
            ],
            "candidates": [self.request],
            "create_candidate_ids": [self.request["candidate_id"]],
            "plan_digest": "digest",
            "confirmation": "IMPORTA 1",
        }
        with mock.patch("passbolt_import.subprocess.run", side_effect=fake_run):
            result = execute_import(
                self.root,
                execution_request,
                node_path=str(node),
                crypto_script=str(script),
            )

        self.assertEqual(result, bridge_result)
        self.assertNotIn(self.secret, json.dumps(result))
        self.assertNotIn("654321", json.dumps(result))


if __name__ == "__main__":
    unittest.main()
