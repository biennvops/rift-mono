"""Command-line interface for deterministic capstone document validation."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys
from typing import Iterable

from .engine import SUPPORTED_SUFFIXES, ValidationEngine
from .output import render_json, render_text
from .results import Status, ValidationResult
from .spec import CapstoneSpec, SpecError


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="rift-doc", description="Deterministic Rift capstone document tooling")
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate = subparsers.add_parser("validate", help="validate one document or a directory")
    validate.add_argument("--spec", required=True, type=Path, help="capstone YAML contract")
    validate.add_argument("--report", help="report/workbook contract id; inferred when omitted")
    validate.add_argument("--input", type=Path, help="directory of documents for batch validation")
    validate.add_argument("--format", choices=("text", "json"), default="text")
    validate.add_argument("--strict", action="store_true", help="treat warnings and review-required findings as failures")
    validate.add_argument("path", nargs="?", type=Path, help="one DOCX/XLSX/XLS path")

    inspect = subparsers.add_parser("inspect", help="print the normalized document structure")
    inspect.add_argument("path", type=Path)
    inspect.add_argument("--spec", type=Path, help="optional contract used for heading matching")
    inspect.add_argument("--report", help="optional report/workbook contract id")
    inspect.add_argument("--format", choices=("text", "json"), default="text")
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(list(argv) if argv is not None else None)
    try:
        if args.command == "validate":
            return _run_validate(args)
        if args.command == "inspect":
            return _run_inspect(args)
        parser.error(f"unknown command {args.command}")
    except (SpecError, OSError, ValueError, RuntimeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    except Exception as exc:  # keep parser/internal failures at the documented code
        print(f"ERROR: internal parser failure: {exc}", file=sys.stderr)
        return 2
    return 2


def _run_validate(args: argparse.Namespace) -> int:
    if args.input and args.path:
        raise ValueError("provide either --input or a positional path, not both")
    if not args.input and not args.path:
        raise ValueError("provide a positional document path or --input directory")
    spec = CapstoneSpec.load(args.spec)
    engine = ValidationEngine(spec)
    paths = _input_paths(args.input or args.path)
    if not paths:
        raise ValueError("no supported DOCX/XLSX/XLS files found")

    results: list[ValidationResult] = []
    for path in paths:
        report_id = args.report or engine.infer_report_id(path)
        if not report_id:
            raise ValueError(f"could not infer a contract for {path}; provide --report")
        results.append(engine.validate(path, report_id))

    print(render_json(results) if args.format == "json" else render_text(results))
    if args.strict:
        return 1 if any(result.has_strict_issues for result in results) else 0
    return 1 if any(result.has_errors for result in results) else 0


def _run_inspect(args: argparse.Namespace) -> int:
    if args.spec:
        spec = CapstoneSpec.load(args.spec)
    else:
        # Inspect needs no contract; this small synthetic contract is avoided by
        # requiring the caller to supply one only when configured heading aliases
        # are desired.  The extractor can still operate without it.
        from .extractors.docx import extract_docx
        from .extractors.spreadsheets import extract_workbook

        if args.path.suffix.casefold() == ".docx":
            normalized = extract_docx(args.path)
        elif args.path.suffix.casefold() in {".xlsx", ".xls"}:
            normalized = extract_workbook(args.path)
        else:
            raise ValueError(f"unsupported input format: {args.path.suffix or '<none>'}")
        print(_inspect_json(normalized) if args.format == "json" else _inspect_text(normalized))
        return 0
    engine = ValidationEngine(spec)
    normalized = engine.inspect(args.path, args.report)
    print(_inspect_json(normalized) if args.format == "json" else _inspect_text(normalized))
    return 0


def _input_paths(value: Path) -> list[Path]:
    if value.is_file():
        if value.suffix.casefold() not in SUPPORTED_SUFFIXES:
            raise ValueError(f"unsupported input format: {value.suffix or '<none>'}")
        return [value]
    if not value.is_dir():
        raise ValueError(f"input path does not exist: {value}")
    return sorted(
        path for path in value.rglob("*") if path.is_file() and path.suffix.casefold() in SUPPORTED_SUFFIXES
    )


def _inspect_text(normalized: object) -> str:
    lines: list[str] = []
    if hasattr(normalized, "sections"):
        document = normalized
        lines.append(f"Document: {document.source_path}")
        lines.append(f"Format: {document.format}")
        lines.append("Sections:")
        for section in document.all_sections():
            lines.append(f"  {'  ' * max(section.level - 1, 0)}- {section.title} [{section.path}]")
        lines.append(f"Tables: {len(document.tables)}")
        for index, table in enumerate(document.tables):
            lines.append(f"  - table {index}: {table.dimensions[0]}x{table.dimensions[1]} ({table.parent_section})")
        lines.append(f"Images: {len(document.images)}")
        for image in document.images:
            lines.append(f"  - {image.source_location.display() if image.source_location else 'image'} ({image.description or 'no description'})")
    else:
        workbook = normalized
        lines.append(f"Workbook: {workbook.source_path}")
        lines.append(f"Format: {workbook.format}")
        lines.append("Sheets:")
        for sheet in workbook.sheets:
            lines.append(
                f"  - {sheet.name}: {sheet.dimensions[0]}x{sheet.dimensions[1]}, "
                f"headers={sheet.detected_header_rows}, merged={len(sheet.merged_regions)}"
            )
    return "\n".join(lines)


def _inspect_json(normalized: object) -> str:
    import json

    return json.dumps(normalized.to_dict(), indent=2, ensure_ascii=False)
