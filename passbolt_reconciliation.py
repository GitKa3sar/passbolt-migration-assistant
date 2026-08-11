"""Durable, secret-free reconciliation journals for Passbolt imports.

The live session workflow appends validated bridge progress events here.  The
recovery UI uses the same records only after revalidating remote state and
source identity through an authenticated Passbolt session.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import uuid
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, BinaryIO, Iterator, Mapping, Sequence
from urllib.parse import urlsplit


SCHEMA_VERSION = 1
MAX_JOURNAL_BYTES = 16 * 1024 * 1024
MAX_EVENT_BYTES = 64 * 1024
MAX_EVENTS = 10_000
MAX_CANDIDATES = 5_000
MAX_JOURNALS = 2_000

_JOURNAL_NAME = re.compile(
    r"^batch-(?P<batch_id>[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-"
    r"[89ab][0-9a-f]{3}-[0-9a-f]{12})\.jsonl$",
    re.IGNORECASE,
)
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_FINGERPRINT = re.compile(r"^[0-9A-F]{40}$")
_CANDIDATE_ID = re.compile(r"^[0-9a-f]{16}$")
_APP_VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$")
_ERROR_CODE = re.compile(r"^[A-Z][A-Z0-9_]{0,63}$")
_PGP_ARMOR = re.compile(r"-----BEGIN [^-\r\n]{1,80}-----", re.IGNORECASE)
_AUTHORIZATION = re.compile(r"\b(?:basic|bearer)\s+[A-Za-z0-9+/_.=-]{8,}", re.IGNORECASE)
_GITHUB_TOKEN = re.compile(r"\bgh[opusr]_[A-Za-z0-9_]{10,}\b")

_SENSITIVE_KEY_PARTS = (
    "password",
    "passphrase",
    "secret",
    "private_key",
    "privatekey",
    "authorization",
    "cookie",
    "session_id",
    "mfa",
    "totp",
)

_EVENT_FIELDS: dict[str, tuple[frozenset[str], frozenset[str]]] = {
    "batch_started": (
        frozenset(
            {
                "app_version",
                "server_origin",
                "server_fingerprint",
                "user_id_hash",
                "plan_digest",
                "resource_format",
                "folder_format",
                "destination_mode",
                "destination_folder_id",
                "candidate_count",
                "candidates",
            }
        ),
        frozenset({"destination_mapping_hash"}),
    ),
    "operation_intent": (
        frozenset({"operation_id", "object_type", "action"}),
        frozenset(
            {"candidate_id", "destination_key_hash", "permission_mask_hash"}
        ),
    ),
    "folder_created": (
        frozenset({"operation_id", "folder_id", "status"}),
        frozenset({"parent_folder_id", "destination_key_hash"}),
    ),
    "folder_shared": (
        frozenset({"operation_id", "folder_id", "status"}),
        frozenset({"added_user_count", "permission_change_count"}),
    ),
    "resource_created": (
        frozenset({"operation_id", "resource_id", "candidate_id", "status"}),
        frozenset(),
    ),
    "resource_shared": (
        frozenset({"operation_id", "resource_id", "candidate_id", "status"}),
        frozenset({"recipient_count", "permission_change_count"}),
    ),
    "duplicate_skipped": (
        frozenset({"candidate_id", "duplicate_kind"}),
        frozenset({"resource_id"}),
    ),
    "operation_failed": (
        frozenset({"operation_id", "error_code", "outcome"}),
        frozenset(
            {
                "object_type",
                "candidate_id",
                "folder_id",
                "resource_id",
                "http_status",
            }
        ),
    ),
    "operation_verified": (
        frozenset(
            {"recovery_id", "operation_id", "object_type", "resolution"}
        ),
        frozenset(
            {
                "candidate_id",
                "destination_key_hash",
                "folder_id",
                "resource_id",
            }
        ),
    ),
    "recovery_verified": (
        frozenset(
            {
                "recovery_id",
                "verification_digest",
                "verified_operation_count",
                "remote_success_count",
                "retry_count",
            }
        ),
        frozenset(),
    ),
    "batch_completed": (
        frozenset(
            {
                "created_folder_count",
                "reconciled_folder_count",
                "created_resource_count",
                "shared_resource_count",
                "skipped_duplicate_count",
            }
        ),
        frozenset(),
    ),
}

_ACTIONS = {
    "create_folder",
    "share_folder",
    "reconcile_folder",
    "create_resource",
    "share_resource",
}
_OBJECT_TYPES = {"folder", "resource"}
_FOLDER_STATUSES = {"created", "created_unshared", "created_shared", "reconciled_shared"}
_RESOURCE_STATUSES = {"created", "created_unshared", "created_shared"}
_FAILURE_OUTCOMES = {"not_started", "unknown", "partial", "confirmed"}
_VERIFICATION_RESOLUTIONS = {"remote_success", "not_applied"}
_DUPLICATE_KINDS = {"batch", "server_destination"}
_DESTINATION_MODES = {"client_folders", "client_mapping", "direct_folder", "root"}
_FORMATS = {"auto", "v4", "v5", "none"}


class ReconciliationJournalError(RuntimeError):
    """Safe journal failure that never contains journal payload values."""


class ReconciliationJournalCorrupt(ReconciliationJournalError):
    """The journal cannot be trusted and must not be resumed automatically."""


class ReconciliationJournalBusy(ReconciliationJournalError):
    """Another process is currently using the journal."""


@dataclass(frozen=True)
class CandidateProof:
    candidate_id: str
    source_sha256: str


@dataclass(frozen=True)
class JournalSnapshot:
    path: Path
    batch_id: str
    events: tuple[dict[str, Any], ...]
    truncated_tail: bool

    @property
    def complete(self) -> bool:
        return bool(self.events and self.events[-1]["event_type"] == "batch_completed")

    @property
    def requires_verification(self) -> bool:
        return self.truncated_tail or not self.complete

    @property
    def next_sequence(self) -> int:
        return len(self.events)

    @property
    def last_record_hash(self) -> str | None:
        if not self.events:
            return None
        return str(self.events[-1]["record_hash"])


@dataclass(frozen=True)
class ReconciliationBatchSummary:
    batch_id: str
    recorded_at: str | None
    status: str
    candidate_count: int | None
    event_count: int | None
    truncated_tail: bool


@dataclass(frozen=True)
class ReconciliationBatchDetails:
    batch_id: str
    recorded_at: str
    status: str
    candidate_count: int
    event_count: int
    truncated_tail: bool
    candidate_ids: tuple[str, ...]


@dataclass(frozen=True)
class ArchivedReconciliationBatch:
    batch_id: str
    previous_status: str
    archived_at: str


class ReconciliationJournalLease:
    """Process-held exclusive lease preventing concurrent recovery of one batch."""

    def __init__(self, path: Path, handle: BinaryIO) -> None:
        self.path = path
        self._handle: BinaryIO | None = handle

    def close(self) -> None:
        handle = self._handle
        if handle is None:
            return
        self._handle = None
        try:
            handle.seek(0)
            if os.name == "nt":
                import msvcrt

                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                import fcntl

                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        except OSError:
            pass
        handle.close()

    def __enter__(self) -> "ReconciliationJournalLease":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()


def _batch_uuid(value: object) -> str:
    return _uuid(value, "Identificativo lotto", version_four=True)


def default_journal_root() -> Path:
    """Return the per-user journal directory, always outside the repository."""

    local_app_data = os.environ.get("LOCALAPPDATA", "").strip()
    if local_app_data:
        base = Path(local_app_data)
    else:
        base = Path.home() / "AppData" / "Local"
    return base / "Passbolt Migration Assistant" / "Reconciliation"


def hash_user_identifier(user_id: str) -> str:
    """Create a stable identity guard without persisting the Passbolt user ID."""

    normalized = str(user_id).strip().lower()
    if not normalized or len(normalized) > 256:
        raise ReconciliationJournalError("Identificativo utente non valido.")
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest()


def hash_client_destination_mapping(value: object) -> str:
    """Hash a client mapping without persisting client labels."""

    if value is None:
        entries: list[dict[str, str | None]] = []
    elif isinstance(value, (list, tuple)) and len(value) <= MAX_CANDIDATES:
        entries = []
        seen: set[str] = set()
        for item in value:
            if not isinstance(item, Mapping) or set(item) != {"client", "folder_id"}:
                raise ReconciliationJournalError(
                    "Mappatura delle destinazioni non valida."
                )
            client = str(item["client"]).strip().casefold()
            if not client or len(client) > 256 or client in seen:
                raise ReconciliationJournalError(
                    "Mappatura delle destinazioni non valida."
                )
            seen.add(client)
            entries.append(
                {
                    "client_hash": hashlib.sha256(
                        client.encode("utf-8")
                    ).hexdigest(),
                    "folder_id": _optional_uuid(
                        item["folder_id"], "Cartella della mappatura"
                    ),
                }
            )
        entries.sort(key=lambda item: str(item["client_hash"]))
    else:
        raise ReconciliationJournalError("Mappatura delle destinazioni non valida.")
    return hashlib.sha256(_canonical_json(entries)).hexdigest()


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace(
        "+00:00", "Z"
    )


def _canonical_json(value: object) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def _record_hash(record_without_hash: Mapping[str, Any]) -> str:
    return hashlib.sha256(_canonical_json(record_without_hash)).hexdigest()


def _strict_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate JSON key")
        value[key] = item
    return value


def _uuid(value: object, label: str, *, version_four: bool = False) -> str:
    try:
        parsed = uuid.UUID(str(value))
    except (ValueError, AttributeError, TypeError) as exc:
        raise ReconciliationJournalError(f"{label} non valido.") from exc
    if version_four and parsed.version != 4:
        raise ReconciliationJournalError(f"{label} non valido.")
    return str(parsed)


def _optional_uuid(value: object, label: str) -> str | None:
    if value is None or str(value).strip() == "":
        return None
    return _uuid(value, label)


def _hex(value: object, pattern: re.Pattern[str], label: str, *, upper: bool = False) -> str:
    normalized = str(value).strip()
    normalized = normalized.upper() if upper else normalized.lower()
    if not pattern.fullmatch(normalized):
        raise ReconciliationJournalError(f"{label} non valido.")
    return normalized


def _count(value: object, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 1_000_000:
        raise ReconciliationJournalError(f"{label} non valido.")
    return value


def _server_origin(value: object) -> str:
    raw = str(value).strip()
    try:
        parsed = urlsplit(raw)
    except ValueError as exc:
        raise ReconciliationJournalError("Origine Passbolt non valida.") from exc
    if (
        parsed.scheme.lower() != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path not in {"", "/"}
        or parsed.query
        or parsed.fragment
    ):
        raise ReconciliationJournalError("Origine Passbolt non valida.")
    try:
        port = parsed.port
    except ValueError as exc:
        raise ReconciliationJournalError("Origine Passbolt non valida.") from exc
    host = parsed.hostname.lower()
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    return f"https://{host}{f':{port}' if port is not None else ''}"


def _reject_sensitive_value(value: object) -> None:
    if isinstance(value, Mapping):
        for key, nested in value.items():
            normalized_key = str(key).strip().lower().replace("-", "_")
            if any(part in normalized_key for part in _SENSITIVE_KEY_PARTS):
                raise ReconciliationJournalError(
                    "Il registro rifiuta campi che potrebbero contenere segreti."
                )
            _reject_sensitive_value(nested)
        return
    if isinstance(value, (list, tuple)):
        for nested in value:
            _reject_sensitive_value(nested)
        return
    if isinstance(value, str) and (
        _PGP_ARMOR.search(value)
        or _AUTHORIZATION.search(value)
        or _GITHUB_TOKEN.search(value)
    ):
        raise ReconciliationJournalError(
            "Il registro rifiuta valori che potrebbero contenere segreti."
        )


def _candidate_payload(value: object) -> list[dict[str, str]]:
    if not isinstance(value, (list, tuple)) or len(value) > MAX_CANDIDATES:
        raise ReconciliationJournalError("Elenco candidati del registro non valido.")
    normalized: list[dict[str, str]] = []
    seen: set[str] = set()
    for item in value:
        if isinstance(item, CandidateProof):
            candidate_id = item.candidate_id
            source_sha256 = item.source_sha256
        elif isinstance(item, Mapping) and set(item) == {"candidate_id", "source_sha256"}:
            candidate_id = item["candidate_id"]
            source_sha256 = item["source_sha256"]
        else:
            raise ReconciliationJournalError("Prova candidato del registro non valida.")
        candidate = _hex(candidate_id, _CANDIDATE_ID, "Identificativo candidato")
        source_hash = _hex(source_sha256, _SHA256, "Hash sorgente")
        if candidate in seen:
            raise ReconciliationJournalError("Il registro contiene candidati duplicati.")
        seen.add(candidate)
        normalized.append({"candidate_id": candidate, "source_sha256": source_hash})
    return sorted(normalized, key=lambda item: item["candidate_id"])


def _event_payload(event_type: str, value: Mapping[str, Any]) -> dict[str, Any]:
    if event_type not in _EVENT_FIELDS:
        raise ReconciliationJournalError("Tipo di evento del registro non supportato.")
    if not isinstance(value, Mapping):
        raise ReconciliationJournalError("Dati dell’evento non validi.")
    _reject_sensitive_value(value)
    required, optional = _EVENT_FIELDS[event_type]
    supplied = set(value)
    if not required.issubset(supplied) or supplied - required - optional:
        raise ReconciliationJournalError("Campi dell’evento non validi.")

    data = dict(value)
    if event_type == "batch_started":
        version = str(data["app_version"]).strip()
        if not _APP_VERSION.fullmatch(version):
            raise ReconciliationJournalError("Versione applicazione non valida.")
        candidates = _candidate_payload(data["candidates"])
        candidate_count = _count(data["candidate_count"], "Numero candidati")
        if candidate_count != len(candidates):
            raise ReconciliationJournalError("Numero candidati incoerente.")
        resource_format = str(data["resource_format"]).strip().lower()
        folder_format = str(data["folder_format"]).strip().lower()
        destination_mode = str(data["destination_mode"]).strip().lower()
        if resource_format not in _FORMATS or folder_format not in _FORMATS:
            raise ReconciliationJournalError("Formato del piano non valido.")
        if destination_mode not in _DESTINATION_MODES:
            raise ReconciliationJournalError("Destinazione del piano non valida.")
        destination_folder_id = _optional_uuid(
            data["destination_folder_id"], "Cartella di destinazione"
        )
        if destination_mode in {"root", "client_mapping"} and destination_folder_id:
            raise ReconciliationJournalError("Cartella di destinazione incoerente.")
        return {
            "app_version": version,
            "server_origin": _server_origin(data["server_origin"]),
            "server_fingerprint": _hex(
                data["server_fingerprint"],
                _FINGERPRINT,
                "Fingerprint server",
                upper=True,
            ),
            "user_id_hash": _hex(data["user_id_hash"], _SHA256, "Hash utente"),
            "plan_digest": _hex(data["plan_digest"], _SHA256, "Digest piano"),
            "resource_format": resource_format,
            "folder_format": folder_format,
            "destination_mode": destination_mode,
            "destination_folder_id": destination_folder_id,
            **(
                {
                    "destination_mapping_hash": _hex(
                        data["destination_mapping_hash"],
                        _SHA256,
                        "Hash mappatura destinazioni",
                    )
                }
                if "destination_mapping_hash" in data
                else {}
            ),
            "candidate_count": candidate_count,
            "candidates": candidates,
        }

    if "operation_id" in data:
        data["operation_id"] = _uuid(
            data["operation_id"], "Identificativo operazione", version_four=True
        )
    if "candidate_id" in data:
        data["candidate_id"] = _hex(
            data["candidate_id"], _CANDIDATE_ID, "Identificativo candidato"
        )
    if "destination_key_hash" in data:
        data["destination_key_hash"] = _hex(
            data["destination_key_hash"], _SHA256, "Hash destinazione"
        )
    if "permission_mask_hash" in data:
        data["permission_mask_hash"] = _hex(
            data["permission_mask_hash"], _SHA256, "Hash permessi"
        )
    if "verification_digest" in data:
        data["verification_digest"] = _hex(
            data["verification_digest"], _SHA256, "Digest verifica"
        )
    if "recovery_id" in data:
        data["recovery_id"] = _uuid(
            data["recovery_id"], "Identificativo recupero", version_four=True
        )
    for field in ("folder_id", "resource_id"):
        if field in data:
            data[field] = _uuid(data[field], field.replace("_", " ").capitalize())
    if "parent_folder_id" in data:
        data["parent_folder_id"] = _optional_uuid(
            data["parent_folder_id"], "Cartella superiore"
        )
    for field in (
        "added_user_count",
        "permission_change_count",
        "recipient_count",
        "created_folder_count",
        "reconciled_folder_count",
        "created_resource_count",
        "shared_resource_count",
        "skipped_duplicate_count",
        "verified_operation_count",
        "remote_success_count",
        "retry_count",
    ):
        if field in data:
            data[field] = _count(data[field], field.replace("_", " ").capitalize())

    if "object_type" in data:
        data["object_type"] = str(data["object_type"]).strip().lower()
        if data["object_type"] not in _OBJECT_TYPES:
            raise ReconciliationJournalError("Tipo di oggetto non valido.")
    if event_type == "operation_intent":
        data["action"] = str(data["action"]).strip().lower()
        if data["action"] not in _ACTIONS:
            raise ReconciliationJournalError("Azione del registro non valida.")
    if event_type in {"folder_created", "folder_shared"}:
        data["status"] = str(data["status"]).strip().lower()
        if data["status"] not in _FOLDER_STATUSES:
            raise ReconciliationJournalError("Stato cartella non valido.")
        if event_type == "folder_created" and data["status"] not in {
            "created",
            "created_unshared",
        }:
            raise ReconciliationJournalError("Stato di creazione cartella non valido.")
        if event_type == "folder_shared" and data["status"] not in {
            "created_shared",
            "reconciled_shared",
        }:
            raise ReconciliationJournalError("Stato di condivisione cartella non valido.")
    if event_type in {"resource_created", "resource_shared"}:
        data["status"] = str(data["status"]).strip().lower()
        if data["status"] not in _RESOURCE_STATUSES:
            raise ReconciliationJournalError("Stato risorsa non valido.")
        if event_type == "resource_created" and data["status"] not in {
            "created",
            "created_unshared",
        }:
            raise ReconciliationJournalError("Stato di creazione risorsa non valido.")
        if event_type == "resource_shared" and data["status"] != "created_shared":
            raise ReconciliationJournalError("Stato di condivisione risorsa non valido.")
    if event_type == "duplicate_skipped":
        data["duplicate_kind"] = str(data["duplicate_kind"]).strip().lower()
        if data["duplicate_kind"] not in _DUPLICATE_KINDS:
            raise ReconciliationJournalError("Tipo di duplicato non valido.")
        if data["duplicate_kind"] == "server_destination" and "resource_id" not in data:
            raise ReconciliationJournalError("Il duplicato remoto non contiene un ID.")
    if event_type == "operation_failed":
        error_code = str(data["error_code"]).strip().upper()
        if not _ERROR_CODE.fullmatch(error_code):
            raise ReconciliationJournalError("Codice errore non valido.")
        data["error_code"] = error_code
        data["outcome"] = str(data["outcome"]).strip().lower()
        if data["outcome"] not in _FAILURE_OUTCOMES:
            raise ReconciliationJournalError("Esito dell’errore non valido.")
        if "http_status" in data:
            status_code = data["http_status"]
            if (
                isinstance(status_code, bool)
                or not isinstance(status_code, int)
                or not 100 <= status_code <= 599
            ):
                raise ReconciliationJournalError("Stato HTTP non valido.")
    if event_type == "operation_verified":
        data["resolution"] = str(data["resolution"]).strip().lower()
        if data["resolution"] not in _VERIFICATION_RESOLUTIONS:
            raise ReconciliationJournalError("Esito della verifica non valido.")
    return data


def _make_record(
    *,
    batch_id: str,
    sequence: int,
    event_type: str,
    payload: Mapping[str, Any],
    previous_hash: str | None,
) -> dict[str, Any]:
    record: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "sequence": sequence,
        "batch_id": batch_id,
        "event_id": str(uuid.uuid4()),
        "recorded_at": _utc_now(),
        "event_type": event_type,
        "payload": _event_payload(event_type, payload),
        "previous_hash": previous_hash,
    }
    record["record_hash"] = _record_hash(record)
    encoded = _canonical_json(record) + b"\n"
    if len(encoded) > MAX_EVENT_BYTES:
        raise ReconciliationJournalError("Evento del registro troppo grande.")
    return record


def _validate_event_flow(events: Sequence[Mapping[str, Any]]) -> None:
    operations: dict[str, dict[str, Any]] = {}
    completed_operations: set[str] = set()
    verifications: dict[str, dict[str, dict[str, Any]]] = {}
    completed_recoveries: set[str] = set()
    folder_actions = {"create_folder", "share_folder", "reconcile_folder"}
    resource_actions = {"create_resource", "share_resource"}

    for event in events:
        event_type = str(event["event_type"])
        payload = event["payload"]
        if event_type == "operation_intent":
            operation_id = str(payload["operation_id"])
            if operation_id in operations:
                raise ReconciliationJournalError("Operazione duplicata nel registro.")
            action = str(payload["action"])
            object_type = str(payload["object_type"])
            if (action in folder_actions) != (object_type == "folder"):
                raise ReconciliationJournalError("Operazione e oggetto non coerenti.")
            if (action in resource_actions) != (object_type == "resource"):
                raise ReconciliationJournalError("Operazione e oggetto non coerenti.")
            if object_type == "resource" and "candidate_id" not in payload:
                raise ReconciliationJournalError("Operazione risorsa senza candidato.")
            if object_type == "folder" and "destination_key_hash" not in payload:
                raise ReconciliationJournalError("Operazione cartella senza destinazione.")
            operations[operation_id] = dict(payload)
            continue

        if event_type in {
            "folder_created",
            "folder_shared",
            "resource_created",
            "resource_shared",
            "operation_failed",
        }:
            operation_id = str(payload["operation_id"])
            intent = operations.get(operation_id)
            if intent is None or operation_id in completed_operations:
                raise ReconciliationJournalError("Esito senza operazione aperta.")
            expected_actions = {
                "folder_created": {"create_folder"},
                "folder_shared": {"share_folder", "reconcile_folder"},
                "resource_created": {"create_resource"},
                "resource_shared": {"share_resource"},
                "operation_failed": _ACTIONS,
            }[event_type]
            if intent["action"] not in expected_actions:
                raise ReconciliationJournalError("Esito non coerente con l’operazione.")
            if "object_type" in payload and payload["object_type"] != intent["object_type"]:
                raise ReconciliationJournalError("Tipo di oggetto dell’esito non coerente.")
            if "candidate_id" in payload and payload["candidate_id"] != intent.get(
                "candidate_id"
            ):
                raise ReconciliationJournalError("Candidato dell’esito non coerente.")
            if event_type == "folder_shared":
                expected_status = (
                    "reconciled_shared"
                    if intent["action"] == "reconcile_folder"
                    else "created_shared"
                )
                if payload["status"] != expected_status:
                    raise ReconciliationJournalError("Stato cartella non coerente.")
            completed_operations.add(operation_id)
            continue

        if event_type == "operation_verified":
            operation_id = str(payload["operation_id"])
            recovery_id = str(payload["recovery_id"])
            intent = operations.get(operation_id)
            if intent is None:
                raise ReconciliationJournalError(
                    "Verifica senza operazione registrata."
                )
            if recovery_id in completed_recoveries:
                raise ReconciliationJournalError(
                    "Verifica aggiunta dopo la chiusura del recupero."
                )
            recovery_items = verifications.setdefault(recovery_id, {})
            if operation_id in recovery_items:
                raise ReconciliationJournalError(
                    "Operazione verificata due volte nello stesso recupero."
                )
            if payload["object_type"] != intent["object_type"]:
                raise ReconciliationJournalError(
                    "Tipo di oggetto della verifica non coerente."
                )
            for field in ("candidate_id", "destination_key_hash"):
                if field in intent and field not in payload:
                    raise ReconciliationJournalError(
                        "Identità tecnica della verifica mancante."
                    )
                if field in payload and payload[field] != intent.get(field):
                    raise ReconciliationJournalError(
                        "Identità tecnica della verifica non coerente."
                    )
            action = str(intent["action"])
            resolution = str(payload["resolution"])
            object_id_field = (
                "folder_id" if intent["object_type"] == "folder" else "resource_id"
            )
            if resolution == "remote_success" and object_id_field not in payload:
                raise ReconciliationJournalError(
                    "Verifica remota riuscita senza identificatore dell’oggetto."
                )
            if action in {"share_folder", "reconcile_folder", "share_resource"}:
                if object_id_field not in payload:
                    raise ReconciliationJournalError(
                        "Verifica della condivisione senza identificatore remoto."
                    )
            recovery_items[operation_id] = dict(payload)
            continue

        if event_type == "recovery_verified":
            recovery_id = str(payload["recovery_id"])
            if recovery_id in completed_recoveries:
                raise ReconciliationJournalError("Recupero duplicato nel registro.")
            recovery_items = verifications.get(recovery_id, {})
            if set(recovery_items) != set(operations):
                raise ReconciliationJournalError(
                    "Il recupero non ha verificato tutte le operazioni registrate."
                )
            if payload["verified_operation_count"] != len(recovery_items):
                raise ReconciliationJournalError(
                    "Conteggio delle operazioni verificate non coerente."
                )
            remote_success_count = sum(
                item["resolution"] == "remote_success"
                for item in recovery_items.values()
            )
            if payload["remote_success_count"] != remote_success_count:
                raise ReconciliationJournalError(
                    "Conteggio delle verifiche remote non coerente."
                )
            retry_count = sum(
                item["resolution"] == "not_applied"
                for item in recovery_items.values()
            )
            if payload["retry_count"] != retry_count:
                raise ReconciliationJournalError(
                    "Conteggio delle operazioni da ripetere non coerente."
                )
            completed_operations.update(recovery_items)
            completed_recoveries.add(recovery_id)
            continue

        if event_type == "batch_completed":
            open_operations = set(operations) - completed_operations
            if open_operations:
                raise ReconciliationJournalError(
                    "Il lotto non può chiudersi con operazioni aperte."
                )


def _encoded_record(record: Mapping[str, Any]) -> bytes:
    encoded = _canonical_json(record) + b"\n"
    if len(encoded) > MAX_EVENT_BYTES:
        raise ReconciliationJournalError("Evento del registro troppo grande.")
    return encoded


def _prepare_root(root: Path) -> None:
    if root.exists() and (not root.is_dir() or root.is_symlink()):
        raise ReconciliationJournalError("Directory del registro non valida.")
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        root.chmod(stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR)
    except OSError:
        # LocalAppData already inherits the current user's Windows ACL.
        pass


def _write_all(file_descriptor: int, value: bytes) -> None:
    offset = 0
    while offset < len(value):
        written = os.write(file_descriptor, value[offset:])
        if written <= 0:
            raise ReconciliationJournalError("Scrittura del registro non riuscita.")
        offset += written


@contextmanager
def _locked_file(path: Path) -> Iterator[BinaryIO]:
    if path.is_symlink():
        raise ReconciliationJournalError("File del registro non valido.")
    handle = path.open("r+b", buffering=0)
    locked = False
    try:
        handle.seek(0)
        if os.name == "nt":
            import msvcrt

            try:
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            except OSError as exc:
                raise ReconciliationJournalBusy(
                    "Il registro è già utilizzato da un altro processo."
                ) from exc
        else:
            import fcntl

            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as exc:
                raise ReconciliationJournalBusy(
                    "Il registro è già utilizzato da un altro processo."
                ) from exc
        locked = True
        yield handle
    finally:
        if locked:
            try:
                handle.seek(0)
                if os.name == "nt":
                    import msvcrt

                    msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
                else:
                    import fcntl

                    fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
            except OSError:
                pass
        handle.close()


def _timestamp(value: object) -> str:
    raw = str(value)
    if not raw.endswith("Z"):
        raise ReconciliationJournalCorrupt("Data del registro non valida.")
    try:
        parsed = datetime.fromisoformat(raw[:-1] + "+00:00")
    except ValueError as exc:
        raise ReconciliationJournalCorrupt("Data del registro non valida.") from exc
    if parsed.tzinfo != timezone.utc:
        raise ReconciliationJournalCorrupt("Data del registro non valida.")
    return raw


def _decode_journal(path: Path, raw: bytes) -> JournalSnapshot:
    match = _JOURNAL_NAME.fullmatch(path.name)
    if not match:
        raise ReconciliationJournalCorrupt("Nome del registro non valido.")
    expected_batch_id = str(uuid.UUID(match.group("batch_id")))
    if not raw:
        raise ReconciliationJournalCorrupt("Registro vuoto.")
    if len(raw) > MAX_JOURNAL_BYTES:
        raise ReconciliationJournalCorrupt("Registro troppo grande.")

    truncated_tail = not raw.endswith(b"\n")
    lines = raw.splitlines()
    if truncated_tail:
        lines = lines[:-1]
    if not lines:
        raise ReconciliationJournalCorrupt("Intestazione del registro incompleta.")
    if len(lines) > MAX_EVENTS:
        raise ReconciliationJournalCorrupt("Il registro contiene troppi eventi.")

    events: list[dict[str, Any]] = []
    previous_hash: str | None = None
    terminal_seen = False
    expected_keys = {
        "schema_version",
        "sequence",
        "batch_id",
        "event_id",
        "recorded_at",
        "event_type",
        "payload",
        "previous_hash",
        "record_hash",
    }
    for sequence, line in enumerate(lines):
        if not line or len(line) + 1 > MAX_EVENT_BYTES:
            raise ReconciliationJournalCorrupt("Evento del registro non valido.")
        try:
            decoded = json.loads(
                line.decode("utf-8"), object_pairs_hook=_strict_json_object
            )
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
            raise ReconciliationJournalCorrupt("Registro danneggiato.") from exc
        if not isinstance(decoded, dict) or set(decoded) != expected_keys:
            raise ReconciliationJournalCorrupt("Struttura del registro non valida.")
        try:
            if (
                isinstance(decoded["schema_version"], bool)
                or not isinstance(decoded["schema_version"], int)
                or decoded["schema_version"] != SCHEMA_VERSION
            ):
                raise ReconciliationJournalCorrupt("Versione del registro non supportata.")
            if (
                isinstance(decoded["sequence"], bool)
                or not isinstance(decoded["sequence"], int)
                or decoded["sequence"] != sequence
            ):
                raise ReconciliationJournalCorrupt("Sequenza del registro non valida.")
            if _uuid(decoded["batch_id"], "Lotto", version_four=True) != expected_batch_id:
                raise ReconciliationJournalCorrupt("Identificativo del lotto non valido.")
            _uuid(decoded["event_id"], "Evento", version_four=True)
            _timestamp(decoded["recorded_at"])
            event_type = str(decoded["event_type"])
            normalized_payload = _event_payload(event_type, decoded["payload"])
        except ReconciliationJournalError as exc:
            if isinstance(exc, ReconciliationJournalCorrupt):
                raise
            raise ReconciliationJournalCorrupt("Contenuto del registro non valido.") from exc
        if normalized_payload != decoded["payload"]:
            raise ReconciliationJournalCorrupt("Contenuto del registro non canonico.")
        if decoded["previous_hash"] != previous_hash:
            raise ReconciliationJournalCorrupt("Catena del registro non valida.")
        supplied_hash = str(decoded["record_hash"])
        if not _SHA256.fullmatch(supplied_hash):
            raise ReconciliationJournalCorrupt("Hash del registro non valido.")
        material = dict(decoded)
        material.pop("record_hash")
        if _record_hash(material) != supplied_hash:
            raise ReconciliationJournalCorrupt("Integrità del registro non verificata.")
        if sequence == 0 and event_type != "batch_started":
            raise ReconciliationJournalCorrupt("Intestazione del registro mancante.")
        if sequence > 0 and event_type == "batch_started":
            raise ReconciliationJournalCorrupt("Intestazione del registro duplicata.")
        if terminal_seen:
            raise ReconciliationJournalCorrupt("Eventi presenti dopo la chiusura del lotto.")
        terminal_seen = event_type == "batch_completed"
        events.append(decoded)
        previous_hash = supplied_hash

    try:
        _validate_event_flow(events)
    except ReconciliationJournalError as exc:
        raise ReconciliationJournalCorrupt("Sequenza operativa del registro non valida.") from exc

    return JournalSnapshot(
        path=path,
        batch_id=expected_batch_id,
        events=tuple(events),
        truncated_tail=truncated_tail,
    )


def read_journal(path: str | Path) -> JournalSnapshot:
    journal_path = Path(path)
    if not journal_path.is_file() or journal_path.is_symlink():
        raise ReconciliationJournalError("File del registro non disponibile.")
    try:
        raw = journal_path.read_bytes()
    except OSError as exc:
        raise ReconciliationJournalError("Lettura del registro non riuscita.") from exc
    return _decode_journal(journal_path, raw)


def journal_path_for_batch(
    batch_id: object, root: str | Path | None = None
) -> Path:
    """Resolve a journal only by its canonical v4 UUID inside the journal root."""

    normalized = _batch_uuid(batch_id)
    journal_root = Path(root) if root is not None else default_journal_root()
    if not journal_root.is_dir() or journal_root.is_symlink():
        raise ReconciliationJournalError("Directory del registro non disponibile.")
    path = journal_root / f"batch-{normalized}.jsonl"
    if path.parent != journal_root:
        raise ReconciliationJournalError("Identificativo lotto non valido.")
    return path


def read_batch(
    batch_id: object, root: str | Path | None = None
) -> JournalSnapshot:
    """Read one exact batch without accepting a caller-controlled path."""

    return read_journal(journal_path_for_batch(batch_id, root))


def acquire_journal_lease(
    journal: "ReconciliationJournal",
) -> ReconciliationJournalLease:
    """Hold a separate one-byte lock for the whole verify/apply lifecycle."""

    snapshot = journal.read()
    return _acquire_path_lease(snapshot.path)


def _acquire_path_lease(journal_path: Path) -> ReconciliationJournalLease:
    """Acquire a batch lock after the caller resolved the canonical journal path."""

    if not journal_path.is_file() or journal_path.is_symlink():
        raise ReconciliationJournalError("File del registro non disponibile.")
    lock_path = journal_path.with_suffix(".lock")
    if lock_path.exists() and (not lock_path.is_file() or lock_path.is_symlink()):
        raise ReconciliationJournalError("File di lock del registro non valido.")
    flags = os.O_RDWR | os.O_CREAT
    if hasattr(os, "O_BINARY"):
        flags |= os.O_BINARY
    try:
        descriptor = os.open(lock_path, flags, 0o600)
        handle = os.fdopen(descriptor, "r+b", buffering=0)
    except OSError as exc:
        raise ReconciliationJournalError(
            "Impossibile aprire il lock del registro."
        ) from exc
    try:
        handle.seek(0, os.SEEK_END)
        if handle.tell() == 0:
            _write_all(handle.fileno(), b"\0")
            os.fsync(handle.fileno())
        handle.seek(0)
        if os.name == "nt":
            import msvcrt

            msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl

            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as exc:
        handle.close()
        raise ReconciliationJournalBusy(
            "Il lotto è già utilizzato da un’altra sessione."
        ) from exc
    return ReconciliationJournalLease(lock_path, handle)


def _snapshot_status(snapshot: JournalSnapshot) -> str:
    if snapshot.complete:
        return "complete"
    if snapshot.truncated_tail:
        return "truncated"
    return "recovery_required"


def list_reconciliation_batches(
    root: str | Path | None = None,
    *,
    incomplete_only: bool = True,
) -> tuple[ReconciliationBatchSummary, ...]:
    """List bounded, secret-free journal summaries for the recovery UI."""

    journal_root = Path(root) if root is not None else default_journal_root()
    if not journal_root.exists():
        return ()
    if not journal_root.is_dir() or journal_root.is_symlink():
        raise ReconciliationJournalError("Directory del registro non valida.")
    try:
        candidates = sorted(
            (
                path
                for path in journal_root.iterdir()
                if _JOURNAL_NAME.fullmatch(path.name)
            ),
            key=lambda path: path.name,
        )
    except OSError as exc:
        raise ReconciliationJournalError("Elenco dei registri non disponibile.") from exc
    if len(candidates) > MAX_JOURNALS:
        raise ReconciliationJournalError("Sono presenti troppi registri locali.")

    summaries: list[ReconciliationBatchSummary] = []
    for path in candidates:
        match = _JOURNAL_NAME.fullmatch(path.name)
        assert match is not None
        batch_id = str(uuid.UUID(match.group("batch_id")))
        try:
            snapshot = read_journal(path)
            header = snapshot.events[0]
            status = _snapshot_status(snapshot)
            if incomplete_only and status == "complete":
                continue
            summaries.append(
                ReconciliationBatchSummary(
                    batch_id=batch_id,
                    recorded_at=str(header["recorded_at"]),
                    status=status,
                    candidate_count=int(header["payload"]["candidate_count"]),
                    event_count=len(snapshot.events),
                    truncated_tail=snapshot.truncated_tail,
                )
            )
        except ReconciliationJournalError:
            summaries.append(
                ReconciliationBatchSummary(
                    batch_id=batch_id,
                    recorded_at=None,
                    status="corrupt",
                    candidate_count=None,
                    event_count=None,
                    truncated_tail=False,
                )
            )
    return tuple(
        sorted(
            summaries,
            key=lambda item: (item.recorded_at or "", item.batch_id),
            reverse=True,
        )
    )


def describe_reconciliation_batch(
    batch_id: object, root: str | Path | None = None
) -> ReconciliationBatchDetails:
    """Return bounded source proofs for one trusted batch selected by UUID."""

    snapshot = read_batch(batch_id, root)
    header = snapshot.events[0]
    payload = header["payload"]
    candidate_ids = tuple(
        str(candidate["candidate_id"]) for candidate in payload["candidates"]
    )
    return ReconciliationBatchDetails(
        batch_id=snapshot.batch_id,
        recorded_at=str(header["recorded_at"]),
        status=_snapshot_status(snapshot),
        candidate_count=int(payload["candidate_count"]),
        event_count=len(snapshot.events),
        truncated_tail=snapshot.truncated_tail,
        candidate_ids=candidate_ids,
    )


def archive_reconciliation_batch(
    batch_id: object,
    *,
    expected_status: object,
    confirmation: object,
    root: str | Path | None = None,
) -> ArchivedReconciliationBatch:
    """Move one exact journal into a status archive without deleting its evidence."""

    normalized_batch_id = _batch_uuid(batch_id)
    normalized_expected = str(expected_status).strip().lower()
    if normalized_expected not in {
        "complete",
        "recovery_required",
        "truncated",
        "corrupt",
    }:
        raise ReconciliationJournalError("Stato atteso del lotto non valido.")
    if str(confirmation).strip() != f"ARCHIVIA {normalized_batch_id}":
        raise ReconciliationJournalError("Conferma di archiviazione non valida.")

    journal_path = journal_path_for_batch(normalized_batch_id, root)
    lease = _acquire_path_lease(journal_path)
    archive_path: Path | None = None
    previous_status = "corrupt"
    try:
        try:
            snapshot = read_journal(journal_path)
            previous_status = _snapshot_status(snapshot)
        except ReconciliationJournalCorrupt:
            previous_status = "corrupt"
        except ReconciliationJournalError:
            previous_status = "corrupt"
        if previous_status != normalized_expected:
            raise ReconciliationJournalError(
                "Lo stato del lotto è cambiato; aggiornare l’elenco prima di archiviarlo."
            )

        journal_root = journal_path.parent
        archive_base = journal_root / "Archive"
        _prepare_root(archive_base)
        archive_root = archive_base / previous_status
        _prepare_root(archive_root)
        archive_path = archive_root / journal_path.name
        if archive_path.exists() or archive_path.is_symlink():
            raise ReconciliationJournalError("Il lotto risulta già archiviato.")
        try:
            journal_path.rename(archive_path)
        except OSError as exc:
            raise ReconciliationJournalError(
                "Archiviazione del registro non riuscita."
            ) from exc
    finally:
        lock_path = lease.path
        lease.close()

    archived_lock_path = archive_path.with_suffix(".lock") if archive_path else None
    if lock_path.exists():
        if not lock_path.is_file() or lock_path.is_symlink():
            raise ReconciliationJournalError(
                "Il registro è archiviato, ma il relativo lock non è valido."
            )
        if archived_lock_path is not None and archived_lock_path.exists():
            raise ReconciliationJournalError(
                "Il registro è archiviato, ma il relativo lock esiste già."
            )
        try:
            if archived_lock_path is not None:
                lock_path.rename(archived_lock_path)
        except OSError as exc:
            raise ReconciliationJournalError(
                "Il registro è archiviato, ma il relativo lock non è stato spostato."
            ) from exc

    return ArchivedReconciliationBatch(
        batch_id=normalized_batch_id,
        previous_status=previous_status,
        archived_at=_utc_now(),
    )


def build_recovery_state(snapshot: JournalSnapshot) -> dict[str, Any]:
    """Build the bounded, secret-free technical state sent to the Node bridge."""

    if snapshot.complete:
        raise ReconciliationJournalError("Il lotto è già completato.")
    if snapshot.truncated_tail:
        raise ReconciliationJournalCorrupt(
            "Il registro contiene una scrittura incompleta; la ripresa automatica è bloccata."
        )
    if not snapshot.events or snapshot.events[0]["event_type"] != "batch_started":
        raise ReconciliationJournalCorrupt("Intestazione del registro mancante.")

    header = dict(snapshot.events[0]["payload"])
    operations: dict[str, dict[str, Any]] = {}
    duplicate_candidates: list[dict[str, Any]] = []
    for event in snapshot.events[1:]:
        event_type = str(event["event_type"])
        payload = dict(event["payload"])
        if event_type == "operation_intent":
            operation_id = str(payload["operation_id"])
            operations[operation_id] = {
                **payload,
                "recorded_outcome": None,
            }
        elif event_type in {
            "folder_created",
            "folder_shared",
            "resource_created",
            "resource_shared",
            "operation_failed",
        }:
            operation = operations.get(str(payload["operation_id"]))
            if operation is None:
                raise ReconciliationJournalCorrupt(
                    "Esito senza operazione nel registro."
                )
            operation["recorded_outcome"] = {
                "event_type": event_type,
                **payload,
            }
        elif event_type == "duplicate_skipped":
            duplicate_candidates.append(payload)

    return {
        "schema_version": SCHEMA_VERSION,
        "batch_id": snapshot.batch_id,
        "server_origin": header["server_origin"],
        "server_fingerprint": header["server_fingerprint"],
        "user_id_hash": header["user_id_hash"],
        "plan_digest": header["plan_digest"],
        "resource_format": header["resource_format"],
        "folder_format": header["folder_format"],
        "destination_mode": header["destination_mode"],
        "destination_folder_id": header["destination_folder_id"],
        **(
            {"destination_mapping_hash": header["destination_mapping_hash"]}
            if "destination_mapping_hash" in header
            else {}
        ),
        "candidate_count": header["candidate_count"],
        "candidates": list(header["candidates"]),
        "operations": list(operations.values()),
        "duplicate_candidates": duplicate_candidates,
    }


class ReconciliationJournal:
    """Single-writer durable event journal for one import batch."""

    def __init__(self, path: Path, batch_id: str) -> None:
        self.path = path
        self.batch_id = batch_id

    @classmethod
    def create(
        cls,
        *,
        app_version: str,
        server_origin: str,
        server_fingerprint: str,
        user_id_hash: str,
        plan_digest: str,
        resource_format: str,
        folder_format: str,
        destination_mode: str,
        destination_folder_id: str | None,
        candidates: Sequence[CandidateProof | Mapping[str, str]],
        destination_mapping_hash: str | None = None,
        root: str | Path | None = None,
    ) -> "ReconciliationJournal":
        journal_root = Path(root) if root is not None else default_journal_root()
        _prepare_root(journal_root)
        batch_id = str(uuid.uuid4())
        path = journal_root / f"batch-{batch_id}.jsonl"
        payload = {
            "app_version": app_version,
            "server_origin": server_origin,
            "server_fingerprint": server_fingerprint,
            "user_id_hash": user_id_hash,
            "plan_digest": plan_digest,
            "resource_format": resource_format,
            "folder_format": folder_format,
            "destination_mode": destination_mode,
            "destination_folder_id": destination_folder_id,
            **(
                {"destination_mapping_hash": destination_mapping_hash}
                if destination_mapping_hash is not None
                else {}
            ),
            "candidate_count": len(candidates),
            "candidates": list(candidates),
        }
        record = _make_record(
            batch_id=batch_id,
            sequence=0,
            event_type="batch_started",
            payload=payload,
            previous_hash=None,
        )
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_BINARY"):
            flags |= os.O_BINARY
        try:
            descriptor = os.open(path, flags, 0o600)
            try:
                _write_all(descriptor, _encoded_record(record))
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            try:
                path.chmod(stat.S_IRUSR | stat.S_IWUSR)
            except OSError:
                pass
        except OSError as exc:
            raise ReconciliationJournalError("Creazione del registro non riuscita.") from exc
        return cls(path, batch_id)

    @classmethod
    def open(cls, path: str | Path) -> "ReconciliationJournal":
        snapshot = read_journal(path)
        return cls(snapshot.path, snapshot.batch_id)

    def read(self) -> JournalSnapshot:
        return read_journal(self.path)

    def append(self, event_type: str, **payload: Any) -> dict[str, Any]:
        try:
            with _locked_file(self.path) as handle:
                handle.seek(0, os.SEEK_END)
                size = handle.tell()
                if size > MAX_JOURNAL_BYTES:
                    raise ReconciliationJournalError("Registro troppo grande.")
                handle.seek(0)
                raw = handle.read(MAX_JOURNAL_BYTES + 1)
                snapshot = _decode_journal(self.path, raw)
                if snapshot.batch_id != self.batch_id:
                    raise ReconciliationJournalCorrupt(
                        "Identificativo del registro non verificato."
                    )
                if snapshot.truncated_tail:
                    raise ReconciliationJournalCorrupt(
                        "Il registro contiene una scrittura incompleta; verificare il lotto."
                    )
                if snapshot.complete:
                    raise ReconciliationJournalError("Il lotto è già completato.")
                record = _make_record(
                    batch_id=self.batch_id,
                    sequence=snapshot.next_sequence,
                    event_type=event_type,
                    payload=payload,
                    previous_hash=snapshot.last_record_hash,
                )
                _validate_event_flow((*snapshot.events, record))
                encoded = _encoded_record(record)
                if size + len(encoded) > MAX_JOURNAL_BYTES:
                    raise ReconciliationJournalError("Registro troppo grande.")
                handle.seek(0, os.SEEK_END)
                _write_all(handle.fileno(), encoded)
                os.fsync(handle.fileno())
                return record
        except FileNotFoundError as exc:
            raise ReconciliationJournalError("File del registro non disponibile.") from exc
