#!/usr/bin/env python3
"""Build sanitized source feedback and migration receipts.

The module accepts aggregate, allow-listed evidence only. It never receives
credential values, source identifiers, Passbolt identities or remote object
identifiers, and it writes receipts atomically as bounded UTF-8 JSON.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import tempfile
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping


APP_VERSION = "0.29.0-beta.1"
ARTIFACT = "passbolt_migration_receipt"
SOURCE_ARTIFACT = "passbolt_source_feedback"
SCHEMA_VERSION = 1
COMPATIBILITY_PROFILE = "passbolt-v4-v5-resource-preview"
MAX_INPUT_BYTES = 256 * 1024
MAX_RECEIPT_BYTES = 128 * 1024
MAX_ISSUES = 128
MAX_CHECKS = 32
MAX_COUNT = (1 << 63) - 1
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
UUID_PATTERN = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
)
SAFE_EXTENSION_PATTERN = re.compile(r"^\.[a-z0-9]{1,12}$")
UTC_TIMESTAMP_PATTERN = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"
)

DESTINATION_MODES = {"root", "direct_folder", "client_folders", "client_mapping"}
PERMISSION_MODES = {"inherited", "custom"}
PREFLIGHT_STATUSES = {"passed", "warning", "blocked"}
CHECK_STATUSES = {"passed", "warning", "blocked", "not_required"}
PREFLIGHT_CHECK_IDS = {
    "authenticated_identity",
    "csrf_token",
    "resource_format",
    "folder_format",
    "metadata_key",
    "resource_catalog",
    "folder_catalog",
    "permission_directory",
    "destination_access",
    "conflicts",
}

ISSUE_DEFINITIONS: dict[str, tuple[str, str]] = {
    "unsupported_format": (
        "Formato non supportato",
        "Convertire il file in un formato supportato oppure escluderlo consapevolmente.",
    ),
    "legacy_xls_conversion": (
        "Excel legacy da convertire",
        "Salvare una copia in formato XLSX moderno prima della revisione.",
    ),
    "file_link_not_reviewed": (
        "Collegamento a file non revisionabile",
        "Usare un file regolare all'interno della cartella sorgente.",
    ),
    "directory_link_skipped": (
        "Collegamento a cartella escluso",
        "Copiare esplicitamente i documenti nella radice selezionata se devono essere inclusi.",
    ),
    "access_error": (
        "Percorso non accessibile",
        "Verificare autorizzazioni e disponibilita' del supporto, quindi aggiornare l'inventario.",
    ),
    "no_candidate": (
        "Nessuna credenziale riconosciuta",
        "Controllare il profilo di mappatura o il contenuto sorgente.",
    ),
    "unsupported_review_format": (
        "Formato non revisionabile",
        "Convertire il documento in un formato revisionabile.",
    ),
    "file_too_large": (
        "Documento oltre il limite di sicurezza",
        "Ridurre o suddividere il documento prima della revisione.",
    ),
    "password_required": (
        "Password del documento richiesta",
        "Fornire la password soltanto nella finestra di revisione locale.",
    ),
    "password_rejected": (
        "Password del documento non valida",
        "Verificare la password e ripetere la revisione locale.",
    ),
    "reader_unavailable": (
        "Lettore del documento cifrato non disponibile",
        "Installare le dipendenze runtime bloccate e ripetere la revisione.",
    ),
    "source_not_available": (
        "Documento non disponibile o non consentito",
        "Verificare che il file sia regolare, accessibile e ancora dentro la radice sorgente.",
    ),
    "document_unreadable": (
        "Documento non analizzabile",
        "Verificare integrita' e formato del documento prima di riprovare.",
    ),
}

class ReceiptError(ValueError):
    """A safe validation error for a local feedback artifact."""


def _utc_now() -> str:
    return datetime.now(tz=timezone.utc).isoformat(timespec="seconds").replace(
        "+00:00", "Z"
    )


def _canonical_bytes(value: Mapping[str, Any]) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def _digest_document(value: Mapping[str, Any]) -> str:
    return hashlib.sha256(_canonical_bytes(value)).hexdigest()


def _mapping(
    value: object,
    *,
    required: set[str],
    optional: set[str] | None = None,
    label: str,
) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise ReceiptError(f"{label} deve essere un oggetto.")
    keys = set(value)
    allowed = required | (optional or set())
    if keys - allowed:
        raise ReceiptError(f"{label} contiene campi non ammessi.")
    if required - keys:
        raise ReceiptError(f"{label} non contiene tutti i campi richiesti.")
    return value


def _count(value: object, label: str) -> int:
    if type(value) is not int or value < 0 or value > MAX_COUNT:
        raise ReceiptError(f"{label} non e' un conteggio valido.")
    return value


def _enum(value: object, allowed: set[str], label: str) -> str:
    normalized = str(value or "").strip().lower()
    if normalized not in allowed:
        raise ReceiptError(f"{label} non e' valido.")
    return normalized


def _sha256(value: object, label: str) -> str:
    normalized = str(value or "").strip().lower()
    if not SHA256_PATTERN.fullmatch(normalized):
        raise ReceiptError(f"{label} non e' un digest SHA-256 valido.")
    return normalized


def _uuid(value: object, label: str) -> str:
    normalized = str(value or "").strip().lower()
    if not UUID_PATTERN.fullmatch(normalized):
        raise ReceiptError(f"{label} non e' un UUID valido.")
    return normalized


def _safe_extension(value: object) -> str:
    normalized = str(value or "").strip().lower()
    if normalized in {"(senza estensione)", "(altro)", "(non disponibile)"}:
        return normalized
    if not SAFE_EXTENSION_PATTERN.fullmatch(normalized):
        raise ReceiptError("Il formato aggregato non e' valido.")
    return normalized


def _normalize_issues(value: object, label: str) -> list[dict[str, Any]]:
    if not isinstance(value, list) or len(value) > MAX_ISSUES:
        raise ReceiptError(f"{label} non e' un elenco bounded valido.")
    normalized: list[dict[str, Any]] = []
    for item in value:
        raw = _mapping(
            item,
            required={"reason_code", "extension", "count"},
            label=f"{label}.issue",
        )
        reason_code = str(raw["reason_code"] or "").strip().lower()
        if reason_code not in ISSUE_DEFINITIONS:
            raise ReceiptError(f"{label} contiene una motivazione sconosciuta.")
        count = _count(raw["count"], f"{label}.count")
        if count == 0:
            raise ReceiptError(f"{label} contiene una segnalazione vuota.")
        normalized.append(
            {
                "reason_code": reason_code,
                "extension": _safe_extension(raw["extension"]),
                "count": count,
            }
        )
    return normalized


def _group_issues(issues: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[str, Counter[str]] = {}
    for issue in issues:
        grouped.setdefault(issue["reason_code"], Counter())[issue["extension"]] += issue[
            "count"
        ]
    result: list[dict[str, Any]] = []
    for reason_code in sorted(grouped):
        formats = grouped[reason_code]
        label, action = ISSUE_DEFINITIONS[reason_code]
        result.append(
            {
                "reason_code": reason_code,
                "label": label,
                "action": action,
                "count": sum(formats.values()),
                "by_format": [
                    {"format": extension, "count": formats[extension]}
                    for extension in sorted(formats)
                ],
            }
        )
    return result


def build_source_feedback(request: object) -> dict[str, Any]:
    raw = _mapping(
        request,
        required={"command", "inventory", "review"},
        label="Richiesta riepilogo",
    )
    if raw["command"] != "source-summary":
        raise ReceiptError("Il comando del riepilogo non e' valido.")
    inventory = _mapping(
        raw["inventory"],
        required={"supported_files", "ignored_files", "issues"},
        label="Inventario aggregato",
    )
    inventory_issues = _normalize_issues(inventory["issues"], "Inventario aggregato")
    ignored_files = _count(inventory["ignored_files"], "File ignorati")
    if sum(
        item["count"]
        for item in inventory_issues
        if item["reason_code"] == "unsupported_format"
    ) != ignored_files:
        raise ReceiptError("I formati non supportati non coincidono con i file ignorati.")
    coverage: dict[str, Any] = {
        "inventory_supported_files": _count(
            inventory["supported_files"], "File supportati"
        ),
        "inventory_ignored_files": ignored_files,
    }
    review_groups: list[dict[str, Any]] = []
    if raw["review"] is not None:
        review = _mapping(
            raw["review"],
            required={
                "selected_files",
                "analyzed_files",
                "candidate_count",
                "ready_count",
                "incomplete_count",
                "issues",
            },
            label="Revisione aggregata",
        )
        selected_files = _count(review["selected_files"], "File selezionati")
        analyzed_files = _count(review["analyzed_files"], "File analizzati")
        candidate_count = _count(review["candidate_count"], "Candidati")
        ready_count = _count(review["ready_count"], "Candidati pronti")
        incomplete_count = _count(
            review["incomplete_count"], "Candidati incompleti"
        )
        if analyzed_files > selected_files or ready_count + incomplete_count != candidate_count:
            raise ReceiptError("I conteggi della revisione non sono coerenti.")
        coverage.update(
            {
                "review_selected_files": selected_files,
                "review_analyzed_files": analyzed_files,
                "review_candidate_count": candidate_count,
                "review_ready_count": ready_count,
                "review_incomplete_count": incomplete_count,
            }
        )
        review_groups = _group_issues(
            _normalize_issues(review["issues"], "Revisione aggregata")
        )

    inventory_groups = _group_issues(inventory_issues)
    return {
        "schema": SCHEMA_VERSION,
        "artifact": SOURCE_ARTIFACT,
        "generated_at_utc": _utc_now(),
        "coverage": coverage,
        "inventory_groups": inventory_groups,
        "review_groups": review_groups,
        "issue_occurrences": sum(item["count"] for item in inventory_groups)
        + sum(item["count"] for item in review_groups),
        "contains_source_identifiers": False,
    }


PREFLIGHT_EVIDENCE_KEYS = {
    "plan_digest",
    "status",
    "destination_mode",
    "resource_format",
    "folder_format",
    "permission_mode",
    "permission_entry_count",
    "selected_count",
    "create_count",
    "duplicate_count",
    "blocked_count",
    "create_folder_count",
    "create_shared_folder_count",
    "reconcile_shared_folder_count",
    "reuse_folder_count",
    "shared_create_count",
    "encrypted_secret_copy_count",
    "required_client_count",
    "mapped_client_count",
    "checks",
}

MIGRATION_EVIDENCE_KEYS = {
    "plan_digest",
    "destination_mode",
    "resource_format",
    "folder_format",
    "permission_mode",
    "permission_entry_count",
    "selected_count",
    "planned_create_count",
    "created_count",
    "shared_created_count",
    "encrypted_secret_copy_count",
    "skipped_duplicate_count",
    "created_folder_count",
    "shared_created_folder_count",
    "reconciled_shared_folder_count",
    "reused_folder_count",
    "verified_resource_count",
    "verification_failed_count",
    "journal_batch_id",
    "journal_status",
    "complete",
}


def _normalize_common_evidence(
    raw: Mapping[str, Any], *, allow_unavailable: bool = False
) -> dict[str, Any]:
    resource_formats = (
        {"v4", "v5", "unavailable"} if allow_unavailable else {"v4", "v5"}
    )
    folder_formats = (
        {"v4", "not_required", "unavailable"}
        if allow_unavailable
        else {"v4", "not_required"}
    )
    resource_format = _enum(
        raw["resource_format"], resource_formats, "Formato risorse"
    )
    folder_format = _enum(
        raw["folder_format"], folder_formats, "Formato cartelle"
    )
    return {
        "plan_digest": _sha256(raw["plan_digest"], "Digest del piano"),
        "destination": {
            "mode": _enum(raw["destination_mode"], DESTINATION_MODES, "Destinazione")
        },
        "formats": {"resource": resource_format, "folder": folder_format},
        "permissions": {
            "mode": _enum(raw["permission_mode"], PERMISSION_MODES, "Permessi"),
            "explicit_entry_count": _count(
                raw["permission_entry_count"], "Destinatari espliciti"
            ),
        },
    }


def _normalize_preflight_evidence(value: object) -> dict[str, Any]:
    raw = _mapping(
        value,
        required=PREFLIGHT_EVIDENCE_KEYS,
        label="Evidenza preflight",
    )
    normalized = _normalize_common_evidence(raw, allow_unavailable=True)
    checks = raw["checks"]
    if not isinstance(checks, list) or not checks or len(checks) > MAX_CHECKS:
        raise ReceiptError("I controlli preflight non sono un elenco bounded valido.")
    normalized_checks: list[dict[str, str]] = []
    seen: set[str] = set()
    for check in checks:
        item = _mapping(
            check,
            required={"id", "status"},
            label="Controllo preflight",
        )
        check_id = _enum(item["id"], PREFLIGHT_CHECK_IDS, "ID controllo")
        if check_id in seen:
            raise ReceiptError("La ricevuta contiene un controllo preflight duplicato.")
        seen.add(check_id)
        normalized_checks.append(
            {
                "id": check_id,
                "status": _enum(item["status"], CHECK_STATUSES, "Esito controllo"),
            }
        )
    normalized["status"] = _enum(raw["status"], PREFLIGHT_STATUSES, "Preflight")
    normalized["counts"] = {
        key: _count(raw[key], key)
        for key in (
            "selected_count",
            "create_count",
            "duplicate_count",
            "blocked_count",
            "create_folder_count",
            "create_shared_folder_count",
            "reconcile_shared_folder_count",
            "reuse_folder_count",
            "shared_create_count",
            "encrypted_secret_copy_count",
            "required_client_count",
            "mapped_client_count",
        )
    }
    counts = normalized["counts"]
    if (
        counts["create_count"]
        + counts["duplicate_count"]
        + counts["blocked_count"]
        != counts["selected_count"]
        or counts["mapped_client_count"] > counts["required_client_count"]
    ):
        raise ReceiptError("I conteggi del preflight non sono coerenti.")
    derived_status = (
        "blocked"
        if any(item["status"] == "blocked" for item in normalized_checks)
        else (
            "warning"
            if any(item["status"] == "warning" for item in normalized_checks)
            else "passed"
        )
    )
    if normalized["status"] != derived_status:
        raise ReceiptError("Lo stato del preflight non coincide con i controlli.")
    normalized["checks"] = sorted(normalized_checks, key=lambda item: item["id"])
    return normalized


def _normalize_migration_evidence(value: object) -> dict[str, Any]:
    raw = _mapping(
        value,
        required=MIGRATION_EVIDENCE_KEYS,
        label="Evidenza migrazione",
    )
    if raw["complete"] is not True:
        raise ReceiptError("La migrazione non risulta completata.")
    if str(raw["journal_status"] or "").strip().lower() != "complete":
        raise ReceiptError("Il journal della migrazione non risulta chiuso.")
    verification_failed = _count(
        raw["verification_failed_count"], "Verifiche non conformi"
    )
    if verification_failed != 0:
        raise ReceiptError("La migrazione contiene verifiche non conformi.")
    normalized = _normalize_common_evidence(raw)
    counts = {
        key: _count(raw[key], key)
        for key in (
            "selected_count",
            "planned_create_count",
            "created_count",
            "shared_created_count",
            "encrypted_secret_copy_count",
            "skipped_duplicate_count",
            "created_folder_count",
            "shared_created_folder_count",
            "reconciled_shared_folder_count",
            "reused_folder_count",
            "verified_resource_count",
            "verification_failed_count",
        )
    }
    if counts["created_count"] != counts["planned_create_count"]:
        raise ReceiptError("Le risorse create non coincidono con il piano confermato.")
    if counts["verified_resource_count"] != counts["created_count"]:
        raise ReceiptError("Le risorse create non risultano tutte verificate.")
    if (
        counts["planned_create_count"] + counts["skipped_duplicate_count"]
        != counts["selected_count"]
        or counts["shared_created_count"] > counts["created_count"]
    ):
        raise ReceiptError("I conteggi della migrazione non sono coerenti.")
    normalized.update(
        {
            "status": "verified",
            "counts": counts,
            "journal": {
                "batch_id": _uuid(raw["journal_batch_id"], "UUID del journal"),
                "status": "complete",
            },
        }
    )
    return normalized


def build_receipt(receipt_type: object, evidence: object) -> dict[str, Any]:
    normalized_type = _enum(
        receipt_type, {"preflight", "migration"}, "Tipo ricevuta"
    )
    normalized = (
        _normalize_preflight_evidence(evidence)
        if normalized_type == "preflight"
        else _normalize_migration_evidence(evidence)
    )
    document: dict[str, Any] = {
        "schema": SCHEMA_VERSION,
        "artifact": ARTIFACT,
        "receipt_type": normalized_type,
        "app_version": APP_VERSION,
        "compatibility_profile": COMPATIBILITY_PROFILE,
        "generated_at_utc": _utc_now(),
        **normalized,
    }
    document["receipt_digest"] = _digest_document(document)
    validate_receipt(document)
    return document


def validate_receipt(value: object) -> dict[str, Any]:
    raw = _mapping(
        value,
        required={
            "schema",
            "artifact",
            "receipt_type",
            "app_version",
            "compatibility_profile",
            "generated_at_utc",
            "plan_digest",
            "destination",
            "formats",
            "permissions",
            "status",
            "counts",
            "receipt_digest",
        },
        optional={"checks", "journal"},
        label="Ricevuta",
    )
    if raw["schema"] != SCHEMA_VERSION or raw["artifact"] != ARTIFACT:
        raise ReceiptError("Schema della ricevuta non supportato.")
    if raw["app_version"] != APP_VERSION:
        raise ReceiptError("Versione applicativa della ricevuta non valida.")
    if raw["compatibility_profile"] != COMPATIBILITY_PROFILE:
        raise ReceiptError("Profilo di compatibilita' della ricevuta non valido.")
    generated_at_utc = str(raw["generated_at_utc"] or "")
    if not UTC_TIMESTAMP_PATTERN.fullmatch(generated_at_utc):
        raise ReceiptError("Timestamp UTC della ricevuta non valido.")
    try:
        datetime.strptime(generated_at_utc, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError as exc:
        raise ReceiptError("Timestamp UTC della ricevuta non valido.") from exc
    receipt_type = _enum(
        raw["receipt_type"], {"preflight", "migration"}, "Tipo ricevuta"
    )
    expected_optional = "checks" if receipt_type == "preflight" else "journal"
    unexpected_optional = "journal" if receipt_type == "preflight" else "checks"
    if expected_optional not in raw or unexpected_optional in raw:
        raise ReceiptError("La struttura della ricevuta non corrisponde al tipo.")
    _sha256(raw["plan_digest"], "Digest del piano")
    _mapping(raw["destination"], required={"mode"}, label="Destinazione")
    _enum(raw["destination"]["mode"], DESTINATION_MODES, "Destinazione")
    formats = _mapping(
        raw["formats"], required={"resource", "folder"}, label="Formati"
    )
    resource_formats = (
        {"v4", "v5", "unavailable"}
        if receipt_type == "preflight"
        else {"v4", "v5"}
    )
    folder_formats = (
        {"v4", "not_required", "unavailable"}
        if receipt_type == "preflight"
        else {"v4", "not_required"}
    )
    _enum(formats["resource"], resource_formats, "Formato risorse")
    _enum(formats["folder"], folder_formats, "Formato cartelle")
    permissions = _mapping(
        raw["permissions"],
        required={"mode", "explicit_entry_count"},
        label="Permessi",
    )
    _enum(permissions["mode"], PERMISSION_MODES, "Permessi")
    _count(permissions["explicit_entry_count"], "Destinatari espliciti")
    if not isinstance(raw["counts"], Mapping):
        raise ReceiptError("I conteggi della ricevuta non sono validi.")
    expected_count_keys = (
        {
            "selected_count",
            "create_count",
            "duplicate_count",
            "blocked_count",
            "create_folder_count",
            "create_shared_folder_count",
            "reconcile_shared_folder_count",
            "reuse_folder_count",
            "shared_create_count",
            "encrypted_secret_copy_count",
            "required_client_count",
            "mapped_client_count",
        }
        if receipt_type == "preflight"
        else {
            "selected_count",
            "planned_create_count",
            "created_count",
            "shared_created_count",
            "encrypted_secret_copy_count",
            "skipped_duplicate_count",
            "created_folder_count",
            "shared_created_folder_count",
            "reconciled_shared_folder_count",
            "reused_folder_count",
            "verified_resource_count",
            "verification_failed_count",
        }
    )
    if set(raw["counts"]) != expected_count_keys:
        raise ReceiptError("Lo schema dei conteggi della ricevuta non e' chiuso.")
    for key, count in raw["counts"].items():
        if not isinstance(key, str):
            raise ReceiptError("Un conteggio della ricevuta non e' valido.")
        _count(count, key)
    if receipt_type == "preflight":
        preflight_status = _enum(raw["status"], PREFLIGHT_STATUSES, "Preflight")
        if (
            not isinstance(raw["checks"], list)
            or not raw["checks"]
            or len(raw["checks"]) > MAX_CHECKS
        ):
            raise ReceiptError("I controlli della ricevuta non sono validi.")
        seen_checks: set[str] = set()
        check_statuses: list[str] = []
        for check in raw["checks"]:
            item = _mapping(
                check, required={"id", "status"}, label="Controllo preflight"
            )
            check_id = _enum(item["id"], PREFLIGHT_CHECK_IDS, "ID controllo")
            if check_id in seen_checks:
                raise ReceiptError("La ricevuta contiene controlli duplicati.")
            seen_checks.add(check_id)
            check_statuses.append(
                _enum(item["status"], CHECK_STATUSES, "Esito controllo")
            )
        if (
            raw["counts"]["create_count"]
            + raw["counts"]["duplicate_count"]
            + raw["counts"]["blocked_count"]
            != raw["counts"]["selected_count"]
            or raw["counts"]["mapped_client_count"]
            > raw["counts"]["required_client_count"]
        ):
            raise ReceiptError("I conteggi del preflight non sono coerenti.")
        derived_status = (
            "blocked"
            if "blocked" in check_statuses
            else ("warning" if "warning" in check_statuses else "passed")
        )
        if preflight_status != derived_status:
            raise ReceiptError("Lo stato del preflight non coincide con i controlli.")
    else:
        if raw["status"] != "verified":
            raise ReceiptError("La ricevuta finale non attesta una verifica completa.")
        journal = _mapping(
            raw["journal"], required={"batch_id", "status"}, label="Journal"
        )
        _uuid(journal["batch_id"], "UUID del journal")
        if journal["status"] != "complete":
            raise ReceiptError("Il journal della ricevuta non e' completo.")
        if (
            raw["counts"]["verification_failed_count"] != 0
            or raw["counts"]["created_count"]
            != raw["counts"]["planned_create_count"]
            or raw["counts"]["verified_resource_count"]
            != raw["counts"]["created_count"]
            or raw["counts"]["planned_create_count"]
            + raw["counts"]["skipped_duplicate_count"]
            != raw["counts"]["selected_count"]
            or raw["counts"]["shared_created_count"]
            > raw["counts"]["created_count"]
        ):
            raise ReceiptError("I conteggi della migrazione non sono coerenti.")
    supplied_digest = _sha256(raw["receipt_digest"], "Digest della ricevuta")
    without_digest = dict(raw)
    without_digest.pop("receipt_digest", None)
    if supplied_digest != _digest_document(without_digest):
        raise ReceiptError("Il digest della ricevuta non corrisponde al contenuto.")
    encoded = _canonical_bytes(raw)
    if len(encoded) > MAX_RECEIPT_BYTES:
        raise ReceiptError("La ricevuta supera il limite consentito.")
    return dict(raw)


def write_receipt(value: object, destination: object) -> dict[str, Any]:
    document = validate_receipt(value)
    destination_text = str(destination or "").strip()
    if not destination_text:
        raise ReceiptError("La destinazione della ricevuta non e' stata indicata.")
    destination_path = Path(destination_text).expanduser().resolve()
    if destination_path.suffix.lower() != ".json":
        raise ReceiptError("La ricevuta deve usare l'estensione .json.")
    if not destination_path.parent.is_dir():
        raise ReceiptError("La cartella di destinazione non esiste.")
    encoded = (
        json.dumps(document, indent=2, ensure_ascii=False, sort_keys=True) + "\n"
    ).encode("utf-8")
    if len(encoded) > MAX_RECEIPT_BYTES:
        raise ReceiptError("La ricevuta supera il limite consentito.")
    temporary_path: Path | None = None
    try:
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{destination_path.name}.",
            suffix=".tmp",
            dir=destination_path.parent,
        )
        temporary_path = Path(temporary_name)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_path, destination_path)
        temporary_path = None
    finally:
        if temporary_path is not None:
            try:
                temporary_path.unlink()
            except OSError:
                pass
    return {
        "receipt_type": document["receipt_type"],
        "receipt_digest": document["receipt_digest"],
        "bytes_written": len(encoded),
        "written": True,
    }


def dispatch_request(value: object) -> dict[str, Any]:
    raw = _mapping(
        value,
        required={"command"},
        optional={"inventory", "review", "receipt_type", "evidence", "destination"},
        label="Richiesta",
    )
    command = str(raw["command"] or "").strip().lower()
    if command == "source-summary":
        return build_source_feedback(raw)
    if command == "build-receipt":
        exact = _mapping(
            raw,
            required={"command", "receipt_type", "evidence"},
            label="Richiesta ricevuta",
        )
        return build_receipt(exact["receipt_type"], exact["evidence"])
    if command == "write-receipt":
        exact = _mapping(
            raw,
            required={"command", "receipt_type", "evidence", "destination"},
            label="Richiesta esportazione",
        )
        receipt = build_receipt(exact["receipt_type"], exact["evidence"])
        return write_receipt(receipt, exact["destination"])
    raise ReceiptError("Comando ricevuta non supportato.")


def _read_request() -> object:
    raw = os.read(0, MAX_INPUT_BYTES + 1)
    if len(raw) > MAX_INPUT_BYTES:
        raise ReceiptError("La richiesta supera il limite consentito.")
    try:
        return json.loads(raw.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ReceiptError("La richiesta non contiene JSON valido.") from exc


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Ricevute sanificate Passbolt")
    parser.add_argument("--secure-json", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        print(
            json.dumps(
                {
                    "ok": True,
                    "result": {
                        "schema": SCHEMA_VERSION,
                        "compatibility_profile": COMPATIBILITY_PROFILE,
                        "closed_schema": True,
                        "atomic_write": True,
                    },
                },
                ensure_ascii=False,
            )
        )
        return 0
    if not args.secure_json:
        print(
            json.dumps(
                {
                    "ok": False,
                    "error": {
                        "code": "RECEIPT_COMMAND_REQUIRED",
                        "message": "Usare --secure-json per una richiesta locale bounded.",
                    },
                },
                ensure_ascii=False,
            )
        )
        return 2
    try:
        result = dispatch_request(_read_request())
    except (OSError, ReceiptError) as exc:
        print(
            json.dumps(
                {
                    "ok": False,
                    "error": {
                        "code": "RECEIPT_REJECTED",
                        "message": str(exc),
                    },
                },
                ensure_ascii=False,
            )
        )
        return 2
    print(json.dumps({"ok": True, "result": result}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
