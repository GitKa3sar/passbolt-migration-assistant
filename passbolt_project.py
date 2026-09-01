#!/usr/bin/env python3
"""Strict, secret-free contracts for DPAPI-protected local preparation projects.

The Windows WPF application performs DPAPI encryption and atomic file writes.
This module owns the canonical payload and envelope schemas so a restored
project cannot silently introduce session state, credentials or trusted pins.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import re
import sys
import urllib.parse
from datetime import datetime, timezone
from pathlib import PurePosixPath, PureWindowsPath
from typing import Mapping

from passbolt_api_probe import ProbeError, normalize_base_url
from passbolt_review import ReviewError, normalize_source_mapping_profile


APP_VERSION = "0.29.0-beta.1"
PROJECT_SCHEMA_VERSION = 1
PROJECT_KIND = "passbolt-migration-preparation"
PROJECT_ENVELOPE_KIND = "passbolt-migration-project"
PROJECT_PROTECTION = "windows-dpapi-current-user"
MAX_SECURE_STDIN_BYTES = 64 * 1024 * 1024
MAX_PROJECT_PAYLOAD_BYTES = 16 * 1024 * 1024
MAX_PROJECT_CIPHERTEXT_BYTES = MAX_PROJECT_PAYLOAD_BYTES + 64 * 1024
MAX_SERVER_ORIGIN_CHARACTERS = 2_048
MAX_SOURCE_ROOT_CHARACTERS = 32_767
MAX_RELATIVE_PATH_CHARACTERS = 32_767
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
CONTROL_PATTERN = re.compile(r"[\x00-\x1f\x7f]")


class ProjectError(RuntimeError):
    """A bounded, user-facing local project validation error."""


def _canonical_bytes(value: object) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")


def _sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _utc_timestamp(value: object, field_name: str) -> str:
    text = str(value or "").strip()
    if not text or len(text) > 40 or not text.endswith("Z"):
        raise ProjectError(f"Il campo {field_name} non contiene un timestamp UTC valido.")
    try:
        parsed = datetime.fromisoformat(text[:-1] + "+00:00")
    except ValueError as exc:
        raise ProjectError(
            f"Il campo {field_name} non contiene un timestamp UTC valido."
        ) from exc
    if parsed.utcoffset() != timezone.utc.utcoffset(parsed):
        raise ProjectError(f"Il campo {field_name} deve essere espresso in UTC.")
    return parsed.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _normalized_server_origin(value: object) -> str:
    text = str(value or "").strip()
    if not text or len(text) > MAX_SERVER_ORIGIN_CHARACTERS:
        raise ProjectError("L'origine Passbolt del progetto non è valida.")
    parsed = urllib.parse.urlsplit(text)
    if parsed.username is not None or parsed.password is not None:
        raise ProjectError("L'origine Passbolt non può contenere credenziali.")
    try:
        return normalize_base_url(text)
    except ProbeError as exc:
        raise ProjectError(str(exc)) from exc


def _normalized_source_root(value: object) -> str:
    text = str(value or "").strip()
    if (
        not text
        or len(text) > MAX_SOURCE_ROOT_CHARACTERS
        or CONTROL_PATTERN.search(text)
    ):
        raise ProjectError("La cartella sorgente del progetto non è valida.")
    windows_path = PureWindowsPath(text)
    posix_path = PurePosixPath(text)
    if not windows_path.is_absolute() and not posix_path.is_absolute():
        raise ProjectError("La cartella sorgente del progetto deve essere assoluta.")
    return text


def _normalized_relative_path(value: object) -> str:
    if not isinstance(value, str):
        raise ProjectError("Un percorso selezionato nel progetto non è una stringa.")
    text = value.strip().replace("\\", "/")
    if (
        not text
        or len(text) > MAX_RELATIVE_PATH_CHARACTERS
        or CONTROL_PATTERN.search(text)
        or ":" in text
    ):
        raise ProjectError("Un percorso relativo selezionato non è valido.")
    path = PurePosixPath(text)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        raise ProjectError("Un percorso selezionato esce dalla cartella sorgente.")
    canonical = path.as_posix()
    if canonical in {"", "."}:
        raise ProjectError("Un percorso relativo selezionato non è valido.")
    return canonical


def _normalized_selected_files(value: object) -> list[str]:
    if not isinstance(value, list):
        raise ProjectError("La selezione dei file del progetto deve essere una lista.")
    result: list[str] = []
    seen: set[str] = set()
    for item in value:
        normalized = _normalized_relative_path(item)
        identity = normalized.casefold()
        if identity in seen:
            raise ProjectError("La selezione del progetto contiene percorsi duplicati.")
        seen.add(identity)
        result.append(normalized)
    return sorted(result, key=lambda item: (item.casefold(), item))


def _normalized_candidate_selections(value: object) -> list[dict[str, str]]:
    if not isinstance(value, list):
        raise ProjectError("La selezione dei candidati del progetto deve essere una lista.")
    result: list[dict[str, str]] = []
    seen: set[str] = set()
    for item in value:
        if not isinstance(item, Mapping) or set(item) != {
            "candidate_id",
            "source_sha256",
        }:
            raise ProjectError("Una selezione candidato del progetto non è valida.")
        candidate_id = str(item.get("candidate_id", "")).strip().lower()
        source_sha256 = str(item.get("source_sha256", "")).strip().lower()
        if not SHA256_PATTERN.fullmatch(candidate_id) or not SHA256_PATTERN.fullmatch(
            source_sha256
        ):
            raise ProjectError("Una prova tecnica del candidato non è un SHA-256 valido.")
        if candidate_id in seen:
            raise ProjectError("La selezione del progetto contiene candidati duplicati.")
        seen.add(candidate_id)
        result.append(
            {"candidate_id": candidate_id, "source_sha256": source_sha256}
        )
    return sorted(result, key=lambda item: item["candidate_id"])


def normalize_project(value: object) -> dict[str, object]:
    """Validate and canonicalize the decrypted, secret-free project payload."""

    if not isinstance(value, Mapping):
        raise ProjectError("Il progetto locale deve essere un oggetto JSON.")
    allowed_keys = {
        "schema_version",
        "kind",
        "app_version",
        "saved_at_utc",
        "server_origin",
        "source_root",
        "source_mapping_profile",
        "selected_files",
        "selected_candidates",
        "digest",
    }
    if set(value) - allowed_keys:
        raise ProjectError("Il progetto locale contiene campi non riconosciuti.")
    required_keys = allowed_keys - {"digest"}
    if not required_keys.issubset(value):
        raise ProjectError("Il progetto locale non contiene tutti i campi obbligatori.")
    if value.get("schema_version") != PROJECT_SCHEMA_VERSION:
        raise ProjectError("La versione del progetto locale non è supportata.")
    if value.get("kind") != PROJECT_KIND:
        raise ProjectError("Il tipo del progetto locale non è riconosciuto.")

    app_version = str(value.get("app_version", "")).strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?", app_version):
        raise ProjectError("La versione applicativa del progetto non è valida.")
    profile_value = value.get("source_mapping_profile")
    try:
        profile = normalize_source_mapping_profile(profile_value)
    except ReviewError as exc:
        raise ProjectError(str(exc)) from exc

    body: dict[str, object] = {
        "schema_version": PROJECT_SCHEMA_VERSION,
        "kind": PROJECT_KIND,
        "app_version": app_version,
        "saved_at_utc": _utc_timestamp(value.get("saved_at_utc"), "saved_at_utc"),
        "server_origin": _normalized_server_origin(value.get("server_origin")),
        "source_root": _normalized_source_root(value.get("source_root")),
        "source_mapping_profile": profile.document() if profile is not None else None,
        "selected_files": _normalized_selected_files(value.get("selected_files")),
        "selected_candidates": _normalized_candidate_selections(
            value.get("selected_candidates")
        ),
    }
    encoded = _canonical_bytes(body)
    if len(encoded) > MAX_PROJECT_PAYLOAD_BYTES:
        raise ProjectError("Il progetto locale supera il limite di sicurezza in byte.")
    digest = _sha256(encoded)
    supplied_digest = str(value.get("digest", "")).strip().lower()
    if supplied_digest and supplied_digest != digest:
        raise ProjectError("Il digest del progetto locale non corrisponde al contenuto.")
    return {**body, "digest": digest}


def create_envelope(value: object) -> dict[str, object]:
    """Validate DPAPI ciphertext and create the strict on-disk envelope."""

    if not isinstance(value, Mapping) or set(value) != {"ciphertext", "saved_at_utc"}:
        raise ProjectError("La richiesta di protezione del progetto non è valida.")
    ciphertext = str(value.get("ciphertext", "")).strip()
    if not ciphertext:
        raise ProjectError("Il progetto protetto è vuoto.")
    try:
        raw = base64.b64decode(ciphertext, validate=True)
    except (ValueError, binascii.Error) as exc:
        raise ProjectError("Il progetto protetto non usa Base64 valido.") from exc
    if not raw or len(raw) > MAX_PROJECT_CIPHERTEXT_BYTES:
        raise ProjectError("Il progetto protetto supera il limite di sicurezza in byte.")
    return {
        "schema_version": PROJECT_SCHEMA_VERSION,
        "kind": PROJECT_ENVELOPE_KIND,
        "protection": PROJECT_PROTECTION,
        "saved_at_utc": _utc_timestamp(value.get("saved_at_utc"), "saved_at_utc"),
        "ciphertext": ciphertext,
        "ciphertext_sha256": _sha256(raw),
    }


def open_envelope(value: object) -> dict[str, str]:
    """Validate an on-disk envelope before the WPF layer invokes DPAPI."""

    if not isinstance(value, Mapping) or set(value) != {
        "schema_version",
        "kind",
        "protection",
        "saved_at_utc",
        "ciphertext",
        "ciphertext_sha256",
    }:
        raise ProjectError("Il file progetto contiene campi mancanti o non riconosciuti.")
    if value.get("schema_version") != PROJECT_SCHEMA_VERSION:
        raise ProjectError("La versione del file progetto non è supportata.")
    if value.get("kind") != PROJECT_ENVELOPE_KIND:
        raise ProjectError("Il file selezionato non è un progetto Passbolt Migration Assistant.")
    if value.get("protection") != PROJECT_PROTECTION:
        raise ProjectError("Il metodo di protezione del progetto non è supportato.")
    _utc_timestamp(value.get("saved_at_utc"), "saved_at_utc")
    ciphertext = str(value.get("ciphertext", "")).strip()
    try:
        raw = base64.b64decode(ciphertext, validate=True)
    except (ValueError, binascii.Error) as exc:
        raise ProjectError("Il contenuto protetto del progetto non usa Base64 valido.") from exc
    if not raw or len(raw) > MAX_PROJECT_CIPHERTEXT_BYTES:
        raise ProjectError("Il progetto protetto supera il limite di sicurezza in byte.")
    expected = str(value.get("ciphertext_sha256", "")).strip().lower()
    if not SHA256_PATTERN.fullmatch(expected) or expected != _sha256(raw):
        raise ProjectError("Il digest del file progetto non corrisponde al contenuto protetto.")
    return {"ciphertext": ciphertext}


def _read_secure_request() -> object:
    raw = sys.stdin.buffer.read(MAX_SECURE_STDIN_BYTES + 1)
    if len(raw) > MAX_SECURE_STDIN_BYTES:
        raise ProjectError("La richiesta locale supera il limite di sicurezza in byte.")
    try:
        return json.loads(raw.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProjectError("La richiesta locale non contiene JSON UTF-8 valido.") from exc


def _strict_json_text(value: object, label: str) -> object:
    if not isinstance(value, str):
        raise ProjectError(f"{label} non contiene JSON testuale valido.")
    encoded = value.encode("utf-8")
    if len(encoded) > MAX_PROJECT_CIPHERTEXT_BYTES * 2:
        raise ProjectError(f"{label} supera il limite di sicurezza in byte.")

    def reject_duplicates(pairs: list[tuple[str, object]]) -> dict[str, object]:
        document: dict[str, object] = {}
        for key, item in pairs:
            if key in document:
                raise ProjectError(f"{label} contiene proprietà JSON duplicate.")
            document[key] = item
        return document

    try:
        return json.loads(value, object_pairs_hook=reject_duplicates)
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise ProjectError(f"{label} non contiene JSON valido.") from exc


def _handle_secure_request(request: object) -> dict[str, object]:
    if not isinstance(request, Mapping):
        raise ProjectError("La richiesta locale deve essere un oggetto JSON.")
    command = request.get("command")
    if command == "normalize-project" and set(request) == {"command", "project"}:
        return {"project": normalize_project(request.get("project"))}
    if command == "normalize-project-json" and set(request) == {
        "command",
        "project_json",
    }:
        return {
            "project": normalize_project(
                _strict_json_text(request.get("project_json"), "Il progetto decifrato")
            )
        }
    if command == "create-envelope" and set(request) == {
        "command",
        "ciphertext",
        "saved_at_utc",
    }:
        return {
            "envelope": create_envelope(
                {
                    "ciphertext": request.get("ciphertext"),
                    "saved_at_utc": request.get("saved_at_utc"),
                }
            )
        }
    if command == "open-envelope" and set(request) == {"command", "envelope"}:
        return open_envelope(request.get("envelope"))
    if command == "open-envelope-json" and set(request) == {
        "command",
        "envelope_json",
    }:
        return open_envelope(
            _strict_json_text(request.get("envelope_json"), "Il file progetto")
        )
    if command == "self-test" and set(request) == {"command"}:
        return {
            "local_project_schema": PROJECT_SCHEMA_VERSION,
            "dpapi_current_user_required": True,
            "secret_fields_serialized": False,
            "trusted_fingerprint_persisted": False,
            "session_state_persisted": False,
            "strict_envelope": True,
        }
    raise ProjectError("Il comando locale per i progetti non è riconosciuto.")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Contratti locali per progetti protetti di preparazione Passbolt."
    )
    parser.add_argument("--secure-json", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        print(
            json.dumps(
                {
                    "app": "Passbolt Migration Assistant local projects",
                    "version": APP_VERSION,
                    "schema_version": PROJECT_SCHEMA_VERSION,
                    "dpapi_current_user_required": True,
                    "secret_fields_serialized": False,
                    "trusted_fingerprint_persisted": False,
                    "session_state_persisted": False,
                    "strict_envelope": True,
                },
                ensure_ascii=False,
            )
        )
        return 0
    if not args.secure_json:
        print("Usare --secure-json oppure --self-test.", file=sys.stderr)
        return 2
    try:
        result = _handle_secure_request(_read_secure_request())
        print(json.dumps({"ok": True, "result": result}, ensure_ascii=False))
        return 0
    except ProjectError as exc:
        print(
            json.dumps(
                {
                    "ok": False,
                    "error": {"code": "LOCAL_PROJECT_INVALID", "message": str(exc)},
                },
                ensure_ascii=False,
            )
        )
        return 0
    except (RecursionError, TypeError, ValueError, OverflowError):
        print(
            json.dumps(
                {
                    "ok": False,
                    "error": {
                        "code": "LOCAL_PROJECT_INVALID",
                        "message": "Il progetto locale non rispetta il formato previsto.",
                    },
                },
                ensure_ascii=False,
            )
        )
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
