#!/usr/bin/env python3
"""Integrity gate and in-memory secret handoff for Passbolt imports.

Reviewed candidates contain no cleartext secrets. Immediately before a dry-run
or write, this module re-opens only the reviewed source files, verifies their
SHA-256 digests, reconstructs the selected candidate records, and (for a write)
passes the secrets directly to the local OpenPGP bridge over stdin. During a
persistent import it also consumes secret-free progress envelopes and commits
them to a reconciliation journal before returning the single final response.
Cleartext is returned to the desktop UI only by the explicit ``--reveal`` action.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping

from passbolt_reconciliation import (
    acquire_journal_lease,
    archive_reconciliation_batch,
    build_recovery_state,
    CandidateProof,
    describe_reconciliation_batch,
    list_reconciliation_batches,
    ReconciliationJournal,
    ReconciliationJournalCorrupt,
    ReconciliationJournalError,
    ReconciliationJournalLease,
    hash_client_destination_mapping,
    hash_permission_configuration,
    hash_user_identifier,
    read_batch,
)
from passbolt_acl_reconciliation import (
    AclReconciliationJournal,
    acquire_acl_journal_lease,
    archive_acl_batch,
    build_acl_recovery_state,
    describe_acl_batch,
    list_acl_batches,
    read_acl_batch,
)

from passbolt_review import (
    MAX_FILE_BYTES,
    MAX_OFFICE_PASSWORD_CHARACTERS,
    REVIEWABLE_EXTENSIONS,
    SECRET_KEYS,
    ReviewError,
    _find_field,
    _is_ole_compound_file,
    _make_candidate,
    _normalized_supplied_path,
    _records_for_file,
    _safe_selected_path,
    _sha256,
)


APP_VERSION = "0.25.0"
MAX_SECRET_CHARACTERS = 65_536
MAX_STDIN_BYTES = 64 * 1024 * 1024
MAX_BRIDGE_OUTPUT_BYTES = 64 * 1024 * 1024
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")


class ImportPreparationError(RuntimeError):
    """A safe error that never includes an extracted secret."""


@dataclass(frozen=True)
class SelectedCandidate:
    candidate_id: str
    source_relative_path: str
    source_sha256: str
    client: str
    source_at_root: bool
    title: str
    username: str
    uri: str
    reviewed_client: str
    reviewed_source_at_root: bool
    reviewed_title: str
    reviewed_username: str
    reviewed_uri: str
    password_overridden: bool
    source_password_required: bool


def _candidate_request(value: object) -> SelectedCandidate:
    if not isinstance(value, dict):
        raise ImportPreparationError("Un candidato selezionato non è valido.")
    candidate_id = str(value.get("candidate_id", "")).strip()
    relative_path = str(value.get("source_relative_path", "")).strip()
    source_sha256 = str(value.get("source_sha256", "")).strip().lower()
    client = str(value.get("client", "")).strip()
    source_at_root = value.get("source_at_root")
    title = str(value.get("title", "")).strip()
    username = str(value.get("username", "")).strip()
    uri = str(value.get("uri", "")).strip()
    reviewed_client = str(value.get("reviewed_client", client)).strip()
    reviewed_source_at_root = value.get("reviewed_source_at_root", source_at_root)
    reviewed_title = str(value.get("reviewed_title", title)).strip()
    reviewed_username = str(value.get("reviewed_username", username)).strip()
    reviewed_uri = str(value.get("reviewed_uri", uri)).strip()
    password_overridden = value.get("password_overridden", False)
    source_password_required = value.get("source_password_required", False)
    if not candidate_id or len(candidate_id) > 200:
        raise ImportPreparationError("Un candidato non contiene un identificatore valido.")
    if not relative_path or len(relative_path) > 4096:
        raise ImportPreparationError("Un candidato non contiene un percorso sorgente valido.")
    if not SHA256_PATTERN.fullmatch(source_sha256):
        raise ImportPreparationError("Un candidato non contiene l’hash SHA-256 della revisione.")
    if not client or len(client) > 256:
        raise ImportPreparationError("Un candidato non contiene un cliente valido.")
    if not isinstance(source_at_root, bool):
        raise ImportPreparationError("Un candidato non indica correttamente la posizione sorgente.")
    if source_at_root != (client.casefold() == "(radice)"):
        raise ImportPreparationError("Cliente e posizione di destinazione del candidato non coincidono.")
    if not title or len(title) > 255:
        raise ImportPreparationError("Ogni candidato deve avere un titolo di massimo 255 caratteri.")
    if len(username) > 255 or len(uri) > 2048:
        raise ImportPreparationError("Username o URL superano i limiti consentiti.")
    if not reviewed_client or len(reviewed_client) > 256:
        raise ImportPreparationError("I metadati originali non contengono un cliente valido.")
    if not isinstance(reviewed_source_at_root, bool):
        raise ImportPreparationError("La posizione sorgente originale non è valida.")
    if reviewed_source_at_root != (reviewed_client.casefold() == "(radice)"):
        raise ImportPreparationError("Cliente e posizione sorgente originali non coincidono.")
    if not reviewed_title or len(reviewed_title) > 255:
        raise ImportPreparationError("Il titolo originale del candidato non è valido.")
    if len(reviewed_username) > 255 or len(reviewed_uri) > 2048:
        raise ImportPreparationError("I metadati originali superano i limiti consentiti.")
    if not isinstance(password_overridden, bool):
        raise ImportPreparationError("Lo stato della password modificata non è valido.")
    if not isinstance(source_password_required, bool):
        raise ImportPreparationError("Lo stato di protezione del file Excel non è valido.")
    return SelectedCandidate(
        candidate_id=candidate_id,
        source_relative_path=relative_path,
        source_sha256=source_sha256,
        client=client,
        source_at_root=source_at_root,
        title=title,
        username=username,
        uri=uri,
        reviewed_client=reviewed_client,
        reviewed_source_at_root=reviewed_source_at_root,
        reviewed_title=reviewed_title,
        reviewed_username=reviewed_username,
        reviewed_uri=reviewed_uri,
        password_overridden=password_overridden,
        source_password_required=source_password_required,
    )


def _selected_candidates(values: object) -> list[SelectedCandidate]:
    if not isinstance(values, list) or not values:
        raise ImportPreparationError("Selezionare almeno un candidato pronto.")
    candidates = [_candidate_request(value) for value in values]
    identifiers = [candidate.candidate_id for candidate in candidates]
    if len(set(identifiers)) != len(identifiers):
        raise ImportPreparationError("La selezione contiene due volte lo stesso candidato.")
    return candidates


def _extension_for(path: Path) -> str:
    extension = path.suffix.lower()
    if not extension and path.name.lower() == ".env":
        extension = ".env"
    if extension not in REVIEWABLE_EXTENSIONS:
        raise ImportPreparationError(
            f"Il formato {extension or '(senza estensione)'} non è più revisionabile."
        )
    return extension


def _extract_resources_impl(
    root: str | Path,
    requests: Iterable[object],
    *,
    include_secrets: bool,
    secret_overrides: dict[str, str] | None = None,
    source_file_passwords: dict[str, str] | None = None,
) -> tuple[list[dict[str, str]], int]:
    """Revalidate reviewed candidates and optionally return their secrets.

    The returned cleartext password is intended only for an immediate stdin
    handoff to the crypto bridge. Callers must never serialize it elsewhere.
    """

    root_path = Path(root).expanduser().resolve()
    if not root_path.is_dir():
        raise ImportPreparationError("La cartella clienti non esiste o non è accessibile.")
    selected = _selected_candidates(list(requests))
    file_passwords = source_file_passwords or {}
    selected_paths = {candidate.source_relative_path for candidate in selected}
    required_password_paths = {
        candidate.source_relative_path
        for candidate in selected
        if candidate.source_password_required
    }
    if set(file_passwords) != required_password_paths:
        raise ImportPreparationError(
            "Le password dei file Excel in memoria non corrispondono ai sorgenti selezionati."
        )
    if any(path not in selected_paths for path in file_passwords):
        raise ImportPreparationError("È stata fornita una password per un sorgente non selezionato.")
    for relative_path, password in file_passwords.items():
        if (
            not isinstance(relative_path, str)
            or not isinstance(password, str)
            or not password
            or len(password) > MAX_OFFICE_PASSWORD_CHARACTERS
        ):
            raise ImportPreparationError("Una password di file Excel in memoria non è valida.")
    overrides = secret_overrides or {}
    required_override_ids = {
        candidate.candidate_id for candidate in selected if candidate.password_overridden
    }
    if include_secrets and set(overrides) != required_override_ids:
        raise ImportPreparationError(
            "Le password modificate in memoria non corrispondono ai candidati selezionati."
        )
    if not include_secrets and overrides:
        raise ImportPreparationError("Il controllo di integrità non accetta password in chiaro.")
    for candidate_id, secret in overrides.items():
        if not isinstance(candidate_id, str) or not isinstance(secret, str) or not secret:
            raise ImportPreparationError("Una password modificata in memoria non è valida.")
        if len(secret) > MAX_SECRET_CHARACTERS:
            raise ImportPreparationError(
                "Una password modificata supera il limite di 65.536 caratteri."
            )
    by_path: dict[str, list[SelectedCandidate]] = {}
    for candidate in selected:
        by_path.setdefault(candidate.source_relative_path, []).append(candidate)

    extracted: dict[str, dict[str, str]] = {}
    for supplied_path, wanted in by_path.items():
        wanted_by_id = {candidate.candidate_id: candidate for candidate in wanted}
        remaining_ids = set(wanted_by_id)
        try:
            path, relative_path = _safe_selected_path(root_path, supplied_path)
            if path.stat().st_size > MAX_FILE_BYTES:
                raise ImportPreparationError("Un file sorgente supera il limite di dimensione.")
            extension = _extension_for(path)
            current_hash = _sha256(path)
        except (OSError, ReviewError) as exc:
            raise ImportPreparationError(
                f"Il file sorgente {supplied_path} non può essere verificato: {exc}"
            ) from exc

        expected_hashes = {candidate.source_sha256 for candidate in wanted}
        if expected_hashes != {current_hash}:
            raise ImportPreparationError(
                f"Il file {relative_path} è cambiato dopo la revisione. Ripetere inventario e revisione."
            )

        relative_parts = Path(relative_path).parts
        client = relative_parts[0] if len(relative_parts) > 1 else "(radice)"
        source_at_root = len(relative_parts) == 1
        source_password_required = (
            extension == ".xlsx" and _is_ole_compound_file(path)
        )
        if any(
            candidate.source_password_required != source_password_required
            for candidate in wanted
        ):
            raise ImportPreparationError(
                "Lo stato di protezione del file Excel non corrisponde più alla revisione."
            )
        try:
            records = _records_for_file(
                path,
                extension,
                file_password=file_passwords.get(relative_path),
            )
            try:
                for location, record in records:
                    candidate = _make_candidate(
                        record,
                        relative_path=relative_path,
                        source_hash=current_hash,
                        client=client,
                        location=location,
                        source_password_required=source_password_required,
                    )
                    if candidate is None or candidate.candidate_id not in remaining_ids:
                        continue
                    request = wanted_by_id[candidate.candidate_id]
                    if (
                        (candidate.status != "ready" and not request.password_overridden)
                        or candidate.client != request.reviewed_client
                        or source_at_root != request.reviewed_source_at_root
                        or candidate.title != request.reviewed_title
                        or candidate.username != request.reviewed_username
                        or candidate.uri != request.reviewed_uri
                        or candidate.source_password_required != request.source_password_required
                    ):
                        raise ImportPreparationError(
                            "I metadati di un candidato non corrispondono più alla revisione."
                        )
                    resource = {
                        "candidate_id": candidate.candidate_id,
                        "title": request.title,
                        "username": request.username,
                        "uri": request.uri,
                    }
                    if include_secrets:
                        if request.password_overridden:
                            secret = overrides[request.candidate_id]
                        else:
                            secret_found, secret = _find_field(
                                record, SECRET_KEYS, allow_prefix=True
                            )
                            if not secret_found or not secret:
                                raise ImportPreparationError(
                                    "La password di un candidato pronto non è più disponibile."
                                )
                        if len(secret) > MAX_SECRET_CHARACTERS:
                            raise ImportPreparationError(
                                "La password di un candidato supera il limite di 65.536 caratteri."
                            )
                        resource["password"] = secret
                        resource["description"] = ""
                    extracted[candidate.candidate_id] = resource
                    remaining_ids.remove(candidate.candidate_id)
                    if not remaining_ids:
                        break
            finally:
                close_records = getattr(records, "close", None)
                if callable(close_records):
                    close_records()
        except ImportPreparationError:
            raise
        except (OSError, ReviewError, ValueError) as exc:
            raise ImportPreparationError(
                f"Il file sorgente {relative_path} non può essere riletto in sicurezza."
            ) from exc
        try:
            hash_after_read = _sha256(path)
        except OSError as exc:
            raise ImportPreparationError(
                f"Il file sorgente {relative_path} non può essere verificato dopo la lettura."
            ) from exc
        if hash_after_read != current_hash:
            raise ImportPreparationError(
                f"Il file {relative_path} è cambiato durante la lettura. Ripetere la revisione."
            )

    missing = [
        candidate.candidate_id
        for candidate in selected
        if candidate.candidate_id not in extracted
    ]
    if missing:
        raise ImportPreparationError(
            "Uno o più candidati non sono più presenti nei documenti sorgente. Ripetere la revisione."
        )
    return [extracted[candidate.candidate_id] for candidate in selected], len(by_path)


def extract_resources(
    root: str | Path,
    requests: Iterable[object],
    *,
    include_secrets: bool,
    secret_overrides: dict[str, str] | None = None,
    source_file_passwords: dict[str, str] | None = None,
) -> tuple[list[dict[str, str]], int]:
    """Revalidate candidates while limiting cleartext password-map lifetime."""

    overrides = dict(secret_overrides or {})
    file_passwords = dict(source_file_passwords or {})
    try:
        return _extract_resources_impl(
            root,
            requests,
            include_secrets=include_secrets,
            secret_overrides=overrides,
            source_file_passwords=file_passwords,
        )
    finally:
        overrides.clear()
        file_passwords.clear()


def verify_integrity(
    root: str | Path,
    requests: Iterable[object],
    *,
    source_file_passwords: dict[str, str] | None = None,
) -> dict[str, Any]:
    resources, source_count = extract_resources(
        root,
        requests,
        include_secrets=False,
        source_file_passwords=source_file_passwords,
    )
    return {
        "verified": True,
        "verified_candidate_count": len(resources),
        "verified_source_count": source_count,
        "candidate_ids": [resource["candidate_id"] for resource in resources],
        "secrets_serialized": False,
    }


def _read_stdin_json() -> dict[str, Any]:
    raw = sys.stdin.buffer.read(MAX_STDIN_BYTES + 1)
    if len(raw) > MAX_STDIN_BYTES:
        raise ImportPreparationError("La richiesta di importazione è troppo grande.")
    try:
        document = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ImportPreparationError("La richiesta non contiene JSON valido.") from exc
    if not isinstance(document, dict):
        raise ImportPreparationError("La richiesta deve essere un oggetto JSON.")
    return document


def _validate_bridge(node_path: str, crypto_script: str) -> tuple[Path, Path]:
    node = Path(node_path).expanduser().resolve()
    script = Path(crypto_script).expanduser().resolve()
    if not node.is_file():
        raise ImportPreparationError("Runtime Node.js locale non trovato.")
    if not script.is_file():
        raise ImportPreparationError("Bridge OpenPGP locale non trovato.")
    return node, script


def _secret_overrides(value: object) -> dict[str, str]:
    if value is None:
        return {}
    if not isinstance(value, list):
        raise ImportPreparationError("L’elenco delle password modificate non è valido.")
    overrides: dict[str, str] = {}
    for item in value:
        if not isinstance(item, dict):
            raise ImportPreparationError("Una password modificata non è valida.")
        candidate_id = str(item.get("candidate_id", "")).strip()
        password = item.get("password")
        if (
            not candidate_id
            or len(candidate_id) > 200
            or candidate_id in overrides
            or not isinstance(password, str)
            or not password
        ):
            raise ImportPreparationError("Una password modificata non è valida.")
        if len(password) > MAX_SECRET_CHARACTERS:
            raise ImportPreparationError(
                "Una password modificata supera il limite di 65.536 caratteri."
            )
        overrides[candidate_id] = password
    return overrides


def _source_file_passwords(value: object) -> dict[str, str]:
    if value is None:
        return {}
    if not isinstance(value, list):
        raise ImportPreparationError("L’elenco delle password dei file Excel non è valido.")
    passwords: dict[str, str] = {}
    for item in value:
        if not isinstance(item, dict):
            raise ImportPreparationError("Una password di file Excel non è valida.")
        relative_path = _normalized_supplied_path(item.get("relative_path", ""))
        password = item.get("password")
        if (
            not relative_path
            or relative_path in passwords
            or not isinstance(password, str)
            or not password
            or len(password) > MAX_OFFICE_PASSWORD_CHARACTERS
        ):
            raise ImportPreparationError("Una password di file Excel non è valida.")
        passwords[relative_path] = password
    return passwords


def _prepare_recovery_context(
    root: str | Path,
    request: Mapping[str, Any],
    journal_root: str | Path | None,
) -> tuple[dict[str, Any], list[object]]:
    candidates = request.get("candidates")
    if not isinstance(candidates, list) or not candidates:
        raise ImportPreparationError(
            "Il recupero non contiene i candidati originali."
        )
    file_passwords = _source_file_passwords(request.get("source_file_passwords"))
    try:
        verify_integrity(
            root,
            candidates,
            source_file_passwords=file_passwords,
        )
    finally:
        file_passwords.clear()
    try:
        snapshot = read_batch(request.get("reconciliation_batch_id"), journal_root)
        recovery_state = build_recovery_state(snapshot)
    except ReconciliationJournalCorrupt as exc:
        raise ImportPreparationError(
            "Il registro locale è incompleto o danneggiato; la ripresa automatica è bloccata."
        ) from exc
    except ReconciliationJournalError as exc:
        raise ImportPreparationError(
            "Il lotto locale richiesto non è disponibile per il recupero."
        ) from exc

    supplied_proofs: list[dict[str, str]] = []
    for candidate in candidates:
        if not isinstance(candidate, Mapping):
            raise ImportPreparationError(
                "Un candidato del recupero non è valido."
            )
        supplied_proofs.append(
            {
                "candidate_id": str(candidate.get("candidate_id", "")).strip(),
                "source_sha256": str(candidate.get("source_sha256", ""))
                .strip()
                .lower(),
            }
        )
    supplied_proofs.sort(key=lambda item: item["candidate_id"])
    if supplied_proofs != recovery_state["candidates"]:
        raise ImportPreparationError(
            "I documenti e i candidati non corrispondono al lotto originale."
        )

    mapping = request.get("client_destination_mapping")
    if recovery_state["destination_mode"] == "client_mapping":
        expected_mapping_hash = recovery_state.get("destination_mapping_hash")
        if not expected_mapping_hash:
            raise ImportPreparationError(
                "Il lotto non contiene una prova sufficiente della mappatura; è richiesta una verifica manuale."
            )
        try:
            supplied_mapping_hash = hash_client_destination_mapping(mapping)
        except ReconciliationJournalError as exc:
            raise ImportPreparationError(
                "La mappatura delle destinazioni del recupero non è valida."
            ) from exc
        if supplied_mapping_hash != expected_mapping_hash:
            raise ImportPreparationError(
                "La mappatura delle destinazioni non corrisponde al lotto originale."
            )
    elif mapping not in (None, []):
        raise ImportPreparationError(
            "Il lotto originale non utilizza una mappatura per cliente."
        )
    expected_permission_mode = str(
        recovery_state.get("permission_mode", "inherited")
    )
    supplied_permission_mode = request.get("permission_mode", "inherited")
    try:
        supplied_permission_hash = hash_permission_configuration(
            supplied_permission_mode, request.get("permission_template")
        )
    except ReconciliationJournalError as exc:
        raise ImportPreparationError(
            "La configurazione dei permessi del recupero non è valida."
        ) from exc
    expected_permission_hash = recovery_state.get("permission_configuration_hash")
    if expected_permission_hash is None:
        expected_permission_hash = hash_permission_configuration("inherited", None)
    if (
        str(supplied_permission_mode).strip().lower() != expected_permission_mode
        or supplied_permission_hash != expected_permission_hash
    ):
        raise ImportPreparationError(
            "I permessi configurati non corrispondono al lotto originale. Riaprire l’editor e ricreare la stessa ACL prima del recupero."
        )
    return recovery_state, candidates


def _prepare_recovery_resources(
    root: str | Path,
    request: dict[str, Any],
) -> tuple[list[object], list[dict[str, Any]]]:
    candidate_ids = request.get("resource_candidate_ids")
    if not isinstance(candidate_ids, list):
        raise ImportPreparationError(
            "L’elenco delle risorse richieste dal recupero non è valido."
        )
    normalized_ids = [str(value).strip() for value in candidate_ids]
    if any(not value for value in normalized_ids) or len(set(normalized_ids)) != len(
        normalized_ids
    ):
        raise ImportPreparationError(
            "L’elenco delle risorse richieste dal recupero non è valido."
        )
    candidates = request.get("candidates")
    if not isinstance(candidates, list) or not candidates:
        raise ImportPreparationError("Il recupero non contiene candidati validi.")
    if not normalized_ids:
        if request.get("secret_overrides") not in (None, []):
            raise ImportPreparationError(
                "Il recupero non richiede password di risorse."
            )
        return candidates, []
    extraction_request = dict(request)
    extraction_request["create_candidate_ids"] = normalized_ids
    return _prepare_import_resources(root, extraction_request)


def _prepare_import_resources(
    root: str | Path, request: dict[str, Any]
) -> tuple[list[object], list[dict[str, Any]]]:
    candidates = request.get("candidates")
    if not isinstance(candidates, list) or not candidates:
        raise ImportPreparationError("Il piano non contiene candidati validi.")
    create_ids_value = request.get("create_candidate_ids")
    if create_ids_value is None:
        create_ids = [str(item.get("candidate_id", "")) for item in candidates]
    elif isinstance(create_ids_value, list):
        create_ids = [str(value) for value in create_ids_value]
    else:
        raise ImportPreparationError("L’elenco delle risorse da creare non è valido.")
    if not create_ids or len(set(create_ids)) != len(create_ids):
        raise ImportPreparationError(
            "L’elenco delle risorse da creare è vuoto o duplicato."
        )
    candidate_ids = {
        str(item.get("candidate_id", ""))
        for item in candidates
        if isinstance(item, dict)
    }
    if any(candidate_id not in candidate_ids for candidate_id in create_ids):
        raise ImportPreparationError(
            "L’elenco delle risorse da creare non corrisponde al piano."
        )
    create_requests = [
        item
        for item in candidates
        if isinstance(item, dict) and str(item.get("candidate_id", "")) in create_ids
    ]
    parsed_create_requests = _selected_candidates(create_requests)
    if any(not (candidate.username or candidate.uri) for candidate in parsed_create_requests):
        raise ImportPreparationError(
            "Ogni risorsa da creare deve avere almeno uno fra username e URL/host."
        )
    overrides = _secret_overrides(request.get("secret_overrides"))
    file_passwords = _source_file_passwords(request.get("source_file_passwords"))
    if any(candidate_id not in create_ids for candidate_id in overrides):
        overrides.clear()
        file_passwords.clear()
        raise ImportPreparationError(
            "Le password modificate non corrispondono alle risorse da creare."
        )
    try:
        resources, _ = extract_resources(
            root,
            create_requests,
            include_secrets=True,
            secret_overrides=overrides,
            source_file_passwords=file_passwords,
        )
    finally:
        overrides.clear()
        file_passwords.clear()
    return candidates, resources


def reveal_secrets(
    root: str | Path,
    requests: Iterable[object],
    *,
    source_file_passwords: dict[str, str] | None = None,
) -> dict[str, Any]:
    """Explicitly reveal selected source secrets to the local desktop process."""

    resources, _ = extract_resources(
        root,
        requests,
        include_secrets=True,
        source_file_passwords=source_file_passwords,
    )
    return {
        "revealed_count": len(resources),
        "secrets": [
            {
                "candidate_id": resource["candidate_id"],
                "password": resource["password"],
            }
            for resource in resources
        ],
    }


def execute_import(
    root: str | Path,
    request: dict[str, Any],
    *,
    node_path: str,
    crypto_script: str,
) -> dict[str, Any]:
    node, script = _validate_bridge(node_path, crypto_script)
    candidates, resources = _prepare_import_resources(root, request)

    bridge_request = {
        "command": "import",
        "base_url": request.get("base_url"),
        "expected_server_fingerprint": request.get("expected_server_fingerprint"),
        "private_key_path": request.get("private_key_path"),
        "passphrase": request.get("passphrase"),
        "mfa_totp": request.get("mfa_totp"),
        "resource_format": request.get("resource_format", "auto"),
        "destination_mode": request.get("destination_mode", "client_folders"),
        "folder_format": request.get("folder_format", "auto"),
        "destination_folder_id": request.get("destination_folder_id"),
        "client_destination_mapping": request.get("client_destination_mapping"),
        "permission_mode": request.get("permission_mode", "inherited"),
        "permission_template": request.get("permission_template"),
        "candidates": candidates,
        "resources": resources,
        "plan_digest": request.get("plan_digest"),
        "confirmation": request.get("confirmation"),
    }
    encoded = json.dumps(
        bridge_request, ensure_ascii=False, separators=(",", ":")
    ).encode("utf-8")
    creation_flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    try:
        completed = subprocess.run(
            [str(node), str(script)],
            input=encoded,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=180,
            check=False,
            creationflags=creation_flags,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise ImportPreparationError(
            "La procedura OpenPGP locale non ha potuto completare l’importazione."
        ) from exc
    finally:
        # Drop the only explicit structures containing cleartext secrets as
        # soon as the child process has consumed its stdin.
        bridge_request.clear()
        resources.clear()
        encoded = b""

    if len(completed.stdout) > MAX_BRIDGE_OUTPUT_BYTES:
        raise ImportPreparationError("La risposta della procedura OpenPGP è troppo grande.")
    try:
        result = json.loads(completed.stdout.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ImportPreparationError(
            "La procedura OpenPGP locale ha restituito una risposta non valida."
        ) from exc
    if not isinstance(result, dict) or not isinstance(result.get("ok"), bool):
        raise ImportPreparationError(
            "La procedura OpenPGP locale ha restituito una struttura inattesa."
        )
    return result


def _session_bridge_request(
    root: str | Path,
    request: dict[str, Any],
    journal_root: str | Path | None = None,
    acl_journal_root: str | Path | None = None,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    command = str(request.get("command", ""))
    if command == "session-open":
        return (
            {
                "command": "session-open",
                "base_url": request.get("base_url"),
                "expected_server_fingerprint": request.get(
                    "expected_server_fingerprint"
                ),
                "private_key_path": request.get("private_key_path"),
                "passphrase": request.get("passphrase"),
                "mfa_totp": request.get("mfa_totp"),
            },
            [],
        )
    if command == "session-readiness":
        candidates = request.get("candidates")
        file_passwords = _source_file_passwords(request.get("source_file_passwords"))
        try:
            verify_integrity(
                root,
                candidates if isinstance(candidates, list) else [],
                source_file_passwords=file_passwords,
            )
        finally:
            file_passwords.clear()
        return (
            {
                "command": "session-readiness",
                "session_id": request.get("session_id"),
                "resource_format": request.get("resource_format", "auto"),
                "destination_mode": request.get(
                    "destination_mode", "client_folders"
                ),
                "folder_format": request.get("folder_format", "auto"),
                "destination_folder_id": request.get("destination_folder_id"),
                "client_destination_mapping": request.get(
                    "client_destination_mapping"
                ),
                "permission_mode": request.get("permission_mode", "inherited"),
                "permission_template": request.get("permission_template"),
                "candidates": candidates,
            },
            [],
        )
    if command == "session-permissions":
        return (
            {
                "command": "session-permissions",
                "session_id": request.get("session_id"),
            },
            [],
        )
    if command == "session-acl-catalog":
        return (
            {
                "command": "session-acl-catalog",
                "session_id": request.get("session_id"),
            },
            [],
        )
    if command == "session-acl-plan":
        raw_permissions = request.get("desired_permissions")
        desired_permissions: Any
        if isinstance(raw_permissions, list):
            desired_permissions = [
                {
                    "aro": item.get("aro"),
                    "aro_foreign_key": item.get("aro_foreign_key"),
                    "type": item.get("type"),
                }
                if isinstance(item, dict)
                else None
                for item in raw_permissions
            ]
        else:
            desired_permissions = None
        return (
            {
                "command": "session-acl-plan",
                "session_id": request.get("session_id"),
                "object_type": request.get("object_type"),
                "object_id": request.get("object_id"),
                "desired_permissions": desired_permissions,
            },
            [],
        )
    if command == "session-acl-apply":
        return (
            {
                "command": "session-acl-apply",
                "session_id": request.get("session_id"),
                "plan_id": request.get("plan_id"),
                "object_state_digest": request.get("object_state_digest"),
                "desired_acl_digest": request.get("desired_acl_digest"),
                "directory_state_digest": request.get("directory_state_digest"),
                "plan_digest": request.get("plan_digest"),
                "confirmation": request.get("confirmation"),
            },
            [],
        )
    if command in {
        "session-acl-recovery-readiness",
        "session-acl-recovery-apply",
    }:
        try:
            recovery_state = build_acl_recovery_state(
                request.get("acl_batch_id"), acl_journal_root
            )
        except ReconciliationJournalError as exc:
            raise ImportPreparationError(
                "Il journal ACL selezionato non è recuperabile automaticamente."
            ) from exc
        return (
            {
                "command": command,
                "session_id": request.get("session_id"),
                "acl_batch_id": recovery_state["batch_id"],
                "acl_recovery_state": recovery_state,
                **(
                    {
                        "recovery_id": request.get("recovery_id"),
                        "recovery_plan_digest": request.get(
                            "recovery_plan_digest"
                        ),
                        "confirmation": request.get("confirmation"),
                    }
                    if command == "session-acl-recovery-apply"
                    else {}
                ),
            },
            [],
        )
    if command == "session-acl-recovery-cancel":
        return (
            {
                "command": command,
                "session_id": request.get("session_id"),
                "acl_batch_id": request.get("acl_batch_id"),
            },
            [],
        )
    if command == "session-import":
        candidates, resources = _prepare_import_resources(root, request)
        return (
            {
                "command": "session-import",
                "session_id": request.get("session_id"),
                "resource_format": request.get("resource_format", "auto"),
                "destination_mode": request.get(
                    "destination_mode", "client_folders"
                ),
                "folder_format": request.get("folder_format", "auto"),
                "destination_folder_id": request.get("destination_folder_id"),
                "client_destination_mapping": request.get(
                    "client_destination_mapping"
                ),
                "permission_mode": request.get("permission_mode", "inherited"),
                "permission_template": request.get("permission_template"),
                "candidates": candidates,
                "resources": resources,
                "plan_digest": request.get("plan_digest"),
                "confirmation": request.get("confirmation"),
            },
            resources,
        )
    if command in {"session-recovery-readiness", "session-recovery-import"}:
        recovery_state, candidates = _prepare_recovery_context(
            root, request, journal_root
        )
        resources: list[dict[str, Any]] = []
        if command == "session-recovery-import":
            candidates, resources = _prepare_recovery_resources(root, request)
        return (
            {
                "command": command,
                "session_id": request.get("session_id"),
                "reconciliation_batch_id": recovery_state["batch_id"],
                "resource_format": recovery_state["resource_format"],
                "destination_mode": recovery_state["destination_mode"],
                "folder_format": recovery_state["folder_format"],
                "destination_folder_id": recovery_state["destination_folder_id"],
                "client_destination_mapping": request.get(
                    "client_destination_mapping"
                ),
                "permission_mode": request.get("permission_mode", "inherited"),
                "permission_template": request.get("permission_template"),
                "candidates": candidates,
                "recovery_state": recovery_state,
                **(
                    {
                        "resources": resources,
                        "resource_candidate_ids": request.get(
                            "resource_candidate_ids"
                        ),
                        "recovery_id": request.get("recovery_id"),
                        "recovery_plan_digest": request.get(
                            "recovery_plan_digest"
                        ),
                        "confirmation": request.get("confirmation"),
                    }
                    if command == "session-recovery-import"
                    else {}
                ),
            },
            resources,
        )
    if command == "session-close":
        return (
            {
                "command": "session-close",
                "session_id": request.get("session_id"),
            },
            [],
        )
    raise ImportPreparationError(
        "Comando della sessione di importazione non riconosciuto."
    )


class _SessionReconciliationCoordinator:
    """Bind one authenticated import session to a durable local journal."""

    def __init__(self, journal_root: str | Path | None = None) -> None:
        self._journal_root = journal_root
        self._session: dict[str, Any] | None = None
        self._readiness: dict[str, Any] | None = None
        self._recovery_readiness: dict[str, Any] | None = None
        self._journal: ReconciliationJournal | None = None
        self._lease: ReconciliationJournalLease | None = None

    @property
    def active_batch_id(self) -> str | None:
        return self._journal.batch_id if self._journal is not None else None

    def _release_lease(self) -> None:
        if self._lease is not None:
            self._lease.close()
            self._lease = None

    @staticmethod
    def _successful_payload(envelope: Mapping[str, Any]) -> dict[str, Any] | None:
        payload = envelope.get("result")
        if envelope.get("ok") is not True or not isinstance(payload, dict):
            return None
        return payload

    def observe(self, command: str, envelope: Mapping[str, Any]) -> None:
        payload = self._successful_payload(envelope)
        if command == "session-open":
            self._session = dict(payload) if payload is not None else None
            self._readiness = None
            self._recovery_readiness = None
        elif command == "session-readiness":
            self._readiness = dict(payload) if payload is not None else None
        elif command == "session-close":
            self._session = None
            self._readiness = None
            self._recovery_readiness = None
            self._journal = None
            self._release_lease()

    def _validate_recovery_identity(
        self, request: Mapping[str, Any], bridge_request: Mapping[str, Any]
    ) -> None:
        if self._session is None:
            raise ImportPreparationError(
                "Avviare prima una sessione Passbolt autenticata."
            )
        session_id = str(request.get("session_id", "")).strip()
        if not session_id or session_id != str(
            self._session.get("session_id", "")
        ).strip():
            raise ImportPreparationError(
                "La sessione Passbolt non corrisponde al recupero."
            )
        state = bridge_request.get("recovery_state")
        user = self._session.get("user")
        if not isinstance(state, Mapping) or not isinstance(user, Mapping):
            raise ImportPreparationError(
                "Il contesto autenticato del recupero non è disponibile."
            )
        try:
            user_hash = hash_user_identifier(str(user.get("id", "")))
        except ReconciliationJournalError as exc:
            raise ImportPreparationError(
                "L’identità Passbolt autenticata non è valida."
            ) from exc
        if (
            str(state.get("server_origin", "")).rstrip("/").casefold()
            != str(self._session.get("base_url", "")).rstrip("/").casefold()
            or str(state.get("server_fingerprint", "")).upper()
            != str(self._session.get("server_fingerprint", "")).upper()
            or str(state.get("user_id_hash", "")) != user_hash
        ):
            raise ImportPreparationError(
                "Server, fingerprint o utente non corrispondono al lotto originale."
            )

    def start_recovery_readiness(
        self,
        request: Mapping[str, Any],
        bridge_request: dict[str, Any],
    ) -> str:
        if self._journal is not None or self._lease is not None:
            raise ImportPreparationError(
                "Un lotto è già verificato in questa sessione; completarlo oppure chiudere la sessione."
            )
        self._validate_recovery_identity(request, bridge_request)
        state = bridge_request.get("recovery_state")
        assert isinstance(state, Mapping)
        batch_id = str(state.get("batch_id", ""))
        try:
            snapshot = read_batch(batch_id, self._journal_root)
            if snapshot.complete or snapshot.truncated_tail:
                raise ReconciliationJournalError(
                    "Il lotto non è riprendibile automaticamente."
                )
            journal = ReconciliationJournal.open(snapshot.path)
            lease = acquire_journal_lease(journal)
        except ReconciliationJournalError as exc:
            raise ImportPreparationError(
                "Il registro locale non può essere aperto per la verifica."
            ) from exc
        self._journal = journal
        self._lease = lease
        self._recovery_readiness = None
        bridge_request["reconciliation_batch_id"] = journal.batch_id
        return journal.batch_id

    def finish_recovery_readiness(
        self, envelope: dict[str, Any]
    ) -> dict[str, Any]:
        journal = self._journal
        if journal is None:
            raise ImportPreparationError(
                "Il registro locale del recupero non è disponibile."
            )
        if envelope.get("ok") is not True:
            self._journal = None
            self._recovery_readiness = None
            self._release_lease()
            return envelope
        payload = self._successful_payload(envelope)
        try:
            snapshot = journal.read()
        except ReconciliationJournalError as exc:
            self._journal = None
            raise ImportPreparationError(
                "La verifica autenticata non è stata salvata integralmente."
            ) from exc
        last_event = snapshot.events[-1] if snapshot.events else None
        if (
            payload is None
            or snapshot.complete
            or not isinstance(last_event, Mapping)
            or last_event.get("event_type") != "recovery_verified"
            or str(last_event["payload"].get("recovery_id", ""))
            != str(payload.get("recovery_id", ""))
            or str(payload.get("reconciliation_batch_id", ""))
            != journal.batch_id
            or type(payload.get("verified_operation_count")) is not int
            or last_event["payload"].get("verified_operation_count")
            != payload.get("verified_operation_count")
            or type(payload.get("remote_success_count")) is not int
            or last_event["payload"].get("remote_success_count")
            != payload.get("remote_success_count")
            or not SHA256_PATTERN.fullmatch(
                str(payload.get("recovery_plan_digest", "")).strip().lower()
            )
            or not isinstance(payload.get("resource_candidate_ids"), list)
        ):
            self._journal = None
            raise ImportPreparationError(
                "La verifica autenticata del lotto non è coerente con il registro."
            )
        self._recovery_readiness = dict(payload)
        return envelope

    def start_recovery_import(
        self,
        request: Mapping[str, Any],
        bridge_request: Mapping[str, Any],
    ) -> None:
        self._validate_recovery_identity(request, bridge_request)
        if self._journal is None or self._recovery_readiness is None:
            raise ImportPreparationError(
                "Eseguire prima la verifica autenticata del lotto."
            )
        expected = self._recovery_readiness
        if (
            str(request.get("reconciliation_batch_id", ""))
            != self._journal.batch_id
            or str(request.get("recovery_id", ""))
            != str(expected.get("recovery_id", ""))
            or str(request.get("recovery_plan_digest", ""))
            != str(expected.get("recovery_plan_digest", ""))
            or request.get("resource_candidate_ids")
            != expected.get("resource_candidate_ids")
        ):
            raise ImportPreparationError(
                "La richiesta non corrisponde all’ultima verifica del recupero."
            )

    def start_import(
        self,
        request: Mapping[str, Any],
        bridge_request: dict[str, Any],
    ) -> str:
        if self._journal is not None:
            raise ImportPreparationError(
                "Un registro di riconciliazione è già attivo per questa sessione."
            )
        if self._session is None or self._readiness is None:
            raise ImportPreparationError(
                "Ripetere il dry-run prima di iniziare l’importazione."
            )

        session_id = str(request.get("session_id", "")).strip()
        if (
            not session_id
            or session_id != str(self._session.get("session_id", "")).strip()
            or session_id != str(self._readiness.get("session_id", "")).strip()
        ):
            raise ImportPreparationError(
                "La sessione del dry-run non corrisponde all’importazione."
            )

        plan_digest = str(request.get("plan_digest", "")).strip().lower()
        readiness_digest = str(self._readiness.get("plan_digest", "")).strip().lower()
        if not SHA256_PATTERN.fullmatch(plan_digest) or plan_digest != readiness_digest:
            raise ImportPreparationError(
                "Il piano dell’importazione non corrisponde all’ultimo dry-run."
            )

        try:
            permission_mode = str(
                request.get("permission_mode", "inherited")
            ).strip().lower()
            permission_configuration_hash = hash_permission_configuration(
                permission_mode, bridge_request.get("permission_template")
            )
        except ReconciliationJournalError as exc:
            raise ImportPreparationError(
                "La configurazione dei permessi dell’importazione non è valida."
            ) from exc
        if (
            permission_mode
            != str(self._readiness.get("permission_mode", "inherited"))
            or permission_configuration_hash
            != str(
                self._readiness.get(
                    "permission_configuration_hash",
                    hash_permission_configuration("inherited", None),
                )
            )
        ):
            raise ImportPreparationError(
                "I permessi dell’importazione non corrispondono all’ultimo dry-run."
            )

        user = self._session.get("user")
        candidates = bridge_request.get("candidates")
        if not isinstance(user, Mapping) or not isinstance(candidates, list):
            raise ImportPreparationError(
                "La sessione non contiene i dati necessari al registro locale."
            )
        proofs: list[CandidateProof] = []
        for candidate in candidates:
            if not isinstance(candidate, Mapping):
                raise ImportPreparationError(
                    "Il piano contiene un candidato non valido per il registro locale."
                )
            proofs.append(
                CandidateProof(
                    candidate_id=str(candidate.get("candidate_id", "")).strip(),
                    source_sha256=str(candidate.get("source_sha256", "")).strip(),
                )
            )

        try:
            journal = ReconciliationJournal.create(
                app_version=APP_VERSION,
                server_origin=str(self._session.get("base_url", "")),
                server_fingerprint=str(
                    self._session.get("server_fingerprint", "")
                ),
                user_id_hash=hash_user_identifier(str(user.get("id", ""))),
                plan_digest=plan_digest,
                resource_format=str(
                    self._readiness.get("resource_format_selected", "")
                ),
                folder_format=str(
                    self._readiness.get("folder_format_selected") or "none"
                ),
                destination_mode=str(
                    self._readiness.get("destination_mode", "")
                ),
                destination_folder_id=self._readiness.get("destination_folder_id"),
                candidates=proofs,
                destination_mapping_hash=(
                    hash_client_destination_mapping(
                        bridge_request.get("client_destination_mapping")
                    )
                    if str(self._readiness.get("destination_mode", ""))
                    == "client_mapping"
                    else None
                ),
                permission_mode=permission_mode,
                permission_configuration_hash=permission_configuration_hash,
                root=self._journal_root,
            )
            lease = acquire_journal_lease(journal)
        except ReconciliationJournalError as exc:
            raise ImportPreparationError(
                "Impossibile inizializzare il registro locale di riconciliazione."
            ) from exc

        self._journal = journal
        self._lease = lease
        bridge_request["reconciliation_batch_id"] = journal.batch_id
        return journal.batch_id

    def persist_progress(self, envelope: Mapping[str, Any]) -> None:
        if set(envelope) != {"type", "batch_id", "event_type", "payload"}:
            raise ReconciliationJournalError(
                "Struttura dell’evento di avanzamento non valida."
            )
        if envelope.get("type") != "progress" or self._journal is None:
            raise ReconciliationJournalError(
                "Evento di avanzamento fuori da un’importazione attiva."
            )
        if str(envelope.get("batch_id", "")).strip().lower() != self._journal.batch_id:
            raise ReconciliationJournalError(
                "L’evento appartiene a un registro differente."
            )
        event_type = str(envelope.get("event_type", "")).strip()
        payload = envelope.get("payload")
        if not event_type or not isinstance(payload, Mapping):
            raise ReconciliationJournalError(
                "Contenuto dell’evento di avanzamento non valido."
            )
        self._journal.append(event_type, **dict(payload))

    def finish_import(self, envelope: dict[str, Any]) -> dict[str, Any]:
        journal = self._journal
        if journal is None:
            raise ImportPreparationError(
                "Il registro locale dell’importazione non è disponibile."
            )
        batch_id = journal.batch_id
        if envelope.get("ok") is True:
            try:
                snapshot = journal.read()
            except ReconciliationJournalError as exc:
                raise ImportPreparationError(
                    "Impossibile verificare il registro locale dell’importazione."
                ) from exc
            if not snapshot.complete:
                raise ImportPreparationError(
                    "L’importazione non ha chiuso correttamente il registro locale; verificare il lotto prima di riprovare."
                )
            result = envelope.get("result")
            if not isinstance(result, dict):
                raise ImportPreparationError(
                    "La risposta finale dell’importazione non è valida."
                )
            terminal_payload = snapshot.events[-1].get("payload", {})
            if isinstance(terminal_payload, Mapping) and (
                "verified_resource_count" in terminal_payload
            ):
                verified_count = terminal_payload["verified_resource_count"]
                verification_results = result.get("verification_results")
                if (
                    result.get("verification_status") != "verified"
                    or type(result.get("verified_resource_count")) is not int
                    or result.get("verified_resource_count") != verified_count
                    or not isinstance(verification_results, list)
                    or len(verification_results) != verified_count
                    or any(
                        not isinstance(item, Mapping)
                        or item.get("status") != "verified"
                        or any(
                            item.get(field) is not True
                            for field in (
                                "metadata_match",
                                "content_match",
                                "destination_match",
                                "acl_match",
                            )
                        )
                        for item in verification_results
                    )
                ):
                    raise ImportPreparationError(
                        "La risposta della verifica post-importazione non è coerente con il registro locale."
                    )
            result["reconciliation_batch_id"] = batch_id
            result["reconciliation_status"] = "complete"
        else:
            error = envelope.get("error")
            if not isinstance(error, dict):
                error = {
                    "code": "IMPORT_FAILED",
                    "message": "L’importazione non è stata completata.",
                }
                envelope["error"] = error
            details = error.get("details")
            safe_details = dict(details) if isinstance(details, Mapping) else {}
            safe_details["reconciliation_batch_id"] = batch_id
            safe_details["reconciliation_status"] = "verification_required"
            error["details"] = safe_details
        self._journal = None
        self._release_lease()
        return envelope

    def abandon_import(self) -> str | None:
        batch_id = self.active_batch_id
        self._journal = None
        self._recovery_readiness = None
        self._release_lease()
        return batch_id


class _SessionAclCoordinator:
    """Bind a volatile ACL plan to a dedicated durable journal."""

    def __init__(self, journal_root: str | Path | None = None) -> None:
        self._journal_root = journal_root
        self._session: dict[str, Any] | None = None
        self._plan: dict[str, Any] | None = None
        self._recovery_readiness: dict[str, Any] | None = None
        self._journal: AclReconciliationJournal | None = None
        self._lease: ReconciliationJournalLease | None = None

    @property
    def active_batch_id(self) -> str | None:
        return self._journal.batch_id if self._journal is not None else None

    @staticmethod
    def _successful_payload(envelope: Mapping[str, Any]) -> dict[str, Any] | None:
        payload = envelope.get("result")
        return payload if envelope.get("ok") is True and isinstance(payload, dict) else None

    def _release_lease(self) -> None:
        if self._lease is not None:
            self._lease.close()
            self._lease = None

    def observe(self, command: str, envelope: Mapping[str, Any]) -> None:
        payload = self._successful_payload(envelope)
        if command == "session-open":
            self._session = dict(payload) if payload is not None else None
            self._plan = None
            self._recovery_readiness = None
        elif command == "session-acl-plan":
            self._plan = dict(payload) if payload is not None else None
        elif command == "session-acl-catalog":
            self._plan = None
        elif command == "session-close":
            self._session = None
            self._plan = None
            self._recovery_readiness = None
            self._journal = None
            self._release_lease()

    def start_apply(
        self,
        request: Mapping[str, Any],
        bridge_request: dict[str, Any],
    ) -> str:
        if self._journal is not None or self._lease is not None:
            raise ImportPreparationError(
                "Un journal ACL è già attivo; completarlo oppure chiudere la sessione."
            )
        if self._session is None or self._plan is None:
            raise ImportPreparationError(
                "Calcolare nuovamente il dry-run ACL prima dell’applicazione."
            )
        if (
            str(request.get("session_id", ""))
            != str(self._session.get("session_id", ""))
            or str(request.get("session_id", ""))
            != str(self._plan.get("session_id", ""))
        ):
            raise ImportPreparationError("La sessione del piano ACL non corrisponde.")
        for field in (
            "plan_id", "object_state_digest", "desired_acl_digest",
            "directory_state_digest", "plan_digest"
        ):
            if str(request.get(field, "")) != str(self._plan.get(field, "")):
                raise ImportPreparationError(
                    "La richiesta ACL non corrisponde all’ultimo dry-run."
                )
        if self._plan.get("apply_available") is not True:
            raise ImportPreparationError(
                "Il piano non contiene modifiche ACL applicabili."
            )
        expected_confirmation = str(self._plan.get("confirmation_required", ""))
        if not expected_confirmation or str(request.get("confirmation", "")) != expected_confirmation:
            raise ImportPreparationError(
                f"Conferma richiesta: {expected_confirmation or 'ricalcolare il piano ACL'}"
            )
        user = self._session.get("user")
        target = self._plan.get("object")
        counts = self._plan.get("counts")
        desired_permissions = self._plan.get("desired_permissions")
        if (
            not isinstance(user, Mapping)
            or not isinstance(target, Mapping)
            or not isinstance(counts, Mapping)
            or not isinstance(desired_permissions, list)
        ):
            raise ImportPreparationError("Il piano ACL non contiene le prove necessarie.")
        try:
            journal = AclReconciliationJournal.create(
                app_version=APP_VERSION,
                server_origin=str(self._session.get("base_url", "")),
                server_fingerprint=str(self._session.get("server_fingerprint", "")),
                user_id_hash=hash_user_identifier(str(user.get("id", ""))),
                object_type=str(target.get("object_type", "")),
                object_id=str(target.get("object_id", "")),
                object_state_digest=str(self._plan.get("object_state_digest", "")),
                desired_acl_digest=str(self._plan.get("desired_acl_digest", "")),
                plan_digest=str(self._plan.get("plan_digest", "")),
                desired_permissions=desired_permissions,
                change_count=int(self._plan.get("change_count", 0)),
                add_count=int(counts.get("add", 0)),
                upgrade_count=int(counts.get("upgrade", 0)),
                downgrade_count=int(counts.get("downgrade", 0)),
                revoke_count=int(counts.get("revoke", 0)),
                apply_mode=str(self._plan.get("apply_mode", "")),
                root=self._journal_root,
            )
            lease = acquire_acl_journal_lease(journal)
        except (ReconciliationJournalError, TypeError, ValueError) as exc:
            raise ImportPreparationError(
                "Impossibile inizializzare il journal locale della modifica ACL."
            ) from exc
        self._journal = journal
        self._lease = lease
        bridge_request["acl_batch_id"] = journal.batch_id
        return journal.batch_id

    def persist_progress(self, envelope: Mapping[str, Any]) -> None:
        if set(envelope) != {"type", "batch_id", "event_type", "payload"}:
            raise ReconciliationJournalError("Struttura dell’evento ACL non valida.")
        if envelope.get("type") != "progress" or self._journal is None:
            raise ReconciliationJournalError("Evento ACL fuori da un’applicazione attiva.")
        if str(envelope.get("batch_id", "")).strip().lower() != self._journal.batch_id:
            raise ReconciliationJournalError("L’evento appartiene a un altro journal ACL.")
        event_type = str(envelope.get("event_type", "")).strip()
        payload = envelope.get("payload")
        if not event_type or not isinstance(payload, Mapping):
            raise ReconciliationJournalError("Contenuto dell’evento ACL non valido.")
        self._journal.append(event_type, **dict(payload))

    def _validate_recovery_identity(
        self, request: Mapping[str, Any], bridge_request: Mapping[str, Any]
    ) -> Mapping[str, Any]:
        if self._session is None:
            raise ImportPreparationError(
                "Avviare prima una sessione Passbolt autenticata."
            )
        if str(request.get("session_id", "")) != str(
            self._session.get("session_id", "")
        ):
            raise ImportPreparationError(
                "La sessione Passbolt non corrisponde al recupero ACL."
            )
        state = bridge_request.get("acl_recovery_state")
        user = self._session.get("user")
        if not isinstance(state, Mapping) or not isinstance(user, Mapping):
            raise ImportPreparationError(
                "Il contesto autenticato del recupero ACL non è disponibile."
            )
        try:
            user_hash = hash_user_identifier(str(user.get("id", "")))
        except ReconciliationJournalError as exc:
            raise ImportPreparationError("L’identità Passbolt non è valida.") from exc
        if (
            str(state.get("server_origin", "")).rstrip("/").casefold()
            != str(self._session.get("base_url", "")).rstrip("/").casefold()
            or str(state.get("server_fingerprint", "")).upper()
            != str(self._session.get("server_fingerprint", "")).upper()
            or str(state.get("user_id_hash", "")) != user_hash
        ):
            raise ImportPreparationError(
                "Server, fingerprint o utente non corrispondono al journal ACL."
            )
        return state

    def start_recovery_readiness(
        self, request: Mapping[str, Any], bridge_request: dict[str, Any]
    ) -> str:
        if self._journal is not None or self._lease is not None:
            raise ImportPreparationError(
                "Un journal ACL è già attivo in questa sessione."
            )
        state = self._validate_recovery_identity(request, bridge_request)
        batch_id = str(state.get("batch_id", ""))
        try:
            snapshot = read_acl_batch(batch_id, self._journal_root)
            if snapshot.complete or snapshot.truncated_tail:
                raise ReconciliationJournalError(
                    "Il lotto ACL non è recuperabile automaticamente."
                )
            journal = AclReconciliationJournal.open(snapshot.path)
            lease = acquire_acl_journal_lease(journal)
        except ReconciliationJournalError as exc:
            raise ImportPreparationError(
                "Il journal ACL non può essere aperto per la verifica."
            ) from exc
        self._journal = journal
        self._lease = lease
        self._recovery_readiness = None
        bridge_request["acl_batch_id"] = journal.batch_id
        return journal.batch_id

    def finish_recovery_readiness(
        self, envelope: dict[str, Any]
    ) -> dict[str, Any]:
        journal = self._journal
        if journal is None:
            raise ImportPreparationError(
                "Il journal del recupero ACL non è disponibile."
            )
        if envelope.get("ok") is not True:
            self._journal = None
            self._recovery_readiness = None
            self._release_lease()
            return envelope
        payload = self._successful_payload(envelope)
        try:
            snapshot = journal.read()
        except ReconciliationJournalError as exc:
            raise ImportPreparationError(
                "La verifica ACL non è stata salvata integralmente."
            ) from exc
        last_event = snapshot.events[-1] if snapshot.events else None
        if (
            payload is None
            or snapshot.complete
            or not isinstance(last_event, Mapping)
            or last_event.get("event_type") != "acl_recovery_verified"
            or str(last_event["payload"].get("recovery_id", ""))
            != str(payload.get("recovery_id", ""))
            or str(last_event["payload"].get("recovery_plan_digest", ""))
            != str(payload.get("recovery_plan_digest", ""))
            or str(payload.get("acl_batch_id", "")) != journal.batch_id
            or payload.get("resolution") not in {"remote_success", "not_applied"}
        ):
            raise ImportPreparationError(
                "La verifica autenticata ACL non è coerente con il journal."
            )
        self._recovery_readiness = dict(payload)
        return envelope

    def start_recovery_apply(
        self, request: Mapping[str, Any], bridge_request: Mapping[str, Any]
    ) -> None:
        self._validate_recovery_identity(request, bridge_request)
        if self._journal is None or self._recovery_readiness is None:
            raise ImportPreparationError(
                "Eseguire prima la verifica autenticata del journal ACL."
            )
        expected = self._recovery_readiness
        if (
            str(request.get("acl_batch_id", "")) != self._journal.batch_id
            or str(request.get("recovery_id", ""))
            != str(expected.get("recovery_id", ""))
            or str(request.get("recovery_plan_digest", ""))
            != str(expected.get("recovery_plan_digest", ""))
            or str(request.get("confirmation", ""))
            != str(expected.get("confirmation_required", ""))
        ):
            raise ImportPreparationError(
                "La richiesta non corrisponde all’ultima verifica del journal ACL."
            )

    def cancel_recovery(self, request: Mapping[str, Any]) -> dict[str, Any]:
        if self._session is None or str(request.get("session_id", "")) != str(
            self._session.get("session_id", "")
        ):
            raise ImportPreparationError(
                "La sessione Passbolt non corrisponde al recupero ACL."
            )
        batch_id = self.active_batch_id
        if batch_id is None or str(request.get("acl_batch_id", "")) != batch_id:
            raise ImportPreparationError("Non esiste un recupero ACL attivo da annullare.")
        self.abandon()
        return {
            "command": "acl-recovery-cancel",
            "session_id": str(self._session.get("session_id", "")),
            "acl_batch_id": batch_id,
            "cancelled": True,
            "remote_write_performed": False,
        }

    def finish_apply(self, envelope: dict[str, Any]) -> dict[str, Any]:
        journal = self._journal
        if journal is None:
            raise ImportPreparationError("Il journal ACL attivo non è disponibile.")
        batch_id = journal.batch_id
        if envelope.get("ok") is True:
            try:
                snapshot = journal.read()
            except ReconciliationJournalError as exc:
                raise ImportPreparationError(
                    "Impossibile verificare la chiusura del journal ACL."
                ) from exc
            if not snapshot.complete:
                raise ImportPreparationError(
                    "La modifica ACL non ha chiuso il journal; verificare il lotto prima di riprovare."
                )
            result = envelope.get("result")
            if not isinstance(result, dict):
                raise ImportPreparationError("La risposta finale ACL non è valida.")
            result["acl_batch_id"] = batch_id
            result["acl_reconciliation_status"] = "complete"
            self._plan = None
            self._recovery_readiness = None
        else:
            error = envelope.get("error")
            if not isinstance(error, dict):
                error = {"code": "ACL_APPLY_FAILED", "message": "La modifica ACL non è stata completata."}
                envelope["error"] = error
            details = error.get("details")
            safe_details = dict(details) if isinstance(details, Mapping) else {}
            safe_details["acl_batch_id"] = batch_id
            safe_details["acl_reconciliation_status"] = "verification_required"
            error["details"] = safe_details
        self._journal = None
        self._release_lease()
        return envelope

    def abandon(self) -> str | None:
        batch_id = self.active_batch_id
        self._journal = None
        self._recovery_readiness = None
        self._release_lease()
        return batch_id


def _bridge_line_exchange(
    process: subprocess.Popen[bytes],
    request: dict[str, Any],
    *,
    progress_handler: Callable[[Mapping[str, Any]], None] | None = None,
) -> dict[str, Any]:
    if process.stdin is None or process.stdout is None:
        raise ImportPreparationError("Canale della sessione OpenPGP non disponibile.")
    encoded = (
        json.dumps(request, ensure_ascii=False, separators=(",", ":")) + "\n"
    ).encode("utf-8")
    if len(encoded) > MAX_STDIN_BYTES:
        raise ImportPreparationError("La richiesta della sessione è troppo grande.")
    try:
        process.stdin.write(encoded)
        process.stdin.flush()
    except (OSError, ValueError) as exc:
        raise ImportPreparationError(
            "La sessione OpenPGP locale non è più disponibile."
        ) from exc
    finally:
        encoded = b""
    while True:
        try:
            raw = process.stdout.readline(MAX_BRIDGE_OUTPUT_BYTES + 1)
        except (OSError, ValueError) as exc:
            raise ImportPreparationError(
                "La sessione OpenPGP locale non è più disponibile."
            ) from exc
        if not raw:
            raise ImportPreparationError(
                "La sessione OpenPGP locale si è chiusa senza risposta."
            )
        if len(raw) > MAX_BRIDGE_OUTPUT_BYTES:
            raise ImportPreparationError(
                "La risposta della sessione OpenPGP è troppo grande."
            )
        try:
            result = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ImportPreparationError(
                "La sessione OpenPGP locale ha restituito una risposta non valida."
            ) from exc
        if isinstance(result, dict) and result.get("type") == "progress":
            if progress_handler is None:
                raise ImportPreparationError(
                    "La sessione OpenPGP ha inviato un avanzamento inatteso."
                )
            try:
                progress_handler(result)
            except ReconciliationJournalError as exc:
                if process.poll() is None:
                    process.kill()
                raise ImportPreparationError(
                    "Il registro locale non ha potuto salvare l’avanzamento; verificare il lotto prima di riprovare."
                ) from exc
            continue
        if not isinstance(result, dict) or not isinstance(result.get("ok"), bool):
            raise ImportPreparationError(
                "La sessione OpenPGP locale ha restituito una struttura inattesa."
            )
        return result


def run_import_session(
    root: str | Path,
    *,
    node_path: str,
    crypto_script: str,
    journal_root: str | Path | None = None,
    acl_journal_root: str | Path | None = None,
) -> int:
    root_path = Path(root).expanduser().resolve()
    if not root_path.is_dir():
        raise ImportPreparationError("La cartella clienti non esiste o non è accessibile.")
    node, script = _validate_bridge(node_path, crypto_script)
    creation_flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    try:
        process = subprocess.Popen(
            [str(node), str(script), "--session"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            bufsize=0,
            creationflags=creation_flags,
        )
    except OSError as exc:
        raise ImportPreparationError(
            "Impossibile avviare la sessione OpenPGP locale."
        ) from exc

    opened = False
    reconciliation = _SessionReconciliationCoordinator(journal_root)
    acl_reconciliation = _SessionAclCoordinator(acl_journal_root)

    def persist_and_forward_import_progress(
        envelope: Mapping[str, Any],
    ) -> None:
        # The GUI only sees a progress envelope after the same event has been
        # durably appended and validated by the local reconciliation journal.
        reconciliation.persist_progress(envelope)
        _write_json(dict(envelope), flush=True)

    try:
        while True:
            raw = sys.stdin.buffer.readline(MAX_STDIN_BYTES + 1)
            if not raw:
                break
            if len(raw) > MAX_STDIN_BYTES:
                _write_json(
                    {
                        "ok": False,
                        "error": {
                            "code": "IMPORT_SESSION_INPUT_TOO_LARGE",
                            "message": "La richiesta della sessione è troppo grande.",
                        },
                    },
                    flush=True,
                )
                break
            request: dict[str, Any] | None = None
            bridge_request: dict[str, Any] | None = None
            resources: list[dict[str, Any]] = []
            command = ""
            try:
                # Windows PowerShell 5.1 can prepend one UTF-8 BOM to the
                # redirected stdin stream. utf-8-sig accepts that first-line
                # preamble while behaving exactly like utf-8 for later lines.
                document = json.loads(raw.decode("utf-8-sig"))
                if not isinstance(document, dict):
                    raise ImportPreparationError(
                        "La richiesta della sessione deve essere un oggetto JSON."
                    )
                request = document
                command = str(request.get("command", ""))
                bridge_request, resources = _session_bridge_request(
                    root_path, request, journal_root, acl_journal_root
                )
                if command == "session-import":
                    reconciliation.start_import(request, bridge_request)
                elif command == "session-acl-apply":
                    acl_reconciliation.start_apply(request, bridge_request)
                elif command == "session-acl-recovery-readiness":
                    acl_reconciliation.start_recovery_readiness(
                        request, bridge_request
                    )
                elif command == "session-acl-recovery-apply":
                    acl_reconciliation.start_recovery_apply(
                        request, bridge_request
                    )
                elif command == "session-recovery-readiness":
                    reconciliation.start_recovery_readiness(request, bridge_request)
                elif command == "session-recovery-import":
                    reconciliation.start_recovery_import(request, bridge_request)
                if command == "session-acl-recovery-cancel":
                    result = {
                        "ok": True,
                        "result": acl_reconciliation.cancel_recovery(request),
                    }
                else:
                    result = _bridge_line_exchange(
                        process,
                        bridge_request,
                        progress_handler=(
                            persist_and_forward_import_progress
                            if command == "session-import"
                            else (
                                reconciliation.persist_progress
                                if command
                                in {
                                    "session-recovery-readiness",
                                    "session-recovery-import",
                                }
                                else (
                                    acl_reconciliation.persist_progress
                                    if command
                                    in {
                                        "session-acl-apply",
                                        "session-acl-recovery-readiness",
                                        "session-acl-recovery-apply",
                                    }
                                    else None
                                )
                            )
                        ),
                    )
                if command == "session-acl-recovery-readiness":
                    result = acl_reconciliation.finish_recovery_readiness(result)
                elif command in {
                    "session-acl-apply",
                    "session-acl-recovery-apply",
                }:
                    result = acl_reconciliation.finish_apply(result)
                elif command == "session-recovery-readiness":
                    result = reconciliation.finish_recovery_readiness(result)
                elif command in {"session-import", "session-recovery-import"}:
                    result = reconciliation.finish_import(result)
                reconciliation.observe(command, result)
                acl_reconciliation.observe(command, result)
                if command == "session-open" and result.get("ok") is True:
                    opened = True
                if command == "session-close" and result.get("ok") is True:
                    opened = False
                _write_json(result, flush=True)
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                _write_json(
                    {
                        "ok": False,
                        "error": {
                            "code": "IMPORT_SESSION_INVALID_INPUT",
                            "message": "La richiesta della sessione non contiene JSON valido.",
                        },
                    },
                    flush=True,
                )
            except ImportPreparationError as exc:
                batch_id = reconciliation.abandon_import()
                acl_batch_id = acl_reconciliation.abandon()
                error: dict[str, Any] = {
                    "code": "IMPORT_PREPARATION_FAILED",
                    "message": str(exc),
                }
                if batch_id is not None:
                    error["details"] = {
                        "reconciliation_batch_id": batch_id,
                        "reconciliation_status": "verification_required",
                    }
                if acl_batch_id is not None:
                    details = dict(error.get("details", {}))
                    details.update(
                        {
                            "acl_batch_id": acl_batch_id,
                            "acl_reconciliation_status": "verification_required",
                        }
                    )
                    error["details"] = details
                _write_json(
                    {
                        "ok": False,
                        "error": error,
                    },
                    flush=True,
                )
            finally:
                raw = b""
                resources.clear()
                if bridge_request is not None:
                    bridge_request["passphrase"] = None
                    bridge_request["mfa_totp"] = None
                    bridge_request.pop("resources", None)
                    bridge_request.clear()
                if request is not None:
                    for key in ("source_file_passwords", "secret_overrides"):
                        entries = request.get(key)
                        if isinstance(entries, list):
                            for entry in entries:
                                if isinstance(entry, dict) and "password" in entry:
                                    entry["password"] = None
                    request["passphrase"] = None
                    request["mfa_totp"] = None
                    request.clear()
            if command == "session-close":
                break
    finally:
        reconciliation.abandon_import()
        acl_reconciliation.abandon()
        if opened and process.poll() is None:
            try:
                _bridge_line_exchange(process, {"command": "session-close"})
            except ImportPreparationError:
                pass
        if process.stdin is not None:
            try:
                process.stdin.close()
            except OSError:
                pass
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
        if process.stdout is not None:
            process.stdout.close()
    return 0


def _write_json(document: dict[str, Any], *, flush: bool = False) -> None:
    print(
        json.dumps(document, ensure_ascii=True, separators=(",", ":")),
        flush=flush,
    )


def _reconciliation_list_result(
    journal_root: str | Path | None = None,
) -> dict[str, Any]:
    try:
        summaries = list_reconciliation_batches(
            journal_root,
            incomplete_only=False,
        )
    except ReconciliationJournalError as exc:
        raise ImportPreparationError(
            "L’elenco dei registri locali non è disponibile."
        ) from exc
    return {
        "batches": [
            {
                "batch_id": item.batch_id,
                "recorded_at": item.recorded_at,
                "status": item.status,
                "candidate_count": item.candidate_count,
                "event_count": item.event_count,
                "truncated_tail": item.truncated_tail,
            }
            for item in summaries
        ]
    }


def _reconciliation_describe_result(
    request: Mapping[str, Any],
    journal_root: str | Path | None = None,
) -> dict[str, Any]:
    try:
        details = describe_reconciliation_batch(
            request.get("batch_id"),
            journal_root,
        )
    except ReconciliationJournalError as exc:
        raise ImportPreparationError(
            "Il registro locale selezionato non può essere descritto in modo affidabile."
        ) from exc
    return {
        "batch_id": details.batch_id,
        "recorded_at": details.recorded_at,
        "status": details.status,
        "candidate_count": details.candidate_count,
        "event_count": details.event_count,
        "truncated_tail": details.truncated_tail,
        "candidate_ids": list(details.candidate_ids),
        "permission_mode": details.permission_mode,
    }


def _reconciliation_archive_result(
    request: Mapping[str, Any],
    journal_root: str | Path | None = None,
) -> dict[str, Any]:
    try:
        archived = archive_reconciliation_batch(
            request.get("batch_id"),
            expected_status=request.get("expected_status"),
            confirmation=request.get("confirmation"),
            root=journal_root,
        )
    except ReconciliationJournalError as exc:
        raise ImportPreparationError(str(exc)) from exc
    return {
        "batch_id": archived.batch_id,
        "previous_status": archived.previous_status,
        "archived_at": archived.archived_at,
        "deleted": False,
    }


def _acl_reconciliation_list_result(
    journal_root: str | Path | None = None,
) -> dict[str, Any]:
    try:
        summaries = list_acl_batches(journal_root, incomplete_only=False)
    except ReconciliationJournalError as exc:
        raise ImportPreparationError(
            "L’elenco dei journal ACL locali non è disponibile."
        ) from exc
    return {
        "batches": [
            {
                "batch_id": item.batch_id,
                "recorded_at": item.recorded_at,
                "status": item.status,
                "object_type": item.object_type,
                "object_id": item.object_id,
                "change_count": item.change_count,
                "add_count": item.add_count,
                "upgrade_count": item.upgrade_count,
                "downgrade_count": item.downgrade_count,
                "revoke_count": item.revoke_count,
                "apply_mode": item.apply_mode,
                "event_count": item.event_count,
                "truncated_tail": item.truncated_tail,
            }
            for item in summaries
        ]
    }


def _acl_reconciliation_describe_result(
    request: Mapping[str, Any],
    journal_root: str | Path | None = None,
) -> dict[str, Any]:
    try:
        details = describe_acl_batch(request.get("batch_id"), journal_root)
    except ReconciliationJournalError as exc:
        raise ImportPreparationError(
            "Il journal ACL selezionato non può essere descritto in modo affidabile."
        ) from exc
    return {
        "batch_id": details.batch_id,
        "recorded_at": details.recorded_at,
        "status": details.status,
        "object_type": details.object_type,
        "object_id": details.object_id,
        "change_count": details.change_count,
        "add_count": details.add_count,
        "upgrade_count": details.upgrade_count,
        "downgrade_count": details.downgrade_count,
        "revoke_count": details.revoke_count,
        "apply_mode": details.apply_mode,
        "event_count": details.event_count,
        "truncated_tail": details.truncated_tail,
        "applied_operation_count": details.applied_operation_count,
        "failed_operation_count": details.failed_operation_count,
        "recovery_verification_count": details.recovery_verification_count,
    }


def _acl_reconciliation_archive_result(
    request: Mapping[str, Any],
    journal_root: str | Path | None = None,
) -> dict[str, Any]:
    try:
        archived = archive_acl_batch(
            request.get("batch_id"),
            expected_status=request.get("expected_status"),
            confirmation=request.get("confirmation"),
            root=journal_root,
        )
    except ReconciliationJournalError as exc:
        raise ImportPreparationError(str(exc)) from exc
    return {
        "batch_id": archived.batch_id,
        "previous_status": archived.previous_status,
        "archived_at": archived.archived_at,
        "deleted": False,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Controllo integrità e handoff in memoria per l’importazione Passbolt."
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--integrity", action="store_true")
    mode.add_argument("--reveal", action="store_true")
    mode.add_argument("--execute", action="store_true")
    mode.add_argument("--session", action="store_true")
    mode.add_argument("--reconciliation-list", action="store_true")
    mode.add_argument("--reconciliation-describe", action="store_true")
    mode.add_argument("--reconciliation-archive", action="store_true")
    mode.add_argument("--acl-reconciliation-list", action="store_true")
    mode.add_argument("--acl-reconciliation-describe", action="store_true")
    mode.add_argument("--acl-reconciliation-archive", action="store_true")
    mode.add_argument("--self-test", action="store_true")
    parser.add_argument("--root")
    parser.add_argument("--journal-root")
    parser.add_argument("--acl-journal-root")
    parser.add_argument("--node")
    parser.add_argument("--crypto-script")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        _write_json(
            {
                "ok": True,
                "result": {
                    "version": APP_VERSION,
                    "unlimited_candidate_selection": True,
                    "indexed_candidate_revalidation": True,
                    "early_parser_stop": True,
                    "source_hash_required": True,
                    "persistent_session_protocol": True,
                    "reconciliation_progress_protocol": True,
                    "dashboard_progress_forwarding": True,
                    "authenticated_preflight_protocol": True,
                    "post_import_verification_protocol": True,
                    "authenticated_recovery_protocol": True,
                    "recovery_management_protocol": True,
                    "recoverable_archive_protocol": True,
                    "explicit_reveal_supported": True,
                    "protected_excel_integrity_supported": True,
                    "permission_editor_protocol": True,
                    "existing_acl_viewer_protocol": True,
                    "existing_acl_dry_run_protocol": True,
                    "existing_acl_additive_apply_protocol": True,
                    "existing_acl_restrictive_apply_protocol": True,
                    "existing_acl_recovery_protocol": True,
                    "dedicated_acl_journal_protocol": True,
                    "acl_journal_management_protocol": True,
                    "secrets_serialized": False,
                },
            }
        )
        return 0

    request: dict[str, Any] | None = None
    file_passwords: dict[str, str] = {}
    try:
        if args.reconciliation_list:
            _write_json(
                {
                    "ok": True,
                    "result": _reconciliation_list_result(args.journal_root),
                }
            )
            return 0
        if args.acl_reconciliation_list:
            _write_json(
                {
                    "ok": True,
                    "result": _acl_reconciliation_list_result(
                        args.acl_journal_root
                    ),
                }
            )
            return 0
        if args.acl_reconciliation_describe or args.acl_reconciliation_archive:
            request = _read_stdin_json()
            if args.acl_reconciliation_describe:
                operation_result = _acl_reconciliation_describe_result(
                    request,
                    args.acl_journal_root,
                )
            else:
                operation_result = _acl_reconciliation_archive_result(
                    request,
                    args.acl_journal_root,
                )
            _write_json({"ok": True, "result": operation_result})
            return 0
        if args.reconciliation_describe or args.reconciliation_archive:
            request = _read_stdin_json()
            if args.reconciliation_describe:
                operation_result = _reconciliation_describe_result(
                    request,
                    args.journal_root,
                )
            else:
                operation_result = _reconciliation_archive_result(
                    request,
                    args.journal_root,
                )
            _write_json({"ok": True, "result": operation_result})
            return 0
        if not args.root:
            raise ImportPreparationError("La cartella clienti non è configurata.")
        if args.session:
            if not args.node or not args.crypto_script:
                raise ImportPreparationError(
                    "Runtime Node.js o bridge OpenPGP non configurato."
                )
            return run_import_session(
                args.root,
                node_path=args.node,
                crypto_script=args.crypto_script,
                journal_root=args.journal_root,
                acl_journal_root=args.acl_journal_root,
            )
        request = _read_stdin_json()
        if args.integrity:
            file_passwords = _source_file_passwords(request.get("source_file_passwords"))
            result = {
                "ok": True,
                "result": verify_integrity(
                    args.root,
                    request.get("candidates", []),
                    source_file_passwords=file_passwords,
                ),
            }
        elif args.reveal:
            file_passwords = _source_file_passwords(request.get("source_file_passwords"))
            result = {
                "ok": True,
                "result": reveal_secrets(
                    args.root,
                    request.get("candidates", []),
                    source_file_passwords=file_passwords,
                ),
            }
        else:
            if not args.node or not args.crypto_script:
                raise ImportPreparationError(
                    "Runtime Node.js o bridge OpenPGP non configurato."
                )
            result = execute_import(
                args.root,
                request,
                node_path=args.node,
                crypto_script=args.crypto_script,
            )
    except ImportPreparationError as exc:
        _write_json(
            {
                "ok": False,
                "error": {
                    "code": "IMPORT_PREPARATION_FAILED",
                    "message": str(exc),
                },
            }
        )
        return 2
    finally:
        file_passwords.clear()
        if request is not None:
            for key in ("source_file_passwords", "secret_overrides"):
                entries = request.get(key)
                if isinstance(entries, list):
                    for entry in entries:
                        if isinstance(entry, dict) and "password" in entry:
                            entry["password"] = None
            request["passphrase"] = None
            request["mfa_totp"] = None
            request.clear()
    _write_json(result)
    return 0 if result.get("ok") else 2


if __name__ == "__main__":
    raise SystemExit(main())
