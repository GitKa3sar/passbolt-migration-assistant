#!/usr/bin/env python3
"""Repeatable, secret-free integration matrix for real Passbolt v4/v5 labs.

The runner automates only read-only checks. Credentials are requested
interactively, sent to the existing Node bridge over stdin and never written to
the configuration, report, command line, environment or logs. Scenarios that
perform remote writes are executed through the desktop application and can be
recorded afterwards as explicit operator attestations.
"""

from __future__ import annotations

import argparse
import getpass
import hashlib
import json
import os
import queue
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import uuid
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

from passbolt_api_probe import ProbeError, normalize_base_url, normalize_fingerprint, run_probe


APP_VERSION = "0.28.1"
CONFIG_SCHEMA_VERSION = 1
REPORT_SCHEMA_VERSION = 1
CI_ENVIRONMENT_VARIABLES = ("CI", "GITHUB_ACTIONS", "PASSBOLT_MIGRATION_CI")
CI_TRUE_VALUES = frozenset({"1", "true", "yes", "on"})
MAX_CONFIG_BYTES = 128 * 1024
MAX_REPORT_BYTES = 1024 * 1024
MAX_BRIDGE_LINE_BYTES = 8 * 1024 * 1024
DEFAULT_TIMEOUT_SECONDS = 120.0
ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
ERROR_CODE_PATTERN = re.compile(r"^[A-Z][A-Z0-9_]{1,63}$")
TIMESTAMP_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
SAFE_AUTH_PHASES = {
    "server_key",
    "server_ownership",
    "user_challenge",
    "challenge_decryption",
    "challenge_response",
    "session_cookie",
    "identity_check",
    "mfa_totp",
    "identity_after_mfa",
    "identity_binding",
}

AUTOMATED_SCENARIOS = (
    "public_probe",
    "authenticated_login",
    "permission_catalog_read",
    "acl_catalog_read",
    "resource_root_dry_run",
    "client_folder_dry_run",
    "session_logout",
)

