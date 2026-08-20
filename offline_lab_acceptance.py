#!/usr/bin/env python3
"""Run the nine mutative acceptance scenarios against the synthetic offline lab.

This runner is deliberately separate from the real-instance integration matrix:
it is allowed to write only to the ephemeral HTTPS simulator on localhost and
never turns an offline result into a real Passbolt attestation.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import ssl
import urllib.request
import uuid
from pathlib import Path
from typing import Any, Mapping

from offline_lab_smoke import OfflineLabSmokeError, load_ready_file, read_lab_status
from passbolt_integration_matrix import JsonLineBridge, MatrixError, locate_node


APP_VERSION = "0.28.1"
STATEFUL_SCENARIOS = (
    "import_root_resource",
    "import_new_client_folder",
    "import_existing_destination",
    "duplicate_detection",
    "custom_shared_permissions",
    "additive_acl_update",
    "restrictive_acl_update",
    "interrupted_import_recovery",
    "interrupted_acl_recovery",
)
ERROR_CODE_PATTERN = re.compile(r"^[A-Z][A-Z0-9_]{2,80}$")
TRANSPORT_ERROR_CODES = {
    "API_CONNECTION_FAILED",
    "API_RESPONSE_READ_FAILED",
    "API_TIMEOUT",
}
SENSITIVE_PROGRESS_KEYS = {
    "password",
    "passphrase",
    "mfa_totp",
    "totp",
    "private_key",
    "private_key_path",
    "description",
    "title",
    "username",
    "uri",
    "data",
}


class OfflineAcceptanceError(RuntimeError):
    """Bounded failure that never includes synthetic credential values."""


def _success(envelope: Mapping[str, Any], phase: str) -> dict[str, Any]:
    result = envelope.get("result")
    if envelope.get("ok") is True and isinstance(result, dict):
        return result
    raw_error = envelope.get("error")
    error = raw_error if isinstance(raw_error, Mapping) else {}
    raw_code = str(error.get("code", ""))
    code = raw_code if ERROR_CODE_PATTERN.fullmatch(raw_code) else "UNEXPECTED_FAILURE"
    raise OfflineAcceptanceError(f"{phase} non riuscita ({code}).")


def _expected_failure(
    envelope: Mapping[str, Any], phase: str, expected_codes: set[str]
) -> str:
    raw_error = envelope.get("error")
    error = raw_error if isinstance(raw_error, Mapping) else {}
    code = str(error.get("code", ""))
    if envelope.get("ok") is not False or code not in expected_codes:
        safe_code = code if ERROR_CODE_PATTERN.fullmatch(code) else "UNEXPECTED_RESPONSE"
        raise OfflineAcceptanceError(
            f"{phase} non ha prodotto l'errore controllato previsto ({safe_code})."
        )
    return code


def _assert_uncertain_write_failure(
    failure: Mapping[str, Any], fault: str
) -> None:
    payload = failure.get("payload")
    if not isinstance(payload, Mapping) or payload.get("outcome") != "unknown":
        raise OfflineAcceptanceError(
            "Il fault di scrittura non contiene un esito incerto valido."
        )
    if fault.endswith("-disconnect"):
        if (
            payload.get("error_code") not in TRANSPORT_ERROR_CODES
            or "http_status" in payload
        ):
            raise OfflineAcceptanceError(
                "La disconnessione non e' stata diagnosticata come errore di trasporto senza stato HTTP."
            )
    elif payload.get("http_status") != 500:
        raise OfflineAcceptanceError(
            "Il fault HTTP non conserva lo stato 500 atteso."
        )


def _candidate(label: str, *, at_root: bool, client: str | None = None) -> dict[str, Any]:
    marker = uuid.uuid4().hex[:12]
    normalized_label = re.sub(r"[^a-z0-9]+", "-", label.lower()).strip("-")
    material = f"offline-acceptance:{marker}:{normalized_label}".encode("utf-8")
    return {
        "candidate_id": f"offline-{marker}-{normalized_label}",
        "source_sha256": hashlib.sha256(material).hexdigest(),
        "client": "(radice)" if at_root else str(client or f"Cliente {marker}"),
        "source_at_root": at_root,
        "title": f"PMA Offline {label} {marker}",
        "username": f"offline-{marker}",
        "uri": f"https://{marker}.example.invalid/{normalized_label}",
    }


def _resource(candidate: Mapping[str, Any]) -> dict[str, Any]:
    return {
        **dict(candidate),
        "password": f"LAB-ONLY-STATEFUL-{uuid.uuid4().hex}",
        "description": "Credenziale sintetica per il collaudo stateful offline.",
    }


def _validate_progress(
    envelope: Mapping[str, Any], expected_batch_id: str, events: list[dict[str, Any]]
) -> None:
    if set(envelope) != {"type", "batch_id", "event_type", "payload"}:
        raise OfflineAcceptanceError("Un evento stateful ha una struttura inattesa.")
    if envelope.get("type") != "progress" or envelope.get("batch_id") != expected_batch_id:
        raise OfflineAcceptanceError("Un evento stateful appartiene a un lotto inatteso.")
    event_type = str(envelope.get("event_type", ""))
    payload = envelope.get("payload")
    if not event_type or len(event_type) > 80 or not isinstance(payload, Mapping):
        raise OfflineAcceptanceError("Un evento stateful non contiene un payload valido.")

    def reject_sensitive_keys(value: Any) -> None:
        if isinstance(value, Mapping):
            for key, child in value.items():
                if str(key).lower() in SENSITIVE_PROGRESS_KEYS:
                    raise OfflineAcceptanceError(
                        "Un evento stateful contiene un campo sensibile non ammesso."
                    )
                reject_sensitive_keys(child)
        elif isinstance(value, list):
            for child in value:
                reject_sensitive_keys(child)
        elif isinstance(value, str) and "LAB-ONLY-STATEFUL-" in value:
            raise OfflineAcceptanceError(
                "Un evento stateful contiene un segreto sintetico non ammesso."
            )

    reject_sensitive_keys(payload)
    if len(events) >= 500:
        raise OfflineAcceptanceError("Il lotto stateful ha prodotto troppi eventi.")
    events.append(dict(envelope))


def _request_with_progress(
    bridge: JsonLineBridge,
    request: Mapping[str, Any],
    batch_id: str,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    events: list[dict[str, Any]] = []
    envelope = bridge.request(
        request,
        progress_handler=lambda item: _validate_progress(item, batch_id, events),
    )
    return envelope, events


def _set_fault(ready: Mapping[str, Any], fault: str) -> None:
    encoded = json.dumps({"fault": fault}, separators=(",", ":")).encode("utf-8")
    request = urllib.request.Request(
        f"{ready['base_url']}/__lab/fault.json",
        data=encoded,
        method="PUT",
        headers={
            "Accept": "application/json",
            "Content-Type": "application/json",
            "X-Offline-Lab-Token": str(ready["lab_token"]),
        },
    )
    context = ssl.create_default_context(cafile=str(ready["certificate_path"]))
    try:
        with urllib.request.urlopen(request, timeout=15, context=context) as response:
            document = json.loads(response.read(64 * 1024).decode("utf-8"))
    except (OSError, TimeoutError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise OfflineAcceptanceError(
            "La fault injection del laboratorio non e' disponibile."
        ) from exc
    body = document.get("body") if isinstance(document, dict) else None
    if not isinstance(body, dict) or body.get("fault") != fault:
        raise OfflineAcceptanceError(
            "La fault injection del laboratorio non e' stata confermata."
        )


def _readiness(
    bridge: JsonLineBridge,
    session_id: str,
    profile: str,
    candidate: Mapping[str, Any],
    *,
    destination_mode: str,
    destination_folder_id: str | None = None,
    permission_mode: str = "inherited",
    permission_template: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    folder_format = profile if destination_mode == "client_folders" else "auto"
    envelope = bridge.request(
        {
            "command": "session-readiness",
            "session_id": session_id,
            "resource_format": profile,
            "destination_mode": destination_mode,
            "folder_format": folder_format,
            "destination_folder_id": destination_folder_id,
            "permission_mode": permission_mode,
            "permission_template": permission_template,
            "candidates": [dict(candidate)],
        }
    )
    return _success(envelope, "Preflight stateful")


def _import_candidate(
    bridge: JsonLineBridge,
    session_id: str,
    profile: str,
    candidate: dict[str, Any],
    *,
    destination_mode: str,
    destination_folder_id: str | None = None,
    permission_mode: str = "inherited",
    permission_template: list[dict[str, Any]] | None = None,
) -> tuple[dict[str, Any], list[dict[str, Any]], dict[str, Any]]:
    readiness = _readiness(
        bridge,
        session_id,
        profile,
        candidate,
        destination_mode=destination_mode,
        destination_folder_id=destination_folder_id,
        permission_mode=permission_mode,
        permission_template=permission_template,
    )
    if (
        readiness.get("preflight_status") != "passed"
        or readiness.get("can_import") is not True
        or readiness.get("create_count") != 1
    ):
        raise OfflineAcceptanceError(
            "Il preflight stateful non ha autorizzato una creazione "
            f"({destination_mode}/{permission_mode})."
        )
    resource = _resource(candidate)
    batch_id = str(uuid.uuid4())
    request = {
        "command": "session-import",
        "session_id": session_id,
        "reconciliation_batch_id": batch_id,
        "resource_format": profile,
        "destination_mode": destination_mode,
        "folder_format": profile if destination_mode == "client_folders" else "auto",
        "destination_folder_id": destination_folder_id,
        "permission_mode": permission_mode,
        "permission_template": permission_template,
        "candidates": [dict(candidate)],
        "resources": [resource],
        "plan_digest": readiness["plan_digest"],
        "confirmation": "IMPORTA 1",
    }
    try:
        envelope, events = _request_with_progress(bridge, request, batch_id)
        result = _success(envelope, "Importazione stateful")
    finally:
        resource["password"] = ""
        request["resources"] = []
    event_types = [str(item["event_type"]) for item in events]
    if (
        result.get("complete") is not True
        or result.get("verification_status") != "verified"
        or result.get("verified_resource_count") != 1
        or "resource_verified" not in event_types
        or not event_types
        or event_types[-1] != "batch_completed"
    ):
        raise OfflineAcceptanceError(
            "L'importazione stateful non ha completato la verifica post-importazione."
        )
    return result, events, readiness


def _acl_plan(
    bridge: JsonLineBridge,
    session_id: str,
    object_id: str,
    desired_permissions: list[dict[str, Any]],
) -> dict[str, Any]:
    result = _success(
        bridge.request(
            {
                "command": "session-acl-plan",
                "session_id": session_id,
                "object_type": "resource",
                "object_id": object_id,
                "desired_permissions": desired_permissions,
            }
        ),
        "Piano ACL stateful",
    )
    if result.get("complete") is not True or result.get("apply_available") is not True:
        raise OfflineAcceptanceError("Il piano ACL stateful non e' applicabile.")
    return result


def _acl_apply_request(
    session_id: str, batch_id: str, plan: Mapping[str, Any]
) -> dict[str, Any]:
    return {
        "command": "session-acl-apply",
        "session_id": session_id,
        "acl_batch_id": batch_id,
        "plan_id": plan["plan_id"],
        "object_state_digest": plan["object_state_digest"],
        "desired_acl_digest": plan["desired_acl_digest"],
        "directory_state_digest": plan["directory_state_digest"],
        "plan_digest": plan["plan_digest"],
        "confirmation": plan["confirmation_required"],
    }


def _acl_recovery_state(batch_id: str, plan: Mapping[str, Any]) -> dict[str, Any]:
    counts = plan.get("counts")
    if not isinstance(counts, Mapping):
        raise OfflineAcceptanceError("Il piano ACL non contiene conteggi validi.")
    return {
        "batch_id": batch_id,
        "object_type": plan["object"]["object_type"],
        "object_id": plan["object"]["object_id"],
        "object_state_digest": plan["object_state_digest"],
        "desired_acl_digest": plan["desired_acl_digest"],
        "plan_digest": plan["plan_digest"],
        "desired_permissions": plan["desired_permissions"],
        "change_count": plan["change_count"],
        "add_count": counts.get("add", 0),
        "upgrade_count": counts.get("upgrade", 0),
        "downgrade_count": counts.get("downgrade", 0),
        "revoke_count": counts.get("revoke", 0),
        "apply_mode": plan["apply_mode"],
    }


def _exercise_import_recovery(
    bridge: JsonLineBridge,
    ready: Mapping[str, Any],
    session_id: str,
    profile: str,
    *,
    label: str,
    fault: str,
    expected_resolution: str,
) -> dict[str, int]:
    if expected_resolution not in {"not_applied", "remote_success"}:
        raise OfflineAcceptanceError("Esito import atteso non valido.")
    candidate = _candidate(label, at_root=True)
    readiness = _readiness(
        bridge,
        session_id,
        profile,
        candidate,
        destination_mode="root",
    )
    _set_fault(ready, fault)
    batch_id = str(uuid.uuid4())
    resource = _resource(candidate)
    failed_request = {
        "command": "session-import",
        "session_id": session_id,
        "reconciliation_batch_id": batch_id,
        "resource_format": profile,
        "destination_mode": "root",
        "folder_format": "auto",
        "destination_folder_id": None,
        "permission_mode": "inherited",
        "permission_template": None,
        "candidates": [dict(candidate)],
        "resources": [resource],
        "plan_digest": readiness["plan_digest"],
        "confirmation": "IMPORTA 1",
    }
    try:
        failed_import, failed_events = _request_with_progress(
            bridge, failed_request, batch_id
        )
    finally:
        resource["password"] = ""
        failed_request["resources"] = []
    _expected_failure(
        failed_import,
        "Importazione interrotta stateful",
        {"IMPORT_PARTIAL_FAILURE"},
    )
    intent = next(
        (item for item in failed_events if item["event_type"] == "operation_intent"),
        None,
    )
    failure = next(
        (item for item in failed_events if item["event_type"] == "operation_failed"),
        None,
    )
    if (
        not isinstance(intent, Mapping)
        or not isinstance(failure, Mapping)
        or failure.get("payload", {}).get("outcome") != "unknown"
    ):
        raise OfflineAcceptanceError("Il lotto interrotto non contiene prove incerte recuperabili.")
    _assert_uncertain_write_failure(failure, fault)
    operation = {
        **dict(intent["payload"]),
        "recorded_outcome": {
            "event_type": "operation_failed",
            **dict(failure["payload"]),
        },
    }
    recovery_state = {
        "schema_version": 1,
        "batch_id": batch_id,
        "resource_format": profile,
        "folder_format": "none",
        "destination_mode": "root",
        "destination_folder_id": None,
        "permission_mode": "inherited",
        "candidate_count": 1,
        "candidates": [
            {
                "candidate_id": candidate["candidate_id"],
                "source_sha256": candidate["source_sha256"],
            }
        ],
        "operations": [operation],
        "duplicate_candidates": [],
    }
    recovery_check_request = {
        "command": "session-recovery-readiness",
        "session_id": session_id,
        "reconciliation_batch_id": batch_id,
        "resource_format": profile,
        "destination_mode": "root",
        "folder_format": "none",
        "destination_folder_id": None,
        "permission_mode": "inherited",
        "permission_template": None,
        "candidates": [dict(candidate)],
        "recovery_state": recovery_state,
    }
    checked_envelope, checked_events = _request_with_progress(
        bridge, recovery_check_request, batch_id
    )
    checked = _success(checked_envelope, "Verifica recupero import stateful")
    remote_success_count = int(expected_resolution == "remote_success")
    retry_count = int(expected_resolution == "not_applied")
    expected_candidate_ids = [candidate["candidate_id"]] if retry_count else []
    if (
        checked.get("remote_success_count") != remote_success_count
        or checked.get("not_applied_count") != retry_count
        or checked.get("retry_action_count") != retry_count
        or checked.get("resource_candidate_ids") != expected_candidate_ids
    ):
        raise OfflineAcceptanceError("Il recupero import non ha classificato l'esito remoto atteso.")

    retry_resource = _resource(candidate) if retry_count else None
    recovery_import_request = {
        **recovery_check_request,
        "command": "session-recovery-import",
        "recovery_id": checked["recovery_id"],
        "recovery_plan_digest": checked["recovery_plan_digest"],
        "resource_candidate_ids": checked["resource_candidate_ids"],
        "resources": [retry_resource] if retry_resource is not None else [],
        "confirmation": checked["confirmation_required"],
    }
    try:
        recovered_envelope, recovered_events = _request_with_progress(
            bridge, recovery_import_request, batch_id
        )
        recovered = _success(recovered_envelope, "Recupero import stateful")
    finally:
        if retry_resource is not None:
            retry_resource["password"] = ""
        recovery_import_request["resources"] = []
    if (
        recovered.get("complete") is not True
        or recovered.get("created_count") != retry_count
        or recovered.get("remote_success_count") != remote_success_count
        or recovered.get("destructive_actions_performed") is not False
        or not checked_events
        or not recovered_events
    ):
        raise OfflineAcceptanceError("Il recupero import stateful non si e' concluso in modo idempotente.")
    return {
        "failed_writes": 1,
        "retried_writes": retry_count,
        "remote_success_without_retry": remote_success_count,
    }


def _exercise_folder_recovery(
    bridge: JsonLineBridge,
    ready: Mapping[str, Any],
    session_id: str,
    profile: str,
    *,
    label: str,
    fault: str,
    expected_resolution: str,
) -> dict[str, int]:
    if expected_resolution not in {"not_applied", "remote_success"}:
        raise OfflineAcceptanceError("Esito cartella atteso non valido.")
    candidate = _candidate(
        label,
        at_root=False,
        client=f"Cartella recupero {uuid.uuid4().hex[:8]}",
    )
    readiness = _readiness(
        bridge,
        session_id,
        profile,
        candidate,
        destination_mode="client_folders",
    )
    if (
        readiness.get("create_count") != 1
        or readiness.get("create_folder_count") != 1
    ):
        raise OfflineAcceptanceError(
            "Il preflight del recupero cartella non pianifica una sola destinazione nuova."
        )
    before_failure = read_lab_status(ready)
    _set_fault(ready, fault)
    batch_id = str(uuid.uuid4())
    resource = _resource(candidate)
    failed_request = {
        "command": "session-import",
        "session_id": session_id,
        "reconciliation_batch_id": batch_id,
        "resource_format": profile,
        "destination_mode": "client_folders",
        "folder_format": profile,
        "destination_folder_id": None,
        "permission_mode": "inherited",
        "permission_template": None,
        "candidates": [dict(candidate)],
        "resources": [resource],
        "plan_digest": readiness["plan_digest"],
        "confirmation": "IMPORTA 1",
    }
    try:
        failed_import, failed_events = _request_with_progress(
            bridge, failed_request, batch_id
        )
    finally:
        resource["password"] = ""
        failed_request["resources"] = []
    _expected_failure(
        failed_import,
        "Creazione cartella interrotta stateful",
        {"IMPORT_PARTIAL_FAILURE"},
    )
    intent = next(
        (
            item
            for item in failed_events
            if item["event_type"] == "operation_intent"
            and item.get("payload", {}).get("action") == "create_folder"
        ),
        None,
    )
    failure = next(
        (
            item
            for item in failed_events
            if item["event_type"] == "operation_failed"
            and item.get("payload", {}).get("operation_id")
            == (intent or {}).get("payload", {}).get("operation_id")
        ),
        None,
    )
    if (
        not isinstance(intent, Mapping)
        or not isinstance(failure, Mapping)
        or failure.get("payload", {}).get("outcome") != "unknown"
    ):
        raise OfflineAcceptanceError(
            "La creazione cartella interrotta non contiene prove incerte recuperabili."
        )
    _assert_uncertain_write_failure(failure, fault)
    remote_success_count = int(expected_resolution == "remote_success")
    retry_count = int(expected_resolution == "not_applied")
    after_failure = read_lab_status(ready)
    if (
        after_failure.get("folder_count")
        != int(before_failure["folder_count"]) + remote_success_count
        or after_failure.get("resource_count") != before_failure.get("resource_count")
    ):
        raise OfflineAcceptanceError(
            "Il fault cartella non ha lasciato lo stato remoto sintetico atteso."
        )
    operation = {
        **dict(intent["payload"]),
        "recorded_outcome": {
            "event_type": "operation_failed",
            **dict(failure["payload"]),
        },
    }
    recovery_state = {
        "schema_version": 1,
        "batch_id": batch_id,
        "resource_format": profile,
        "folder_format": profile,
        "destination_mode": "client_folders",
        "destination_folder_id": None,
        "permission_mode": "inherited",
        "candidate_count": 1,
        "candidates": [
            {
                "candidate_id": candidate["candidate_id"],
                "source_sha256": candidate["source_sha256"],
            }
        ],
        "operations": [operation],
        "duplicate_candidates": [],
    }
    recovery_check_request = {
        "command": "session-recovery-readiness",
        "session_id": session_id,
        "reconciliation_batch_id": batch_id,
        "resource_format": profile,
        "destination_mode": "client_folders",
        "folder_format": profile,
        "destination_folder_id": None,
        "permission_mode": "inherited",
        "permission_template": None,
        "candidates": [dict(candidate)],
        "recovery_state": recovery_state,
    }
    checked_envelope, checked_events = _request_with_progress(
        bridge, recovery_check_request, batch_id
    )
    checked = _success(checked_envelope, "Verifica recupero cartella stateful")
    expected_retry_actions = 1 + retry_count
    if (
        checked.get("remote_success_count") != remote_success_count
        or checked.get("not_applied_count") != retry_count
        or checked.get("retry_action_count") != expected_retry_actions
        or checked.get("resource_candidate_ids") != [candidate["candidate_id"]]
    ):
        raise OfflineAcceptanceError(
            "Il recupero cartella non ha classificato l'esito remoto atteso."
        )

    retry_resource = _resource(candidate)
    recovery_import_request = {
        **recovery_check_request,
        "command": "session-recovery-import",
        "recovery_id": checked["recovery_id"],
        "recovery_plan_digest": checked["recovery_plan_digest"],
        "resource_candidate_ids": checked["resource_candidate_ids"],
        "resources": [retry_resource],
        "confirmation": checked["confirmation_required"],
    }
    try:
        recovered_envelope, recovered_events = _request_with_progress(
            bridge, recovery_import_request, batch_id
        )
        recovered = _success(recovered_envelope, "Recupero cartella stateful")
    finally:
        retry_resource["password"] = ""
        recovery_import_request["resources"] = []
    after_recovery = read_lab_status(ready)
    if (
        recovered.get("complete") is not True
        or recovered.get("created_count") != 1
        or recovered.get("created_folder_count") != retry_count
        or recovered.get("remote_success_count") != remote_success_count
        or recovered.get("destructive_actions_performed") is not False
        or after_recovery.get("folder_count")
        != int(before_failure["folder_count"]) + 1
        or after_recovery.get("resource_count")
        != int(before_failure["resource_count"]) + 1
        or not checked_events
        or not recovered_events
    ):
        raise OfflineAcceptanceError(
            "Il recupero cartella stateful non si e' concluso senza duplicazioni."
        )
    return {
        "failed_writes": 1,
        "retried_writes": retry_count,
        "remote_success_without_retry": remote_success_count,
        "followup_resource_writes": 1,
    }


def _exercise_acl_recovery(
    bridge: JsonLineBridge,
    ready: Mapping[str, Any],
    session_id: str,
    object_id: str,
    recipient_id: str,
    *,
    desired_type: int,
    fault: str,
    expected_resolution: str,
) -> dict[str, int]:
    if expected_resolution not in {"not_applied", "remote_success"}:
        raise OfflineAcceptanceError("Esito ACL atteso non valido.")
    plan = _acl_plan(
        bridge,
        session_id,
        object_id,
        [{"aro": "User", "aro_foreign_key": recipient_id, "type": desired_type}],
    )
    batch_id = str(uuid.uuid4())
    _set_fault(ready, fault)
    failed_acl, failed_events = _request_with_progress(
        bridge,
        _acl_apply_request(session_id, batch_id, plan),
        batch_id,
    )
    expected_error_codes = {"ACL_APPLY_FAILED"}
    if fault.endswith("-disconnect"):
        expected_error_codes |= TRANSPORT_ERROR_CODES
    failure_code = _expected_failure(
        failed_acl, "ACL interrotta stateful", expected_error_codes
    )
    if (
        [item["event_type"] for item in failed_events]
        != ["acl_operation_intent", "acl_operation_failed"]
        or failed_events[-1].get("payload", {}).get("outcome") != "unknown"
    ):
        raise OfflineAcceptanceError("Il journal ACL interrotto non e' riconciliabile.")
    _assert_uncertain_write_failure(failed_events[-1], fault)
    if failed_events[-1].get("payload", {}).get("error_code") != failure_code:
        raise OfflineAcceptanceError(
            "La diagnostica ACL non coincide con l'errore restituito al chiamante."
        )
    recovery_state = _acl_recovery_state(batch_id, plan)
    check_request = {
        "command": "session-acl-recovery-readiness",
        "session_id": session_id,
        "acl_batch_id": batch_id,
        "acl_recovery_state": recovery_state,
    }
    checked_envelope, checked_events = _request_with_progress(
        bridge, check_request, batch_id
    )
    checked = _success(checked_envelope, "Verifica recupero ACL stateful")
    retry_write = expected_resolution == "not_applied"
    if (
        checked.get("resolution") != expected_resolution
        or checked.get("retry_write_required") is not retry_write
    ):
        raise OfflineAcceptanceError("La ACL interrotta non e' stata classificata.")
    recovery_request = {
        "command": "session-acl-recovery-apply",
        "session_id": session_id,
        "acl_batch_id": batch_id,
        "acl_recovery_state": recovery_state,
        "recovery_id": checked["recovery_id"],
        "recovery_plan_digest": checked["recovery_plan_digest"],
        "confirmation": checked["confirmation_required"],
    }
    recovered_envelope, recovered_events = _request_with_progress(
        bridge, recovery_request, batch_id
    )
    recovered = _success(recovered_envelope, "Recupero ACL stateful")
    if (
        recovered.get("complete") is not True
        or recovered.get("resolution") != expected_resolution
        or recovered.get("remote_write_performed") is not retry_write
        or not checked_events
        or not recovered_events
    ):
        raise OfflineAcceptanceError("Il recupero ACL stateful non si e' concluso in modo idempotente.")
    return {
        "failed_writes": 1,
        "retried_writes": int(retry_write),
        "remote_success_without_retry": int(not retry_write),
    }


def run_acceptance(ready: dict[str, Any]) -> dict[str, Any]:
    if ready.get("app_version") != APP_VERSION:
        raise OfflineAcceptanceError(
            "Il manifesto stateful appartiene a una versione applicativa diversa."
        )
    if ready.get("scenario") != "healthy" or ready.get("fault") != "none":
        raise OfflineAcceptanceError(
            "L'accettazione stateful richiede un laboratorio sano senza fault iniziale."
        )
    profile = str(ready["profile"])
    crypto_script = Path(__file__).resolve().with_name("passbolt_crypto.mjs")
    node = locate_node()
    results: list[dict[str, Any]] = []

    with JsonLineBridge(node, crypto_script, timeout=120.0) as bridge:
        open_request = {
            "command": "session-open",
            "base_url": ready["base_url"],
            "expected_server_fingerprint": ready["server_fingerprint"],
            "private_key_path": ready["private_key_path"],
            "passphrase": ready["passphrase"],
            "mfa_totp": ready["mfa_totp"],
        }
        try:
            opened = _success(bridge.request(open_request), "Login stateful")
        finally:
            open_request["passphrase"] = None
            open_request["mfa_totp"] = None
        session_id = str(opened.get("session_id", ""))
        if not session_id or opened.get("secrets_serialized") is not False:
            raise OfflineAcceptanceError("La sessione stateful non e' valida.")

        permissions = _success(
            bridge.request({"command": "session-permissions", "session_id": session_id}),
            "Directory permessi stateful",
        )
        entries = permissions.get("entries")
        if not isinstance(entries, list):
            raise OfflineAcceptanceError("La directory stateful non contiene destinatari.")
        recipient = next(
            (
                entry
                for entry in entries
                if isinstance(entry, Mapping)
                and entry.get("aro") == "User"
                and entry.get("available") is True
            ),
            None,
        )
        group = next(
            (
                entry
                for entry in entries
                if isinstance(entry, Mapping)
                and entry.get("aro") == "Group"
                and entry.get("available") is True
            ),
            None,
        )
        if not isinstance(recipient, Mapping) or not isinstance(group, Mapping):
            raise OfflineAcceptanceError(
                "Il laboratorio stateful non espone utente e gruppo sintetici verificati."
            )
        recipient_id = str(recipient.get("aro_foreign_key", ""))
        group_id = str(group.get("aro_foreign_key", ""))

        root_candidate = _candidate("Root import", at_root=True)
        root_import, _, _ = _import_candidate(
            bridge, session_id, profile, root_candidate, destination_mode="root"
        )
        root_resource_id = str(root_import["created"][0]["resource_id"])
        results.append(
            {
                "name": "import_root_resource",
                "status": "passed",
                "metrics": {"created": 1, "verified": 1},
            }
        )

        folder_candidate = _candidate(
            "New client folder", at_root=False, client=f"Cliente Offline {uuid.uuid4().hex[:8]}"
        )
        folder_import, _, _ = _import_candidate(
            bridge,
            session_id,
            profile,
            folder_candidate,
            destination_mode="client_folders",
        )
        if folder_import.get("created_folder_count") != 1:
            raise OfflineAcceptanceError("La cartella cliente stateful non e' stata creata.")
        destination_folder_id = str(folder_import["created_folders"][0]["folder_id"])
        results.append(
            {
                "name": "import_new_client_folder",
                "status": "passed",
                "metrics": {"created_resources": 1, "created_folders": 1},
            }
        )

        direct_candidate = _candidate("Existing destination", at_root=True)
        direct_import, _, _ = _import_candidate(
            bridge,
            session_id,
            profile,
            direct_candidate,
            destination_mode="direct_folder",
            destination_folder_id=destination_folder_id,
        )
        if direct_import.get("created")[0].get("folder_parent_id") != destination_folder_id:
            raise OfflineAcceptanceError("La destinazione esistente non e' stata rispettata.")
        results.append(
            {
                "name": "import_existing_destination",
                "status": "passed",
                "metrics": {"created": 1, "destination_reused": 1},
            }
        )

        before_duplicate = read_lab_status(ready)
        duplicate = _readiness(
            bridge,
            session_id,
            profile,
            root_candidate,
            destination_mode="root",
        )
        after_duplicate = read_lab_status(ready)
        if (
            duplicate.get("duplicate_count") != 1
            or duplicate.get("create_count") != 0
            or before_duplicate.get("mutation_count")
            != after_duplicate.get("mutation_count")
        ):
            raise OfflineAcceptanceError("Il controllo duplicati stateful non e' fail-safe.")
        results.append(
            {
                "name": "duplicate_detection",
                "status": "passed",
                "metrics": {"duplicates": 1, "remote_writes": 0},
            }
        )

        custom_template = [
            {"aro": "User", "aro_foreign_key": recipient_id, "type": 7},
            {"aro": "Group", "aro_foreign_key": group_id, "type": 1},
        ]
        shared_candidate = _candidate("Custom sharing", at_root=True)
        shared_import, _, _ = _import_candidate(
            bridge,
            session_id,
            profile,
            shared_candidate,
            destination_mode="root",
            permission_mode="custom",
            permission_template=custom_template,
        )
        if shared_import.get("shared_created_count") != 1:
            raise OfflineAcceptanceError("La condivisione personalizzata non e' stata verificata.")
        results.append(
            {
                "name": "custom_shared_permissions",
                "status": "passed",
                "metrics": {"shared_resources": 1, "verified": 1},
            }
        )

        additive_plan = _acl_plan(
            bridge,
            session_id,
            root_resource_id,
            [{"aro": "User", "aro_foreign_key": recipient_id, "type": 1}],
        )
        additive_batch_id = str(uuid.uuid4())
        additive_envelope, additive_events = _request_with_progress(
            bridge,
            _acl_apply_request(session_id, additive_batch_id, additive_plan),
            additive_batch_id,
        )
        additive_result = _success(additive_envelope, "ACL additiva stateful")
        if (
            additive_result.get("complete") is not True
            or additive_result.get("added_user_count") != 1
            or additive_result.get("destructive_actions_performed") is not False
            or [item["event_type"] for item in additive_events][-1:]
            != ["acl_batch_completed"]
        ):
            raise OfflineAcceptanceError("La ACL additiva stateful non e' coerente.")
        results.append(
            {
                "name": "additive_acl_update",
                "status": "passed",
                "metrics": {"changes": 1, "added_users": 1},
            }
        )

        restrictive_plan = _acl_plan(
            bridge, session_id, root_resource_id, []
        )
        restrictive_batch_id = str(uuid.uuid4())
        restrictive_envelope, restrictive_events = _request_with_progress(
            bridge,
            _acl_apply_request(session_id, restrictive_batch_id, restrictive_plan),
            restrictive_batch_id,
        )
        restrictive_result = _success(
            restrictive_envelope, "ACL restrittiva stateful"
        )
        if (
            restrictive_result.get("complete") is not True
            or restrictive_result.get("removed_user_count") != 1
            or restrictive_result.get("destructive_actions_performed") is not True
            or [item["event_type"] for item in restrictive_events][-1:]
            != ["acl_batch_completed"]
        ):
            raise OfflineAcceptanceError("La ACL restrittiva stateful non e' coerente.")
        results.append(
            {
                "name": "restrictive_acl_update",
                "status": "passed",
                "metrics": {"changes": 1, "removed_users": 1},
            }
        )

        import_recovery_metrics = [
            _exercise_import_recovery(
                bridge,
                ready,
                session_id,
                profile,
                label=label,
                fault=fault,
                expected_resolution=resolution,
            )
            for label, fault, resolution in (
                (
                    "Interrupted import before HTTP commit",
                    "next-resource-create-500",
                    "not_applied",
                ),
                (
                    "Interrupted import after HTTP commit",
                    "next-resource-create-after-commit-500",
                    "remote_success",
                ),
                (
                    "Interrupted import before transport commit",
                    "next-resource-create-disconnect",
                    "not_applied",
                ),
                (
                    "Interrupted import after transport commit",
                    "next-resource-create-after-commit-disconnect",
                    "remote_success",
                ),
            )
        ]
        folder_recovery_metrics = [
            _exercise_folder_recovery(
                bridge,
                ready,
                session_id,
                profile,
                label=label,
                fault=fault,
                expected_resolution=resolution,
            )
            for label, fault, resolution in (
                (
                    "Interrupted folder before HTTP commit",
                    "next-folder-create-500",
                    "not_applied",
                ),
                (
                    "Interrupted folder after HTTP commit",
                    "next-folder-create-after-commit-500",
                    "remote_success",
                ),
                (
                    "Interrupted folder before transport commit",
                    "next-folder-create-disconnect",
                    "not_applied",
                ),
                (
                    "Interrupted folder after transport commit",
                    "next-folder-create-after-commit-disconnect",
                    "remote_success",
                ),
            )
        ]
        combined_import_metrics = import_recovery_metrics + folder_recovery_metrics
        results.append(
            {
                "name": "interrupted_import_recovery",
                "status": "passed",
                "metrics": {
                    key: sum(item[key] for item in combined_import_metrics)
                    for key in import_recovery_metrics[0]
                }
                | {
                    "followup_resource_writes": sum(
                        item["followup_resource_writes"]
                        for item in folder_recovery_metrics
                    )
                },
            }
        )

        acl_recovery_metrics = [
            _exercise_acl_recovery(
                bridge,
                ready,
                session_id,
                root_resource_id,
                recipient_id,
                desired_type=desired_type,
                fault=fault,
                expected_resolution=resolution,
            )
            for desired_type, fault, resolution in (
                (7, "next-share-500", "not_applied"),
                (1, "next-share-after-commit-500", "remote_success"),
                (7, "next-share-disconnect", "not_applied"),
                (1, "next-share-after-commit-disconnect", "remote_success"),
            )
        ]
        results.append(
            {
                "name": "interrupted_acl_recovery",
                "status": "passed",
                "metrics": {
                    key: sum(item[key] for item in acl_recovery_metrics)
                    for key in acl_recovery_metrics[0]
                },
            }
        )

        closed = _success(
            bridge.request({"command": "session-close", "session_id": session_id}),
            "Chiusura sessione stateful",
        )
        if closed.get("closed") is not True:
            raise OfflineAcceptanceError("La sessione stateful non e' stata chiusa.")

    if tuple(item["name"] for item in results) != STATEFUL_SCENARIOS or any(
        item.get("status") != "passed" for item in results
    ):
        raise OfflineAcceptanceError("L'accettazione stateful non e' completa.")
    status = read_lab_status(ready)
    if status.get("active_fault") != "none":
        raise OfflineAcceptanceError("Una fault injection e' rimasta attiva nel laboratorio.")
    if status.get("resource_count") != 12 or status.get("folder_count") != 5:
        raise OfflineAcceptanceError(
            "Lo stato finale del laboratorio non corrisponde ai nove scenari."
        )
    report = {
        "app": "Passbolt Migration Assistant Offline Acceptance",
        "version": APP_VERSION,
        "profile": profile,
        "synthetic_stateful": True,
        "real_instance_attestation": False,
        "scenario_count": len(results),
        "passed_count": len(results),
        "recovery_fault_path_count": 12,
        "scenarios": results,
        "remote_resource_count": int(status["resource_count"]),
        "remote_folder_count": int(status["folder_count"]),
        "contains_real_credentials": False,
        "status": "OK",
    }
    serialized = json.dumps(report, ensure_ascii=False, sort_keys=True)
    for forbidden in (
        str(ready.get("passphrase", "")),
        str(ready.get("mfa_totp", "")),
        str(ready.get("lab_token", "")),
        "LAB-ONLY-STATEFUL-",
        "BEGIN PGP",
    ):
        if forbidden and forbidden in serialized:
            raise OfflineAcceptanceError(
                "Il report stateful contiene materiale sintetico riservato."
            )
    return report


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Accettazione mutativa del laboratorio Passbolt offline."
    )
    parser.add_argument("--ready-file", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    ready: dict[str, Any] | None = None
    try:
        ready = load_ready_file(args.ready_file)
        os.environ["SSL_CERT_FILE"] = str(ready["certificate_path"])
        os.environ["NODE_EXTRA_CA_CERTS"] = str(ready["certificate_path"])
        report = run_acceptance(ready)
    except (
        OfflineAcceptanceError,
        OfflineLabSmokeError,
        MatrixError,
        OSError,
        ValueError,
    ) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
        return 2
    except (IndexError, KeyError, TypeError):
        print(
            json.dumps(
                {
                    "ok": False,
                    "error": "Il laboratorio ha restituito un contratto stateful inatteso.",
                },
                ensure_ascii=False,
            )
        )
        return 2
    finally:
        if ready is not None:
            ready["passphrase"] = ""
            ready["mfa_totp"] = ""
            ready["lab_token"] = ""
    print(json.dumps({"ok": True, "result": report}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
