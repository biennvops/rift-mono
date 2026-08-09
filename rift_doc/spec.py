"""Machine-readable capstone contract loading and lookup helpers."""

from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
import re
from typing import Any, Iterator


class SpecError(Exception):
    """Base error for contract loading failures."""


class SpecParseError(SpecError):
    """The YAML/JSON contract could not be parsed."""


class SpecValidationError(SpecError):
    """The parsed contract does not satisfy its JSON Schema."""

    def __init__(self, errors: list[str]) -> None:
        self.errors = errors
        super().__init__("invalid capstone specification:\n" + "\n".join(f"- {error}" for error in errors))


@dataclass(frozen=True)
class SectionRule:
    report_id: str
    rule_id: str
    path: str
    data: dict[str, Any]
    parent_rule_id: str | None = None


@dataclass(frozen=True)
class TraceTargetRule:
    domain: str
    kinds: tuple[str, ...]
    requirement: str = "MUST"
    condition: Any = None
    allow_explicit_na: bool = False
    role: str | None = None
    data: dict[str, Any] | None = None


@dataclass(frozen=True)
class TraceRule:
    rule_id: str
    handler: str
    source_domain: str
    source_kinds: tuple[str, ...]
    targets: tuple[TraceTargetRule, ...] = ()
    path: str = ""
    data: dict[str, Any] | None = None


@dataclass(frozen=True)
class OrphanRule:
    rule_id: str
    source_domain: str
    source_kinds: tuple[str, ...]
    target_domain: str
    target_kinds: tuple[str, ...]
    severity: str = "warning"
    status: str = "REVIEW_REQUIRED"
    path: str = ""
    data: dict[str, Any] | None = None


