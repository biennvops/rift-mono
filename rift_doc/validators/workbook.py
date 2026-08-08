"""Generic YAML-driven validation for normalized XLSX/XLS workbooks."""

from __future__ import annotations

import re
from typing import Any

from ..classification import ContentClassifier
from ..model import Cell, ContentClass, Sheet, Workbook
from ..results import Finding, Status, ValidationResult
from ..spec import CapstoneSpec


class WorkbookValidator:
    def __init__(self, spec: CapstoneSpec) -> None:
        self.spec = spec

    def validate(self, workbook: Workbook, workbook_id: str) -> ValidationResult:
        contract = self.spec.workbook(workbook_id)
        result = ValidationResult(
            source_path=workbook.source_path,
            report=workbook_id,
            format=workbook.format,
            metadata={
                "spec_version": self.spec.version,
                "purpose": contract.get("purpose"),
                "source_ambiguities": self.spec.source_ambiguities,
            },
        )
        classifier = ContentClassifier.from_config(self._classification_for_workbook(workbook_id))
        for sheet in workbook.sheets:
            for row in sheet.rows:
                for cell in row:
                    classifier.classify_cell(cell)

        sheets_by_name = {sheet.name: sheet for sheet in workbook.sheets}
        required_names = [str(value) for value in contract.get("required_sheets", [])]
        configured_sheets = contract.get("sheets", {})
        configured_sheets = configured_sheets if isinstance(configured_sheets, dict) else {}
        ignored_names = {
            name for name, rule in configured_sheets.items() if isinstance(rule, dict) and rule.get("ignore_for_content")
        }

        for name in required_names:
            if name not in sheets_by_name:
                result.add(
                    Finding(
                        status=Status.FAIL,
                        severity="error",
                        rule_id=f"sheet.{name}.required",
                        report=workbook_id,
                        section=name,
                        location="workbook",
                        message=f"Required sheet {name!r} was not detected.",
                        source_requirement=contract.get("purpose"),
                        spec_path=f"workbooks.{workbook_id}.required_sheets",
                    )
                )
            else:
                result.add(
                    Finding(
                        status=Status.PASS,
                        severity="info",
                        rule_id=f"sheet.{name}.present",
                        report=workbook_id,
                        section=name,
                        location=sheets_by_name[name].source_location,
                        message="Required sheet detected.",
                        source_requirement=contract.get("purpose"),
                        spec_path=f"workbooks.{workbook_id}.required_sheets",
                    )
                )
        patterns = contract.get("sheet_patterns", [])
        if isinstance(patterns, list):
            for index, pattern_rule in enumerate(patterns):
                if not isinstance(pattern_rule, dict) or not pattern_rule.get("pattern"):
                    continue
                try:
                    pattern = re.compile(str(pattern_rule["pattern"]), re.IGNORECASE)
                except re.error:
                    result.add(
                        Finding(
                            status=Status.REVIEW_REQUIRED,
                            severity="warning",
                            rule_id=f"sheet_pattern.{index}",
                            report=workbook_id,
                            section=None,
                            location="workbook",
                            message=f"Sheet pattern {pattern_rule['pattern']!r} is invalid.",
                            spec_path=f"workbooks.{workbook_id}.sheet_patterns[{index}]",
                        )
                    )
                    continue
                matched = [sheet for sheet in workbook.sheets if pattern.search(sheet.name)]
                minimum = int(pattern_rule.get("min", 1 if pattern_rule.get("required", True) else 0))
                if len(matched) < minimum:
                    status = Status.FAIL if pattern_rule.get("required", True) else Status.WARNING
                    result.add(
                        Finding(
                            status=status,
                            severity="error" if status == Status.FAIL else "warning",
                            rule_id=f"sheet_pattern.{index}",
                            report=workbook_id,
                            section=None,
                            location="workbook",
                            message=f"Expected at least {minimum} sheet(s) matching {pattern_rule['pattern']!r}; detected {len(matched)}.",
                            source_requirement=contract.get("purpose"),
                            spec_path=f"workbooks.{workbook_id}.sheet_patterns[{index}]",
                        )
                    )
                for sheet in matched:
                    self._validate_sheet(sheet, pattern_rule, workbook_id, contract, result, f"sheet_patterns[{index}]")
                if len(matched) >= minimum:
                    result.add(
                        Finding(
                            status=Status.PASS,
                            severity="info",
                            rule_id=f"sheet_pattern.{index}.present",
                            report=workbook_id,
                            section=None,
                            location="workbook",
                            message=f"Detected {len(matched)} sheet(s) matching {pattern_rule['pattern']!r}.",
                            source_requirement=contract.get("purpose"),
                            spec_path=f"workbooks.{workbook_id}.sheet_patterns[{index}]",
                        )
                    )
        for name, raw_rule in configured_sheets.items():
            rule = raw_rule if isinstance(raw_rule, dict) else {}
            sheet = sheets_by_name.get(name)
            if sheet is None:
                if rule.get("required") and name not in required_names:
                    result.add(
                        Finding(
                            status=Status.FAIL,
                            severity="error",
                            rule_id=f"sheet.{name}.required",
                            report=workbook_id,
                            section=name,
                            location="workbook",
                            message=f"Required sheet {name!r} was not detected.",
                            source_requirement=contract.get("purpose"),
                            spec_path=f"workbooks.{workbook_id}.sheets[{name}].required",
                        )
                    )
                continue
            self._validate_sheet(sheet, rule, workbook_id, contract, result, f"sheets[{name}]")

        # Placeholders in actual data sheets remain findings.  Guideline/example
        # tabs are explicitly source material and are excluded from requirements.
        for sheet in workbook.sheets:
            if sheet.name in ignored_names:
                continue
            for cell in _non_empty_cells(sheet):
                if cell.classification in {
                    ContentClass.PLACEHOLDER,
                    ContentClass.TEMPLATE_INSTRUCTION,
                    ContentClass.SAMPLE_RESIDUE,
                }:
                    self._classification_finding(workbook_id, sheet, cell, result)
        return result

    def _classification_for_workbook(self, workbook_id: str) -> dict[str, Any]:
        config = dict(self.spec.classification_config)
        for key in ("placeholder_patterns", "instruction_patterns", "sample_fingerprints"):
            patterns = config.get(key)
            if not isinstance(patterns, list):
                continue
            selected = []
            for pattern in patterns:
                if not isinstance(pattern, dict):
                    selected.append(pattern)
                    continue
                applies_to = pattern.get("applies_to")
                if not applies_to or workbook_id in applies_to:
                    selected.append(pattern)
            config[key] = selected
        return config

    def _validate_sheet(
        self,
        sheet: Sheet,
        rule: dict[str, Any],
        workbook_id: str,
        contract: dict[str, Any],
        result: ValidationResult,
        spec_suffix: str,
    ) -> None:
        initial_findings = len(result.findings)
        header_rows = [int(value) for value in rule.get("header_rows", []) if isinstance(value, int)]
        for row_number in header_rows:
            if row_number > len(sheet.rows):
                result.add(
                    Finding(
                        status=Status.FAIL,
                        severity="error",
                        rule_id=f"{spec_suffix}.header_row.{row_number}",
                        report=workbook_id,
                        section=sheet.name,
                        location=sheet.source_location,
                        message=f"Configured header row {row_number} is outside the detected sheet dimensions.",
                        source_requirement=contract.get("purpose"),
                        spec_path=f"workbooks.{workbook_id}.{spec_suffix}.header_rows",
                    )
                )

        required_columns = [str(value) for value in rule.get("required_columns", [])]
        if required_columns:
            normalized_headers = {
                _normalize_header(str(value))
                for row_number in header_rows
                for value in sheet.row_values(row_number)
                if value is not None and str(value).strip()
            }
            missing = [value for value in required_columns if _normalize_header(value) not in normalized_headers]
            if missing:
                result.add(
                    Finding(
                        status=Status.FAIL,
                        severity="error",
                        rule_id=f"{spec_suffix}.required_columns",
                        report=workbook_id,
                        section=sheet.name,
                        location=sheet.source_location,
                        message=f"Required spreadsheet column(s) missing: {', '.join(missing)}.",
                        evidence=[{"header_rows": header_rows, "detected_headers": sorted(normalized_headers)}],
                        source_requirement=contract.get("purpose"),
                        spec_path=f"workbooks.{workbook_id}.{spec_suffix}.required_columns",
                    )
                )

        required_labels = [str(value) for value in rule.get("required_labels", [])]
        if required_labels:
            label_rows = [int(value) for value in rule.get("label_rows", []) if isinstance(value, int)]
            rows = label_rows or list(range(1, len(sheet.rows) + 1))
            labels = {
                _normalize_header(str(cell.value))
                for row_number in rows
                for cell in (sheet.rows[row_number - 1] if 1 <= row_number <= len(sheet.rows) else [])
                if not cell.is_empty
            }
            missing = [value for value in required_labels if _normalize_header(value) not in labels]
            if missing:
                result.add(
                    Finding(
                        status=Status.FAIL,
                        severity="error",
                        rule_id=f"{spec_suffix}.required_labels",
                        report=workbook_id,
                        section=sheet.name,
                        location=sheet.source_location,
                        message=f"Required visible label(s) missing: {', '.join(missing)}.",
                        evidence=[{"rows": rows, "detected_labels": sorted(labels)}],
                        source_requirement=contract.get("purpose"),
                        spec_path=f"workbooks.{workbook_id}.{spec_suffix}.required_labels",
                    )
                )

        expected_merged = {str(value) for value in rule.get("merged_regions", [])}
        if expected_merged:
            actual_merged = set(sheet.merged_regions)
            missing_merged = sorted(expected_merged - actual_merged)
            if missing_merged:
                result.add(
                    Finding(
                        status=Status.FAIL,
                        severity="error",
                        rule_id=f"{spec_suffix}.merged_regions",
                        report=workbook_id,
                        section=sheet.name,
                        location=sheet.source_location,
                        message=f"Configured merged region(s) missing: {', '.join(missing_merged)}.",
                        evidence=[{"actual_merged_regions": sorted(actual_merged)}],
                        source_requirement=contract.get("purpose"),
                        spec_path=f"workbooks.{workbook_id}.{spec_suffix}.merged_regions",
                    )
                )

        if rule.get("content_required"):
            minimum = int(rule.get("min_real_data_rows", 1))
            data_rows = _real_data_rows(sheet, header_rows, [int(value) for value in rule.get("label_rows", []) if isinstance(value, int)])
            if len(data_rows) < minimum:
                result.add(
                    Finding(
                        status=Status.FAIL,
                        severity="error",
                        rule_id=f"{spec_suffix}.content",
                        report=workbook_id,
                        section=sheet.name,
                        location=sheet.source_location,
                        message=f"Sheet contains fewer completed data rows than required ({len(data_rows)} detected, {minimum} required).",
                        evidence=[cell.to_dict() for cell in _non_empty_cells(sheet)[:8]],
                        source_requirement=contract.get("purpose"),
                        spec_path=f"workbooks.{workbook_id}.{spec_suffix}.content_required",
                    )
                )

        if rule.get("enforce_allowed_values") and isinstance(rule.get("allowed_values"), dict):
            self._validate_allowed_values(sheet, rule["allowed_values"], header_rows, workbook_id, contract, result, spec_suffix)
        if not any(item.status == Status.FAIL for item in result.findings[initial_findings:]):
            result.add(
                Finding(
                    status=Status.PASS,
                    severity="info",
                    rule_id=f"{spec_suffix}.structure",
                    report=workbook_id,
                    section=sheet.name,
                    location=sheet.source_location,
                    message="Configured sheet structure detected.",
                    source_requirement=contract.get("purpose"),
                    spec_path=f"workbooks.{workbook_id}.{spec_suffix}",
                )
            )

    def _validate_allowed_values(
        self,
        sheet: Sheet,
        allowed_values: dict[str, Any],
        header_rows: list[int],
        workbook_id: str,
        contract: dict[str, Any],
        result: ValidationResult,
        spec_suffix: str,
    ) -> None:
        # Enum enforcement is opt-in because the source templates visibly show
        # examples, not necessarily an exhaustive project-specific vocabulary.
        header_rows = header_rows or [int(value) for value in getattr(sheet, "detected_header_rows", [])]
        header_columns: dict[str, list[int]] = {}
        for field in allowed_values:
            target = _normalize_header(str(field))
            for row_number in header_rows:
                for cell in sheet.rows[row_number - 1] if 1 <= row_number <= len(sheet.rows) else []:
                    if _normalize_header(str(cell.value)) == target:
                        header_columns.setdefault(field, []).append(cell.column)
        for field, choices in allowed_values.items():
            if not isinstance(choices, list):
                continue
            allowed = {_normalize_header(str(choice)) for choice in choices}
            for row in sheet.rows:
                for cell in row:
                    if cell.column not in header_columns.get(field, []) or cell.row in header_rows or cell.is_empty:
                        continue
                    if _normalize_header(str(cell.value)) not in allowed:
                        result.add(
                            Finding(
                                status=Status.FAIL,
                                severity="error",
                                rule_id=f"{spec_suffix}.allowed_values.{field}",
                                report=workbook_id,
                                section=sheet.name,
                                location=cell.source_location,
                                message=f"Value {cell.value!r} is not in the configured {field} enumeration.",
                                evidence=[cell.to_dict()],
                                source_requirement=contract.get("purpose"),
                                spec_path=f"workbooks.{workbook_id}.{spec_suffix}.allowed_values.{field}",
                            )
                        )

    def _classification_finding(self, workbook_id: str, sheet: Sheet, cell: Cell, result: ValidationResult) -> None:
        labels = {
            ContentClass.PLACEHOLDER: ("placeholder.unresolved", "Unresolved placeholder remains", "classification.placeholder_patterns"),
            ContentClass.TEMPLATE_INSTRUCTION: ("template.instruction", "Template instruction remains", "classification.instruction_patterns"),
            ContentClass.SAMPLE_RESIDUE: ("sample.residue", "Known official sample residue remains", "classification.sample_fingerprints"),
        }
        rule_id, label, classification_path = labels[cell.classification]
        result.add(
            Finding(
                status=Status.FAIL,
                severity="error",
                rule_id=rule_id,
                report=workbook_id,
                section=sheet.name,
                location=cell.source_location.display() if cell.source_location else sheet.name,
                message=f"{label}: {cell.original_text!r}",
                evidence=[cell.to_dict()],
                source_requirement="Completed workbooks must not retain unresolved template instructions, placeholders, or configured sample material.",
                spec_path=classification_path,
            )
        )


def _normalize_header(value: str) -> str:
    value = value.replace("\\n", " ").replace("\n", " ").replace("\r", " ")
    value = re.sub(r"\s+", " ", value).strip().casefold()
    return value


def _non_empty_cells(sheet: Sheet) -> list[Cell]:
    return [cell for row in sheet.rows for cell in row if not cell.is_empty]


def _real_data_rows(sheet: Sheet, header_rows: list[int], label_rows: list[int]) -> set[int]:
    skip = set(header_rows) | set(label_rows)
    first_header = min(header_rows) if header_rows else 0
    rows: set[int] = set()
    for row_number, row in enumerate(sheet.rows, start=1):
        if row_number in skip or row_number <= first_header:
            continue
        if any(not cell.is_empty and cell.classification == ContentClass.REAL_CONTENT for cell in row):
            rows.add(row_number)
    return rows
