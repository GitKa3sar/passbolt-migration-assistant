"""Durable, secret-free reconciliation journals for Passbolt imports.

The live session workflow appends validated bridge progress events here.  The
future recovery UI will use the same records only after revalidating remote
state and source identity through an authenticated Passbolt session.
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
        frozenset(),
    ),
    "operation_intent": (
        frozenset({"operation_id", "object_type", "action"}),
        frozenset({"candidate_id", "destination_key_hash"}),
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