@dataclass
class CapstoneSpec:
    path: Path
    data: dict[str, Any]
    schema_path: Path

    @classmethod
    def load(
        cls,
        path: str | Path,
        schema_path: str | Path | None = None,
    ) -> "CapstoneSpec":
        spec_path = Path(path)
        try:
            import yaml
        except ImportError as exc:  # pragma: no cover - packaging failure
            raise SpecError("PyYAML is required to load the capstone specification") from exc

        try:
            with spec_path.open("r", encoding="utf-8") as handle:
                data = yaml.safe_load(handle)
        except (OSError, yaml.YAMLError) as exc:
            raise SpecParseError(f"could not parse specification {spec_path}: {exc}") from exc
        if not isinstance(data, dict):
            raise SpecValidationError(["$: expected a YAML object"])

        resolved_schema = cls._find_schema(spec_path, schema_path)
        try:
            with resolved_schema.open("r", encoding="utf-8") as handle:
                schema = json.load(handle)
        except (OSError, json.JSONDecodeError) as exc:
            raise SpecError(f"could not load JSON Schema {resolved_schema}: {exc}") from exc

        try:
            import jsonschema
        except ImportError as exc:  # pragma: no cover - packaging failure
            raise SpecError("jsonschema is required to validate the capstone specification") from exc

        validator = jsonschema.Draft202012Validator(schema)
        errors = sorted(validator.iter_errors(data), key=lambda error: list(error.absolute_path))
        if errors:
            formatted = []
            for error in errors:
                location = _schema_path(error.absolute_path)
                formatted.append(f"{location}: {error.message}")
            raise SpecValidationError(formatted)

        regex_errors = _contract_regex_errors(data)
        if regex_errors:
            raise SpecValidationError(regex_errors)
        trace_errors = _trace_rule_errors(data)
        if trace_errors:
            raise SpecValidationError(trace_errors)
        return cls(path=spec_path, data=data, schema_path=resolved_schema)

    @staticmethod
    def _find_schema(spec_path: Path, schema_path: str | Path | None) -> Path:
        if schema_path is not None:
            return Path(schema_path)
        candidates = [
            spec_path.parent / "capstone-doc-spec.schema.json",
            Path.cwd() / "capstone-doc-spec.schema.json",
            Path(__file__).resolve().parent.parent / "capstone-doc-spec.schema.json",
        ]
        for candidate in candidates:
            if candidate.exists():
                return candidate
        return candidates[0]

    @property
    def version(self) -> str:
        return str(self.data.get("spec_version", self.data.get("version", "unknown")))

    @property
    def reports(self) -> dict[str, dict[str, Any]]:
        value = self.data.get("reports", {})
        return value if isinstance(value, dict) else {}

    @property
    def workbooks(self) -> dict[str, dict[str, Any]]:
        value = self.data.get("workbooks", {})
        return value if isinstance(value, dict) else {}

    @property
    def classification_config(self) -> dict[str, Any]:
        value = self.data.get("classification", {})
        return value if isinstance(value, dict) else {}

    @property
    def source_ambiguities(self) -> list[dict[str, Any]]:
        value = self.data.get("source_ambiguities", [])
        return value if isinstance(value, list) else []

    @property
    def cross_document_traceability(self) -> list[dict[str, Any]]:
        value = self.data.get("cross_document_traceability", [])
        if isinstance(value, dict):
            return [dict(item, id=key) if isinstance(item, dict) else {"id": key, "handler": item} for key, item in value.items()]
        return [item for item in value if isinstance(item, dict)] if isinstance(value, list) else []

    @property
    def cross_document_orphan_checks(self) -> list[dict[str, Any]]:
        value = self.data.get("cross_document_orphan_checks", [])
        return [item for item in value if isinstance(item, dict)] if isinstance(value, list) else []

    def iter_trace_rules(self) -> Iterator[TraceRule]:
        for index, raw in enumerate(self.cross_document_traceability):
            rule_id = str(raw.get("id", raw.get("rule_id", f"XT-UNNAMED-{index + 1}")))
            handler = str(raw.get("handler", raw.get("type", raw.get("kind", "")))).casefold()
            source_domain = str(
                raw.get(
                    "source_domain",
                    raw.get("source_report", raw.get("source", raw.get("from_domain", raw.get("from", "")))),
                )
            )
            source_kinds = _string_tuple(
                raw.get(
                    "source_kinds",
                    raw.get(
                        "source_kind",
                        raw.get("source_entity_kind", raw.get("entity_kind", raw.get("entity_types", []))),
                    ),
                )
            )
            if not source_kinds:
                source_kinds = ("feature",)
            targets_raw = raw.get(
                "targets",
                raw.get("target_domains", raw.get("target_reports", raw.get("target", []))),
            )
            if isinstance(targets_raw, dict):
                targets_raw = [
                    dict(value, domain=key) if isinstance(value, dict) else {"domain": key, "kind": value}
                    for key, value in targets_raw.items()
                ]
            targets: list[TraceTargetRule] = []
            for target in targets_raw if isinstance(targets_raw, list) else []:
                if isinstance(target, str):
                    target = {"domain": target}
                if not isinstance(target, dict):
                    continue
                domain = str(
                    target.get("domain", target.get("target_domain", target.get("report", target.get("to", ""))))
                )
                kinds = _string_tuple(
                    target.get(
                        "kinds",
                        target.get(
                            "kind",
                            target.get("target_kinds", target.get("target_kind", target.get("entity_kind", []))),
                        ),
                    )
                )
                if not kinds:
                    kinds = ("feature",)
                requirement = target.get(
                    "requirement",
                    target.get("requirement_level", raw.get("requirement", raw.get("requirement_level", "MUST"))),
                )
                targets.append(
                    TraceTargetRule(
                        domain=domain,
                        kinds=kinds,
                        requirement=str(requirement).upper(),
                        condition=target.get("condition", target.get("applicability")),
                        allow_explicit_na=bool(target.get("allow_explicit_na", raw.get("allow_explicit_na", False))),
                        role=str(target.get("role", target.get("stage")))
                        if target.get("role", target.get("stage")) is not None
                        else None,
                        data=target,
                    )
                )
            yield TraceRule(
                rule_id=rule_id,
                handler=handler,
                source_domain=source_domain,
                source_kinds=source_kinds,
                targets=tuple(targets),
                path=f"cross_document_traceability[{index}]",
                data=raw,
            )

    def iter_orphan_rules(self) -> Iterator[OrphanRule]:
        for index, raw in enumerate(self.cross_document_orphan_checks):
            yield OrphanRule(
                rule_id=str(raw.get("id", f"ORPHAN-{index + 1}")),
                source_domain=str(raw.get("source_domain", raw.get("source_report", raw.get("source", "")))),
                source_kinds=_string_tuple(raw.get("source_kinds", raw.get("source_kind", []))),
                target_domain=str(raw.get("target_domain", raw.get("target_report", raw.get("target", "")))),
                target_kinds=_string_tuple(raw.get("target_kinds", raw.get("target_kind", []))),
                severity=str(raw.get("severity", "warning")),
                status=str(raw.get("status", "REVIEW_REQUIRED")),
                path=f"cross_document_orphan_checks[{index}]",
                data=raw,
            )

    def report(self, report_id: str) -> dict[str, Any]:
        try:
            value = self.reports[report_id]
        except KeyError as exc:
            raise SpecError(f"report {report_id!r} is not defined at reports.{report_id}") from exc
        if not isinstance(value, dict):
            raise SpecError(f"reports.{report_id}: expected an object")
        return value

    def workbook(self, workbook_id: str) -> dict[str, Any]:
        try:
            value = self.workbooks[workbook_id]
        except KeyError as exc:
            raise SpecError(f"workbook {workbook_id!r} is not defined at workbooks.{workbook_id}") from exc
        if not isinstance(value, dict):
            raise SpecError(f"workbooks.{workbook_id}: expected an object")
        return value

    def iter_section_rules(self, report_id: str) -> Iterator[SectionRule]:
        report = self.report(report_id)
        sections = report.get("sections", {})
        if not isinstance(sections, dict):
            return

        def walk(items: dict[str, Any], prefix: str, parent: str | None) -> Iterator[SectionRule]:
            for rule_id, raw_rule in items.items():
                if not isinstance(raw_rule, dict):
                    continue
                rule_path = f"{prefix}[{rule_id}]"
                rule = SectionRule(report_id, str(rule_id), rule_path, raw_rule, parent)
                yield rule
                children = raw_rule.get("children", {})
                if isinstance(children, dict):
                    yield from walk(children, rule_path + ".children", str(rule_id))

        yield from walk(sections, f"reports.{report_id}.sections", None)

    def report_source_names(self, report_id: str) -> list[str]:
        report = self.report(report_id)
        names: list[str] = []
        for key in ("source_file", "source_template", "source_filename"):
            value = report.get(key)
            if isinstance(value, str):
                names.append(value)
        for value in report.get("source_files", []):
            if isinstance(value, str):
                names.append(value)
        return names

    def infer_report_id(self, path: str | Path) -> str | None:
        name = Path(path).name.casefold()
        candidates: list[tuple[int, str]] = []
        for report_id, report in self.reports.items():
            aliases = [report_id, str(report.get("short_name", "")), str(report.get("title", ""))]
            aliases.extend(self.report_source_names(report_id))
            for alias in aliases:
                normalized = Path(alias).name.casefold()
                if normalized and normalized in name:
                    candidates.append((len(normalized), report_id))
        for workbook_id, workbook in self.workbooks.items():
            aliases = [workbook_id, str(workbook.get("short_name", "")), str(workbook.get("source_file", ""))]
            for alias in aliases:
                normalized = Path(alias).name.casefold()
                if normalized and normalized in name:
                    candidates.append((len(normalized), workbook_id))
        if not candidates:
            return None
        return max(candidates)[1]

    def to_dict(self) -> dict[str, Any]:
        return self.data


