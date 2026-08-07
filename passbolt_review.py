#!/usr/bin/env python3
"""Local, read-only credential candidate review for selected inventory files.

The module intentionally never serializes a discovered secret. Candidate output
contains only a presence flag, its length and a fixed mask.
"""

from __future__ import annotations

import argparse
import configparser
import csv
import hashlib
import io
import json
import logging
import re
import sys
import unicodedata
import warnings
import zipfile
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Iterator
from xml.etree import ElementTree


APP_VERSION = "0.12.1"
ROOT_CLIENT_LABEL = "(radice)"
MAX_SELECTED_FILES = 50
MAX_FILE_BYTES = 20 * 1024 * 1024
MAX_ARCHIVE_UNCOMPRESSED_BYTES = 100 * 1024 * 1024
MAX_TEXT_CHARACTERS = 2_000_000
MAX_RECORDS_PER_FILE = 5_000
MAX_PDF_PAGES = 200
MAX_CANDIDATES = 2_000

# Third-party document readers can emit advisory warnings on stderr. The CLI
# stdout is a strict JSON contract consumed by Windows PowerShell 5.1, so known
# parser warnings are suppressed here and represented as controlled per-file
# warnings by analyze_files instead.
logging.getLogger("pypdf").setLevel(logging.ERROR)
warnings.filterwarnings("ignore", module=r"^(openpyxl|docx|pypdf)(\.|$)")

REVIEWABLE_EXTENSIONS = {
    ".txt",
    ".csv",
    ".tsv",
    ".json",
    ".xml",
    ".yaml",
    ".yml",
    ".ini",
    ".cfg",
    ".conf",
    ".env",
    ".properties",
    ".docx",
    ".xlsx",
    ".xls",
    ".pdf",
}


class ReviewError(RuntimeError):
    """A safe, user-facing review error."""


@dataclass(frozen=True)
class CredentialCandidate:
    candidate_id: str
    source_relative_path: str
    source_sha256: str
    client: str
    location: str
    title: str
    username: str
    uri: str
    secret_present: bool
    secret_mask: str
    secret_length: int
    status: str
    confidence: str
    fields_detected: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class ReviewResult:
    root: str
    reviewed_at_utc: str
    selected_files: int
    analyzed_files: int
    candidate_count: int
    ready_count: int
    incomplete_count: int
    candidates: list[CredentialCandidate] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


def _normalized_key(value: object) -> str:
    text = unicodedata.normalize("NFKD", str(value or ""))
    ascii_text = "".join(character for character in text if not unicodedata.combining(character))
    return re.sub(r"[^a-z0-9]", "", ascii_text.casefold())


TITLE_KEYS = {
    _normalized_key(value)
    for value in (
        "title",
        "titolo",
        "name",
        "nome",
        "resource",
        "risorsa",
        "service",
        "servizio",
        "application",
        "applicazione",
        "descrizione",
    )
}
USERNAME_KEYS = {
    _normalized_key(value)
    for value in (
        "username",
        "user",
        "utente",
        "login",
        "login name",
        "user name",
        "nome utente",
        "email",
        "e-mail",
        "account",
    )
}
SECRET_KEYS = {
    _normalized_key(value)
    for value in (
        "password",
        "pass",
        "passwd",
        "pwd",
        "secret",
        "segreto",
        "pin",
        "token",
        "api key",
        "apikey",
        "chiave api",
    )
}
URI_KEYS = {
    _normalized_key(value)
    for value in (
        "url",
        "uri",
        "website",
        "sito",
        "link",
        "host",
        "hostname",
        "server",
        "ip",
        "indirizzo",
    )
}
ALL_CREDENTIAL_KEYS = TITLE_KEYS | USERNAME_KEYS | SECRET_KEYS | URI_KEYS


def _utc_now() -> str:
    return datetime.now(tz=timezone.utc).isoformat().replace("+00:00", "Z")


def _scalar(value: object) -> str:
    if value is None:
        return ""
    if isinstance(value, (str, int, float, bool)):
        return str(value).strip()
    return ""


