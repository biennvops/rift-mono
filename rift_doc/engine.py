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
        result = self.cross_document.audit(loaded)
        phase1_results = self._validate_set_phase1(loaded)
        phase1_findings = [finding for item in phase1_results for finding in item.findings]
        result.findings = [*phase1_findings, *result.findings]
        result.metadata["phase1"] = {
            "results": [
                {
                    "source_path": item.source_path,
                    "report": item.report,
                    "format": item.format,
                    "counts": item.counts,
                }
                for item in phase1_results
            ],
            "finding_count": len(phase1_findings),
        }
        return result

    def _validate_set_phase1(self, document_set: DocumentSet) -> list[ValidationResult]:
        items: list[tuple[str, str, NormalizedDocument]] = []
        seen: set[int] = set()
        for artifact in document_set.iter_active_artifacts():
            key = id(artifact.document)
            if key in seen:
                continue
            seen.add(key)
            items.append((artifact.artifact_id, artifact.domain, artifact.document))
        for report_id, document in document_set.reports.items():
            key = id(document)
            if key in seen:
                continue
            seen.add(key)
            items.append((str(report_id), str(report_id), document))
        for index, workbook in enumerate([*document_set.tracking_workbooks, *document_set.test_workbooks], start=1):
            artifact_id = f"set-workbook-{index}"
            key = id(workbook)
            if key in seen:
                continue
            seen.add(key)
            items.append((artifact_id, "", workbook))

        results: list[ValidationResult] = []
        for artifact_id, domain, document in items:
            contract_id = self._phase1_contract_id(artifact_id, domain, document)
            if contract_id is None:
                continue
            results.append(self.validate_normalized(document, contract_id))
        return results

    def _phase1_contract_id(
        self,
        artifact_id: str,
        domain: str,
        document: NormalizedDocument,
    ) -> str | None:
        candidates = [domain, artifact_id, self.spec.infer_report_id(document.source_path)]
        if isinstance(document, Document):
            return next((str(candidate) for candidate in candidates if candidate and str(candidate) in self.spec.reports), None)
        return next((str(candidate) for candidate in candidates if candidate and str(candidate) in self.spec.workbooks), None)

    def trace(self, document_set: DocumentSet | str | Path) -> ValidationResult:
        """Alias for callers using the CLI command name."""

        return self.validate_set(document_set)


def aggregate_results(results: list[ValidationResult]) -> dict[str, Any]:
    counts = {status.value: 0 for status in Status}
    for result in results:
        for key, value in result.counts.items():
            counts[key] += value
    return {"documents": len(results), "counts": counts}
