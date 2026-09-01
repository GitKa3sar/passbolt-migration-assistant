import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

import passbolt_integration_matrix as matrix


FINGERPRINT = "0123456789ABCDEF0123456789ABCDEF01234567"


class FakeBridge:
    def __init__(self, resource_format="v4", folder_format="v4"):
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
                    "folder_format_selected": None if at_root else self.folder_format,
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


class InvalidRootFolderPlanBridge(FakeBridge):
    def request(self, request):
        response = super().request(request)
        if request["command"] == "session-readiness" and request["destination_mode"] == "root":
            response["result"]["folder_format_selected"] = "v5"
            response["result"]["create_folder_count"] = 3
        return response


class GpgAuthOnlyBridge(FakeBridge):
    def request(self, request):
        response = super().request(request)
        if request["command"] == "session-open":
            response["result"]["authentication"] = "GPGAuth"
            response["result"]["mfa_provider"] = None
        return response


class IntegrationMatrixTests(unittest.TestCase):
    def profile(self, **overrides):
        values = {
            "instance_id": "v4-lab",
            "enabled": True,
            "base_url": "https://private-passbolt.example.test",
            "expected_server_fingerprint": FINGERPRINT,
            "expected_resource_format": "v4",
            "expected_folder_format": "v4",
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
                                "id": "v4-lab",
                                "enabled": True,
                                "base_url": "https://passbolt.example.test",
                                "expected_server_fingerprint": FINGERPRINT,
                                "expected_resource_format": "v4",
                                "expected_folder_format": "v4",
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            profiles = matrix.load_config(path)
            self.assertEqual(profiles[0].expected_resource_format, "v4")
            document = json.loads(path.read_text(encoding="utf-8"))
            document["instances"][0]["expected_resource_format"] = "v5"
            document["instances"][0]["expected_folder_format"] = "v4"
            path.write_text(json.dumps(document), encoding="utf-8")
            v5_profiles = matrix.load_config(path)
            self.assertEqual(
                (
                    v5_profiles[0].expected_resource_format,
                    v5_profiles[0].expected_folder_format,
                ),
                ("v5", "v4"),
            )
            document["instances"][0]["expected_folder_format"] = "v5"
            path.write_text(json.dumps(document), encoding="utf-8")
            with self.assertRaisesRegex(matrix.MatrixError, "cartelle v5"):
                matrix.load_config(path)
            document["instances"][0]["enabled"] = False
            path.write_text(json.dumps(document), encoding="utf-8")
            with self.assertRaisesRegex(matrix.MatrixError, "cartelle v5"):
                matrix.load_config(path)
            document["instances"][0]["expected_resource_format"] = "auto"
            document["instances"][0]["expected_folder_format"] = "v4"
            path.write_text(json.dumps(document), encoding="utf-8")
            with self.assertRaisesRegex(matrix.MatrixError, "auto"):
                matrix.load_config(path)
            document = json.loads(path.read_text(encoding="utf-8"))
            document["instances"][0]["enabled"] = True
            document["instances"][0]["expected_resource_format"] = "v4"
            document["instances"][0]["expected_folder_format"] = "v4"
            document["instances"][0]["expected_server_fingerprint"] = "0" * 40
            path.write_text(json.dumps(document), encoding="utf-8")
            with self.assertRaises(matrix.MatrixError):
                matrix.load_config(path)

    def test_v5_resource_preview_uses_v4_folders_end_to_end(self):
        bridge = FakeBridge(resource_format="v5", folder_format="v4")
        profile = self.profile(
            instance_id="v5-resource-preview",
            expected_resource_format="v5",
            expected_folder_format="v4",
        )
        report = matrix.run_instance(
            profile,
            Path("C:/private/key.asc"),
            "passphrase",
            "123456",
            probe_runner=self.probe,
            bridge_factory=lambda: bridge,
        )
        matrix.validate_report_document(report)
        self.assertEqual(
            (report["expected_resource_format"], report["expected_folder_format"]),
            ("v5", "v4"),
        )
        readiness_requests = [
            request for request in bridge.requests if request["command"] == "session-readiness"
        ]
        self.assertEqual(len(readiness_requests), 2)
        self.assertTrue(
            all(
                request["resource_format"] == "v5"
                and request["folder_format"] == "v4"
                for request in readiness_requests
            )
        )
        self.assertTrue(
            all(
                next(
                    item
                    for item in report["scenarios"]
                    if item["name"] == scenario_name
                )["status"]
                == "passed"
                for scenario_name in matrix.AUTOMATED_SCENARIOS
            )
        )

    def test_direct_run_rejects_v5_folders_before_probe(self):
        with self.assertRaisesRegex(matrix.MatrixError, "cartelle v5"):
            matrix.run_instance(
                self.profile(
                    expected_resource_format="v5", expected_folder_format="v5"
                ),
                Path("C:/private/key.asc"),
                "passphrase",
                "123456",
                probe_runner=lambda *args: self.fail("probe must not run"),
                bridge_factory=lambda: self.fail("bridge must not start"),
            )

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

    def test_root_readiness_accepts_null_folder_format(self):
        report = matrix.run_instance(
            self.profile(),
            Path("C:/private/key.asc"),
            "passphrase",
            "123456",
            probe_runner=self.probe,
            bridge_factory=lambda: FakeBridge(),
        )
        scenario = next(item for item in report["scenarios"] if item["name"] == "resource_root_dry_run")
        self.assertEqual(scenario["status"], "passed")
        self.assertIsNone(scenario["metrics"]["folder_format_selected"])

    def test_root_readiness_rejects_folder_format_and_create_count(self):
        report = matrix.run_instance(
            self.profile(),
            Path("C:/private/key.asc"),
            "passphrase",
            "123456",
            probe_runner=self.probe,
            bridge_factory=lambda: InvalidRootFolderPlanBridge(),
        )
        root = next(item for item in report["scenarios"] if item["name"] == "resource_root_dry_run")
        client = next(item for item in report["scenarios"] if item["name"] == "client_folder_dry_run")
        self.assertEqual(root["status"], "failed")
        self.assertEqual(root["metrics"]["error_code"], "READINESS_EXPECTATION_MISMATCH")
        self.assertEqual(client["status"], "passed")

    def test_gpg_auth_only_login_preserves_null_mfa_provider(self):
        report = matrix.run_instance(
            self.profile(),
            Path("C:/private/key.asc"),
            "passphrase",
            "",
            probe_runner=self.probe,
            bridge_factory=lambda: GpgAuthOnlyBridge(),
        )
        scenario = next(item for item in report["scenarios"] if item["name"] == "authenticated_login")
        self.assertEqual(scenario["status"], "passed")
        self.assertEqual(scenario["metrics"]["authentication"], "GPGAuth")
        self.assertIsNone(scenario["metrics"]["mfa_provider"])
        matrix.validate_report_document(report)

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
            bridge_factory=lambda: FakeBridge(resource_format="v5", folder_format="v5"),
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
            self.assertEqual(
                scenario["metrics"]["attestation_contract"],
                matrix.REMOTE_WRITE_SUCCESS,
            )
            self.assertTrue(scenario["metrics"]["remote_writes_recorded"])
            with self.assertRaises(matrix.MatrixError):
                matrix.record_manual_result(path, "authenticated_login", "passed", None)

    def test_v5_custom_share_requires_negative_no_write_proof(self):
        report = matrix.run_instance(
            self.profile(
                instance_id="v5-resource-preview",
                expected_resource_format="v5",
                expected_folder_format="v4",
            ),
            Path("C:/private/key.asc"),
            "passphrase",
            "123456",
            probe_runner=self.probe,
            bridge_factory=lambda: FakeBridge(resource_format="v5", folder_format="v4"),
        )
        contracts = {
            scenario["name"]: scenario["metrics"].get("attestation_contract")
            for scenario in report["scenarios"]
            if scenario["kind"] == "manual"
        }
        self.assertEqual(
            contracts["custom_shared_permissions"], matrix.FAIL_CLOSED_NO_WRITE
        )
        self.assertEqual(
            contracts["additive_acl_update"], matrix.FAIL_CLOSED_NO_WRITE
        )
        self.assertEqual(
            contracts["restrictive_acl_update"], matrix.FAIL_CLOSED_NO_WRITE
        )
        self.assertEqual(contracts["duplicate_detection"], matrix.NO_WRITE_SUCCESS)

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "v5-resource-preview.json"
            matrix.write_report(report, path)
            with self.assertRaisesRegex(matrix.MatrixError, "ACL_V5_MUTATION_DISABLED"):
                matrix.record_manual_result(
                    path, "custom_shared_permissions", "passed", None
                )
            with self.assertRaisesRegex(matrix.MatrixError, "ACL_V5_MUTATION_DISABLED"):
                matrix.record_manual_result(
                    path, "custom_shared_permissions", "passed", "WRONG_REJECTION"
                )
            matrix.record_manual_result(
                path,
                "custom_shared_permissions",
                "passed",
                "ACL_V5_MUTATION_DISABLED",
            )
            updated = matrix.load_report(path)
            custom = next(
                scenario
                for scenario in updated["scenarios"]
                if scenario["name"] == "custom_shared_permissions"
            )
            self.assertEqual(
                custom["metrics"],
                {
                    "attestation_contract": matrix.FAIL_CLOSED_NO_WRITE,
                    "operator_attested": True,
                    "remote_writes_recorded": False,
                    "rejection_observed": True,
                    "error_code": "ACL_V5_MUTATION_DISABLED",
                },
            )
            custom["metrics"]["remote_writes_recorded"] = True
            updated = matrix.finalize_report(updated)
            path.write_text(json.dumps(updated), encoding="utf-8")
            with self.assertRaisesRegex(matrix.MatrixError, "contratto|metriche"):
                matrix.load_report(path)

        self_test = matrix.self_test()
        self.assertTrue(self_test["v5_custom_share_negative_proof_required"])
        self.assertTrue(self_test["v5_custom_share_negative_proof_recorded"])
        self.assertTrue(self_test["v5_manual_contract_complete"])

    def test_release_completion_accepts_v5_resource_preview_but_not_v5_folders(self):
        report = matrix.run_instance(
            self.profile(),
            Path("C:/private/key.asc"),
            "passphrase",
            "123456",
            probe_runner=self.probe,
            bridge_factory=lambda: FakeBridge(),
        )
        v4_pair = ("v4", "v4")
        for scenario in report["scenarios"]:
            if scenario["name"] in matrix.MANUAL_SCENARIOS:
                scenario["status"] = "passed"
                scenario["metrics"] = matrix._manual_passed_metrics(
                    v4_pair, scenario["name"]
                )
        report = matrix.finalize_report(report)
        self.assertTrue(matrix.report_is_release_complete(report))

        v5_resource_preview = matrix.run_instance(
            self.profile(
                instance_id="v5-resource-preview",
                expected_resource_format="v5",
                expected_folder_format="v4",
            ),
            Path("C:/private/key.asc"),
            "passphrase",
            "123456",
            probe_runner=self.probe,
            bridge_factory=lambda: FakeBridge(resource_format="v5", folder_format="v4"),
        )
        v5_pair = ("v5", "v4")
        for scenario in v5_resource_preview["scenarios"]:
            if scenario["name"] in matrix.MANUAL_SCENARIOS:
                contract = matrix._manual_attestation_contract(
                    v5_pair, scenario["name"]
                )
                scenario["status"] = "passed"
                scenario["metrics"] = matrix._manual_passed_metrics(
                    v5_pair,
                    scenario["name"],
                    matrix.V5_ACL_REJECTION_CODE
                    if contract == matrix.FAIL_CLOSED_NO_WRITE
                    else None,
                )
        v5_resource_preview = matrix.finalize_report(v5_resource_preview)
        matrix.validate_report_document(v5_resource_preview)
        self.assertTrue(matrix.report_is_release_complete(v5_resource_preview))

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "v5-resource-preview.json"
            matrix.write_report(v5_resource_preview, path)
            matrix.record_manual_result(path, "import_root_resource", "passed", None)

        historical_v5 = json.loads(json.dumps(report))
        historical_v5["expected_resource_format"] = "v5"
        historical_v5["expected_folder_format"] = "v5"
        historical_v5 = matrix.finalize_report(historical_v5)
        matrix.validate_report_document(historical_v5)
        self.assertFalse(matrix.report_is_release_complete(historical_v5))

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "historical-v5.json"
            matrix.write_report(historical_v5, path)
            with self.assertRaisesRegex(matrix.MatrixError, "evidenza storica"):
                matrix.record_manual_result(path, "import_root_resource", "passed", None)

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

    def test_real_instance_runs_are_blocked_in_ci_only(self):
        self.assertFalse(matrix.real_instance_runs_allowed({"CI": "true"}))
        self.assertFalse(matrix.real_instance_runs_allowed({"GITHUB_ACTIONS": "1"}))
        self.assertFalse(matrix.real_instance_runs_allowed({"PASSBOLT_MIGRATION_CI": "yes"}))
        self.assertTrue(matrix.real_instance_runs_allowed({"CI": "false"}))
        self.assertTrue(matrix.real_instance_runs_allowed({}))

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