def _string_tuple(value: Any) -> tuple[str, ...]:
    if isinstance(value, str):
        return (value,)
    if isinstance(value, (list, tuple, set)):
        return tuple(str(item) for item in value if str(item).strip())
    return ()


def _trace_rule_errors(data: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    raw_rules = data.get("cross_document_traceability", [])
    if isinstance(raw_rules, dict):
        raw_rules = [dict(value, id=key) if isinstance(value, dict) else {"id": key, "handler": value} for key, value in raw_rules.items()]
    if raw_rules is None:
        return errors
    if not isinstance(raw_rules, list):
        return ["$.cross_document_traceability: expected an array or object"]
    for index, rule in enumerate(raw_rules):
        path = f"$.cross_document_traceability[{index}]"
        if not isinstance(rule, dict):
            errors.append(f"{path}: expected an object")
            continue
        if not str(rule.get("id", rule.get("rule_id", ""))).strip():
            errors.append(f"{path}.id: required")
        handler = rule.get("handler", rule.get("type", rule.get("kind")))
        if not isinstance(handler, str) or not handler.strip():
            errors.append(f"{path}.handler: required (use handler or type)")
        source = rule.get("source_domain", rule.get("source_report", rule.get("source", rule.get("from_domain", rule.get("from")))))
        if not isinstance(source, str) or not source.strip():
            errors.append(f"{path}.source_domain: required (use source_domain/source_report/source)")
        targets = rule.get("targets", rule.get("target_domains", rule.get("target_reports", rule.get("target"))))
        if not isinstance(targets, (list, dict)) or not targets:
            errors.append(f"{path}.targets: required and must not be empty")
        elif isinstance(targets, list):
            for target_index, target in enumerate(targets):
                if isinstance(target, str):
                    continue
                if not isinstance(target, dict):
                    errors.append(f"{path}.targets[{target_index}]: expected an object or domain string")
                    continue
                domain = target.get("domain", target.get("target_domain", target.get("report", target.get("to"))))
                if not isinstance(domain, str) or not domain.strip():
                    errors.append(f"{path}.targets[{target_index}].domain: required")
    return errors


def _schema_path(path: Any) -> str:
    parts = list(path)
    if not parts:
        return "$"
    result = "$"
    for part in parts:
        if isinstance(part, int):
            result += f"[{part}]"
        else:
            result += f".{part}"
    return result


def _contract_regex_errors(data: dict[str, Any]) -> list[str]:
    errors: list[str] = []

    def check(value: Any, path: str) -> None:
        if not isinstance(value, str):
            return
        try:
            re.compile(value)
        except re.error as exc:
            errors.append(f"{path}: invalid regular expression: {exc}")

    classification = data.get("classification", {})
    if isinstance(classification, dict):
        for key in ("placeholder_patterns", "instruction_patterns", "sample_fingerprints"):
            patterns = classification.get(key, [])
            if not isinstance(patterns, list):
                continue
            for index, item in enumerate(patterns):
                if isinstance(item, str):
                    check(item, f"$.classification.{key}[{index}]")
                elif isinstance(item, dict):
                    expression_key = "pattern" if "pattern" in item else "regex"
                    check(item.get(expression_key), f"$.classification.{key}[{index}].{expression_key}")

    def walk_sections(items: Any, path: str) -> None:
        if not isinstance(items, dict):
            return
        for rule_id, rule in items.items():
            if not isinstance(rule, dict):
                continue
            rule_path = f"{path}.{rule_id}"
            match = rule.get("match")
            if isinstance(match, dict):
                check(match.get("regex"), f"{rule_path}.match.regex")
            condition = rule.get("condition")
            if isinstance(condition, dict):
                check(condition.get("pattern"), f"{rule_path}.condition.pattern")
                patterns = condition.get("patterns", [])
                if isinstance(patterns, list):
                    for index, pattern in enumerate(patterns):
                        check(pattern, f"{rule_path}.condition.patterns[{index}]")
            walk_sections(rule.get("children"), f"{rule_path}.children")

    reports = data.get("reports", {})
    if isinstance(reports, dict):
        for report_id, report in reports.items():
            if isinstance(report, dict):
                walk_sections(report.get("sections"), f"$.reports.{report_id}.sections")

    workbooks = data.get("workbooks", {})
    if isinstance(workbooks, dict):
        for workbook_id, workbook in workbooks.items():
            if not isinstance(workbook, dict):
                continue
            patterns = workbook.get("sheet_patterns", [])
            if isinstance(patterns, list):
                for index, pattern_rule in enumerate(patterns):
                    if isinstance(pattern_rule, dict):
                        check(pattern_rule.get("pattern"), f"$.workbooks.{workbook_id}.sheet_patterns[{index}].pattern")

    return errors
