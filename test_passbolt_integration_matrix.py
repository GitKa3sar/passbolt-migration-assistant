import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

import passbolt_integration_matrix as matrix


FINGERPRINT = "0123456789ABCDEF0123456789ABCDEF01234567"


class FakeBridge:
    def __init__(self, resource_format="v5", folder_format="v5"):
        self.resource_format = resource_format
        self.folder_format = folder_format
        self.requests = []

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return None

    def request(self, request):
        self.requests.append(json.loads(json.dumps(request)))
        command = request["command"]
        if command == "session-open":
            return {
                "ok": True,
                "result": {
                    "session_id": "session-secret-id",
                    "authentication": "GPGAuth + TOTP",
                    "mfa_provider": "totp",
                    "secrets_serialized": False,
                    "user": {"id": "private-user-id", "username": "private@example.test"},
                },
            }
        if command == "session-permissions":
            return {"ok": True, "result": {"entries": [{"aro": "User"}, {"aro": "Group"}]}}
        if command == "session-acl-catalog":
            return {
                "ok": True,
                "result": {
                    "read_only": True,
                    "write_requests": 0,
                    "folder_count": 2,
                    "resource_count": 3,
                    "shared_count": 1,
                    "verified_count": 5,
                    "warning_count": 0,
                    "objects": [{"object_id": "private-object-id"}],
                },
            }
        if command == "session-readiness":
            at_root = request["destination_mode"] == "root"
            return {
                "ok": True,
                "result": {
                    "resource_format_selected": self.resource_format,
                    "folder_format_selected": "none" if at_root else self.folder_format,
                    "can_import": True,
                    "create_count": 1,
                    "blocked_count": 0,
                    "create_folder_count": 0 if at_root else 1,
                    "plan_digest": "a" * 64,
                    "candidates": [{"title": "private-title"}],
                },
            }
        if command == "session-close":
            return {"ok": True, "result": {"closed": True}}
        raise AssertionError(command)


