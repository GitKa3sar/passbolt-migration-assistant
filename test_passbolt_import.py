from __future__ import annotations

import io
import json
import subprocess
import sys
import tempfile
import unittest
from dataclasses import asdict
from pathlib import Path
from unittest import mock

from passbolt_import import (
    ImportPreparationError,
    _session_bridge_request,
    execute_import,
    extract_resources,
    verify_integrity,
)
from passbolt_review import analyze_files


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

    def test_secret_is_reextracted_only_for_immediate_handoff(self) -> None:
        resources, source_count = extract_resources(
            self.root, [self.request], include_secrets=True
        )

        self.assertEqual(source_count, 1)
        self.assertEqual(resources[0]["password"], self.secret)
        self.assertEqual(resources[0]["candidate_id"], self.request["candidate_id"])

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
                "candidates": [self.request],
            },
        )

        self.assertEqual(bridge_request["command"], "session-readiness")
        self.assertEqual(bridge_request["session_id"], "session-id")
        self.assertEqual(resources, [])
        self.assertNotIn(self.secret, json.dumps(bridge_request))

    def test_persistent_session_import_hands_off_secrets_without_auth_data(self) -> None:
        bridge_request, resources = _session_bridge_request(
            self.root,
            {
                "command": "session-import",
                "session_id": "session-id",
                "resource_format": "v4",
                "destination_mode": "root",
                "folder_format": "auto",
                "candidates": [self.request],
                "create_candidate_ids": [self.request["candidate_id"]],
                "plan_digest": "digest",
                "confirmation": "IMPORTA 1",
            },
        )

        self.assertEqual(bridge_request["command"], "session-import")
        self.assertEqual(resources[0]["password"], self.secret)
        self.assertEqual(bridge_request["resources"][0]["password"], self.secret)
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
for raw in sys.stdin:
    request = json.loads(raw)
    command = request.get("command")
    if command == "session-open":
        assert request.get("passphrase") == "key-passphrase"
        assert request.get("mfa_totp") == "654321"
        result = {"session_id": session_id, "authentication": "GPGAuth + TOTP"}
    elif command == "session-readiness":
        assert request.get("session_id") == session_id
        assert "passphrase" not in request and "mfa_totp" not in request
        assert "resources" not in request
        result = {"session_id": session_id, "command": "readiness", "can_import": True}
    elif command == "session-import":
        assert request.get("session_id") == session_id
        assert "passphrase" not in request and "mfa_totp" not in request
        assert request["resources"][0]["password"] == "Segreto-importazione-123"
        result = {"session_id": session_id, "command": "import", "created_count": 1}
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
                "plan_digest": "digest",
                "confirmation": "IMPORTA 1",
            },
            {"command": "session-close", "session_id": "test-session-id"},
        ]
        session_input = "".join(
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
        )

        self.assertEqual(completed.returncode, 0, completed.stderr.decode("utf-8"))
        responses = [json.loads(line) for line in completed.stdout.splitlines()]
        self.assertEqual(len(responses), 4)
        self.assertTrue(all(response["ok"] for response in responses))
        self.assertEqual(responses[0]["result"]["session_id"], "test-session-id")
        self.assertEqual(responses[2]["result"]["created_count"], 1)
        serialized_responses = completed.stdout.decode("utf-8")
        self.assertNotIn(self.secret, serialized_responses)
        self.assertNotIn("key-passphrase", serialized_responses)
        self.assertNotIn("654321", serialized_responses)

    def test_changed_source_is_rejected(self) -> None:
        self.source.write_text(
            self.source.read_text(encoding="utf-8") + "\nNota: modificato\n",
            encoding="utf-8",
        )

        with self.assertRaisesRegex(ImportPreparationError, "cambiato"):
            verify_integrity(self.root, [self.request])

    def test_change_during_read_is_rejected(self) -> None:
        from passbolt_review import _records_for_file as real_records_for_file

        def changing_records(path: Path, extension: str, *, file_password: str | None = None):
            records = list(
                real_records_for_file(path, extension, file_password=file_password)
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
