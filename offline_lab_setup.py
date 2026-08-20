#!/usr/bin/env python3
"""Create ephemeral TLS material and synthetic source documents for the offline lab."""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID


APP_VERSION = "0.28.0"
LAB_MARKER = "LAB-ONLY-NOT-A-REAL-SECRET"
WORKSPACE_NAME_PATTERN = re.compile(r"^passbolt-offline-lab-[0-9a-f]{32}$")


class OfflineLabSetupError(RuntimeError):
    """Safe setup failure that never includes generated credential values."""


def _safe_workspace(path: str | Path) -> Path:
    workspace = Path(path).expanduser().resolve()
    temp_root = Path(os.environ.get("TEMP") or os.environ.get("TMP") or ".").resolve()
    try:
        relative = workspace.relative_to(temp_root)
    except ValueError as exc:
        raise OfflineLabSetupError(
            "Il laboratorio deve essere creato nella directory temporanea locale."
        ) from exc
    if len(relative.parts) != 1 or not WORKSPACE_NAME_PATTERN.fullmatch(workspace.name):
        raise OfflineLabSetupError(
            "Il nome della directory temporanea del laboratorio non e' valido."
        )
    if workspace.exists() and any(workspace.iterdir()):
        raise OfflineLabSetupError(
            "La directory temporanea del laboratorio non e' vuota."
        )
    workspace.mkdir(parents=False, exist_ok=True)
    return workspace


def _write_private(path: Path, content: bytes) -> None:
    path.write_bytes(content)
    try:
        path.chmod(0o600)
    except OSError:
        pass


def _generate_tls(workspace: Path) -> tuple[Path, Path]:
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = issuer = x509.Name(
        [
            x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Passbolt Migration Assistant"),
            x509.NameAttribute(NameOID.COMMON_NAME, "Passbolt Offline Lab"),
        ]
    )
    now = datetime.now(timezone.utc)
    certificate = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(private_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(minutes=5))
        .not_valid_after(now + timedelta(days=2))
        .add_extension(
            x509.SubjectAlternativeName(
                [
                    x509.DNSName("localhost"),
                    x509.IPAddress(ipaddress.ip_address("127.0.0.1")),
                ]
            ),
            critical=False,
        )
        .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
        .add_extension(
            x509.KeyUsage(
                digital_signature=True,
                content_commitment=False,
                key_encipherment=True,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=True,
                crl_sign=True,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
        .add_extension(
            x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]),
            critical=False,
        )
        .sign(private_key, hashes.SHA256())
    )
    key_path = workspace / "localhost-key.pem"
    certificate_path = workspace / "localhost-ca-and-server.pem"
    _write_private(
        key_path,
        private_key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        ),
    )
    certificate_path.write_bytes(certificate.public_bytes(serialization.Encoding.PEM))
    return certificate_path, key_path


def _generate_dataset(workspace: Path) -> tuple[Path, list[dict[str, Any]]]:
    dataset = workspace / "clienti-sintetici"
    alpha = dataset / "Cliente Alfa"
    beta = dataset / "Cliente Beta"
    alpha.mkdir(parents=True)
    beta.mkdir(parents=True)
    documents: dict[Path, str] = {
        alpha / "portale-clienti.txt": (
            "Titolo: Portale clienti laboratorio\n"
            "Utente: lab-alpha-user\n"
            f"Password: {LAB_MARKER}-ALPHA-001\n"
            "URL: https://alpha.example.invalid\n"
        ),
        alpha / "router-sede.txt": (
            "Titolo: Router sede laboratorio\n"
            "Username: lab-router-admin\n"
            f"Password: {LAB_MARKER}-ROUTER-002\n"
            "Indirizzo IP: 192.0.2.25\n"
        ),
        beta / "accessi.json": json.dumps(
            {
                "credenziali": [
                    {
                        "titolo": "CRM laboratorio",
                        "username": "lab-crm-user",
                        "password": f"{LAB_MARKER}-CRM-003",
                        "url": "https://crm.example.invalid",
                    },
                    {
                        "titolo": "NAS laboratorio",
                        "username": "lab-nas-user",
                        "password": f"{LAB_MARKER}-NAS-004",
                        "ipv6": "2001:db8::25",
                    },
                ]
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        dataset / "credenziale-radice.env": (
            "TITLE=Accesso radice laboratorio\n"
            "USERNAME=lab-root-user\n"
            f"PASSWORD={LAB_MARKER}-ROOT-005\n"
            "URL=https://root.example.invalid\n"
        ),
    }
    manifest: list[dict[str, Any]] = []
    for path, content in documents.items():
        path.write_text(content, encoding="utf-8")
        relative = path.relative_to(dataset).as_posix()
        manifest.append(
            {
                "relative_path": relative,
                "sha256": hashlib.sha256(content.encode("utf-8")).hexdigest(),
                "synthetic": True,
            }
        )
    manifest.sort(key=lambda item: item["relative_path"])
    return dataset, manifest


def create_offline_lab_workspace(path: str | Path) -> dict[str, Any]:
    workspace = _safe_workspace(path)
    certificate_path, key_path = _generate_tls(workspace)
    dataset_path, documents = _generate_dataset(workspace)
    manifest = {
        "schema_version": 1,
        "app_version": APP_VERSION,
        "workspace": str(workspace),
        "certificate_path": str(certificate_path),
        "tls_private_key_path": str(key_path),
        "dataset_root": str(dataset_path),
        "document_count": len(documents),
        "documents": documents,
        "contains_real_credentials": False,
        "status": "OK",
    }
    manifest_path = workspace / "setup-manifest.json"
    manifest_path.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return {**manifest, "manifest_path": str(manifest_path)}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Prepara il laboratorio Passbolt offline.")
    parser.add_argument("--workspace", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        result = create_offline_lab_workspace(args.workspace)
    except (OfflineLabSetupError, OSError, ValueError) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
        return 2
    print(json.dumps({"ok": True, "result": result}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
