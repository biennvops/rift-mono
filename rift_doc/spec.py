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
