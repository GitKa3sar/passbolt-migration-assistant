from __future__ import annotations

import json
import tempfile
import unittest
from dataclasses import asdict
from pathlib import Path
from unittest import mock

from passbolt_review import MAX_SELECTED_FILES, ReviewError, analyze_files


class ReviewTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        (self.root / "Cliente Alfa").mkdir()
        (self.root / "Cliente Beta").mkdir()

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_text_candidate_masks_and_never_serializes_secret(self) -> None:
        source = self.root / "Cliente Alfa" / "portale.txt"
        source.write_text(
            "Titolo: Portale clienti\n"
            "URL: https://example.test\n"
            "Utente: mario.rossi\n"
            "Password: Segreto-Non-Esportare-123\n",
            encoding="utf-8",
        )

        result = analyze_files(self.root, ["Cliente Alfa/portale.txt"])

        self.assertEqual(result.analyzed_files, 1)
        self.assertEqual(result.candidate_count, 1)
        candidate = result.candidates[0]
        self.assertEqual(candidate.status, "ready")
        self.assertEqual(candidate.title, "Portale clienti")
        self.assertEqual(candidate.username, "mario.rossi")
        self.assertEqual(candidate.secret_mask, "********")
        self.assertEqual(candidate.secret_length, len("Segreto-Non-Esportare-123"))
        serialized = json.dumps(asdict(result), ensure_ascii=False)
        self.assertNotIn("Segreto-Non-Esportare-123", serialized)

    def test_incomplete_candidate_is_kept_for_review(self) -> None:
        source = self.root / "Cliente Alfa" / "incompleto.env"
        source.write_text(
            "TITLE=Router\nUSERNAME=admin\nURL=https://router.test\nPASSWORD=\n",
            encoding="utf-8",
        )

        result = analyze_files(self.root, ["Cliente Alfa/incompleto.env"])

        self.assertEqual(result.candidate_count, 1)
        self.assertEqual(result.incomplete_count, 1)
        self.assertFalse(result.candidates[0].secret_present)
        self.assertEqual(result.candidates[0].secret_mask, "")

    def test_prefixed_environment_keys_are_recognized(self) -> None:
        source = self.root / "Cliente Alfa" / ".env"
        source.write_text(
            "DB_USERNAME=db-user\nDB_PASSWORD=db-secret\nDB_HOST=db.internal.test\n",
            encoding="utf-8",
        )

        result = analyze_files(self.root, ["Cliente Alfa/.env"])

        self.assertEqual(result.candidate_count, 1)
        candidate = result.candidates[0]
        self.assertEqual(candidate.username, "db-user")
        self.assertEqual(candidate.uri, "db.internal.test")
        self.assertTrue(candidate.secret_present)
        self.assertNotIn("db-secret", json.dumps(asdict(result)))

    def test_csv_and_nested_json_records(self) -> None:
        csv_source = self.root / "Cliente Alfa" / "credenziali.csv"
        csv_source.write_text(
            "nome,username,password,url\n"
            "CRM,crm-user,crm-secret,https://crm.test\n"
            "NAS,nas-user,nas-secret,https://nas.test\n",
            encoding="utf-8",
        )
        json_source = self.root / "Cliente Beta" / "accessi.json"
        json_source.write_text(
            json.dumps(
                {
                    "gruppo": {
                        "elementi": [
                            {
                                "service": "VPN",
                                "login": "vpn-user",
                                "pass": "vpn-secret",
                                "host": "vpn.test",
                            }
                        ]
                    }
                }
            ),
            encoding="utf-8",
        )

        result = analyze_files(
            self.root,
            ["Cliente Alfa/credenziali.csv", "Cliente Beta/accessi.json"],
        )

        self.assertEqual(result.candidate_count, 3)
        self.assertEqual({item.title for item in result.candidates}, {"CRM", "NAS", "VPN"})
        serialized = json.dumps(asdict(result))
        self.assertNotIn("crm-secret", serialized)
        self.assertNotIn("vpn-secret", serialized)

    def test_xlsx_docx_and_pdf_are_read_locally(self) -> None:
        from docx import Document
        from openpyxl import Workbook
        from reportlab.pdfgen import canvas

        xlsx_path = self.root / "Cliente Alfa" / "foglio.xlsx"
        workbook = Workbook()
        sheet = workbook.active
        sheet.title = "Accessi"
        sheet.append(["Titolo", "Utente", "Password", "URL"])
        sheet.append(["Gestionale", "gest-user", "gest-secret", "https://gest.test"])
        workbook.save(xlsx_path)
        workbook.close()

        docx_path = self.root / "Cliente Beta" / "documento.docx"
        document = Document()
        table = document.add_table(rows=1, cols=4)
        for cell, value in zip(
            table.rows[0].cells,
            ["Nome", "Login", "Password", "Sito"],
        ):
            cell.text = value
        cells = table.add_row().cells
        for cell, value in zip(
            cells,
            ["Extranet", "extra-user", "extra-secret", "https://extra.test"],
        ):
            cell.text = value
        document.save(docx_path)

        pdf_path = self.root / "Cliente Beta" / "scheda.pdf"
        pdf = canvas.Canvas(str(pdf_path))
        pdf.drawString(72, 760, "Titolo: Firewall")
        pdf.drawString(72, 740, "Username: fw-user")
        pdf.drawString(72, 720, "Password: fw-secret")
        pdf.drawString(72, 700, "Host: firewall.test")
        pdf.save()

        result = analyze_files(
            self.root,
            [
                "Cliente Alfa/foglio.xlsx",
                "Cliente Beta/documento.docx",
                "Cliente Beta/scheda.pdf",
            ],
        )

        self.assertEqual(result.analyzed_files, 3)
        self.assertEqual(result.candidate_count, 3)
        self.assertEqual(
            {item.title for item in result.candidates},
            {"Gestionale", "Extranet", "Firewall"},
        )
        serialized = json.dumps(asdict(result))
        for secret in ("gest-secret", "extra-secret", "fw-secret"):
            self.assertNotIn(secret, serialized)

    def test_path_traversal_and_legacy_xls_become_safe_warnings(self) -> None:
        outside = self.root.parent / "outside-review.txt"
        outside.write_text("password=outside-secret", encoding="utf-8")
        legacy = self.root / "Cliente Alfa" / "legacy.xls"
        legacy.write_bytes(b"not-opened")
        try:
            result = analyze_files(
                self.root,
                ["../outside-review.txt", "Cliente Alfa/legacy.xls"],
            )
        finally:
            outside.unlink(missing_ok=True)

        self.assertEqual(result.analyzed_files, 0)
        self.assertEqual(result.candidate_count, 0)
        self.assertEqual(len(result.warnings), 2)
        self.assertFalse(any("outside-secret" in warning for warning in result.warnings))

    def test_file_size_and_selection_limits(self) -> None:
        source = self.root / "Cliente Alfa" / "grande.txt"
        source.write_text("password=secret", encoding="utf-8")

        with mock.patch("passbolt_review.MAX_FILE_BYTES", 1):
            result = analyze_files(self.root, ["Cliente Alfa/grande.txt"])
        self.assertEqual(result.analyzed_files, 0)
        self.assertIn("limite", result.warnings[0])

        with self.assertRaisesRegex(ReviewError, "massimo"):
            analyze_files(
                self.root,
                [f"file-{index}.txt" for index in range(MAX_SELECTED_FILES + 1)],
            )

    def test_xml_dtd_is_rejected_without_entity_expansion(self) -> None:
        source = self.root / "Cliente Alfa" / "malevolo.xml"
        source.write_text(
            '<!DOCTYPE data [<!ENTITY secret "do-not-expand">]>'
            "<data><password>&secret;</password></data>",
            encoding="utf-8",
        )

        result = analyze_files(self.root, ["Cliente Alfa/malevolo.xml"])

        self.assertEqual(result.analyzed_files, 0)
        self.assertEqual(result.candidate_count, 0)
        self.assertIn("DTD", result.warnings[0])


if __name__ == "__main__":
    unittest.main()
