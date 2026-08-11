"""Durable, secret-free journals for ACL updates on existing Passbolt objects."""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping, Sequence

from passbolt_reconciliation import (
    ReconciliationJournalBusy,
    ReconciliationJournalCorrupt,
    ReconciliationJournalError,
    ReconciliationJournalLease,
    _acquire_path_lease,
    _locked_file,
    _prepare_root,
    _server_origin,
    _write_all,
)


SCHEMA_VERSION = 1
MAX_JOURNAL_BYTES = 1024 * 1024
MAX_EVENT_BYTES = 64 * 1024
MAX_EVENTS = 100
MAX_JOURNALS = 2_000

_NAME = re.compile(
    r"^acl-batch-(?P<batch_id>[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-"
    r"[89ab][0-9a-f]{3}-[0-9a-f]{12})\.jsonl$",
    re.IGNORECASE,
)
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_FINGERPRINT = re.compile(r"^[0-9A-F]{40}$")
_APP_VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$")
_ERROR_CODE = re.compile(r"^[A-Z][A-Z0-9_]{0,63}$")
_SENSITIVE_KEYS = (
    "password", "passphrase", "secret", "private_key", "authorization",
    "cookie", "session_id", "mfa", "totp",
)
_PGP_ARMOR = re.compile(r"-----BEGIN [^-\r\n]{1,80}-----", re.IGNORECASE)


@dataclass(frozen=True)
class AclJournalSnapshot:
    path: Path
    batch_id: str
    events: tuple[dict[str, Any], ...]
    truncated_tail: bool

    @property
    def complete(self) -> bool:
        return bool(self.events and self.events[-1]["event_type"] == "acl_batch_completed")

    @property
    def next_sequence(self) -> int:
        return len(self.events)

    @property
    def last_record_hash(self) -> str | None:
        return str(self.events[-1]["record_hash"]) if self.events else None


@dataclass(frozen=True)
class AclBatchSummary:
    batch_id: str
    recorded_at: str | None
    status: str
    object_type: str | None
    object_id: str | None
    change_count: int | None
    event_count: int | None
    truncated_tail: bool


def default_acl_journal_root() -> Path:
    local_app_data = os.environ.get("LOCALAPPDATA", "").strip()
    base = Path(local_app_data) if local_app_data else Path.home() / "AppData" / "Local"
    return base / "Passbolt Migration Assistant" / "AclReconciliation"


