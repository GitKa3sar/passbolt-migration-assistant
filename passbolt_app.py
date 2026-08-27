#!/usr/bin/env python3
"""Metadata-only inventory backend for the Passbolt Migration Assistant."""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
from collections import Counter
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path


APP_TITLE = "Passbolt Migration Assistant"
APP_VERSION = "0.28.2"
ROOT_CLIENT_LABEL = "(radice)"

SUPPORTED_EXTENSIONS = {
    ".txt": "Testo",
    ".csv": "Dati tabellari",
    ".tsv": "Dati tabellari",
    ".json": "Configurazione",
    ".xml": "Configurazione",
    ".yaml": "Configurazione",
    ".yml": "Configurazione",
    ".ini": "Configurazione",
    ".cfg": "Configurazione",
    ".conf": "Configurazione",
    ".env": "Configurazione",
    ".properties": "Configurazione",
    ".docx": "Word",
    ".xlsx": "Excel",
    ".xls": "Excel",
    ".pdf": "PDF",
}


@dataclass(frozen=True)
class InventoryItem:
    """One supported file described only through filesystem metadata."""

    client: str
    relative_path: str
    name: str
    extension: str
    category: str
    size_bytes: int
    modified_utc: str | None
    is_link: bool


@dataclass(frozen=True)
class InventoryIssueSummary:
    """One aggregate source issue without file, client or path identifiers."""

    reason_code: str
    extension: str
    count: int


@dataclass(frozen=True)
class InventoryResult:
    root: str
    scanned_at_utc: str
    client_folders: int
    supported_files: int
    ignored_files: int
    supported_bytes: int
    by_extension: dict[str, int] = field(default_factory=dict)
    by_category: dict[str, int] = field(default_factory=dict)
    by_client: dict[str, int] = field(default_factory=dict)
    items: list[InventoryItem] = field(default_factory=list)
    access_errors: list[str] = field(default_factory=list)
    skipped_directory_links: list[str] = field(default_factory=list)
    issues: list[InventoryIssueSummary] = field(default_factory=list)


def human_size(value: int) -> str:
    size = float(value)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if size < 1024 or unit == "TB":
            return f"{size:.0f} {unit}" if unit == "B" else f"{size:.1f} {unit}"
        size /= 1024
    return f"{value} B"


def _utc_timestamp(value: float) -> str:
    return datetime.fromtimestamp(value, tz=timezone.utc).isoformat().replace("+00:00", "Z")


def _safe_extension_bucket(extension: str) -> str:
    """Return a bounded format label that cannot disclose a filename."""

    normalized = str(extension or "").strip().lower()
    if not normalized:
        return "(senza estensione)"
    if re.fullmatch(r"\.[a-z0-9]{1,12}", normalized):
        return normalized
    return "(altro)"


