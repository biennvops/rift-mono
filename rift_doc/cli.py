"""Command-line interface for deterministic capstone document validation."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys
from typing import Iterable

from .engine import SUPPORTED_SUFFIXES, ValidationEngine
from .output import render_json, render_semantic_plan_json, render_semantic_plan_text, render_text
from .repository import InventoryOptions, RepositoryClaimKind, RepositoryInventory, RepositoryMappingConfig
from .results import ValidationResult
from .semantic import LLMProviderConfig, OpenAICompatibleProvider, SemanticAuditOptions, SemanticTaskType
from .spec import CapstoneSpec, SpecError


_SEMANTIC_TASK_CHOICES = tuple(
    task_type.value.casefold().replace("_", "-") for task_type in SemanticTaskType
)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="rift-doc", description="Rift capstone document audit tooling")
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
    _add_repository_arguments(validate_set, include_filters=True)
    validate_set.add_argument("--semantic", action="store_true", help="append bounded semantic review")
    _add_semantic_arguments(validate_set, execution=True, selector="--semantic-rule")

    semantic = subparsers.add_parser(
        "semantic",
        help="run a targeted bounded semantic review with deterministic evidence",
    )
    semantic.add_argument("--manifest", required=True, type=Path, help="document-set YAML manifest")
    semantic.add_argument(
        "--spec",
        type=Path,
        default=Path("capstone-doc-spec.v0.1.yaml"),
        help="capstone YAML contract (defaults to the repository contract)",
    )
    semantic.add_argument("--format", choices=("text", "json"), default="text")
    semantic.add_argument("--entity", help="only review one entity ID or matching name")
    semantic.add_argument("--strict", action="store_true", help="treat warnings and review-required findings as failures")
    _add_repository_arguments(semantic, include_filters=False)
    _add_semantic_arguments(semantic, execution=True, selector="--task")

    semantic_plan = subparsers.add_parser(
        "semantic-plan",
        help="list bounded semantic tasks and evidence sizes without calling a model",
    )
    semantic_plan.add_argument("--manifest", required=True, type=Path, help="document-set YAML manifest")
    semantic_plan.add_argument(
        "--spec",
        type=Path,
        default=Path("capstone-doc-spec.v0.1.yaml"),
        help="capstone YAML contract (defaults to the repository contract)",
    )
    semantic_plan.add_argument("--format", choices=("text", "json"), default="text")
    semantic_plan.add_argument("--entity", help="only plan tasks for one entity ID or matching name")
    _add_repository_arguments(semantic_plan, include_filters=False)
    _add_semantic_arguments(semantic_plan, execution=False, selector="--task")

    evidence = subparsers.add_parser(
        "evidence",
        help="validate document claims against a local repository",
    )
    evidence.add_argument("--manifest", required=True, type=Path, help="document-set YAML manifest")
    evidence.add_argument(
        "--spec",
        type=Path,
        default=Path("capstone-doc-spec.v0.1.yaml"),
        help="capstone YAML contract (defaults to the repository contract)",
    )
    evidence.add_argument("--format", choices=("text", "json"), default="text")
    evidence.add_argument("--strict", action="store_true", help="treat warnings and review-required findings as failures")
    _add_repository_arguments(evidence, required=True, include_filters=True)

    repo_inspect = subparsers.add_parser(
        "repo-inspect",
        help="inspect a local repository evidence inventory without a document audit",
    )
    repo_inspect.add_argument("--repo", required=True, type=Path, help="local repository/worktree")
    repo_inspect.add_argument("--artifacts", type=Path, help="optional package/result artifact directory")
    repo_inspect.add_argument("--mapping", type=Path, help="optional repository mapping YAML (also supplies exclusions)")
    repo_inspect.add_argument("--exclude", action="append", default=[], help="additional repository path/glob to exclude")
    repo_inspect.add_argument("--format", choices=("text", "json"), default="text")

    inspect = subparsers.add_parser("inspect", help="print the normalized document structure")
    inspect.add_argument("path", type=Path)
    inspect.add_argument("--spec", type=Path, help="optional contract used for heading matching")
    inspect.add_argument("--report", help="optional report/workbook contract id")
    inspect.add_argument("--format", choices=("text", "json"), default="text")
    return parser


def _add_repository_arguments(
    parser: argparse.ArgumentParser,
    *,
    required: bool = False,
    include_filters: bool = False,
) -> None:
    parser.add_argument("--repo", required=required, type=Path, help="local repository/worktree evidence source")
    parser.add_argument("--artifacts", type=Path, help="optional package/result artifact directory")
    parser.add_argument("--mapping", type=Path, help="schema-validated repository mapping YAML")
    if include_filters:
        parser.add_argument(
            "--kind",
            action="append",
            choices=("function", "architecture", "test", "deliverable"),
            help="only evaluate one or more repository claim kinds",
        )
        parser.add_argument("--claim", help="only evaluate an exact claim ID or name")


def _add_semantic_arguments(
    parser: argparse.ArgumentParser,
    *,
    execution: bool,
    selector: str,
) -> None:
    parser.add_argument(
        selector,
        action="append",
        choices=_SEMANTIC_TASK_CHOICES,
        help="only plan or run one or more semantic task types",
    )
    parser.add_argument("--max-tasks", type=int, default=50, help="hard semantic task limit (default: 50)")
    parser.add_argument(
        "--max-input-tokens",
        type=int,
        default=12_000,
        help="hard estimated input-token limit per task (default: 12000)",
    )
    parser.add_argument("--max-cost", type=float, help="optional estimated provider cost limit")
    parser.add_argument(
        "--semantic-exclude",
        action="append",
        default=[],
        help="additional evidence path/glob to exclude",
    )
    if not execution:
        return
    parser.add_argument(
        "--semantic-provider",
        choices=("openai-compatible",),
        help="provider adapter (or RIFT_DOC_LLM_PROVIDER)",
    )
    parser.add_argument("--semantic-model", help="provider model (or RIFT_DOC_LLM_MODEL)")
    parser.add_argument("--semantic-endpoint", help="chat-completions endpoint (or RIFT_DOC_LLM_ENDPOINT)")
    parser.add_argument("--semantic-temperature", type=float, help="review temperature (default/env: 0)")
    parser.add_argument("--semantic-max-output", type=int, help="maximum output tokens")
    parser.add_argument("--semantic-timeout", type=float, help="provider timeout in seconds")
    parser.add_argument("--semantic-retries", type=int, help="bounded retry count")
    parser.add_argument(
        "--semantic-api-key-env",
        help="name of the environment variable containing the API key",
    )
    parser.add_argument(
        "--semantic-local-only",
        action="store_true",
        default=None,
        help="reject non-local provider endpoints",
    )
    parser.add_argument("--semantic-input-cost-per-million", type=float, help="input-token pricing for --max-cost")
    parser.add_argument("--semantic-output-cost-per-million", type=float, help="output-token pricing for --max-cost")
    parser.add_argument("--no-cache", action="store_true", help="disable semantic result caching")
    parser.add_argument(
        "--semantic-cache",
        type=Path,
        default=Path(".rift-doc-cache/semantic"),
        help="semantic cache directory",
    )


def main(argv: Iterable[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(list(argv) if argv is not None else None)
    try:
        if args.command == "validate":
            return _run_validate(args)
        if args.command in {"validate-set", "trace"}:
            return _run_validate_set(args)
        if args.command == "semantic":
            return _run_semantic(args)
        if args.command == "semantic-plan":
            return _run_semantic_plan(args)
        if args.command == "evidence":
            return _run_evidence(args)
        if args.command == "repo-inspect":
            return _run_repo_inspect(args)
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
    provider = _semantic_provider(args) if args.semantic else None
    result = engine.validate_set(
        args.manifest,
        repository=args.repo,
        artifacts=args.artifacts,
        repository_mapping=args.mapping,
        repository_kinds=_repository_kinds(args.kind),
        repository_claim=args.claim,
        semantic_provider=provider,
        semantic_options=_semantic_options(args, selector_name="semantic_rule") if args.semantic else None,
    )
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


def _run_semantic(args: argparse.Namespace) -> int:
    spec = CapstoneSpec.load(args.spec)
    result = ValidationEngine(spec).validate_set(
        args.manifest,
        repository=args.repo,
        artifacts=args.artifacts,
        repository_mapping=args.mapping,
        semantic_provider=_semantic_provider(args),
        semantic_options=_semantic_options(args, selector_name="task"),
    )
    print(render_json([result]) if args.format == "json" else render_text([result]))
    if args.strict:
        return 1 if result.has_strict_issues else 0
    return 1 if result.has_errors else 0


def _run_semantic_plan(args: argparse.Namespace) -> int:
    spec = CapstoneSpec.load(args.spec)
    plan = ValidationEngine(spec).plan_semantic(
        args.manifest,
        repository=args.repo,
        artifacts=args.artifacts,
        repository_mapping=args.mapping,
        semantic_options=_semantic_options(args, selector_name="task"),
    )
    print(render_semantic_plan_json(plan) if args.format == "json" else render_semantic_plan_text(plan))
    return 0


def _run_evidence(args: argparse.Namespace) -> int:
    spec = CapstoneSpec.load(args.spec)
    result = ValidationEngine(spec).validate_repository_evidence(
        args.manifest,
        repository=args.repo,
        artifacts=args.artifacts,
        repository_mapping=args.mapping,
        repository_kinds=_repository_kinds(args.kind),
        repository_claim=args.claim,
    )
    print(render_json([result]) if args.format == "json" else render_text([result]))
    if args.strict:
        return 1 if result.has_strict_issues else 0
    return 1 if result.has_errors else 0


def _run_repo_inspect(args: argparse.Namespace) -> int:
    mapping = RepositoryMappingConfig.load(args.mapping) if args.mapping else None
    excluded = [*(mapping.excluded_paths if mapping else ()), *args.exclude]
    snapshot = RepositoryInventory(InventoryOptions(excluded_paths=tuple(excluded))).scan(
        args.repo,
        artifact_root=args.artifacts,
    )
    if args.format == "json":
        import json

        print(json.dumps(snapshot.to_dict(), indent=2, ensure_ascii=False))
    else:
        print(_repository_inspect_text(snapshot))
    return 0


def _repository_kinds(values: list[str] | None) -> list[RepositoryClaimKind] | None:
    if not values:
        return None
    aliases = {
        "function": RepositoryClaimKind.FUNCTION_OR_FEATURE,
        "architecture": RepositoryClaimKind.ARCHITECTURE_COMPONENT,
        "test": RepositoryClaimKind.TEST_CLAIM,
        "deliverable": RepositoryClaimKind.DELIVERABLE_OR_PACKAGE,
    }
    return list(dict.fromkeys(aliases[value] for value in values))


def _semantic_options(args: argparse.Namespace, *, selector_name: str) -> SemanticAuditOptions:
    selected = getattr(args, selector_name, None)
    task_types = (
        tuple(SemanticTaskType(value.upper().replace("-", "_")) for value in selected)
        if selected
        else None
    )
    return SemanticAuditOptions(
        max_tasks=args.max_tasks,
        max_input_tokens=args.max_input_tokens,
        max_cost=args.max_cost,
        task_types=task_types,
        entity_query=getattr(args, "entity", None),
        excluded_paths=tuple(args.semantic_exclude),
        cache_enabled=not getattr(args, "no_cache", False),
        cache_directory=getattr(args, "semantic_cache", Path(".rift-doc-cache/semantic")),
    )


def _semantic_provider(args: argparse.Namespace) -> OpenAICompatibleProvider:
    config = LLMProviderConfig.from_environment(
        provider=args.semantic_provider,
        model=args.semantic_model,
        endpoint=args.semantic_endpoint,
        temperature=args.semantic_temperature,
        max_output_tokens=args.semantic_max_output,
        timeout_seconds=args.semantic_timeout,
        retry_attempts=args.semantic_retries,
        api_key_environment=args.semantic_api_key_env,
        local_only=args.semantic_local_only,
        input_cost_per_million=args.semantic_input_cost_per_million,
        output_cost_per_million=args.semantic_output_cost_per_million,
    )
    return OpenAICompatibleProvider(config)


def _repository_inspect_text(snapshot: object) -> str:
    vcs = snapshot.vcs_metadata
    counts = snapshot.metadata.get("counts", {})
    lines = ["Detected repository", f"Root: {snapshot.root}"]
    if vcs is not None:
        lines.append(f"Commit: {vcs.commit_sha or 'unknown'}")
        lines.append(f"Dirty: {str(vcs.dirty).lower() if vcs.dirty is not None else 'unknown'}")
        if vcs.branch:
            lines.append(f"Branch: {vcs.branch}")
    else:
        lines.append("Commit: unavailable (plain source tree)")
        lines.append("Dirty: unavailable")
    languages = snapshot.metadata.get("languages", {})
    lines.append("Languages: " + (", ".join(f"{key} ({value})" for key, value in languages.items()) or "none"))
    lines.extend(
        [
            f"Packages/modules: {counts.get('modules', 0)}",
            f"Symbols: {counts.get('symbols', 0)}",
            f"Tests: {counts.get('tests', 0)}",
            f"Test results: {counts.get('test_results', 0)}",
            f"CI definitions/jobs: {counts.get('ci_configs', 0)}",
            f"Build targets: {counts.get('build_configs', 0)}",
            f"Release artifacts: {counts.get('release_artifacts', 0)}",
            f"Scanned files: {snapshot.metadata.get('scanned_file_count', 0)}",
        ]
    )
    return "\n".join(lines)


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