def _canonical(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _strict_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def _uuid4(value: object, label: str) -> str:
    try:
        parsed = uuid.UUID(str(value))
    except (ValueError, TypeError, AttributeError) as exc:
        raise ReconciliationJournalError(f"{label} non valido.") from exc
    if parsed.version != 4:
        raise ReconciliationJournalError(f"{label} non valido.")
    return str(parsed)


def _digest(value: object, label: str) -> str:
    normalized = str(value).strip().lower()
    if not _SHA256.fullmatch(normalized):
        raise ReconciliationJournalError(f"{label} non valido.")
    return normalized


def _technical_id(value: object, label: str) -> str:
    normalized = str(value).strip()
    if not normalized or len(normalized) > 200 or any(ord(c) < 32 or ord(c) == 127 for c in normalized):
        raise ReconciliationJournalError(f"{label} non valido.")
    return normalized


def _count(value: object, label: str, *, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= 2_000:
        raise ReconciliationJournalError(f"{label} non valido.")
    return value


def _permissions(value: object) -> list[dict[str, str | int]]:
    if not isinstance(value, (list, tuple)) or len(value) > 500:
        raise ReconciliationJournalError("ACL desiderata non valida.")
    normalized: list[dict[str, str | int]] = []
    seen: set[str] = set()
    for item in value:
        if not isinstance(item, Mapping) or set(item) != {"aro", "aro_foreign_key", "type"}:
            raise ReconciliationJournalError("Voce della ACL desiderata non valida.")
        aro = str(item["aro"])
        subject_id = _technical_id(item["aro_foreign_key"], "Soggetto ACL")
        permission_type = item["type"]
        if aro not in {"User", "Group"} or isinstance(permission_type, bool) or permission_type not in {1, 7, 15}:
            raise ReconciliationJournalError("Voce della ACL desiderata non valida.")
        key = f"{aro}:{subject_id}"
        if key in seen:
            raise ReconciliationJournalError("Soggetto duplicato nella ACL desiderata.")
        seen.add(key)
        normalized.append({"aro": aro, "aro_foreign_key": subject_id, "type": permission_type})
    normalized.sort(key=lambda item: (str(item["aro"]), str(item["aro_foreign_key"])))
    return normalized


def _reject_sensitive(value: object) -> None:
    if isinstance(value, Mapping):
        for key, nested in value.items():
            normalized = str(key).strip().lower().replace("-", "_")
            if any(part in normalized for part in _SENSITIVE_KEYS):
                raise ReconciliationJournalError("Il journal ACL rifiuta campi sensibili.")
            _reject_sensitive(nested)
    elif isinstance(value, (list, tuple)):
        for nested in value:
            _reject_sensitive(nested)
    elif isinstance(value, str) and _PGP_ARMOR.search(value):
        raise ReconciliationJournalError("Il journal ACL rifiuta materiale OpenPGP.")


def _payload(event_type: str, raw: Mapping[str, Any]) -> dict[str, Any]:
    if not isinstance(raw, Mapping):
        raise ReconciliationJournalError("Payload del journal ACL non valido.")
    _reject_sensitive(raw)
    fields: dict[str, tuple[set[str], set[str]]] = {
        "acl_batch_started": ({
            "app_version", "server_origin", "server_fingerprint", "user_id_hash",
            "object_type", "object_id", "object_state_digest", "desired_acl_digest",
            "plan_digest", "desired_permissions", "change_count", "add_count", "upgrade_count",
        }, {"downgrade_count", "revoke_count", "apply_mode"}),
        "acl_operation_intent": ({
            "operation_id", "object_type", "object_id", "permission_change_count", "added_user_count",
        }, {"removed_user_count", "restrictive_change_count"}),
        "acl_operation_applied": ({
            "operation_id", "object_type", "object_id", "permission_change_count", "added_user_count",
        }, {"removed_user_count", "restrictive_change_count"}),
        "acl_operation_failed": ({
            "operation_id", "object_type", "object_id", "error_code", "outcome",
        }, {"http_status"}),
        "acl_recovery_verified": ({
            "recovery_id", "resolution", "remote_acl_digest", "recovery_plan_digest",
        }, set()),
        "acl_batch_completed": ({
            "object_type", "object_id", "resulting_acl_digest", "applied_change_count",
            "permission_change_count", "added_user_count", "recovered",
        }, {"removed_user_count", "restrictive_change_count", "destructive_actions_performed"}),
    }
    if event_type not in fields:
        raise ReconciliationJournalError("Tipo di evento ACL non supportato.")
    required, optional = fields[event_type]
    if not required.issubset(raw) or set(raw) - required - optional:
        raise ReconciliationJournalError("Campi dell’evento ACL non validi.")
    data = dict(raw)
    if event_type == "acl_batch_started":
        version = str(data["app_version"]).strip()
        if not _APP_VERSION.fullmatch(version):
            raise ReconciliationJournalError("Versione applicazione non valida.")
        fingerprint = str(data["server_fingerprint"]).strip().upper()
        if not _FINGERPRINT.fullmatch(fingerprint):
            raise ReconciliationJournalError("Fingerprint server non valida.")
        user_hash = _digest(data["user_id_hash"], "Hash utente")
        permissions = _permissions(data["desired_permissions"])
        change_count = _count(data["change_count"], "Numero modifiche", minimum=1)
        add_count = _count(data["add_count"], "Numero aggiunte")
        upgrade_count = _count(data["upgrade_count"], "Numero aumenti")
        restrictive_fields = {"downgrade_count", "revoke_count", "apply_mode"}
        has_restrictive_metadata = bool(restrictive_fields.intersection(data))
        if has_restrictive_metadata and not restrictive_fields.issubset(data):
            raise ReconciliationJournalError("Metadati restrittivi ACL incompleti.")
        downgrade_count = _count(data.get("downgrade_count", 0), "Numero riduzioni")
        revoke_count = _count(data.get("revoke_count", 0), "Numero revoche")
        if change_count != add_count + upgrade_count + downgrade_count + revoke_count:
            raise ReconciliationJournalError("Conteggi ACL incoerenti.")
        expected_mode = "additive" if downgrade_count + revoke_count == 0 else (
            "mixed" if add_count + upgrade_count > 0 else "restrictive"
        )
        if has_restrictive_metadata and str(data["apply_mode"]).strip().lower() != expected_mode:
            raise ReconciliationJournalError("Modalità ACL incoerente con i conteggi.")
        result = {
            "app_version": version,
            "server_origin": _server_origin(data["server_origin"]),
            "server_fingerprint": fingerprint,
            "user_id_hash": user_hash,
            "object_type": _object_type(data["object_type"]),
            "object_id": _technical_id(data["object_id"], "Oggetto ACL"),
            "object_state_digest": _digest(data["object_state_digest"], "Digest snapshot"),
            "desired_acl_digest": _digest(data["desired_acl_digest"], "Digest ACL desiderata"),
            "plan_digest": _digest(data["plan_digest"], "Digest piano"),
            "desired_permissions": permissions,
            "change_count": change_count,
            "add_count": add_count,
            "upgrade_count": upgrade_count,
        }
        if has_restrictive_metadata:
            result.update({
                "downgrade_count": downgrade_count,
                "revoke_count": revoke_count,
                "apply_mode": expected_mode,
            })
        return result
    if event_type in {"acl_operation_intent", "acl_operation_applied"}:
        has_restrictive_metadata = "removed_user_count" in data or "restrictive_change_count" in data
        if has_restrictive_metadata and not {"removed_user_count", "restrictive_change_count"}.issubset(data):
            raise ReconciliationJournalError("Impatto effettivo ACL incompleto.")
        result = {
            "operation_id": _uuid4(data["operation_id"], "Operazione ACL"),
            "object_type": _object_type(data["object_type"]),
            "object_id": _technical_id(data["object_id"], "Oggetto ACL"),
            "permission_change_count": _count(data["permission_change_count"], "Modifiche permesso", minimum=1),
            "added_user_count": _count(data["added_user_count"], "Nuovi utenti"),
        }
        if has_restrictive_metadata:
            result.update({
                "removed_user_count": _count(data["removed_user_count"], "Utenti rimossi"),
                "restrictive_change_count": _count(data["restrictive_change_count"], "Modifiche restrittive"),
            })
        return result
    if event_type == "acl_operation_failed":
        error_code = str(data["error_code"]).strip().upper()
        if not _ERROR_CODE.fullmatch(error_code) or str(data["outcome"]).strip().lower() not in {"unknown", "not_started", "confirmed"}:
            raise ReconciliationJournalError("Esito dell’operazione ACL non valido.")
        result: dict[str, Any] = {
            "operation_id": _uuid4(data["operation_id"], "Operazione ACL"),
            "object_type": _object_type(data["object_type"]),
            "object_id": _technical_id(data["object_id"], "Oggetto ACL"),
            "error_code": error_code,
            "outcome": str(data["outcome"]).strip().lower(),
        }
        if "http_status" in data:
            status = data["http_status"]
            if isinstance(status, bool) or not isinstance(status, int) or not 100 <= status <= 599:
                raise ReconciliationJournalError("Stato HTTP non valido.")
            result["http_status"] = status
        return result
    if event_type == "acl_recovery_verified":
        resolution = str(data["resolution"]).strip().lower()
        if resolution not in {"remote_success", "not_applied"}:
            raise ReconciliationJournalError("Esito della verifica ACL non valido.")
        return {
            "recovery_id": _uuid4(data["recovery_id"], "Recupero ACL"),
            "resolution": resolution,
            "remote_acl_digest": _digest(data["remote_acl_digest"], "Digest ACL remota"),
            "recovery_plan_digest": _digest(data["recovery_plan_digest"], "Digest piano di recupero"),
        }
    if not isinstance(data["recovered"], bool):
        raise ReconciliationJournalError("Indicatore di recupero non valido.")
    restrictive_completion_fields = {"removed_user_count", "restrictive_change_count", "destructive_actions_performed"}
    has_restrictive_metadata = bool(restrictive_completion_fields.intersection(data))
    if has_restrictive_metadata and not restrictive_completion_fields.issubset(data):
        raise ReconciliationJournalError("Esito restrittivo ACL incompleto.")
    result = {
        "object_type": _object_type(data["object_type"]),
        "object_id": _technical_id(data["object_id"], "Oggetto ACL"),
        "resulting_acl_digest": _digest(data["resulting_acl_digest"], "Digest ACL risultante"),
        "applied_change_count": _count(data["applied_change_count"], "Modifiche applicate"),
        "permission_change_count": _count(data["permission_change_count"], "Modifiche permesso"),
        "added_user_count": _count(data["added_user_count"], "Nuovi utenti"),
        "recovered": data["recovered"],
    }
    if has_restrictive_metadata:
        destructive = data["destructive_actions_performed"]
        if not isinstance(destructive, bool):
            raise ReconciliationJournalError("Indicatore di azione restrittiva non valido.")
        restrictive_count = _count(data["restrictive_change_count"], "Modifiche restrittive")
        if destructive != (restrictive_count > 0):
            raise ReconciliationJournalError("Esito restrittivo ACL incoerente.")
        result.update({
            "removed_user_count": _count(data["removed_user_count"], "Utenti rimossi"),
            "restrictive_change_count": restrictive_count,
            "destructive_actions_performed": destructive,
        })
    return result


def _object_type(value: object) -> str:
    normalized = str(value).strip().lower()
    if normalized not in {"folder", "resource"}:
        raise ReconciliationJournalError("Tipo di oggetto ACL non valido.")
    return normalized


def _record(batch_id: str, sequence: int, event_type: str, payload: Mapping[str, Any], previous_hash: str | None) -> dict[str, Any]:
    result: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "sequence": sequence,
        "batch_id": batch_id,
        "event_id": str(uuid.uuid4()),
        "recorded_at": _utc_now(),
        "event_type": event_type,
        "payload": _payload(event_type, payload),
        "previous_hash": previous_hash,
    }
    result["record_hash"] = hashlib.sha256(_canonical(result)).hexdigest()
    if len(_canonical(result)) + 1 > MAX_EVENT_BYTES:
        raise ReconciliationJournalError("Evento ACL troppo grande.")
    return result


def _validate_flow(events: Sequence[Mapping[str, Any]]) -> None:
    header = events[0]["payload"]
    intents: dict[str, Mapping[str, Any]] = {}
    finished: set[str] = set()
    recoveries: set[str] = set()
    for event in events[1:]:
        event_type = str(event["event_type"])
        payload = event["payload"]
        if "object_type" in payload and (
            payload["object_type"] != header["object_type"] or payload["object_id"] != header["object_id"]
        ):
            raise ReconciliationJournalError("Oggetto incoerente nel journal ACL.")
        if event_type == "acl_operation_intent":
            operation_id = str(payload["operation_id"])
            if operation_id in intents:
                raise ReconciliationJournalError("Operazione ACL duplicata.")
            intents[operation_id] = payload
        elif event_type in {"acl_operation_applied", "acl_operation_failed"}:
            operation_id = str(payload["operation_id"])
            if operation_id not in intents or operation_id in finished:
                raise ReconciliationJournalError("Esito ACL senza operazione aperta.")
            intent = intents[operation_id]
            if event_type == "acl_operation_applied" and (
                payload["permission_change_count"] != intent["permission_change_count"]
                or payload["added_user_count"] != intent["added_user_count"]
                or payload.get("removed_user_count", 0) != intent.get("removed_user_count", 0)
                or payload.get("restrictive_change_count", 0) != intent.get("restrictive_change_count", 0)
            ):
                raise ReconciliationJournalError("Esito ACL incoerente con l’intento.")
            finished.add(operation_id)
        elif event_type == "acl_recovery_verified":
            recovery_id = str(payload["recovery_id"])
            if recovery_id in recoveries:
                raise ReconciliationJournalError("Verifica ACL duplicata.")
            recoveries.add(recovery_id)
        elif event_type == "acl_batch_completed":
            if payload["resulting_acl_digest"] != header["desired_acl_digest"]:
                raise ReconciliationJournalError("Digest finale ACL incoerente.")
            if not payload["recovered"] and not any(
                item["event_type"] == "acl_operation_applied" for item in events
            ):
                raise ReconciliationJournalError("Chiusura ACL senza applicazione verificata.")


def _decode(path: Path, raw: bytes) -> AclJournalSnapshot:
    match = _NAME.fullmatch(path.name)
    if not match or not raw or len(raw) > MAX_JOURNAL_BYTES:
        raise ReconciliationJournalCorrupt("Journal ACL non valido.")
    batch_id = str(uuid.UUID(match.group("batch_id")))
    truncated = not raw.endswith(b"\n")
    lines = raw.splitlines()[:-1] if truncated else raw.splitlines()
    if not lines or len(lines) > MAX_EVENTS:
        raise ReconciliationJournalCorrupt("Journal ACL incompleto o troppo grande.")
    events: list[dict[str, Any]] = []
    previous_hash: str | None = None
    terminal = False
    keys = {"schema_version", "sequence", "batch_id", "event_id", "recorded_at", "event_type", "payload", "previous_hash", "record_hash"}
    for sequence, line in enumerate(lines):
        try:
            decoded = json.loads(line.decode("utf-8"), object_pairs_hook=_strict_object)
            if not isinstance(decoded, dict) or set(decoded) != keys:
                raise ValueError("invalid structure")
            if isinstance(decoded["schema_version"], bool) or decoded["schema_version"] != SCHEMA_VERSION or isinstance(decoded["sequence"], bool) or decoded["sequence"] != sequence:
                raise ValueError("invalid sequence")
            if _uuid4(decoded["batch_id"], "Lotto ACL") != batch_id:
                raise ValueError("invalid batch")
            _uuid4(decoded["event_id"], "Evento ACL")
            recorded_at = str(decoded["recorded_at"])
            if not recorded_at.endswith("Z"):
                raise ValueError("invalid timestamp")
            parsed_at = datetime.fromisoformat(recorded_at[:-1] + "+00:00")
            if parsed_at.tzinfo != timezone.utc:
                raise ValueError("invalid timestamp")
            normalized = _payload(str(decoded["event_type"]), decoded["payload"])
            if normalized != decoded["payload"] or decoded["previous_hash"] != previous_hash:
                raise ValueError("non canonical")
            material = dict(decoded)
            supplied_hash = _digest(material.pop("record_hash"), "Hash record ACL")
            if hashlib.sha256(_canonical(material)).hexdigest() != supplied_hash:
                raise ValueError("hash mismatch")
            if sequence == 0 and decoded["event_type"] != "acl_batch_started":
                raise ValueError("missing header")
            if sequence > 0 and decoded["event_type"] == "acl_batch_started":
                raise ValueError("duplicate header")
            if terminal:
                raise ValueError("event after terminal")
            terminal = decoded["event_type"] == "acl_batch_completed"
        except (ValueError, TypeError, json.JSONDecodeError, UnicodeDecodeError, ReconciliationJournalError) as exc:
            raise ReconciliationJournalCorrupt("Integrita del journal ACL non verificata.") from exc
        events.append(decoded)
        previous_hash = supplied_hash
    try:
        _validate_flow(events)
    except ReconciliationJournalError as exc:
        raise ReconciliationJournalCorrupt("Sequenza del journal ACL non valida.") from exc
    return AclJournalSnapshot(path, batch_id, tuple(events), truncated)


def read_acl_journal(path: str | Path) -> AclJournalSnapshot:
    journal_path = Path(path)
    if not journal_path.is_file() or journal_path.is_symlink():
        raise ReconciliationJournalError("Journal ACL non disponibile.")
    try:
        return _decode(journal_path, journal_path.read_bytes())
    except OSError as exc:
        raise ReconciliationJournalError("Lettura del journal ACL non riuscita.") from exc


def acl_journal_path(batch_id: object, root: str | Path | None = None) -> Path:
    normalized = _uuid4(batch_id, "Lotto ACL")
    journal_root = Path(root) if root is not None else default_acl_journal_root()
    if not journal_root.is_dir() or journal_root.is_symlink():
        raise ReconciliationJournalError("Directory dei journal ACL non disponibile.")
    return journal_root / f"acl-batch-{normalized}.jsonl"


def read_acl_batch(batch_id: object, root: str | Path | None = None) -> AclJournalSnapshot:
    return read_acl_journal(acl_journal_path(batch_id, root))


def acquire_acl_journal_lease(journal: "AclReconciliationJournal") -> ReconciliationJournalLease:
    return _acquire_path_lease(journal.read().path)


def list_acl_batches(root: str | Path | None = None, *, incomplete_only: bool = False) -> tuple[AclBatchSummary, ...]:
    journal_root = Path(root) if root is not None else default_acl_journal_root()
    if not journal_root.exists():
        return ()
    if not journal_root.is_dir() or journal_root.is_symlink():
        raise ReconciliationJournalError("Directory dei journal ACL non valida.")
    candidates = sorted((path for path in journal_root.iterdir() if _NAME.fullmatch(path.name)), key=lambda path: path.name)
    if len(candidates) > MAX_JOURNALS:
        raise ReconciliationJournalError("Sono presenti troppi journal ACL.")
    result: list[AclBatchSummary] = []
    for path in candidates:
        try:
            snapshot = read_acl_journal(path)
            status = "complete" if snapshot.complete else ("truncated" if snapshot.truncated_tail else "recovery_required")
            if incomplete_only and status == "complete":
                continue
            header = snapshot.events[0]
            result.append(AclBatchSummary(
                snapshot.batch_id, str(header["recorded_at"]), status,
                str(header["payload"]["object_type"]), str(header["payload"]["object_id"]),
                int(header["payload"]["change_count"]), len(snapshot.events), snapshot.truncated_tail,
            ))
        except ReconciliationJournalError:
            match = _NAME.fullmatch(path.name)
            assert match is not None
            result.append(AclBatchSummary(str(uuid.UUID(match.group("batch_id"))), None, "corrupt", None, None, None, None, False))
    result.sort(key=lambda item: item.recorded_at or "", reverse=True)
    return tuple(result)


def build_acl_recovery_state(batch_id: object, root: str | Path | None = None) -> dict[str, Any]:
    snapshot = read_acl_batch(batch_id, root)
    if snapshot.complete or snapshot.truncated_tail:
        raise ReconciliationJournalError("Il lotto ACL non e recuperabile automaticamente.")
    header = snapshot.events[0]["payload"]
    return {
        "batch_id": snapshot.batch_id,
        "server_origin": header["server_origin"],
        "server_fingerprint": header["server_fingerprint"],
        "user_id_hash": header["user_id_hash"],
        "object_type": header["object_type"],
        "object_id": header["object_id"],
        "object_state_digest": header["object_state_digest"],
        "desired_acl_digest": header["desired_acl_digest"],
        "plan_digest": header["plan_digest"],
        "desired_permissions": list(header["desired_permissions"]),
        "change_count": header["change_count"],
        "add_count": header["add_count"],
        "upgrade_count": header["upgrade_count"],
        "downgrade_count": header.get("downgrade_count", 0),
        "revoke_count": header.get("revoke_count", 0),
        "apply_mode": header.get("apply_mode", "additive"),
        "event_count": len(snapshot.events),
    }


class AclReconciliationJournal:
    def __init__(self, path: Path, batch_id: str) -> None:
        self.path = path
        self.batch_id = batch_id

    @classmethod
    def create(cls, *, root: str | Path | None = None, **payload: Any) -> "AclReconciliationJournal":
        journal_root = Path(root) if root is not None else default_acl_journal_root()
        _prepare_root(journal_root)
        batch_id = str(uuid.uuid4())
        path = journal_root / f"acl-batch-{batch_id}.jsonl"
        record = _record(batch_id, 0, "acl_batch_started", payload, None)
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_BINARY"):
            flags |= os.O_BINARY
        try:
            descriptor = os.open(path, flags, 0o600)
            try:
                _write_all(descriptor, _canonical(record) + b"\n")
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            try:
                path.chmod(stat.S_IRUSR | stat.S_IWUSR)
            except OSError:
                pass
        except OSError as exc:
            raise ReconciliationJournalError("Creazione del journal ACL non riuscita.") from exc
        return cls(path, batch_id)

    @classmethod
    def open(cls, path: str | Path) -> "AclReconciliationJournal":
        snapshot = read_acl_journal(path)
        return cls(snapshot.path, snapshot.batch_id)

    def read(self) -> AclJournalSnapshot:
        return read_acl_journal(self.path)

    def append(self, event_type: str, **payload: Any) -> dict[str, Any]:
        try:
            with _locked_file(self.path) as handle:
                handle.seek(0)
                raw = handle.read(MAX_JOURNAL_BYTES + 1)
                snapshot = _decode(self.path, raw)
                if snapshot.truncated_tail or snapshot.complete:
                    raise ReconciliationJournalError("Il journal ACL non accetta altri eventi.")
                record = _record(self.batch_id, snapshot.next_sequence, event_type, payload, snapshot.last_record_hash)
                _validate_flow((*snapshot.events, record))
                encoded = _canonical(record) + b"\n"
                if len(raw) + len(encoded) > MAX_JOURNAL_BYTES:
                    raise ReconciliationJournalError("Journal ACL troppo grande.")
                handle.seek(0, os.SEEK_END)
                _write_all(handle.fileno(), encoded)
                os.fsync(handle.fileno())
                return record
        except FileNotFoundError as exc:
            raise ReconciliationJournalError("Journal ACL non disponibile.") from exc


__all__ = [
    "AclBatchSummary", "AclJournalSnapshot", "AclReconciliationJournal",
    "ReconciliationJournalBusy", "ReconciliationJournalCorrupt", "ReconciliationJournalError",
    "ReconciliationJournalLease", "acquire_acl_journal_lease", "build_acl_recovery_state",
    "default_acl_journal_root", "list_acl_batches", "read_acl_batch", "read_acl_journal",
]
