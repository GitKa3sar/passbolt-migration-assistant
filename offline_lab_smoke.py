#!/usr/bin/env python3
"""Run the existing read-only v4/v5 integration matrix against the offline lab."""

from __future__ import annotations

import argparse
import json
import os
import re
import ssl
import urllib.request
from pathlib import Path
from typing import Any

from passbolt_integration_matrix import (
    AUTOMATED_SCENARIOS,
    MANUAL_SCENARIOS,
    InstanceProfile,
    run_instance,
    validate_report_document,
)


APP_VERSION = "0.21.0"
MAX_READY_BYTES = 128 * 1024
LOCAL_URL_PATTERN = re.compile(r"^https://localhost:[1-9][0-9]{0,4}$")


class OfflineLabSmokeError(RuntimeError):
    """Safe smoke-test failure without credential values."""


def load_ready_file(path: str | Path) -> dict[str, Any]:
    ready_path = Path(path).expanduser().resolve()
    try:
        size = ready_path.stat().st_size
    except OSError as exc:
        raise OfflineLabSmokeError("Il file ready del laboratorio non e' disponibile.") from exc
    if size <= 0 or size > MAX_READY_BYTES:
        raise OfflineLabSmokeError("Il file ready del laboratorio non e' valido.")
    try:
        document = json.loads(ready_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise OfflineLabSmokeError("Il file ready non contiene JSON valido.") from exc
    required = {
        "schema_version",
        "app_version",
        "profile",
        "scenario",
        "fault",
        "base_url",
        "server_fingerprint",
        "private_key_path",
        "passphrase",
        "mfa_totp",
        "certificate_path",
        "dataset_root",
        "workspace",
        "lab_token",
        "contains_real_credentials",
    }
    if not isinstance(document, dict) or set(document) != required:
        raise OfflineLabSmokeError("Il file ready ha una struttura inattesa.")
    if document.get("schema_version") != 1 or document.get("contains_real_credentials") is not False:
        raise OfflineLabSmokeError("Il laboratorio non dichiara un'identita' sintetica valida.")
    if document.get("profile") not in {"v4", "v5"}:
        raise OfflineLabSmokeError("Il profilo del laboratorio non e' supportato.")
    if document.get("fault") != "none":
        raise OfflineLabSmokeError("Lo smoke test richiede un laboratorio senza fault injection.")
    if not LOCAL_URL_PATTERN.fullmatch(str(document.get("base_url", ""))):
        raise OfflineLabSmokeError("Il laboratorio non usa un endpoint HTTPS locale valido.")
    fingerprint = str(document.get("server_fingerprint", ""))
    if not re.fullmatch(r"[0-9A-F]{40}", fingerprint):
        raise OfflineLabSmokeError("La fingerprint sintetica del laboratorio non e' valida.")
    if not str(document.get("passphrase", "")).startswith("LAB-ONLY-"):
        raise OfflineLabSmokeError("La passphrase non e' marcata come sintetica.")
    if not re.fullmatch(r"\d{6}", str(document.get("mfa_totp", ""))):
        raise OfflineLabSmokeError("Il TOTP sintetico non e' valido.")
    workspace = Path(str(document["workspace"])).resolve()
    for field in ("private_key_path", "certificate_path", "dataset_root"):
        candidate = Path(str(document[field])).resolve()
        try:
            candidate.relative_to(workspace)
        except ValueError as exc:
            raise OfflineLabSmokeError(
                "Un percorso del laboratorio esce dal workspace temporaneo."
            ) from exc
        if not candidate.exists():
            raise OfflineLabSmokeError("Un file temporaneo del laboratorio non esiste.")
    return document


def read_lab_status(ready: dict[str, Any]) -> dict[str, Any]:
    request = urllib.request.Request(
        f"{ready['base_url']}/__lab/status.json",
        headers={
            "Accept": "application/json",
            "X-Offline-Lab-Token": str(ready["lab_token"]),
        },
    )
    context = ssl.create_default_context(cafile=str(ready["certificate_path"]))
    try:
        with urllib.request.urlopen(request, timeout=15, context=context) as response:
            raw = response.read(256 * 1024)
    except (OSError, TimeoutError) as exc:
        raise OfflineLabSmokeError("Lo stato del laboratorio non e' leggibile.") from exc
    try:
        envelope = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise OfflineLabSmokeError("Lo stato del laboratorio non contiene JSON valido.") from exc
    body = envelope.get("body") if isinstance(envelope, dict) else None
    if not isinstance(body, dict):
        raise OfflineLabSmokeError("Lo stato del laboratorio ha una struttura inattesa.")
    return body


def run_smoke(ready: dict[str, Any]) -> dict[str, Any]:
    profile_name = str(ready["profile"])
    profile = InstanceProfile(
        instance_id=f"offline-{profile_name}",
        enabled=True,
        base_url=str(ready["base_url"]),
        expected_server_fingerprint=str(ready["server_fingerprint"]),
        expected_resource_format=profile_name,
        expected_folder_format=profile_name,
    )
    report = run_instance(
        profile,
        Path(str(ready["private_key_path"])),
        str(ready["passphrase"]),
        str(ready["mfa_totp"]),
    )
    validate_report_document(report)
    automated = report["scenarios"][: len(AUTOMATED_SCENARIOS)]
    manual = report["scenarios"][len(AUTOMATED_SCENARIOS) :]
    failed = [item["name"] for item in automated if item.get("status") != "passed"]
    if failed:
        raise OfflineLabSmokeError(
            "Scenari automatici offline non superati: " + ", ".join(failed)
        )
    if len(manual) != len(MANUAL_SCENARIOS) or any(
        item.get("status") != "not_run" for item in manual
    ):
        raise OfflineLabSmokeError(
            "Gli scenari con scrittura non sono rimasti disabilitati nel smoke test."
        )
    status = read_lab_status(ready)
    if status.get("resource_count") != 0 or status.get("folder_count") != 0:
        raise OfflineLabSmokeError(
            "Il test in sola lettura ha lasciato oggetti nel laboratorio."
        )
    return {
        "app": "Passbolt Migration Assistant Offline Lab",
        "version": APP_VERSION,
        "profile": profile_name,
        "scenario": ready["scenario"],
        "automated_scenarios_passed": len(automated),
        "manual_write_scenarios_executed": 0,
        "remote_resource_count": status["resource_count"],
        "remote_folder_count": status["folder_count"],
        "contains_real_credentials": False,
        "status": "OK",
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Smoke test del laboratorio Passbolt offline.")
    parser.add_argument("--ready-file", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        ready = load_ready_file(args.ready_file)
        os.environ["SSL_CERT_FILE"] = str(ready["certificate_path"])
        os.environ["NODE_EXTRA_CA_CERTS"] = str(ready["certificate_path"])
        result = run_smoke(ready)
    except OfflineLabSmokeError as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
        return 2
    finally:
        if "ready" in locals():
            ready["passphrase"] = ""
            ready["mfa_totp"] = ""
            ready["lab_token"] = ""
    print(json.dumps({"ok": True, "result": result}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