def _matches_field_key(key: object, aliases: set[str], allow_prefix: bool) -> bool:
    normalized = _normalized_key(key)
    if normalized in aliases:
        return True
    if not allow_prefix:
        return False
    # Environment/configuration files commonly use keys such as DB_PASSWORD
    # or PORTAL_USERNAME. Short aliases (for example "ip") are kept exact to
    # avoid accidental suffix matches in unrelated words.
    return any(len(alias) >= 4 and normalized.endswith(alias) for alias in aliases)


def _find_field(
    record: dict[object, object], aliases: set[str], *, allow_prefix: bool = False
) -> tuple[bool, str]:
    for key, value in record.items():
        if _matches_field_key(key, aliases, allow_prefix):
            return True, _scalar(value)
    return False, ""


def _has_credential_key(record: dict[object, object]) -> bool:
    return any(
        _matches_field_key(key, TITLE_KEYS, False)
        or _matches_field_key(key, USERNAME_KEYS, True)
        or _matches_field_key(key, SECRET_KEYS, True)
        or _matches_field_key(key, URI_KEYS, True)
        for key in record
    )


def _make_candidate(
    record: dict[object, object],
    *,
    relative_path: str,
    source_hash: str,
    client: str,
    location: str,
) -> CredentialCandidate | None:
    title_found, title = _find_field(record, TITLE_KEYS)
    username_found, username = _find_field(record, USERNAME_KEYS, allow_prefix=True)
    secret_found, secret = _find_field(record, SECRET_KEYS, allow_prefix=True)
    uri_found, uri = _find_field(record, URI_KEYS, allow_prefix=True)

    secret_present = bool(secret_found and secret)
    if not secret_found and not (username_found and (title_found or uri_found)):
        return None

    if not title:
        title = Path(relative_path).stem
    fields_detected: list[str] = []
    if title_found:
        fields_detected.append("title")
    if username_found:
        fields_detected.append("username")
    if secret_found:
        fields_detected.append("secret")
    if uri_found:
        fields_detected.append("uri")

    ready = secret_present and bool(username or uri)
    confidence = "high" if ready and (title_found or uri_found) else "medium"
    if not secret_present:
        confidence = "low"
    identifier_material = "\x1f".join(
        (relative_path, location, title, username, uri, source_hash)
    ).encode("utf-8", errors="surrogatepass")
    candidate_id = hashlib.sha256(identifier_material).hexdigest()[:16]

    return CredentialCandidate(
        candidate_id=candidate_id,
        source_relative_path=relative_path,
        source_sha256=source_hash,
        client=client,
        location=location,
        title=title,
        username=username,
        uri=uri,
        secret_present=secret_present,
        secret_mask="********" if secret_present else "",
        secret_length=len(secret) if secret_present else 0,
        status="ready" if ready else "incomplete",
        confidence=confidence,
        fields_detected=fields_detected,
    )


def _decode_text(raw: bytes) -> str:
    for encoding in ("utf-8-sig", "cp1252", "latin-1"):
        try:
            text = raw.decode(encoding)
            return text[:MAX_TEXT_CHARACTERS]
        except UnicodeDecodeError:
            continue
    raise ReviewError("Codifica testuale non riconosciuta.")


