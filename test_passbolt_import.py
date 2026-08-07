from __future__ import annotations

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

        def changing_records(path: Path, extension: str):
            records = list(real_records_for_file(path, extension))
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