class IntegrationMatrixTests(unittest.TestCase):
    def profile(self, **overrides):
        values = {
            "instance_id": "v5-lab",
            "enabled": True,
            "base_url": "https://private-passbolt.example.test",
            "expected_server_fingerprint": FINGERPRINT,
            "expected_resource_format": "v5",
            "expected_folder_format": "v5",
        }
        values.update(overrides)
        return matrix.InstanceProfile(**values)

    def probe(self, base_url, expected, timeout):
        self.assertEqual(base_url, "https://private-passbolt.example.test")
        self.assertEqual(expected, FINGERPRINT)
        return SimpleNamespace(
            fingerprint_matches_expected=True,
            health_http_status=200,
            verify_http_status=200,
            armored_public_key_present=True,
        )

    def test_config_validation_and_placeholder_protection(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "matrix.json"
            path.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "instances": [
                            {
                                "id": "v5-lab",
                                "enabled": True,
                                "base_url": "https://passbolt.example.test",
                                "expected_server_fingerprint": FINGERPRINT,
                                "expected_resource_format": "v5",
                                "expected_folder_format": "v5",
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            profiles = matrix.load_config(path)
            self.assertEqual(profiles[0].expected_resource_format, "v5")
            document = json.loads(path.read_text(encoding="utf-8"))
            document["instances"][0]["expected_server_fingerprint"] = "0" * 40
            path.write_text(json.dumps(document), encoding="utf-8")
            with self.assertRaises(matrix.MatrixError):
                matrix.load_config(path)

    def test_read_only_run_is_complete_and_report_contains_no_secrets(self):
        bridge = FakeBridge()
        report = matrix.run_instance(
            self.profile(),
            Path("C:/private/key.asc"),
            "super-secret-passphrase",
            "123456",
            probe_runner=self.probe,
            bridge_factory=lambda: bridge,
        )
        statuses = {item["name"]: item["status"] for item in report["scenarios"]}
        for name in matrix.AUTOMATED_SCENARIOS:
            self.assertEqual(statuses[name], "passed")
        for name in matrix.MANUAL_SCENARIOS:
            self.assertEqual(statuses[name], "not_run")
        serialized = json.dumps(report, sort_keys=True)
        for forbidden in (
            "super-secret-passphrase",
            "123456",
            "private-passbolt",
            FINGERPRINT,
            "private-user-id",
            "private@example.test",
            "session-secret-id",
            "private-object-id",
            "private-title",
            "key.asc",
        ):
            self.assertNotIn(forbidden, serialized)
        self.assertEqual(report["remote_writes_performed"], 0)
        self.assertEqual(report["report_digest"], matrix.calculate_report_digest(report))

    def test_bridge_receives_secrets_only_in_session_open(self):
        bridge = FakeBridge()
        matrix.run_instance(
            self.profile(),
            Path("C:/private/key.asc"),
            "passphrase-value",
            "654321",
            probe_runner=self.probe,
            bridge_factory=lambda: bridge,
        )
        self.assertEqual(bridge.requests[0]["command"], "session-open")
        self.assertEqual(bridge.requests[0]["passphrase"], "passphrase-value")
        self.assertEqual(bridge.requests[0]["mfa_totp"], "654321")
        for request in bridge.requests[1:]:
            self.assertNotIn("passphrase", request)
            self.assertNotIn("mfa_totp", request)
            self.assertNotIn("resources", request)
            self.assertNotIn("confirmation", request)

    def test_format_mismatch_fails_only_the_relevant_readiness(self):
        report = matrix.run_instance(
            self.profile(),
            Path("C:/private/key.asc"),
            "passphrase",
            "123456",
            probe_runner=self.probe,
            bridge_factory=lambda: FakeBridge(resource_format="v4", folder_format="v4"),
        )
        statuses = {item["name"]: item["status"] for item in report["scenarios"]}
        self.assertEqual(statuses["authenticated_login"], "passed")
        self.assertEqual(statuses["resource_root_dry_run"], "failed")
        self.assertEqual(statuses["client_folder_dry_run"], "failed")

    def test_public_probe_failure_blocks_authentication_without_starting_bridge(self):
        def fail_probe(*args):
            raise matrix.ProbeError("private failure")

        report = matrix.run_instance(
            self.profile(),
            Path("C:/private/key.asc"),
            "passphrase",
            "123456",
            probe_runner=fail_probe,
            bridge_factory=lambda: self.fail("bridge must not start"),
        )
        statuses = {item["name"]: item["status"] for item in report["scenarios"]}
        self.assertEqual(statuses["public_probe"], "failed")
        self.assertEqual(statuses["authenticated_login"], "blocked")

    def test_manual_attestation_updates_digest_and_rejects_automated_scenario(self):
        report = matrix.run_instance(
            self.profile(),
            Path("C:/private/key.asc"),
            "passphrase",
            "123456",
            probe_runner=self.probe,
            bridge_factory=lambda: FakeBridge(),
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            matrix.write_report(report, path)
            old_digest = matrix.load_report(path)["report_digest"]
            matrix.record_manual_result(path, "import_root_resource", "passed", None)
            updated = matrix.load_report(path)
            self.assertNotEqual(updated["report_digest"], old_digest)
            scenario = next(item for item in updated["scenarios"] if item["name"] == "import_root_resource")
            self.assertEqual(scenario["status"], "passed")
            self.assertTrue(scenario["metrics"]["operator_attested"])
            with self.assertRaises(matrix.MatrixError):
                matrix.record_manual_result(path, "authenticated_login", "passed", None)

    def test_report_tampering_is_detected(self):
        report = matrix.run_instance(
            self.profile(),
            Path("C:/private/key.asc"),
            "passphrase",
            "123456",
            probe_runner=self.probe,
            bridge_factory=lambda: FakeBridge(),
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            matrix.write_report(report, path)
            document = json.loads(path.read_text(encoding="utf-8"))
            document["scenarios"][0]["status"] = "failed"
            path.write_text(json.dumps(document), encoding="utf-8")
            with self.assertRaises(matrix.MatrixError):
                matrix.load_report(path)

    def test_report_schema_rejects_unknown_fields_even_with_recalculated_digest(self):
        report = matrix.run_instance(
            self.profile(),
            Path("C:/private/key.asc"),
            "passphrase",
            "123456",
            probe_runner=self.probe,
            bridge_factory=lambda: FakeBridge(),
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            matrix.write_report(report, path)
            document = json.loads(path.read_text(encoding="utf-8"))
            document["operator_note"] = "a field that must never be preserved"
            document["report_digest"] = matrix.calculate_report_digest(document)
            path.write_text(json.dumps(document), encoding="utf-8")
            with self.assertRaises(matrix.MatrixError):
                matrix.load_report(path)

    def test_safe_error_projection_is_enumerated(self):
        safe = matrix._safe_error(
            {
                "error": {
                    "code": "MFA_TOTP_REJECTED",
                    "message": "private message",
                    "details": {
                        "auth_phase": "mfa_totp",
                        "http_status": 400,
                        "clock_skew_seconds": 31,
                        "cookie": "private-cookie",
                    },
                }
            },
            "FALLBACK",
        )
        self.assertEqual(
            safe,
            {
                "error_code": "MFA_TOTP_REJECTED",
                "auth_phase": "mfa_totp",
                "http_status": 400,
                "clock_skew_seconds": 31,
            },
        )


if __name__ == "__main__":
    unittest.main()