def _strip_wrapping_quotes(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        return value[1:-1]
    return value


def _key_value_records(text: str, label: str = "testo") -> Iterator[tuple[str, dict[str, str]]]:
    record: dict[str, str] = {}
    start_line = 1

    def emit(end_line: int) -> tuple[str, dict[str, str]] | None:
        nonlocal record, start_line
        if not record or not _has_credential_key(record):
            record = {}
            return None
        location = f"{label}, righe {start_line}-{end_line}"
        result = (location, record)
        record = {}
        return result

    lines = text.splitlines()
    for line_number, original_line in enumerate(lines, start=1):
        line = original_line.strip()
        if not line:
            result = emit(line_number - 1)
            if result:
                yield result
            start_line = line_number + 1
            continue
        if line.startswith(("#", ";", "//")):
            continue
        line = re.sub(r"^[-*]\s+", "", line)
        match = re.match(r"^([^:=\t]{1,100})\s*[:=\t]\s*(.*)$", line)
        if not match:
            continue
        key = match.group(1).strip()
        value = _strip_wrapping_quotes(match.group(2))
        normalized = _normalized_key(key)
        if normalized in {_normalized_key(existing) for existing in record}:
            result = emit(line_number - 1)
            if result:
                yield result
            start_line = line_number
        record[key] = value
    result = emit(len(lines))
    if result:
        yield result


def _csv_records(text: str, delimiter: str) -> Iterator[tuple[str, dict[str, str]]]:
    reader = csv.DictReader(io.StringIO(text), delimiter=delimiter)
    if not reader.fieldnames:
        return
    for row_number, row in enumerate(reader, start=2):
        if row_number > MAX_RECORDS_PER_FILE + 1:
            break
        yield f"riga {row_number}", {str(key): _scalar(value) for key, value in row.items() if key}


def _json_records(text: str) -> Iterator[tuple[str, dict[object, object]]]:
    try:
        document = json.loads(text)
    except json.JSONDecodeError as exc:
        raise ReviewError(f"JSON non valido alla riga {exc.lineno}.") from exc

    emitted = 0

    def visit(value: object, path: str) -> Iterator[tuple[str, dict[object, object]]]:
        nonlocal emitted
        if emitted >= MAX_RECORDS_PER_FILE:
            return
        if isinstance(value, dict):
            if _has_credential_key(value):
                emitted += 1
                yield path, value
            for key, child in value.items():
                if isinstance(child, (dict, list)):
                    safe_key = str(key).replace("~", "~0").replace("/", "~1")
                    yield from visit(child, f"{path}/{safe_key}")
        elif isinstance(value, list):
            for index, child in enumerate(value):
                if isinstance(child, (dict, list)):
                    yield from visit(child, f"{path}/{index}")

    yield from visit(document, "$")


def _xml_records(raw: bytes) -> Iterator[tuple[str, dict[str, str]]]:
    normalized = raw.upper()
    if b"<!DOCTYPE" in normalized or b"<!ENTITY" in normalized:
        raise ReviewError("XML con DTD o entità non consentite.")
    try:
        root = ElementTree.fromstring(raw)
    except ElementTree.ParseError as exc:
        raise ReviewError("XML non valido.") from exc

    emitted = 0
    for index, element in enumerate(root.iter(), start=1):
        children = list(element)
        if not children:
            continue
        record: dict[str, str] = {}
        for child in children:
            if not list(child):
                tag = child.tag.rsplit("}", 1)[-1]
                record[tag] = (child.text or "").strip()
        if record and _has_credential_key(record):
            emitted += 1
            yield f"elemento {element.tag.rsplit('}', 1)[-1]} #{index}", record
            if emitted >= MAX_RECORDS_PER_FILE:
                break


def _ini_records(text: str) -> Iterator[tuple[str, dict[str, str]]]:
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    parser.optionxform = str
    try:
        parser.read_string(text)
    except configparser.Error:
        yield from _key_value_records(text)
        return
    for section in parser.sections():
        yield f"sezione [{section}]", dict(parser.items(section))
    if parser.defaults():
        yield "sezione [DEFAULT]", dict(parser.defaults())


def _preflight_zip(path: Path) -> None:
    try:
        with zipfile.ZipFile(path) as archive:
            total = sum(member.file_size for member in archive.infolist())
            if total > MAX_ARCHIVE_UNCOMPRESSED_BYTES:
                raise ReviewError("Archivio Office troppo grande dopo la decompressione.")
            if any(member.flag_bits & 0x1 for member in archive.infolist()):
                raise ReviewError("Archivio Office cifrato non supportato.")
    except zipfile.BadZipFile as exc:
        raise ReviewError("Documento Office non valido o danneggiato.") from exc


def _xlsx_records(path: Path) -> Iterator[tuple[str, dict[str, str]]]:
    _preflight_zip(path)
    try:
        from openpyxl import load_workbook
    except ImportError as exc:
        raise ReviewError("Parser XLSX non disponibile.") from exc

    workbook = load_workbook(path, read_only=True, data_only=False, keep_links=False)
    try:
        emitted = 0
        for worksheet in workbook.worksheets:
            headers: list[str] | None = None
            header_row = 0
            for row_number, values in enumerate(worksheet.iter_rows(values_only=True), start=1):
                if not any(value is not None and str(value).strip() for value in values):
                    continue
                if headers is None:
                    headers = [
                        _scalar(value) or f"colonna_{index}"
                        for index, value in enumerate(values, start=1)
                    ]
                    header_row = row_number
                    continue
                record = {
                    headers[index]: _scalar(value)
                    for index, value in enumerate(values)
                    if index < len(headers)
                }
                emitted += 1
                yield f"foglio {worksheet.title}, riga {row_number}", record
                if emitted >= MAX_RECORDS_PER_FILE:
                    return
            if headers is not None and header_row and emitted >= MAX_RECORDS_PER_FILE:
                return
    finally:
        workbook.close()


def _docx_records(path: Path) -> Iterator[tuple[str, dict[str, str]]]:
    _preflight_zip(path)
    try:
        from docx import Document
    except ImportError as exc:
        raise ReviewError("Parser DOCX non disponibile.") from exc

    document = Document(path)
    paragraph_text = "\n".join(paragraph.text for paragraph in document.paragraphs)
    yield from _key_value_records(paragraph_text, "paragrafi")
    emitted = 0
    for table_number, table in enumerate(document.tables, start=1):
        if not table.rows:
            continue
        headers = [cell.text.strip() or f"colonna_{index}" for index, cell in enumerate(table.rows[0].cells, start=1)]
        for row_number, row in enumerate(table.rows[1:], start=2):
            record = {
                headers[index]: cell.text.strip()
                for index, cell in enumerate(row.cells)
                if index < len(headers)
            }
            emitted += 1
            yield f"tabella {table_number}, riga {row_number}", record
            if emitted >= MAX_RECORDS_PER_FILE:
                return


def _pdf_records(path: Path) -> Iterator[tuple[str, dict[str, str]]]:
    try:
        from pypdf import PdfReader
    except ImportError as exc:
        raise ReviewError("Parser PDF non disponibile.") from exc

    reader = PdfReader(str(path), strict=False)
    if reader.is_encrypted:
        try:
            if reader.decrypt("") == 0:
                raise ReviewError("PDF cifrato: inserimento password non disponibile.")
        except ReviewError:
            raise
        except Exception as exc:
            raise ReviewError("PDF cifrato: inserimento password non disponibile.") from exc
    for page_number, page in enumerate(reader.pages[:MAX_PDF_PAGES], start=1):
        try:
            text = (page.extract_text() or "")[:MAX_TEXT_CHARACTERS]
        except Exception as exc:
            raise ReviewError(f"Testo PDF non leggibile a pagina {page_number}.") from exc
        yield from _key_value_records(text, f"pagina {page_number}")


def _records_for_file(path: Path, extension: str) -> Iterable[tuple[str, dict[object, object]]]:
    if extension == ".xls":
        raise ReviewError("Formato XLS legacy non disponibile; salvare una copia come XLSX.")
    if extension == ".xlsx":
        return _xlsx_records(path)
    if extension == ".docx":
        return _docx_records(path)
    if extension == ".pdf":
        return _pdf_records(path)

    raw = path.read_bytes()
    if extension == ".xml":
        return _xml_records(raw)
    text = _decode_text(raw)
    if extension == ".csv":
        return _csv_records(text, ",")
    if extension == ".tsv":
        return _csv_records(text, "\t")
    if extension == ".json":
        return _json_records(text)
    if extension in {".ini", ".cfg"}:
        return _ini_records(text)
    return _key_value_records(text)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _safe_selected_path(root: Path, supplied: str) -> tuple[Path, str]:
    relative = Path(supplied)
    if relative.is_absolute():
        raise ReviewError("Il file selezionato deve essere relativo alla cartella clienti.")
    unresolved_candidate = root / relative
    if unresolved_candidate.is_symlink():
        raise ReviewError("I collegamenti a file non vengono aperti in revisione.")
    candidate = unresolved_candidate.resolve()
    try:
        normalized_relative = candidate.relative_to(root)
    except ValueError as exc:
        raise ReviewError("Percorso selezionato esterno alla cartella clienti.") from exc
    if not candidate.is_file():
        raise ReviewError("File selezionato non trovato o non accessibile.")
    return candidate, normalized_relative.as_posix()


def analyze_files(root: str | Path, selected_files: Iterable[str]) -> ReviewResult:
    root_path = Path(root).expanduser().resolve()
    if not root_path.is_dir():
        raise ReviewError("La cartella clienti non esiste o non è accessibile.")

    supplied_files = list(dict.fromkeys(str(value) for value in selected_files))
    if not supplied_files:
        raise ReviewError("Selezionare almeno un file da revisionare.")
    if len(supplied_files) > MAX_SELECTED_FILES:
        raise ReviewError(f"Selezionare al massimo {MAX_SELECTED_FILES} file per ogni revisione.")

    candidates: list[CredentialCandidate] = []
    warnings: list[str] = []
    analyzed_files = 0

    for supplied in supplied_files:
        if len(candidates) >= MAX_CANDIDATES:
            warnings.append(f"Limite complessivo di {MAX_CANDIDATES} candidati raggiunto.")
            break
        try:
            path, relative_path = _safe_selected_path(root_path, supplied)
            extension = path.suffix.lower()
            if not extension and path.name.lower() == ".env":
                extension = ".env"
            if extension not in REVIEWABLE_EXTENSIONS:
                raise ReviewError(f"Formato {extension or '(senza estensione)'} non revisionabile.")
            size = path.stat().st_size
            if size > MAX_FILE_BYTES:
                raise ReviewError(f"File oltre il limite di {MAX_FILE_BYTES // (1024 * 1024)} MB.")

            source_hash = _sha256(path)
            relative_parts = Path(relative_path).parts
            client = relative_parts[0] if len(relative_parts) > 1 else ROOT_CLIENT_LABEL
            file_candidates = 0
            for location, record in _records_for_file(path, extension):
                candidate = _make_candidate(
                    record,
                    relative_path=relative_path,
                    source_hash=source_hash,
                    client=client,
                    location=location,
                )
                if candidate is not None:
                    candidates.append(candidate)
                    file_candidates += 1
                if len(candidates) >= MAX_CANDIDATES:
                    break
            analyzed_files += 1
            if file_candidates == 0:
                warnings.append(f"{relative_path}: nessun candidato riconosciuto.")
        except (OSError, ReviewError, ValueError, zipfile.BadZipFile) as exc:
            warnings.append(f"{supplied}: {exc}")
        except Exception as exc:
            warnings.append(f"{supplied}: documento non analizzabile ({type(exc).__name__}).")

    ready_count = sum(candidate.status == "ready" for candidate in candidates)
    return ReviewResult(
        root=str(root_path),
        reviewed_at_utc=_utc_now(),
        selected_files=len(supplied_files),
        analyzed_files=analyzed_files,
        candidate_count=len(candidates),
        ready_count=ready_count,
        incomplete_count=len(candidates) - ready_count,
        candidates=candidates,
        warnings=warnings,
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Revisione locale e mascherata dei candidati Passbolt.")
    parser.add_argument("--root", help="Cartella principale configurata nell'app.")
    parser.add_argument("--file", action="append", default=[], help="Percorso relativo selezionato; ripetibile.")
    parser.add_argument("--json", action="store_true", help="Stampa il report JSON con segreti mascherati.")
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        print(
            json.dumps(
                {
                    "version": APP_VERSION,
                    "max_selected_files": MAX_SELECTED_FILES,
                    "reviewable_extensions": len(REVIEWABLE_EXTENSIONS),
                    "secrets_serialized": False,
                }
            )
        )
        return 0
    if not args.root or not args.file:
        print("ERRORE: indicare --root e almeno un --file.", file=sys.stderr)
        return 2
    try:
        result = analyze_files(args.root, args.file)
    except ReviewError as exc:
        print(f"ERRORE: {exc}", file=sys.stderr)
        return 2

    document = asdict(result)
    if args.json:
        # ensure_ascii keeps the stdout contract reliable under Windows
        # PowerShell 5.1 regardless of its active console code page.
        print(json.dumps(document, indent=2, ensure_ascii=True))
    else:
        print(f"File analizzati: {result.analyzed_files}/{result.selected_files}")
        print(f"Candidati: {result.candidate_count}")
        print(f"Pronti: {result.ready_count}")
        print(f"Da completare: {result.incomplete_count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