def build_inventory(root: str | Path) -> InventoryResult:
    """Walk *root* and collect metadata without opening any document content."""

    root_path = Path(root).expanduser().resolve()
    if not root_path.is_dir():
        raise ValueError("La cartella clienti selezionata non esiste o non è accessibile.")

    client_folders: set[str] = set()
    by_extension: Counter[str] = Counter()
    by_category: Counter[str] = Counter()
    by_client: Counter[str] = Counter()
    items: list[InventoryItem] = []
    ignored_files = 0
    ignored_by_extension: Counter[str] = Counter()
    file_links_by_extension: Counter[str] = Counter()
    supported_bytes = 0
    access_errors: list[str] = []
    skipped_directory_links: list[str] = []

    def on_walk_error(error: OSError) -> None:
        path = str(getattr(error, "filename", None) or "percorso non disponibile")
        access_errors.append(path)

    # os.walk does not follow directory links by default. lstat below also avoids
    # following file links while collecting metadata.
    for current_dir, dir_names, file_names in os.walk(
        root_path, onerror=on_walk_error, followlinks=False
    ):
        current_path = Path(current_dir)
        try:
            relative_directory = current_path.relative_to(root_path)
        except ValueError:
            continue

        # Explicitly prune both symbolic directory links and Windows junctions.
        # This keeps the scan inside the selected tree even on runtimes where a
        # junction is not reported as a regular symbolic link.
        for directory_name in list(dir_names):
            directory_path = current_path / directory_name
            is_junction = bool(
                hasattr(os.path, "isjunction") and os.path.isjunction(directory_path)
            )
            if directory_path.is_symlink() or is_junction:
                dir_names.remove(directory_name)
                skipped_directory_links.append(
                    directory_path.relative_to(root_path).as_posix()
                )

        if relative_directory.parts:
            client_folders.add(relative_directory.parts[0])
        else:
            client_folders.update(dir_names)

        for file_name in file_names:
            file_path = current_path / file_name
            extension = file_path.suffix.lower()
            if not extension and file_name.lower() == ".env":
                extension = ".env"
            if extension not in SUPPORTED_EXTENSIONS:
                ignored_files += 1
                ignored_by_extension[_safe_extension_bucket(extension)] += 1
                continue

            relative_path = file_path.relative_to(root_path)
            client = relative_path.parts[0] if len(relative_path.parts) > 1 else ROOT_CLIENT_LABEL
            category = SUPPORTED_EXTENSIONS[extension]
            size_bytes = 0
            modified_utc: str | None = None
            is_link = file_path.is_symlink()
            if is_link:
                file_links_by_extension[_safe_extension_bucket(extension)] += 1
            try:
                metadata = file_path.lstat()
                size_bytes = int(metadata.st_size)
                modified_utc = _utc_timestamp(metadata.st_mtime)
            except OSError:
                access_errors.append(str(file_path))

            by_extension[extension] += 1
            by_category[category] += 1
            by_client[client] += 1
            supported_bytes += size_bytes
            items.append(
                InventoryItem(
                    client=client,
                    relative_path=relative_path.as_posix(),
                    name=file_name,
                    extension=extension,
                    category=category,
                    size_bytes=size_bytes,
                    modified_utc=modified_utc,
                    is_link=is_link,
                )
            )

    items.sort(key=lambda item: (item.client.casefold(), item.relative_path.casefold()))
    issues: list[InventoryIssueSummary] = []
    issues.extend(
        InventoryIssueSummary("unsupported_format", extension, count)
        for extension, count in sorted(ignored_by_extension.items())
    )
    legacy_xls_count = int(by_extension.get(".xls", 0))
    if legacy_xls_count:
        issues.append(
            InventoryIssueSummary("legacy_xls_conversion", ".xls", legacy_xls_count)
        )
    issues.extend(
        InventoryIssueSummary("file_link_not_reviewed", extension, count)
        for extension, count in sorted(file_links_by_extension.items())
    )
    unique_access_errors = sorted(set(access_errors), key=str.casefold)
    if unique_access_errors:
        issues.append(
            InventoryIssueSummary(
                "access_error", "(non disponibile)", len(unique_access_errors)
            )
        )
    unique_directory_links = sorted(set(skipped_directory_links), key=str.casefold)
    if unique_directory_links:
        issues.append(
            InventoryIssueSummary(
                "directory_link_skipped",
                "(non disponibile)",
                len(unique_directory_links),
            )
        )
    return InventoryResult(
        root=str(root_path),
        scanned_at_utc=_utc_timestamp(datetime.now(tz=timezone.utc).timestamp()),
        client_folders=len(client_folders),
        supported_files=len(items),
        ignored_files=ignored_files,
        supported_bytes=supported_bytes,
        by_extension=dict(sorted(by_extension.items())),
        by_category=dict(sorted(by_category.items())),
        by_client=dict(sorted(by_client.items(), key=lambda pair: pair[0].casefold())),
        items=items,
        access_errors=unique_access_errors,
        skipped_directory_links=unique_directory_links,
        issues=issues,
    )


def _safe_spreadsheet_cell(value: object) -> object:
    """Prevent paths controlled by filenames from becoming spreadsheet formulae."""

    if isinstance(value, str) and value.startswith(("=", "+", "-", "@")):
        return "'" + value
    return value


def write_inventory_csv(result: InventoryResult, destination: str | Path) -> Path:
    """Write the metadata report as UTF-8 CSV, never document contents."""

    destination_path = Path(destination).expanduser().resolve()
    destination_path.parent.mkdir(parents=True, exist_ok=True)
    with destination_path.open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(
            [
                "Cliente",
                "Percorso relativo",
                "Nome file",
                "Estensione",
                "Categoria",
                "Dimensione (byte)",
                "Modificato (UTC)",
                "Collegamento",
            ]
        )
        for item in result.items:
            writer.writerow(
                [
                    _safe_spreadsheet_cell(item.client),
                    _safe_spreadsheet_cell(item.relative_path),
                    _safe_spreadsheet_cell(item.name),
                    item.extension,
                    item.category,
                    item.size_bytes,
                    item.modified_utc or "",
                    "sì" if item.is_link else "no",
                ]
            )
    return destination_path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=APP_TITLE)
    parser.add_argument(
        "--inventory", metavar="CARTELLA", help="Crea un inventario senza leggere il contenuto dei file."
    )
    parser.add_argument("--json", action="store_true", help="Stampa il risultato in JSON.")
    parser.add_argument("--csv", metavar="FILE", help="Esporta anche il dettaglio metadati in CSV.")
    parser.add_argument("--self-test", action="store_true", help="Controlla il backend locale.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        print(
            json.dumps(
                {
                    "app": APP_TITLE,
                    "version": APP_VERSION,
                    "supported_extensions": len(SUPPORTED_EXTENSIONS),
                }
            )
        )
        return 0
    if not args.inventory:
        print("ERRORE: indicare --inventory CARTELLA oppure usare run_passbolt_app.ps1.")
        return 2

    try:
        result = build_inventory(args.inventory)
        csv_path = write_inventory_csv(result, args.csv) if args.csv else None
    except (OSError, ValueError) as exc:
        print(f"ERRORE: {exc}")
        return 2

    if args.json:
        document = asdict(result)
        if csv_path:
            document["csv_path"] = str(csv_path)
        print(json.dumps(document, indent=2, ensure_ascii=False))
    else:
        print(f"Clienti: {result.client_folders}")
        print(f"File supportati: {result.supported_files}")
        print(f"Dimensione: {human_size(result.supported_bytes)}")
        if csv_path:
            print(f"CSV: {csv_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
