import io
import sys
import unittest
from contextlib import redirect_stderr
from unittest import mock

import passbolt_api_probe as probe


FINGERPRINT = "0123456789ABCDEF0123456789ABCDEF01234567"
PUBLIC_KEY = (
    "-----BEGIN PGP PUBLIC KEY BLOCK-----\n"
    "synthetic-test-key\n"
    "-----END PGP PUBLIC KEY BLOCK-----"
)


def successful_responses():
    return [
        (200, {"header": {"status": "success"}, "body": "OK"}),
        (
            200,
            {
                "header": {"status": "success"},
                "body": {"fingerprint": FINGERPRINT, "keydata": PUBLIC_KEY},
            },
        ),
    ]


class ProbeFingerprintTests(unittest.TestCase):
    @mock.patch.object(probe, "get_json")
    def test_discovery_returns_fingerprint_without_claiming_a_match(self, get_json):
        get_json.side_effect = successful_responses()

        result = probe.run_probe("https://passbolt.example.test", None, 1.0)

        self.assertEqual(result.fingerprint, FINGERPRINT)
        self.assertIsNone(result.fingerprint_matches_expected)
        self.assertTrue(result.armored_public_key_present)

    @mock.patch.object(probe, "get_json")
    def test_pinned_mode_reports_a_matching_fingerprint(self, get_json):
        get_json.side_effect = successful_responses()

        result = probe.run_probe(
            "https://passbolt.example.test",
            FINGERPRINT,
            1.0,
        )

        self.assertTrue(result.fingerprint_matches_expected)

    @mock.patch.object(probe, "get_json")
    def test_pinned_mode_reports_a_mismatch(self, get_json):
        get_json.side_effect = successful_responses()

        result = probe.run_probe(
            "https://passbolt.example.test",
            "A" * 40,
            1.0,
        )

        self.assertFalse(result.fingerprint_matches_expected)

    def test_cli_requires_an_explicit_fingerprint_mode(self):
        with mock.patch.object(
            sys,
            "argv",
            ["passbolt_api_probe.py", "--base-url", "https://passbolt.example.test"],
        ):
            with redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    probe.parse_args()

    def test_cli_accepts_discovery_mode(self):
        with mock.patch.object(
            sys,
            "argv",
            [
                "passbolt_api_probe.py",
                "--base-url",
                "https://passbolt.example.test",
                "--discover-fingerprint",
            ],
        ):
            args = probe.parse_args()

        self.assertTrue(args.discover_fingerprint)
        self.assertIsNone(args.expected_fingerprint)


if __name__ == "__main__":
    unittest.main()
