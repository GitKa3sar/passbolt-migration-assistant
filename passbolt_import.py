#!/usr/bin/env python3
"""Integrity gate and in-memory secret handoff for Passbolt imports.

Reviewed candidates contain no cleartext secrets. Immediately before a dry-run
or write, this module re-opens only the reviewed source files, verifies their
SHA-256 digests, reconstructs the selected candidate records, and (for a write)
passes the secrets directly to the local OpenPGP bridge over stdin.
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
from typing import Any, Iterable

from passbolt_review import (
    MAX_FILE_BYTES,
    REVIEWABLE_EXTENSIONS,
    SECRET_KEYS,
    ReviewError,
    _find_field,
    _make_candidate,
    _records_for_file,
    _safe_selected_path,
    _sha256,
)


APP_VERSION = "0.12.1"
MAX_IMPORT_CANDIDATES = 25
MAX_SECRET_CHARACTERS = 65_536
MAX_STDIN_BYTES = 4 * 1024 * 1024
MAX_BRIDGE_OUTPUT_BYTES = 4 * 1024 * 1024
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
    if not title or len(title) > 255:
        raise ImportPreparationError("Ogni candidato deve avere un titolo di massimo 255 caratteri.")
    if len(username) > 255 or len(uri) > 2048:
        raise ImportPreparationError("Username o URL superano i limiti consentiti.")
    return SelectedCandidate(
        candidate_id=candidate_id,
        source_relative_path=relative_path,
        source_sha256=source_sha256,
        client=client,
        source_at_root=source_at_root,
        title=title,
        username=username,
        uri=uri,
    )


def _selected_candidates(values: object) -> list[SelectedCandidate]:
    if not isinstance(values, list) or not values:
        raise ImportPreparationError("Selezionare almeno un candidato pronto.")
    if len(values) > MAX_IMPORT_CANDIDATES:
        raise ImportPreparationError(
            f"Selezionare al massimo {MAX_IMPORT_CANDIDATES} candidati per importazione."
        )
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


def extract_resources(
    root: str | Path,
    requests: Iterable[object],
    *,
    include_secrets: bool,
) -> tuple[list[dict[str, str]], int]:
    """Revalidate reviewed candidates and optionally return their secrets.

    The returned cleartext password is intended only for an immediate stdin
    handoff to the crypto bridge. Callers must never serialize it elsewhere.
    """

    root_path = Path(root).expanduser().resolve()
    if not root_path.is_dir():
        raise ImportPreparationError("La cartella clienti non esiste o non è accessibile.")
    selected = _selected_candidates(list(requests))
    by_path: dict[str, list[SelectedCandidate]] = {}
    for candidate in selected:
        by_path.setdefault(candidate.source_relative_path, []).append(candidate)

    extracted: dict[str, dict[str, str]] = {}
    for supplied_path, wanted in by_path.items():
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
        wanted_ids = {candidate.candidate_id for candidate in wanted}
        try:
            for location, record in _records_for_file(path, extension):
                candidate = _make_candidate(
                    record,
                    relative_path=relative_path,
                    source_hash=current_hash,
                    client=client,
                    location=location,
                )
                if candidate is None or candidate.candidate_id not in wanted_ids:
                    continue
                request = next(
                    item for item in wanted if item.candidate_id == candidate.candidate_id
                )
                if (
                    candidate.status != "ready"
                    or candidate.client != request.client
                    or source_at_root != request.source_at_root
                    or candidate.title != request.title
                    or candidate.username != request.username
                    or candidate.uri != request.uri
                ):
                    raise ImportPreparationError(
                        "I metadati di un candidato non corrispondono più alla revisione."
                    )
                resource = {
                    "candidate_id": candidate.candidate_id,
                    "title": candidate.title,
                    "username": candidate.username,
                    "uri": candidate.uri,
                }
                if include_secrets:
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


def verify_integrity(root: str | Path, requests: Iterable[object]) -> dict[str, Any]:
    resources, source_count = extract_resources(
        root, requests, include_secrets=False
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
    resources, _ = extract_resources(root, create_requests, include_secrets=True)
    return candidates, resources


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
    root: str | Path, request: dict[str, Any]
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
        verify_integrity(root, candidates if isinstance(candidates, list) else [])
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
                "candidates": candidates,
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
                "candidates": candidates,
                "resources": resources,
                "plan_digest": request.get("plan_digest"),
                "confirmation": request.get("confirmation"),
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


def _bridge_line_exchange(
    process: subprocess.Popen[bytes], request: dict[str, Any]
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
        raw = process.stdout.readline(MAX_BRIDGE_OUTPUT_BYTES + 1)
    except (OSError, ValueError) as exc:
        raise ImportPreparationError(
            "La sessione OpenPGP locale non è più disponibile."
        ) from exc
    finally:
        encoded = b""
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
    if not isinstance(result, dict) or not isinstance(result.get("ok"), bool):
        raise ImportPreparationError(
            "La sessione OpenPGP locale ha restituito una struttura inattesa."
        )
    return result


def run_import_session(
    root: str | Path, *, node_path: str, crypto_script: str
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
                document = json.loads(raw.decode("utf-8"))
                if not isinstance(document, dict):
                    raise ImportPreparationError(
                        "La richiesta della sessione deve essere un oggetto JSON."
                    )
                request = document
                command = str(request.get("command", ""))
                bridge_request, resources = _session_bridge_request(root_path, request)
                result = _bridge_line_exchange(process, bridge_request)
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
                _write_json(
                    {
                        "ok": False,
                        "error": {
                            "code": "IMPORT_PREPARATION_FAILED",
                            "message": str(exc),
                        },
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
                    request["passphrase"] = None
                    request["mfa_totp"] = None
                    request.clear()
            if command == "session-close":
                break
    finally:
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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Controllo integrità e handoff in memoria per l’importazione Passbolt."
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--integrity", action="store_true")
    mode.add_argument("--execute", action="store_true")
    mode.add_argument("--session", action="store_true")
    mode.add_argument("--self-test", action="store_true")
    parser.add_argument("--root")
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
                    "max_import_candidates": MAX_IMPORT_CANDIDATES,
                    "source_hash_required": True,
                    "persistent_session_protocol": True,
                    "secrets_serialized": False,
                },
            }
        )
        return 0

    try:
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
            )
        request = _read_stdin_json()
        if args.integrity:
            result = {
                "ok": True,
                "result": verify_integrity(args.root, request.get("candidates", [])),
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
    _write_json(result)
    return 0 if result.get("ok") else 2


if __name__ == "__main__":
    raise SystemExit(main())
