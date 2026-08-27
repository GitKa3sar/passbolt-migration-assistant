from __future__ import annotations

import base64
import copy
import hashlib
import json
import subprocess
import sys
import unittest
from datetime import datetime, timezone

from passbolt_project import (
    ProjectError,
    _strict_json_text,
    create_envelope,
    normalize_project,
    open_envelope,
)
from passbolt_review import normalize_source_mapping_profile


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def sample_profile() -> dict[str, object]:
    return normalize_source_mapping_profile(
        {
            "schema_version": 1,
            "name": "Esportazione sintetica",
            "fields": {
                "title": ["record_name"],
                "username": ["login_name"],
                "secret": ["access_value"],
                "uri": ["target_host"],
            },
        }
    ).document()


def sample_project() -> dict[str, object]:
    return {
        "schema_version": 1,
        "kind": "passbolt-migration-preparation",
        "app_version": "0.28.2",
        "saved_at_utc": utc_now(),
        "server_origin": "https://passbolt.example.test",
        "source_root": r"C:\Synthetic\Migration",
        "source_mapping_profile": sample_profile(),
        "selected_files": ["Cliente Beta/server.txt", "Cliente Alfa/accessi.csv"],
        "selected_candidates": [
            {"candidate_id": "a" * 64, "source_sha256": "b" * 64}
        ],
    }


class ProjectTests(unittest.TestCase):
    def test_project_is_canonical_and_binds_profile_and_selections(self) -> None:
        normalized = normalize_project(sample_project())

        self.assertRegex(str(normalized["digest"]), r"^[0-9a-f]{64}$")
        self.assertEqual(
            normalized["selected_files"],
            ["Cliente Alfa/accessi.csv", "Cliente Beta/server.txt"],
        )
        self.assertEqual(
            normalized["source_mapping_profile"]["digest"], sample_profile()["digest"]
        )
        self.assertNotIn("fingerprint", json.dumps(normalized).casefold())
        self.assertNotIn("session", json.dumps(normalized).casefold())

    def test_project_digest_detects_plaintext_change_after_decryption(self) -> None:
        normalized = normalize_project(sample_project())
        changed = copy.deepcopy(normalized)
        changed["selected_files"] = ["Cliente Alfa/diverso.csv"]

        with self.assertRaisesRegex(ProjectError, "digest"):
            normalize_project(changed)

    def test_project_rejects_unknown_secret_or_trust_fields(self) -> None:
        for name, value in (
            ("password", "LAB-ONLY-NOT-A-REAL-SECRET"),
            ("server_fingerprint", "0" * 40),
            ("session_id", "synthetic-session"),
        ):
            with self.subTest(name=name):
                project = sample_project()
                project[name] = value
                with self.assertRaisesRegex(ProjectError, "non riconosciuti"):
                    normalize_project(project)

        project = sample_project()
        project["server_origin"] = "https://user:secret@passbolt.example.test"
        with self.assertRaisesRegex(ProjectError, "credenziali"):
            normalize_project(project)

    def test_project_rejects_traversal_and_case_insensitive_duplicates(self) -> None:
        traversal = sample_project()
        traversal["selected_files"] = ["../outside.txt"]
        with self.assertRaises(ProjectError):
            normalize_project(traversal)

        duplicate = sample_project()
        duplicate["selected_files"] = ["Cliente/File.txt", "cliente/file.TXT"]
        with self.assertRaisesRegex(ProjectError, "duplicati"):
            normalize_project(duplicate)

    def test_project_rejects_tampered_source_profile_digest(self) -> None:
        project = sample_project()
        project["source_mapping_profile"]["digest"] = "f" * 64

        with self.assertRaisesRegex(ProjectError, "digest"):
            normalize_project(project)

    def test_envelope_validates_ciphertext_digest_and_schema(self) -> None:
        raw = b"synthetic-dpapi-ciphertext"
        envelope = create_envelope(
            {"ciphertext": base64.b64encode(raw).decode("ascii"), "saved_at_utc": utc_now()}
        )

        opened = open_envelope(envelope)
        self.assertEqual(base64.b64decode(opened["ciphertext"]), raw)
        self.assertEqual(envelope["ciphertext_sha256"], hashlib.sha256(raw).hexdigest())
        tampered = dict(envelope)
        tampered["ciphertext_sha256"] = "0" * 64
        with self.assertRaisesRegex(ProjectError, "digest"):
            open_envelope(tampered)

    def test_secure_cli_error_does_not_echo_rejected_value(self) -> None:
        marker = "LAB-ONLY-NOT-A-REAL-SECRET"
        project = sample_project()
        project["password"] = marker
        completed = subprocess.run(
            [sys.executable, "passbolt_project.py", "--secure-json"],
            input=json.dumps({"command": "normalize-project", "project": project}),
            text=True,
            capture_output=True,
            check=True,
        )

        response = json.loads(completed.stdout)
        self.assertFalse(response["ok"])
        self.assertEqual(response["error"]["code"], "LOCAL_PROJECT_INVALID")
        self.assertNotIn(marker, completed.stdout)
        self.assertEqual(completed.stderr, "")

    def test_strict_json_rejects_duplicate_properties(self) -> None:
        with self.assertRaisesRegex(ProjectError, "duplicate"):
            _strict_json_text('{"kind":"first","kind":"second"}', "Il file progetto")


if __name__ == "__main__":
    unittest.main()
