from __future__ import annotations

import builtins
import csv
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from passbolt_app import ROOT_CLIENT_LABEL, build_inventory, human_size, write_inventory_csv


class InventoryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        (self.root / "Cliente Alfa" / "server").mkdir(parents=True)
        (self.root / "Cliente Beta").mkdir()
        (self.root / "Cliente Alfa" / "note.txt").write_bytes(b"12345")
        (self.root / "Cliente Alfa" / "server" / "accessi.xlsx").write_bytes(b"1234567")
        (self.root / "Cliente Beta" / "config.env").write_bytes(b"abc")
        (self.root / "Cliente Beta" / ".env").write_bytes(b"xy")
        (self.root / "Cliente Beta" / "programma.exe").write_bytes(b"ignored")
        (self.root / "riepilogo.json").write_bytes(b"{}")

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_inventory_collects_only_supported_metadata(self) -> None:
        result = build_inventory(self.root)

        self.assertEqual(result.client_folders, 2)
        self.assertEqual(result.supported_files, 5)
        self.assertEqual(result.ignored_files, 1)
        self.assertEqual(result.supported_bytes, 19)
        self.assertEqual(result.by_extension, {".env": 2, ".json": 1, ".txt": 1, ".xlsx": 1})
        self.assertEqual(result.by_category["Configurazione"], 3)
        self.assertEqual(result.by_client["Cliente Alfa"], 2)
        self.assertEqual(result.by_client["Cliente Beta"], 2)
        self.assertEqual(result.by_client[ROOT_CLIENT_LABEL], 1)
        self.assertEqual(
            {item.relative_path for item in result.items},
            {
                "Cliente Alfa/note.txt",
                "Cliente Alfa/server/accessi.xlsx",
                "Cliente Beta/.env",
                "Cliente Beta/config.env",
                "riepilogo.json",
            },
        )
        self.assertTrue(all(item.modified_utc and item.modified_utc.endswith("Z") for item in result.items))
        self.assertEqual(
            [(item.reason_code, item.extension, item.count) for item in result.issues],
            [("unsupported_format", ".exe", 1)],
        )

    def test_inventory_feedback_is_aggregate_and_marks_legacy_excel(self) -> None:
        (self.root / "Cliente Alfa" / "legacy.xls").write_bytes(b"legacy")
        (self.root / "Cliente Beta" / "backup.private-customer-name").write_bytes(
            b"ignored"
        )

        result = build_inventory(self.root)

        issues = {
            (item.reason_code, item.extension): item.count for item in result.issues
        }
        self.assertEqual(issues[("legacy_xls_conversion", ".xls")], 1)
        self.assertEqual(issues[("unsupported_format", "(altro)")], 1)
        self.assertNotIn("private-customer-name", repr(result.issues))

    def test_inventory_does_not_open_document_content(self) -> None:
        original_open = builtins.open

        def reject_document_open(file, *args, **kwargs):
            try:
                candidate = Path(file)
            except TypeError:
                return original_open(file, *args, **kwargs)
            if candidate.suffix.lower() in {".txt", ".xlsx", ".env", ".json", ".exe"}:
                raise AssertionError(f"Il contenuto non deve essere aperto: {candidate}")
            return original_open(file, *args, **kwargs)

        with mock.patch("builtins.open", side_effect=reject_document_open):
            result = build_inventory(self.root)

        self.assertEqual(result.supported_files, 5)

    def test_csv_export_is_utf8_and_neutralizes_formula_names(self) -> None:
        dangerous = self.root / "Cliente Beta" / "=avvio.txt"
        dangerous.write_bytes(b"x")
        destination = self.root / "report.csv"

        result = build_inventory(self.root)
        exported = write_inventory_csv(result, destination)

        self.assertEqual(exported, destination.resolve())
        with destination.open("r", encoding="utf-8-sig", newline="") as stream:
            rows = list(csv.DictReader(stream))
        dangerous_row = next(row for row in rows if row["Nome file"].endswith("avvio.txt"))
        self.assertEqual(dangerous_row["Nome file"], "'=avvio.txt")
        self.assertEqual(dangerous_row["Cliente"], "Cliente Beta")
        self.assertEqual(dangerous_row["Collegamento"], "no")

    def test_missing_root_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "non esiste"):
            build_inventory(self.root / "cartella-assente")

    def test_empty_root_produces_an_empty_inventory(self) -> None:
        empty_root = self.root / "vuota"
        empty_root.mkdir()

        result = build_inventory(empty_root)

        self.assertEqual(result.client_folders, 0)
        self.assertEqual(result.supported_files, 0)
        self.assertEqual(result.items, [])
        self.assertEqual(result.by_client, {})

    def test_human_size_boundaries(self) -> None:
        self.assertEqual(human_size(0), "0 B")
        self.assertEqual(human_size(1023), "1023 B")
        self.assertEqual(human_size(1024), "1.0 KB")


if __name__ == "__main__":
    unittest.main()
