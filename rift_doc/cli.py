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

    validate_set = subparsers.add_parser(
        "validate-set",
        aliases=["trace"],
        help="validate cross-document traceability for a manifest",
    )
    validate_set.add_argument("--manifest", required=True, type=Path, help="document-set YAML manifest")
    validate_set.add_argument(
        "--spec",
        type=Path,
        default=Path("capstone-doc-spec.v0.1.yaml"),
        help="capstone YAML contract (defaults to the repository contract)",
    )
    validate_set.add_argument("--format", choices=("text", "json"), default="text")
    validate_set.add_argument("--rule", action="append", help="only show one or more trace rule IDs")
    validate_set.add_argument("--entity", help="only show findings for an entity ID or exact normalized name")
    validate_set.add_argument("--show-graph", action="store_true", help="include a compact graph section in text output")
    validate_set.add_argument("--strict", action="store_true", help="treat warnings and review-required findings as failures")

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
        if args.command in {"validate-set", "trace"}:
            return _run_validate_set(args)
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


def _run_validate_set(args: argparse.Namespace) -> int:
    spec = CapstoneSpec.load(args.spec)
    engine = ValidationEngine(spec)
    result = engine.validate_set(args.manifest)
    has_errors = result.has_errors
    has_strict_issues = result.has_strict_issues
    display_result = _filter_trace_result(result, args.rule, args.entity)
    if args.format == "json":
        print(render_json([display_result]))
    else:
        text = render_text([display_result])
        if args.show_graph:
            graph = display_result.metadata.get("trace_graph", {})
            nodes = graph.get("nodes", []) if isinstance(graph, dict) else []
            edges = graph.get("edges", []) if isinstance(graph, dict) else []
            if text:
                text += "\n"
            text += "Trace graph: " + str(len(nodes)) + " node(s), " + str(len(edges)) + " edge(s)"
            for edge in edges[:20]:
                text += "\n  " + str(edge.get("from_entity")) + " -> " + str(edge.get("to_entity")) + " [" + str(edge.get("rule_id")) + "]"
        print(text)
    if args.strict:
        return 1 if has_strict_issues else 0
    return 1 if has_errors else 0


def _filter_trace_result(
    result: ValidationResult,
    rule_ids: list[str] | None,
    entity_query: str | None,
) -> ValidationResult:
    filtered = ValidationResult(
        source_path=result.source_path,
        report=result.report,
        format=result.format,
        findings=list(result.findings),
        metadata=dict(result.metadata),
    )
    if rule_ids:
        allowed = {str(rule_id).casefold() for rule_id in rule_ids}
        filtered.findings = [finding for finding in filtered.findings if finding.rule_id.casefold() in allowed]
        coverage = filtered.metadata.get("coverage")
        if isinstance(coverage, dict):
            filtered.metadata["coverage"] = {key: value for key, value in coverage.items() if key.casefold() in allowed}
    if entity_query:
        from .trace_model import normalize_name

        query = normalize_name(entity_query)
        def matches(finding: object) -> bool:
            source = getattr(finding, "source_entity", None)
            if isinstance(source, dict):
                values = [source.get("entity_id"), source.get("canonical_name"), *(source.get("aliases", []) or [])]
                return any(query == normalize_name(str(value)) or query in normalize_name(str(value)) for value in values if value)
            return query in normalize_name(str(getattr(finding, "message", "")))
        filtered.findings = [finding for finding in filtered.findings if matches(finding)]
    return filtered


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
