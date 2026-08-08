#!/usr/bin/env python3
"""Read-only connectivity and server-key verification for a Passbolt API."""

from __future__ import annotations

import argparse
import json
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass
from typing import Any


USER_AGENT = "Passbolt-Migration-Assistant-Probe/0.12.5"


class ProbeError(RuntimeError):
    """A safe, user-facing probe failure."""


@dataclass(frozen=True)
class ProbeResult:
    base_url: str
    health_http_status: int
    health_api_status: str | None
    health_body: Any
    verify_http_status: int
    verify_api_status: str | None
    fingerprint: str
    fingerprint_matches_expected: bool | None
    armored_public_key_present: bool
    public_key_length: int


def normalize_base_url(value: str) -> str:
    value = value.strip().rstrip("/")
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme.lower() != "https":
        raise ProbeError("L'URL Passbolt deve usare HTTPS.")
    if not parsed.hostname:
        raise ProbeError("L'URL Passbolt non contiene un nome host valido.")
    if parsed.path or parsed.query or parsed.fragment:
        raise ProbeError("Indicare soltanto l'URL base, senza percorso, query o frammento.")
    return value


def normalize_fingerprint(value: str) -> str:
    normalized = re.sub(r"[^0-9A-Fa-f]", "", value).upper()
    if len(normalized) != 40:
        raise ProbeError("La fingerprint OpenPGP attesa deve contenere 40 cifre esadecimali.")
    return normalized


def get_json(base_url: str, path: str, timeout: float) -> tuple[int, dict[str, Any]]:
    url = f"{base_url}{path}"
    request = urllib.request.Request(
        url,
        method="GET",
        headers={
            "Accept": "application/json",
            "User-Agent": USER_AGENT,
        },
    )
    context = ssl.create_default_context()
    try:
        with urllib.request.urlopen(request, timeout=timeout, context=context) as response:
            status = int(response.status)
            content_type = response.headers.get_content_type()
            if content_type != "application/json":
                raise ProbeError(
                    f"{path} ha restituito Content-Type {content_type!r}, non JSON."
                )
            raw = response.read()
    except urllib.error.HTTPError as exc:
        raise ProbeError(f"{path} ha restituito HTTP {exc.code} {exc.reason}.") from exc
    except urllib.error.URLError as exc:
        raise ProbeError(f"Connessione a {path} non riuscita: {exc.reason}") from exc
    except TimeoutError as exc:
        raise ProbeError(f"Timeout durante la richiesta a {path}.") from exc
    except ssl.SSLError as exc:
        raise ProbeError(f"Verifica TLS non riuscita per {path}: {exc}") from exc

    try:
        parsed = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProbeError(f"{path} non ha restituito un documento JSON valido.") from exc
    if not isinstance(parsed, dict):
        raise ProbeError(f"{path} ha restituito una struttura JSON inattesa.")
    return status, parsed


def api_status(document: dict[str, Any]) -> str | None:
    header = document.get("header")
    if not isinstance(header, dict):
        return None
    value = header.get("status")
    return value if isinstance(value, str) else None


def run_probe(
    base_url: str,
    expected_fingerprint: str | None,
    timeout: float,
) -> ProbeResult:
    health_http, health = get_json(base_url, "/healthcheck/status.json", timeout)
    if health_http != 200 or api_status(health) != "success" or health.get("body") != "OK":
        raise ProbeError("L'healthcheck Passbolt non dichiara lo stato OK.")

    verify_http, verify = get_json(base_url, "/auth/verify.json", timeout)
    if verify_http != 200 or api_status(verify) != "success":
        raise ProbeError("L'endpoint di verifica Passbolt non dichiara successo.")

    body = verify.get("body")
    if not isinstance(body, dict):
        raise ProbeError("La risposta di verifica non contiene un body valido.")

    fingerprint_value = body.get("fingerprint")
    keydata = body.get("keydata")
    if not isinstance(fingerprint_value, str):
        raise ProbeError("La risposta non contiene la fingerprint del server.")
    if not isinstance(keydata, str):
        raise ProbeError("La risposta non contiene la chiave pubblica del server.")

    fingerprint = normalize_fingerprint(fingerprint_value)
    key_is_armored = (
        "-----BEGIN PGP PUBLIC KEY BLOCK-----" in keydata
        and "-----END PGP PUBLIC KEY BLOCK-----" in keydata
    )
    if not key_is_armored:
        raise ProbeError("La chiave del server non è un blocco pubblico OpenPGP completo.")

    return ProbeResult(
        base_url=base_url,
        health_http_status=health_http,
        health_api_status=api_status(health),
        health_body=health.get("body"),
        verify_http_status=verify_http,
        verify_api_status=api_status(verify),
        fingerprint=fingerprint,
        fingerprint_matches_expected=(
            None if expected_fingerprint is None else fingerprint == expected_fingerprint
        ),
        armored_public_key_present=key_is_armored,
        public_key_length=len(keydata),
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Verifica in sola lettura healthcheck, TLS e fingerprint pubblica "
            "di un server Passbolt. Non effettua il login e non legge password."
        )
    )
    parser.add_argument(
        "--base-url",
        required=True,
        help="URL base HTTPS dell'istanza Passbolt.",
    )
    fingerprint_mode = parser.add_mutually_exclusive_group(required=True)
    fingerprint_mode.add_argument(
        "--expected-fingerprint",
        help="Fingerprint verificata con un canale amministrativo indipendente.",
    )
    fingerprint_mode.add_argument(
        "--discover-fingerprint",
        action="store_true",
        help=(
            "Rileva la fingerprint dichiarata dal server senza confrontarla con un "
            "valore preconfigurato. Richiede una conferma separata dell'utente."
        ),
    )
    parser.add_argument("--timeout", type=float, default=20.0)
    parser.add_argument(
        "--json",
        action="store_true",
        help="Stampa un risultato JSON adatto ad automazioni.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        base_url = normalize_base_url(args.base_url)
        expected = (
            normalize_fingerprint(args.expected_fingerprint)
            if args.expected_fingerprint
            else None
        )
        result = run_probe(base_url, expected, args.timeout)
    except ProbeError as exc:
        print(f"ERRORE: {exc}", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps(asdict(result), indent=2, ensure_ascii=False))
    else:
        print(f"Server: {result.base_url}")
        print(f"Healthcheck: HTTP {result.health_http_status}, {result.health_body}")
        print(f"API verify: HTTP {result.verify_http_status}, {result.verify_api_status}")
        print(f"Fingerprint: {result.fingerprint}")
        if result.fingerprint_matches_expected is None:
            print("Fingerprint attesa: NON FORNITA (modalità rilevamento)")
        else:
            print(
                "Fingerprint attesa: "
                + (
                    "CORRISPONDE"
                    if result.fingerprint_matches_expected
                    else "NON CORRISPONDE"
                )
            )
        print(
            "Chiave pubblica OpenPGP: "
            + ("PRESENTE" if result.armored_public_key_present else "NON VALIDA")
        )

    if result.fingerprint_matches_expected is False:
        print(
            "ERRORE: la fingerprint del server è cambiata. Non procedere con il login.",
            file=sys.stderr,
        )
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