MANUAL_SCENARIOS = (
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

ALL_SCENARIOS = AUTOMATED_SCENARIOS + MANUAL_SCENARIOS
FINAL_STATUSES = {"passed", "failed", "blocked"}
REPORT_KEYS = {
    "schema_version",
    "app_version",
    "run_id",
    "instance_id",
    "expected_resource_format",
    "expected_folder_format",
    "started_at",
    "completed_at",
    "read_only_automation",
    "remote_writes_performed",
    "scenarios",
    "report_digest",
}
SAFE_METRIC_KEYS = {
    "health_http_status",
    "verify_http_status",
    "fingerprint_matches_expected",
    "armored_public_key_present",
    "write_requests",
    "authentication",
    "mfa_provider",
    "secrets_serialized",
    "entry_count",
    "user_count",
    "group_count",
    "folder_count",
    "resource_count",
    "shared_count",
    "verified_count",
    "warning_count",
    "read_only",
    "resource_format_selected",
    "folder_format_selected",
    "can_import",
    "create_count",
    "blocked_count",
    "create_folder_count",
    "closed",
    "error_code",
    "auth_phase",
    "http_status",
    "clock_skew_seconds",
    "operator_attested",
    "remote_writes_recorded",
}
BOOLEAN_METRICS = {
    "fingerprint_matches_expected",
    "armored_public_key_present",
    "secrets_serialized",
    "read_only",
    "can_import",
    "closed",
    "operator_attested",
    "remote_writes_recorded",
}
COUNT_METRICS = {
    "write_requests",
    "entry_count",
    "user_count",
    "group_count",
    "folder_count",
    "resource_count",
    "shared_count",
    "verified_count",
    "warning_count",
    "create_count",
    "blocked_count",
    "create_folder_count",
}


class MatrixError(RuntimeError):
    """Safe, user-facing integration-matrix failure."""


@dataclass(frozen=True)
class InstanceProfile:
    instance_id: str
    enabled: bool
    base_url: str
    expected_server_fingerprint: str
    expected_resource_format: str
    expected_folder_format: str


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _read_json_file(path: Path, limit: int, label: str) -> dict[str, Any]:
    try:
        size = path.stat().st_size
    except OSError as exc:
        raise MatrixError(f"{label} non disponibile.") from exc
    if size <= 0 or size > limit:
        raise MatrixError(f"{label} vuoto o oltre il limite consentito.")
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise MatrixError(f"{label} non contiene JSON UTF-8 valido.") from exc
    if not isinstance(document, dict):
        raise MatrixError(f"{label} deve contenere un oggetto JSON.")
    return document


def load_config(path: str | Path) -> list[InstanceProfile]:
    config_path = Path(path).expanduser().resolve()
    document = _read_json_file(config_path, MAX_CONFIG_BYTES, "La configurazione della matrice")
    if set(document) != {"schema_version", "instances"}:
        raise MatrixError("La configurazione contiene campi non riconosciuti.")
    if document.get("schema_version") != CONFIG_SCHEMA_VERSION:
        raise MatrixError("Versione dello schema di configurazione non supportata.")
    raw_instances = document.get("instances")
    if not isinstance(raw_instances, list) or not 1 <= len(raw_instances) <= 8:
        raise MatrixError("La configurazione deve contenere da una a otto istanze.")

    profiles: list[InstanceProfile] = []
    seen: set[str] = set()
    for raw in raw_instances:
        if not isinstance(raw, dict):
            raise MatrixError("Ogni profilo della matrice deve essere un oggetto JSON.")
        if set(raw) != {
            "id",
            "enabled",
            "base_url",
            "expected_server_fingerprint",
            "expected_resource_format",
            "expected_folder_format",
        }:
            raise MatrixError("Un profilo della matrice contiene campi non riconosciuti.")
        instance_id = str(raw.get("id", "")).strip().lower()
        if not ID_PATTERN.fullmatch(instance_id) or instance_id in seen:
            raise MatrixError("Gli ID delle istanze devono essere univoci e contenere solo lettere minuscole, numeri, _ o -.")
        seen.add(instance_id)
        enabled = raw.get("enabled")
        if type(enabled) is not bool:
            raise MatrixError(f"Il profilo {instance_id} deve dichiarare enabled come booleano.")
        try:
            base_url = normalize_base_url(str(raw.get("base_url", "")))
            fingerprint = normalize_fingerprint(str(raw.get("expected_server_fingerprint", "")))
        except ProbeError as exc:
            raise MatrixError(f"Il profilo {instance_id} non contiene URL e fingerprint validi.") from exc
        resource_format = str(raw.get("expected_resource_format", "")).strip().lower()
        folder_format = str(raw.get("expected_folder_format", "")).strip().lower()
        if resource_format not in {"v4", "v5"} or folder_format not in {"v4", "v5"}:
            raise MatrixError(f"Il profilo {instance_id} deve richiedere formati v4 oppure v5.")
        if enabled and len(set(fingerprint)) == 1:
            raise MatrixError(f"Il profilo attivo {instance_id} usa ancora una fingerprint segnaposto.")
        profiles.append(
            InstanceProfile(
                instance_id=instance_id,
                enabled=enabled,
                base_url=base_url,
                expected_server_fingerprint=fingerprint,
                expected_resource_format=resource_format,
                expected_folder_format=folder_format,
            )
        )
    return profiles


def find_profile(profiles: Sequence[InstanceProfile], instance_id: str) -> InstanceProfile:
    normalized = instance_id.strip().lower()
    matches = [profile for profile in profiles if profile.instance_id == normalized]
    if len(matches) != 1:
        raise MatrixError("Il profilo richiesto non esiste nella configurazione.")
    if not matches[0].enabled:
        raise MatrixError("Il profilo richiesto è disabilitato nella configurazione.")
    return matches[0]


def locate_node() -> Path:
    candidates: list[Path] = []
    user_profile = os.environ.get("USERPROFILE")
    if user_profile:
        candidates.append(
            Path(user_profile)
            / ".cache"
            / "codex-runtimes"
            / "codex-primary-runtime"
            / "dependencies"
            / "node"
            / "bin"
            / "node.exe"
        )
    resolved = shutil.which("node")
    if resolved:
        candidates.append(Path(resolved))
    for candidate in candidates:
        try:
            path = candidate.expanduser().resolve(strict=True)
        except OSError:
            continue
        if path.is_file():
            return path
    raise MatrixError("Node.js non trovato. Installare Node.js 18 o superiore.")


class JsonLineBridge:
    """Persistent stdin/stdout bridge with bounded, timeout-aware responses."""

    def __init__(self, node_path: Path, crypto_script: Path, timeout: float = DEFAULT_TIMEOUT_SECONDS) -> None:
        self.node_path = node_path
        self.crypto_script = crypto_script
        self.timeout = timeout
        self.process: subprocess.Popen[bytes] | None = None
        self.responses: queue.Queue[bytes | None] = queue.Queue()
        self.reader: threading.Thread | None = None

    def __enter__(self) -> "JsonLineBridge":
        creation_flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        try:
            self.process = subprocess.Popen(
                [str(self.node_path), str(self.crypto_script), "--session"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                cwd=str(self.crypto_script.parent),
                bufsize=0,
                creationflags=creation_flags,
            )
        except OSError as exc:
            raise MatrixError("Impossibile avviare il bridge OpenPGP locale.") from exc

        def pump() -> None:
            assert self.process is not None and self.process.stdout is not None
            while True:
                raw = self.process.stdout.readline(MAX_BRIDGE_LINE_BYTES + 1)
                if not raw:
                    self.responses.put(None)
                    return
                self.responses.put(raw)

        self.reader = threading.Thread(target=pump, daemon=True, name="passbolt-matrix-bridge-reader")
        self.reader.start()
        return self

    def request(
        self,
        document: Mapping[str, Any],
        *,
        progress_handler: Callable[[Mapping[str, Any]], None] | None = None,
    ) -> dict[str, Any]:
        process = self.process
        if process is None or process.stdin is None or process.poll() is not None:
            raise MatrixError("La sessione OpenPGP locale non è disponibile.")
        encoded = (json.dumps(document, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
        if len(encoded) > MAX_BRIDGE_LINE_BYTES:
            raise MatrixError("La richiesta della matrice supera il limite consentito.")
        try:
            process.stdin.write(encoded)
            process.stdin.flush()
        except (OSError, ValueError) as exc:
            raise MatrixError("Invio al bridge OpenPGP non riuscito.") from exc
        finally:
            encoded = b""

        while True:
            try:
                raw = self.responses.get(timeout=self.timeout)
            except queue.Empty as exc:
                raise MatrixError("Timeout durante una verifica della matrice.") from exc
            if raw is None:
                raise MatrixError("Il bridge OpenPGP si è chiuso senza risposta.")
            if len(raw) > MAX_BRIDGE_LINE_BYTES:
                raise MatrixError("La risposta del bridge supera il limite consentito.")
            try:
                envelope = json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise MatrixError("Il bridge OpenPGP ha restituito JSON non valido.") from exc
            if isinstance(envelope, dict) and envelope.get("type") == "progress":
                if progress_handler is None:
                    raise MatrixError("Il bridge ha segnalato una scrittura inattesa durante una prova in sola lettura.")
                try:
                    progress_handler(envelope)
                except Exception as exc:
                    raise MatrixError("Un avanzamento stateful del laboratorio non e' valido.") from exc
                continue
            if not isinstance(envelope, dict) or type(envelope.get("ok")) is not bool:
                raise MatrixError("Il bridge OpenPGP ha restituito una struttura inattesa.")
            return envelope

    def __exit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        process = self.process
        if process is None:
            return
        if process.poll() is None:
            try:
                if process.stdin is not None:
                    process.stdin.close()
                process.wait(timeout=5)
            except (OSError, subprocess.TimeoutExpired):
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)
        self.process = None


def _safe_error(envelope: Mapping[str, Any], fallback: str) -> dict[str, Any]:
    raw_error = envelope.get("error")
    error = raw_error if isinstance(raw_error, Mapping) else {}
    raw_code = str(error.get("code", ""))
    code = raw_code if ERROR_CODE_PATTERN.fullmatch(raw_code) else fallback
    result: dict[str, Any] = {"error_code": code}
    details = error.get("details")
    if isinstance(details, Mapping):
        phase = str(details.get("auth_phase", ""))
        if phase in SAFE_AUTH_PHASES:
            result["auth_phase"] = phase
        status = details.get("http_status")
        if type(status) is int and 100 <= status <= 599:
            result["http_status"] = status
        skew = details.get("clock_skew_seconds")
        if type(skew) is int and -86400 <= skew <= 86400:
            result["clock_skew_seconds"] = skew
    return result


def _passed(name: str, metrics: Mapping[str, Any] | None = None) -> dict[str, Any]:
    return {"name": name, "kind": "automated" if name in AUTOMATED_SCENARIOS else "manual", "status": "passed", "metrics": dict(metrics or {})}


def _failed(name: str, code: str, envelope: Mapping[str, Any] | None = None) -> dict[str, Any]:
    metrics = _safe_error(envelope or {}, code)
    return {"name": name, "kind": "automated" if name in AUTOMATED_SCENARIOS else "manual", "status": "failed", "metrics": metrics}


def _blocked(name: str, code: str) -> dict[str, Any]:
    return {"name": name, "kind": "automated" if name in AUTOMATED_SCENARIOS else "manual", "status": "blocked", "metrics": {"error_code": code}}


def _manual_not_run(name: str) -> dict[str, Any]:
    return {"name": name, "kind": "manual", "status": "not_run", "metrics": {}}


def _success_payload(envelope: Mapping[str, Any]) -> Mapping[str, Any] | None:
    payload = envelope.get("result")
    return payload if envelope.get("ok") is True and isinstance(payload, Mapping) else None


def _count_entries(entries: Any, aro: str) -> int:
    if not isinstance(entries, list):
        return 0
    return sum(1 for entry in entries if isinstance(entry, Mapping) and str(entry.get("aro", "")) == aro)


def _candidate(run_id: str, *, at_root: bool) -> dict[str, Any]:
    marker = run_id.replace("-", "")[:12]
    return {
        "candidate_id": f"matrix-{marker}-{'root' if at_root else 'folder'}",
        "client": "(radice)" if at_root else f"PMA Integration {marker}",
        "source_at_root": at_root,
        "title": f"PMA Integration {marker} {'Root' if at_root else 'Folder'}",
        "username": f"integration-{marker}",
        "uri": f"https://integration.example.invalid/{marker}",
    }


def _readiness_request(
    session_id: str,
    profile: InstanceProfile,
    run_id: str,
    *,
    at_root: bool,
) -> dict[str, Any]:
    return {
        "command": "session-readiness",
        "session_id": session_id,
        "resource_format": profile.expected_resource_format,
        "destination_mode": "root" if at_root else "client_folders",
        "folder_format": "auto" if at_root else profile.expected_folder_format,
        "destination_folder_id": None,
        "permission_mode": "inherited",
        "candidates": [_candidate(run_id, at_root=at_root)],
    }


def _evaluate_readiness(
    name: str,
    envelope: Mapping[str, Any],
    profile: InstanceProfile,
    *,
    expect_folder: bool,
) -> dict[str, Any]:
    payload = _success_payload(envelope)
    if payload is None:
        return _failed(name, "READINESS_FAILED", envelope)
    resource_format = str(payload.get("resource_format_selected", ""))
    raw_folder_format = payload.get("folder_format_selected")
    folder_format = "" if raw_folder_format is None else str(raw_folder_format)
    can_import = payload.get("can_import") is True
    create_count = payload.get("create_count") if type(payload.get("create_count")) is int else -1
    blocked_count = payload.get("blocked_count") if type(payload.get("blocked_count")) is int else -1
    create_folder_count = payload.get("create_folder_count") if type(payload.get("create_folder_count")) is int else -1
    if (
        resource_format != profile.expected_resource_format
        or not can_import
        or create_count != 1
        or blocked_count != 0
        or (expect_folder and (folder_format != profile.expected_folder_format or create_folder_count != 1))
    ):
        return _failed(name, "READINESS_EXPECTATION_MISMATCH")
    return _passed(
        name,
        {
            "resource_format_selected": resource_format,
            "folder_format_selected": folder_format or None,
            "can_import": can_import,
            "create_count": create_count,
            "blocked_count": blocked_count,
            "create_folder_count": create_folder_count,
            "write_requests": 0,
        },
    )


def _report_without_digest(report: Mapping[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in report.items() if key != "report_digest"}


def calculate_report_digest(report: Mapping[str, Any]) -> str:
    encoded = json.dumps(_report_without_digest(report), ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _validate_safe_metrics(metrics: Any) -> None:
    if not isinstance(metrics, dict) or not set(metrics).issubset(SAFE_METRIC_KEYS):
        raise MatrixError("Il report contiene metriche non riconosciute.")
    for key, value in metrics.items():
        if key in BOOLEAN_METRICS and type(value) is not bool:
            raise MatrixError("Il report contiene una metrica booleana non valida.")
        if key in COUNT_METRICS and (type(value) is not int or not 0 <= value <= 1_000_000_000):
            raise MatrixError("Il report contiene un contatore non valido.")
    if "authentication" in metrics and metrics["authentication"] not in {"GPGAuth", "GPGAuth + TOTP"}:
        raise MatrixError("Il report contiene un tipo di autenticazione non riconosciuto.")
    if "mfa_provider" in metrics and metrics["mfa_provider"] not in {None, "totp"}:
        raise MatrixError("Il report contiene un provider MFA non riconosciuto.")
    for key in ("resource_format_selected", "folder_format_selected"):
        if key in metrics and metrics[key] not in {None, "none", "v4", "v5"}:
            raise MatrixError("Il report contiene un formato Passbolt non riconosciuto.")
    if "error_code" in metrics and not ERROR_CODE_PATTERN.fullmatch(str(metrics["error_code"])):
        raise MatrixError("Il report contiene un codice errore non valido.")
    if "auth_phase" in metrics and metrics["auth_phase"] not in SAFE_AUTH_PHASES:
        raise MatrixError("Il report contiene una fase di autenticazione non riconosciuta.")
    if "http_status" in metrics and (type(metrics["http_status"]) is not int or not 100 <= metrics["http_status"] <= 599):
        raise MatrixError("Il report contiene uno stato HTTP non valido.")
    if "clock_skew_seconds" in metrics and (type(metrics["clock_skew_seconds"]) is not int or not -86400 <= metrics["clock_skew_seconds"] <= 86400):
        raise MatrixError("Il report contiene uno scarto temporale non valido.")


def validate_report_document(report: Mapping[str, Any]) -> None:
    if set(report) != REPORT_KEYS:
        raise MatrixError("Il report contiene campi non riconosciuti o mancanti.")
    if report.get("schema_version") != REPORT_SCHEMA_VERSION or report.get("app_version") != APP_VERSION:
        raise MatrixError("Il report usa uno schema o una versione applicativa non supportati.")
    try:
        run_id = uuid.UUID(str(report.get("run_id", "")))
    except (ValueError, AttributeError) as exc:
        raise MatrixError("Il report non contiene un identificativo run valido.") from exc
    if run_id.version != 4 or str(run_id) != str(report.get("run_id", "")):
        raise MatrixError("Il report non contiene un UUID v4 canonico.")
    if not ID_PATTERN.fullmatch(str(report.get("instance_id", ""))):
        raise MatrixError("Il report non contiene un ID istanza valido.")
    if report.get("expected_resource_format") not in {"v4", "v5"} or report.get("expected_folder_format") not in {"v4", "v5"}:
        raise MatrixError("Il report non contiene formati Passbolt validi.")
    if not TIMESTAMP_PATTERN.fullmatch(str(report.get("started_at", ""))) or not TIMESTAMP_PATTERN.fullmatch(str(report.get("completed_at", ""))):
        raise MatrixError("Il report non contiene timestamp UTC validi.")
    if report.get("read_only_automation") is not True or report.get("remote_writes_performed") != 0:
        raise MatrixError("Il report non appartiene all'automazione in sola lettura prevista.")
    scenarios = report.get("scenarios")
    if not isinstance(scenarios, list) or len(scenarios) != len(ALL_SCENARIOS):
        raise MatrixError("Il report non contiene il numero di scenari atteso.")
    for index, (scenario, expected_name) in enumerate(zip(scenarios, ALL_SCENARIOS)):
        if not isinstance(scenario, dict) or set(scenario) != {"name", "kind", "status", "metrics"} or scenario.get("name") != expected_name:
            raise MatrixError("Il report non contiene la matrice di scenari attesa.")
        expected_kind = "automated" if index < len(AUTOMATED_SCENARIOS) else "manual"
        if scenario.get("kind") != expected_kind:
            raise MatrixError("Il report contiene un tipo di scenario non valido.")
        allowed_statuses = FINAL_STATUSES if expected_kind == "automated" else FINAL_STATUSES | {"not_run"}
        if scenario.get("status") not in allowed_statuses:
            raise MatrixError("Il report contiene uno stato di scenario non valido.")
        _validate_safe_metrics(scenario.get("metrics"))
    digest = str(report.get("report_digest", ""))
    if not re.fullmatch(r"[0-9a-f]{64}", digest) or digest != calculate_report_digest(report):
        raise MatrixError("Il digest del report non corrisponde: il file è stato modificato o troncato.")


def finalize_report(report: dict[str, Any]) -> dict[str, Any]:
    report["report_digest"] = calculate_report_digest(report)
    return report


def default_report_directory() -> Path:
    local = os.environ.get("LOCALAPPDATA")
    base = Path(local) if local else Path(tempfile.gettempdir())
    return base / "Passbolt Migration Assistant" / "IntegrationMatrix"


def write_report(report: dict[str, Any], path: str | Path | None = None) -> Path:
    target = Path(path).expanduser().resolve() if path else default_report_directory() / f"matrix-{report['instance_id']}-{report['run_id']}.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    finalized = finalize_report(report)
    validate_report_document(finalized)
    encoded = (json.dumps(finalized, indent=2, ensure_ascii=False, sort_keys=True) + "\n").encode("utf-8")
    if len(encoded) > MAX_REPORT_BYTES:
        raise MatrixError("Il report della matrice supera il limite consentito.")
    temporary = target.with_name(f".{target.name}.{uuid.uuid4().hex}.tmp")
    try:
        with temporary.open("xb") as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, target)
    except OSError as exc:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass
        raise MatrixError("Il report della matrice non può essere salvato.") from exc
    return target


def load_report(path: str | Path) -> dict[str, Any]:
    report = _read_json_file(Path(path).expanduser().resolve(), MAX_REPORT_BYTES, "Il report della matrice")
    validate_report_document(report)
    return report


def run_instance(
    profile: InstanceProfile,
    private_key_path: Path,
    passphrase: str,
    mfa_totp: str,
    *,
    probe_runner: Callable[[str, str | None, float], Any] = run_probe,
    bridge_factory: Callable[[], Any] | None = None,
) -> dict[str, Any]:
    run_id = str(uuid.uuid4())
    started = utc_now()
    scenarios: list[dict[str, Any]] = []
    try:
        probe = probe_runner(profile.base_url, profile.expected_server_fingerprint, 20.0)
        if probe.fingerprint_matches_expected is not True:
            raise ProbeError("Fingerprint non corrispondente.")
        scenarios.append(
            _passed(
                "public_probe",
                {
                    "health_http_status": int(probe.health_http_status),
                    "verify_http_status": int(probe.verify_http_status),
                    "fingerprint_matches_expected": True,
                    "armored_public_key_present": bool(probe.armored_public_key_present),
                    "write_requests": 0,
                },
            )
        )
    except (ProbeError, OSError, ValueError):
        scenarios.append(_failed("public_probe", "PUBLIC_PROBE_FAILED"))
        for name in AUTOMATED_SCENARIOS[1:]:
            scenarios.append(_blocked(name, "PUBLIC_PROBE_REQUIRED"))
        scenarios.extend(_manual_not_run(name) for name in MANUAL_SCENARIOS)
        return finalize_report(
            {
                "schema_version": REPORT_SCHEMA_VERSION,
                "app_version": APP_VERSION,
                "run_id": run_id,
                "instance_id": profile.instance_id,
                "expected_resource_format": profile.expected_resource_format,
                "expected_folder_format": profile.expected_folder_format,
                "started_at": started,
                "completed_at": utc_now(),
                "read_only_automation": True,
                "remote_writes_performed": 0,
                "scenarios": scenarios,
            }
        )

    if bridge_factory is None:
        node = locate_node()
        script = Path(__file__).resolve().with_name("passbolt_crypto.mjs")
        if not script.is_file():
            raise MatrixError("Il bridge OpenPGP del progetto non è disponibile.")
        bridge_factory = lambda: JsonLineBridge(node, script)

    session_id = ""
    try:
        with bridge_factory() as bridge:
            open_request = {
                "command": "session-open",
                "base_url": profile.base_url,
                "expected_server_fingerprint": profile.expected_server_fingerprint,
                "private_key_path": str(private_key_path),
                "passphrase": passphrase,
                "mfa_totp": mfa_totp,
            }
            open_envelope = bridge.request(open_request)
            open_request["passphrase"] = None
            open_request["mfa_totp"] = None
            passphrase = ""
            mfa_totp = ""
            open_payload = _success_payload(open_envelope)
            if open_payload is None:
                scenarios.append(_failed("authenticated_login", "AUTHENTICATED_LOGIN_FAILED", open_envelope))
                for name in AUTOMATED_SCENARIOS[2:]:
                    scenarios.append(_blocked(name, "AUTHENTICATED_LOGIN_REQUIRED"))
            else:
                session_id = str(open_payload.get("session_id", ""))
                if not session_id or open_payload.get("secrets_serialized") is not False:
                    scenarios.append(_failed("authenticated_login", "AUTHENTICATED_LOGIN_RESPONSE_INVALID"))
                    for name in AUTOMATED_SCENARIOS[2:]:
                        scenarios.append(_blocked(name, "AUTHENTICATED_LOGIN_REQUIRED"))
                else:
                    scenarios.append(
                        _passed(
                            "authenticated_login",
                            {
                                "authentication": str(open_payload.get("authentication", "")),
                                "mfa_provider": str(open_payload.get("mfa_provider", "")) or None,
                                "secrets_serialized": False,
                                "write_requests": 0,
                            },
                        )
                    )

                    permissions = bridge.request({"command": "session-permissions", "session_id": session_id})
                    permission_payload = _success_payload(permissions)
                    if permission_payload is None:
                        scenarios.append(_failed("permission_catalog_read", "PERMISSION_CATALOG_FAILED", permissions))
                    else:
                        entries = permission_payload.get("entries")
                        entry_count = len(entries) if isinstance(entries, list) else -1
                        scenarios.append(
                            _passed(
                                "permission_catalog_read",
                                {
                                    "entry_count": entry_count,
                                    "user_count": _count_entries(entries, "User"),
                                    "group_count": _count_entries(entries, "Group"),
                                    "write_requests": 0,
                                },
                            )
                            if entry_count >= 0
                            else _failed("permission_catalog_read", "PERMISSION_CATALOG_RESPONSE_INVALID")
                        )

                    acl = bridge.request({"command": "session-acl-catalog", "session_id": session_id})
                    acl_payload = _success_payload(acl)
                    if acl_payload is None:
                        scenarios.append(_failed("acl_catalog_read", "ACL_CATALOG_FAILED", acl))
                    else:
                        numeric = ("folder_count", "resource_count", "shared_count", "verified_count", "warning_count")
                        if acl_payload.get("read_only") is not True or acl_payload.get("write_requests") != 0 or any(type(acl_payload.get(key)) is not int for key in numeric):
                            scenarios.append(_failed("acl_catalog_read", "ACL_CATALOG_RESPONSE_INVALID"))
                        else:
                            scenarios.append(_passed("acl_catalog_read", {key: int(acl_payload[key]) for key in numeric} | {"read_only": True, "write_requests": 0}))

                    root_readiness = bridge.request(_readiness_request(session_id, profile, run_id, at_root=True))
                    scenarios.append(_evaluate_readiness("resource_root_dry_run", root_readiness, profile, expect_folder=False))
                    folder_readiness = bridge.request(_readiness_request(session_id, profile, run_id, at_root=False))
                    scenarios.append(_evaluate_readiness("client_folder_dry_run", folder_readiness, profile, expect_folder=True))

                    close = bridge.request({"command": "session-close", "session_id": session_id})
                    close_payload = _success_payload(close)
                    scenarios.append(
                        _passed("session_logout", {"closed": True, "write_requests": 0})
                        if close_payload is not None and close_payload.get("closed") is True
                        else _failed("session_logout", "SESSION_LOGOUT_FAILED", close)
                    )
    except MatrixError:
        present = {scenario["name"] for scenario in scenarios}
        for name in AUTOMATED_SCENARIOS[1:]:
            if name not in present:
                scenarios.append(_blocked(name, "LOCAL_BRIDGE_FAILURE"))
    finally:
        passphrase = ""
        mfa_totp = ""

    by_name = {scenario["name"]: scenario for scenario in scenarios}
    ordered = [by_name.get(name, _blocked(name, "SCENARIO_NOT_COMPLETED")) for name in AUTOMATED_SCENARIOS]
    ordered.extend(_manual_not_run(name) for name in MANUAL_SCENARIOS)
    return finalize_report(
        {
            "schema_version": REPORT_SCHEMA_VERSION,
            "app_version": APP_VERSION,
            "run_id": run_id,
            "instance_id": profile.instance_id,
            "expected_resource_format": profile.expected_resource_format,
            "expected_folder_format": profile.expected_folder_format,
            "started_at": started,
            "completed_at": utc_now(),
            "read_only_automation": True,
            "remote_writes_performed": 0,
            "scenarios": ordered,
        }
    )


def record_manual_result(report_path: str | Path, scenario_name: str, status: str, error_code: str | None) -> Path:
    if scenario_name not in MANUAL_SCENARIOS:
        raise MatrixError("È possibile attestare soltanto gli scenari manuali previsti.")
    if status not in FINAL_STATUSES:
        raise MatrixError("Lo stato manuale deve essere passed, failed oppure blocked.")
    normalized_error = str(error_code or "").strip().upper()
    if status != "passed" and not ERROR_CODE_PATTERN.fullmatch(normalized_error):
        raise MatrixError("Per uno scenario non superato indicare un codice errore enumerato.")
    report = load_report(report_path)
    for scenario in report["scenarios"]:
        if scenario["name"] == scenario_name:
            scenario["status"] = status
            scenario["metrics"] = (
                {"operator_attested": True, "remote_writes_recorded": True}
                if status == "passed"
                else {"operator_attested": True, "error_code": normalized_error}
            )
            break
    report["completed_at"] = utc_now()
    return write_report(report, report_path)


def report_summary(report: Mapping[str, Any]) -> dict[str, int]:
    counts = {"passed": 0, "failed": 0, "blocked": 0, "not_run": 0}
    for scenario in report.get("scenarios", []):
        if isinstance(scenario, Mapping) and scenario.get("status") in counts:
            counts[str(scenario["status"])] += 1
    return counts


def real_instance_runs_allowed(environ: Mapping[str, Any] | None = None) -> bool:
    """Return False when a non-interactive CI environment is active.

    Validation, report inspection and the self-test remain available in CI. Only
    the command that prompts for real credentials and contacts a configured
    Passbolt laboratory is denied.
    """

    values = os.environ if environ is None else environ
    return not any(
        str(values.get(name, "")).strip().lower() in CI_TRUE_VALUES
        for name in CI_ENVIRONMENT_VARIABLES
    )


def self_test() -> dict[str, Any]:
    scenarios = [_passed(name, {"write_requests": 0}) for name in AUTOMATED_SCENARIOS]
    scenarios.extend(_manual_not_run(name) for name in MANUAL_SCENARIOS)
    report = finalize_report(
        {
            "schema_version": REPORT_SCHEMA_VERSION,
            "app_version": APP_VERSION,
            "run_id": str(uuid.uuid4()),
            "instance_id": "self-test",
            "expected_resource_format": "v5",
            "expected_folder_format": "v5",
            "started_at": utc_now(),
            "completed_at": utc_now(),
            "read_only_automation": True,
            "remote_writes_performed": 0,
            "scenarios": scenarios,
        }
    )
    safe = _safe_error(
        {
            "error": {
                "code": "MFA_TOTP_REJECTED",
                "message": "secret-message",
                "details": {
                    "auth_phase": "mfa_totp",
                    "http_status": 400,
                    "clock_skew_seconds": 35,
                    "private_key": "secret-key",
                    "base_url": "https://private.invalid",
                },
            }
        },
        "SELF_TEST_FAILED",
    )
    serialized = json.dumps({"report": report, "safe": safe}, sort_keys=True)
    return {
        "schema_version": REPORT_SCHEMA_VERSION,
        "automated_scenario_count": len(AUTOMATED_SCENARIOS),
        "manual_scenario_count": len(MANUAL_SCENARIOS),
        "read_only_automation": True,
        "ci_real_instance_guard": not real_instance_runs_allowed({"CI": "true"}),
        "report_digest_valid": report["report_digest"] == calculate_report_digest(report),
        "safe_failure_projection": "secret" not in serialized and "private.invalid" not in serialized,
        "secrets_serialized": False,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Matrice di integrazione sicura per istanze Passbolt v4/v5 reali.")
    subparsers = parser.add_subparsers(dest="action", required=True)

    validate = subparsers.add_parser("validate", help="Valida una configurazione senza collegarsi a Passbolt.")
    validate.add_argument("--config", required=True)

    run = subparsers.add_parser("run", help="Esegue le prove automatizzate in sola lettura su un profilo attivo.")
    run.add_argument("--config", required=True)
    run.add_argument("--instance", required=True)
    run.add_argument("--output")

    record = subparsers.add_parser("record", help="Registra l'esito attestato di uno scenario manuale.")
    record.add_argument("--report", required=True)
    record.add_argument("--scenario", required=True, choices=MANUAL_SCENARIOS)
    record.add_argument("--status", required=True, choices=sorted(FINAL_STATUSES))
    record.add_argument("--error-code")

    summary = subparsers.add_parser("summary", help="Verifica digest e riepiloga uno o più report.")
    summary.add_argument("--report", action="append", required=True)
    summary.add_argument("--require-complete", action="store_true")

    subparsers.add_parser("self-test", help=argparse.SUPPRESS)
    return parser.parse_args()


def _prompt_private_key() -> Path:
    value = input("Percorso della chiave privata OpenPGP (.asc): ").strip().strip('"')
    try:
        path = Path(value).expanduser().resolve(strict=True)
    except OSError as exc:
        raise MatrixError("La chiave privata selezionata non esiste.") from exc
    if not path.is_file() or path.suffix.lower() != ".asc":
        raise MatrixError("Selezionare un file .asc contenente la chiave privata OpenPGP.")
    return path


def main() -> int:
    args = parse_args()
    try:
        if args.action == "self-test":
            print(json.dumps({"ok": True, "result": self_test()}, ensure_ascii=False))
            return 0
        if args.action == "validate":
            profiles = load_config(args.config)
            enabled = sum(1 for profile in profiles if profile.enabled)
            print(f"Configurazione valida: {len(profiles)} profili, {enabled} attivi.")
            return 0
        if args.action == "run":
            if not real_instance_runs_allowed():
                raise MatrixError(
                    "L'esecuzione contro istanze Passbolt reali e disabilitata negli ambienti CI."
                )
            profile = find_profile(load_config(args.config), args.instance)
            private_key = _prompt_private_key()
            passphrase = getpass.getpass("Passphrase della chiave privata: ")
            mfa_totp = getpass.getpass("Codice MFA TOTP corrente (vuoto se non richiesto): ").strip()
            if mfa_totp and not re.fullmatch(r"\d{6}", mfa_totp):
                raise MatrixError("Il codice MFA TOTP deve contenere esattamente 6 cifre.")
            report = run_instance(profile, private_key, passphrase, mfa_totp)
            path = write_report(report, args.output)
            counts = report_summary(report)
            print(f"Report salvato: {path}")
            print(f"Automazione: {counts['passed']} superati, {counts['failed']} falliti, {counts['blocked']} bloccati; scenari manuali non eseguiti: {counts['not_run']}.")
            return 0 if counts["failed"] == 0 and counts["blocked"] == 0 else 4
        if args.action == "record":
            path = record_manual_result(args.report, args.scenario, args.status, args.error_code)
            print(f"Attestazione registrata: {path}")
            return 0
        if args.action == "summary":
            incomplete = False
            for value in args.report:
                report = load_report(value)
                counts = report_summary(report)
                print(f"{report['instance_id']}: {counts['passed']} passed, {counts['failed']} failed, {counts['blocked']} blocked, {counts['not_run']} not_run")
                incomplete = incomplete or counts["passed"] != len(ALL_SCENARIOS)
            return 5 if args.require_complete and incomplete else 0
    except MatrixError as exc:
        print(f"ERRORE: {exc}", file=sys.stderr)
        return 2
    finally:
        if "passphrase" in locals():
            passphrase = ""
        if "mfa_totp" in locals():
            mfa_totp = ""
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
