"""Validation orchestration and normalized-document inspection."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from .extractors.docx import extract_docx
from .extractors.spreadsheets import extract_workbook
from .document_set import DocumentSet, DocumentSetLoader
from .model import Document, NormalizedDocument, Workbook
from .results import Finding, Status, ValidationResult
from .spec import CapstoneSpec, SpecError
from .validators.cross_document import CrossDocumentValidator
from .validators.structural import StructuralValidator
from .validators.workbook import WorkbookValidator


SUPPORTED_SUFFIXES = {".docx", ".xlsx", ".xls"}


class ValidationEngine:
    def __init__(self, spec: CapstoneSpec) -> None:
        self.spec = spec
        self.structural = StructuralValidator(spec)
        self.workbooks = WorkbookValidator(spec)
        self.cross_document = CrossDocumentValidator(spec)

    def infer_report_id(self, path: str | Path) -> str | None:
        return self.spec.infer_report_id(path)

    def extract(self, path: str | Path, report_id: str | None = None) -> NormalizedDocument:
        source = Path(path)
        if source.suffix.casefold() == ".docx":
            known_headings = self.structural.known_headings(report_id) if report_id in self.spec.reports else None
            return extract_docx(source, known_headings=known_headings)
        if source.suffix.casefold() in {".xlsx", ".xls"}:
            sheet_rules = {}
            if report_id in self.spec.workbooks:
                contract = self.spec.workbook(report_id)
                if isinstance(contract.get("sheets"), dict):
                    sheet_rules.update(contract["sheets"])
                if isinstance(contract.get("sheet_patterns"), list):
                    sheet_rules["__patterns__"] = contract["sheet_patterns"]
            return extract_workbook(source, sheet_rules=sheet_rules)
        raise ValueError(f"unsupported input format: {source.suffix or '<none>'}")

    def validate(self, path: str | Path, report_id: str | None = None) -> ValidationResult:
        source = Path(path)
        actual_report_id = report_id or self.infer_report_id(source)
        if not actual_report_id:
            raise SpecError(f"could not infer a report/workbook contract for {source.name}; provide --report")
        normalized = self.extract(source, actual_report_id)
        return self.validate_normalized(normalized, actual_report_id)

    def validate_normalized(self, document: NormalizedDocument, report_id: str) -> ValidationResult:
        if isinstance(document, Document):
            if report_id not in self.spec.reports:
                raise SpecError(f"{report_id!r} is not a DOCX report contract")
            return self.structural.validate(document, report_id)
        if isinstance(document, Workbook):
            if report_id not in self.spec.workbooks:
                raise SpecError(f"{report_id!r} is not a workbook contract")
            return self.workbooks.validate(document, report_id)
        raise TypeError(f"unsupported normalized document type {type(document)!r}")

    def inspect(self, path: str | Path, report_id: str | None = None) -> NormalizedDocument:
        actual_report_id = report_id or self.infer_report_id(path)
        return self.extract(path, actual_report_id)

    def load_document_set(self, manifest_path: str | Path) -> DocumentSet:
        loader = DocumentSetLoader(self.spec, self.extract)
        return loader.load(manifest_path)

    def validate_set(self, document_set: DocumentSet | str | Path) -> ValidationResult:
        loaded = self.load_document_set(document_set) if isinstance(document_set, (str, Path)) else document_set
        return self.cross_document.audit(loaded)

    def trace(self, document_set: DocumentSet | str | Path) -> ValidationResult:
        """Alias for callers using the CLI command name."""

        return self.validate_set(document_set)


def aggregate_results(results: list[ValidationResult]) -> dict[str, Any]:
    counts = {status.value: 0 for status in Status}
    for result in results:
        for key, value in result.counts.items():
            counts[key] += value
    return {"documents": len(results), "counts": counts}
