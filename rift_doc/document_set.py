"""Manifest loading for one cross-document audit set."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
import re
from typing import Any, Callable, Iterable

from .model import Document, NormalizedDocument, Workbook
from .results import Finding, Status


@dataclass
class ArtifactCandidate:
    """One possible source file for a logical audit artifact."""

    artifact_id: str
    domain: str
    path: Path
    metadata: dict[str, Any] = field(default_factory=dict)
    document: NormalizedDocument | None = None
    selected: bool = False

    @property
    def version(self) -> str | None:
        value = self.metadata.get("version")
        return str(value) if value is not None and str(value).strip() else None

    def to_dict(self) -> dict[str, Any]:
        return {
            "artifact_id": self.artifact_id,
            "domain": self.domain,
            "path": str(self.path),
            "metadata": _json_value(self.metadata),
            "selected": self.selected,
            "loaded": self.document is not None,
        }


@dataclass
class DocumentArtifact:
    """An active normalized document and its logical cross-document domain."""

    artifact_id: str
    domain: str
    document: NormalizedDocument
    metadata: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "artifact_id": self.artifact_id,
            "domain": self.domain,
            "source_path": self.document.source_path,
            "format": self.document.format,
            "metadata": _json_value(self.metadata),
        }


@dataclass
class DocumentSet:
    """All active inputs for one audit, including incomplete-set diagnostics."""

    reports: dict[str, NormalizedDocument] = field(default_factory=dict)
    test_workbooks: list[Workbook] = field(default_factory=list)
    tracking_workbooks: list[Workbook] = field(default_factory=list)
    metadata: dict[str, Any] = field(default_factory=dict)
    source_manifest: dict[str, Any] = field(default_factory=dict)
    source_manifest_path: str | None = None
    candidates: dict[str, list[ArtifactCandidate]] = field(default_factory=dict)
    artifacts: list[DocumentArtifact] = field(default_factory=list)
    missing_inputs: list[dict[str, Any]] = field(default_factory=list)
    duplicate_inputs: list[dict[str, Any]] = field(default_factory=list)
    load_findings: list[Finding] = field(default_factory=list)

    @classmethod
    def from_manifest(
        cls,
        manifest_path: str | Path,
        spec: Any,
        extractor: Callable[[Path, str | None], NormalizedDocument] | None = None,
    ) -> "DocumentSet":
        return DocumentSetLoader(spec, extractor).load(manifest_path)

    @classmethod
    def load(
        cls,
        manifest_path: str | Path,
        spec: Any,
        extractor: Callable[[Path, str | None], NormalizedDocument] | None = None,
    ) -> "DocumentSet":
        """Compatibility alias for callers that prefer ``DocumentSet.load``."""

        return cls.from_manifest(manifest_path, spec, extractor)

    @property
    def active_reports(self) -> dict[str, NormalizedDocument]:
        return self.reports

    @property
    def selected_sources(self) -> dict[str, str]:
        return {
            artifact_id: artifact.document.source_path
            for artifact in self.artifacts
            for artifact_id in [artifact.artifact_id]
        }

    def add_artifact(self, artifact: DocumentArtifact) -> None:
        self.artifacts.append(artifact)
        if artifact.domain.startswith("report") and artifact.domain[6:7].isdigit() and isinstance(artifact.document, Document):
            self.reports.setdefault(artifact.domain, artifact.document)
        elif artifact.domain == "tracking" or artifact.artifact_id.startswith("tracking"):
            if isinstance(artifact.document, Workbook):
                self.tracking_workbooks.append(artifact.document)
        elif (
            artifact.domain in {"tests", "test", "report5", "report5_unit_test", "report5_test_report"}
            or artifact.artifact_id.startswith("test")
        ):
            if isinstance(artifact.document, Workbook):
                self.test_workbooks.append(artifact.document)

    def domain_artifacts(self, domain: str) -> list[DocumentArtifact]:
        """Return active artifacts contributing to a logical target domain."""

        target = _domain_alias(domain)
        selected: list[DocumentArtifact] = []
        for artifact in self.artifacts:
            artifact_domain = _domain_alias(artifact.domain)
            if artifact_domain == target:
                selected.append(artifact)
                continue
            # Report 5 is a composite document domain: its DOCX plus the test
            # workbooks are all valid evidence for XT-002/003/005.
            if target == "report5" and (
                artifact_domain == "report5"
                or artifact.artifact_id.startswith("test")
                or artifact.domain in {"tests", "test", "report5_unit_test", "report5_test_report"}
            ):
                selected.append(artifact)
                continue
            if target == "tracking" and (
                artifact.domain == "tracking" or artifact.artifact_id.startswith("tracking")
            ):
                selected.append(artifact)
                continue
            if target == "tests" and (
                artifact.domain == "tests" or artifact.artifact_id.startswith("test")
            ):
                selected.append(artifact)
        return selected

    def domain_documents(self, domain: str) -> list[NormalizedDocument]:
        return [artifact.document for artifact in self.domain_artifacts(domain)]

    def iter_active_artifacts(self) -> Iterable[DocumentArtifact]:
        yield from self.artifacts

    def to_dict(self) -> dict[str, Any]:
        return {
            "reports": {
                report_id: {
                    "source_path": document.source_path,
                    "format": document.format,
                }
                for report_id, document in self.reports.items()
            },
            "test_workbooks": [workbook.source_path for workbook in self.test_workbooks],
            "tracking_workbooks": [workbook.source_path for workbook in self.tracking_workbooks],
            "metadata": _json_value(self.metadata),
            "source_manifest": _json_value(self.source_manifest),
            "source_manifest_path": self.source_manifest_path,
            "selected_sources": self.selected_sources,
            "candidates": {
                key: [candidate.to_dict() for candidate in values]
                for key, values in self.candidates.items()
            },
            "artifacts": [artifact.to_dict() for artifact in self.artifacts],
            "missing_inputs": _json_value(self.missing_inputs),
            "duplicate_inputs": _json_value(self.duplicate_inputs),
        }


class DocumentSetLoader:
    """Load a manifest without reparsing an input more than once."""

    def __init__(self, spec: Any, extractor: Callable[[Path, str | None], NormalizedDocument] | Any | None = None) -> None:
        self.spec = spec
        if extractor is not None and not callable(extractor) and hasattr(extractor, "extract"):
            extractor = extractor.extract
        self.extractor = extractor or _default_extract

    def load(self, manifest_path: str | Path) -> DocumentSet:
        path = Path(manifest_path)
        data = _load_manifest(path)
        result = DocumentSet(
            metadata=data.get("metadata", {}) if isinstance(data.get("metadata"), dict) else {},
            source_manifest=data,
            source_manifest_path=str(path),
        )
        base_dir = path.parent
        reports = data.get("reports", {})
        if not isinstance(reports, dict):
            result.load_findings.append(
                _set_finding(
                    Status.FAIL,
                    "SET-001",
                    "reports",
                    "Manifest field 'reports' must be an object.",
                )
            )
            reports = {}

        expected_reports = [str(report_id) for report_id in self.spec.reports]
        for report_id in expected_reports:
            raw = reports.get(report_id)
            if raw is None:
                result.missing_inputs.append({"artifact_id": report_id, "domain": report_id, "reason": "not listed"})
                result.load_findings.append(
                    _set_finding(
                        Status.WARNING,
                        "SET-002",
                        report_id,
                        f"No input was listed for required audit domain {report_id}.",
                    )
                )
                continue
            self._load_candidates(
                result,
                artifact_id=report_id,
                domain=report_id,
                raw=raw,
                base_dir=base_dir,
                selection=_selection_for(data, report_id),
                required=True,
            )

        # Preserve explicitly supplied non-standard report domains too.  This
        # allows a future contract to add report-like artifacts without changing
        # the loader.
        for report_id, raw in reports.items():
            report_id = str(report_id)
            if report_id in expected_reports:
                continue
            if raw is None:
                continue
            self._load_candidates(
                result,
                artifact_id=report_id,
                domain=report_id,
                raw=raw,
                base_dir=base_dir,
                selection=_selection_for(data, report_id),
                required=False,
            )

        self._load_collection(result, data.get("tracking", data.get("tracking_workbooks", [])), "tracking", base_dir)
        self._load_collection(result, data.get("tests", data.get("test_workbooks", [])), "tests", base_dir)
        result.metadata.setdefault("project", data.get("project"))
        result.metadata["active_latest"] = result.selected_sources
        return result

    def _load_collection(
        self,
        result: DocumentSet,
        raw: Any,
        default_domain: str,
        base_dir: Path,
    ) -> None:
        entries: list[tuple[str, Any]] = []
        if isinstance(raw, dict):
            entries = [(str(key), value) for key, value in raw.items()]
        elif isinstance(raw, list):
            entries = [(f"{default_domain}{index + 1}", value) for index, value in enumerate(raw)]
        elif raw:
            entries = [(default_domain, raw)]
        for artifact_id, value in entries:
            if isinstance(value, dict) and value.get("id"):
                artifact_id = str(value["id"])
            domain = str(value.get("domain", default_domain)) if isinstance(value, dict) else default_domain
            self._load_candidates(
                result,
                artifact_id=artifact_id,
                domain=domain,
                raw=value,
                base_dir=base_dir,
                selection=_selection_for(result.source_manifest, artifact_id),
                required=False,
            )

    def _load_candidates(
        self,
        result: DocumentSet,
        *,
        artifact_id: str,
        domain: str,
        raw: Any,
        base_dir: Path,
        selection: str | None,
        required: bool,
    ) -> None:
        candidate_specs = _candidate_specs(raw)
        if isinstance(raw, dict) and raw.get("selected") is not None and selection is None:
            selection = str(raw["selected"])
        candidates: list[ArtifactCandidate] = []
        for index, candidate_spec in enumerate(candidate_specs):
            candidate_path, metadata = _path_and_metadata(candidate_spec)
            if not candidate_path:
                result.load_findings.append(
                    _set_finding(Status.FAIL, "SET-003", artifact_id, "Manifest candidate has no path.")
                )
                continue
            candidate_path = Path(candidate_path)
            if not candidate_path.is_absolute():
                candidate_path = base_dir / candidate_path
            candidate = ArtifactCandidate(
                artifact_id=artifact_id,
                domain=domain,
                path=candidate_path,
                metadata=dict(metadata),
            )
            candidates.append(candidate)
            if not candidate_path.exists():
                result.missing_inputs.append(
                    {
                        "artifact_id": artifact_id,
                        "domain": domain,
                        "path": str(candidate_path),
                        "reason": "file does not exist",
                    }
                )
                result.load_findings.append(
                    _set_finding(
                        Status.FAIL,
                        "SET-004",
                        domain,
                        f"Input file does not exist: {candidate_path}.",
                        evidence=[{"artifact_id": artifact_id, "path": str(candidate_path)}],
                    )
                )
                continue
            try:
                extraction_id = domain
                if extraction_id not in self.spec.reports and extraction_id not in self.spec.workbooks:
                    inferred = self.spec.infer_report_id(candidate_path)
                    extraction_id = inferred or domain
                candidate.document = self.extractor(candidate_path, extraction_id)
            except (OSError, ValueError, RuntimeError) as exc:
                result.load_findings.append(
                    _set_finding(
                        Status.FAIL,
                        "SET-005",
                        domain,
                        f"Could not load {candidate_path.name}: {exc}",
                        evidence=[{"artifact_id": artifact_id, "path": str(candidate_path)}],
                    )
                )

        result.candidates[artifact_id] = candidates
        selected = _select_candidate(candidates, selection)
        if len(candidates) == 1 and candidates[0].document is not None and selected is None:
            selected = candidates[0]
        if selected is None and len([item for item in candidates if item.document is not None]) > 1:
            paths = [str(item.path) for item in candidates if item.document is not None]
            duplicate = {"artifact_id": artifact_id, "domain": domain, "paths": paths}
            result.duplicate_inputs.append(duplicate)
            result.load_findings.append(
                _set_finding(
                    Status.REVIEW_REQUIRED,
                    "SET-006",
                    domain,
                    f"Multiple active candidates require explicit resolution for {artifact_id}: {', '.join(paths)}.",
                    evidence=[duplicate],
                )
            )
        if selected is None:
            return
        selected.selected = True
        artifact = DocumentArtifact(
            artifact_id=artifact_id,
            domain=domain,
            document=selected.document,  # type: ignore[arg-type]
            metadata=selected.metadata,
        )
        result.add_artifact(artifact)


def _default_extract(path: Path, report_id: str | None = None) -> NormalizedDocument:
    if path.suffix.casefold() == ".docx":
        from .extractors.docx import extract_docx

        return extract_docx(path)
    if path.suffix.casefold() in {".xlsx", ".xls"}:
        from .extractors.spreadsheets import extract_workbook

        return extract_workbook(path)
    raise ValueError(f"unsupported input format: {path.suffix or '<none>'}")


def _load_manifest(path: Path) -> dict[str, Any]:
    try:
        import yaml
    except ImportError as exc:  # pragma: no cover - packaging failure
        raise RuntimeError("PyYAML is required to load a document-set manifest") from exc
    try:
        with path.open("r", encoding="utf-8") as handle:
            data = yaml.safe_load(handle)
    except (OSError, yaml.YAMLError) as exc:
        raise ValueError(f"could not parse document-set manifest {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise ValueError(f"document-set manifest {path} must contain a YAML object")
    return data


def _candidate_specs(raw: Any) -> list[Any]:
    if isinstance(raw, list):
        return raw
    if isinstance(raw, dict) and isinstance(raw.get("candidates"), list):
        return raw["candidates"]
    return [raw]


def _path_and_metadata(value: Any) -> tuple[str | None, dict[str, Any]]:
    if isinstance(value, (str, Path)):
        return str(value), {}
    if isinstance(value, dict):
        for key in ("path", "file", "source"):
            if value.get(key):
                return str(value[key]), {str(k): v for k, v in value.items() if k not in {"path", "file", "source"}}
    return None, {}


def _selection_for(data: dict[str, Any], artifact_id: str) -> str | None:
    resolutions = data.get("resolutions", data.get("selection", {}))
    if isinstance(resolutions, dict):
        value = resolutions.get(artifact_id)
        if isinstance(value, dict):
            value = value.get("rule", value.get("strategy"))
        if value:
            return str(value)
    if isinstance(resolutions, str):
        return resolutions
    return None


def _select_candidate(candidates: list[ArtifactCandidate], selection: str | None) -> ArtifactCandidate | None:
    usable = [candidate for candidate in candidates if candidate.document is not None]
    explicit = [candidate for candidate in usable if candidate.metadata.get("selected") or candidate.metadata.get("active")]
    if selection:
        requested = Path(str(selection))
        selected_by_path = [
            candidate
            for candidate in usable
            if candidate.path == requested
            or candidate.path.name == requested.name
            or str(candidate.metadata.get("id", "")) == str(selection)
        ]
        if len(selected_by_path) == 1:
            return selected_by_path[0]
    if len(explicit) == 1:
        return explicit[0]
    if len(explicit) > 1:
        return None
    if not usable:
        return None
    if selection and selection.casefold() in {"latest_version", "version", "highest_version"}:
        versioned = [candidate for candidate in usable if candidate.version is not None]
        if len(versioned) != len(usable):
            return None
        ordered = sorted(versioned, key=lambda candidate: _version_key(candidate.version or ""), reverse=True)
        if len(ordered) == 1 or _version_key(ordered[0].version or "") != _version_key(ordered[1].version or ""):
            return ordered[0]
        return None
    if selection and selection.casefold() in {"latest_modified", "modified", "mtime"}:
        ordered = sorted(usable, key=lambda candidate: candidate.path.stat().st_mtime, reverse=True)
        if len(ordered) == 1 or ordered[0].path.stat().st_mtime != ordered[1].path.stat().st_mtime:
            return ordered[0]
        return None
    # A version field is an explicit deterministic freshness signal even when
    # the manifest does not repeat the selection rule.
    if usable and all(candidate.version is not None for candidate in usable):
        ordered = sorted(usable, key=lambda candidate: _version_key(candidate.version or ""), reverse=True)
        if len(ordered) == 1 or _version_key(ordered[0].version or "") != _version_key(ordered[1].version or ""):
            return ordered[0]
    return usable[0] if len(usable) == 1 else None


def _version_key(value: str) -> tuple[Any, ...]:
    parts = re.split(r"[^0-9A-Za-z]+", value.casefold())
    result: list[Any] = []
    for part in parts:
        if not part:
            continue
        result.append((0, int(part)) if part.isdigit() else (1, part))
    return tuple(result)


def _domain_alias(domain: str) -> str:
    value = str(domain).casefold().replace("_", "-")
    aliases = {
        "report-1": "report1",
        "report-2": "report2",
        "report-3": "report3",
        "report-4": "report4",
        "report-5": "report5",
        "report-6": "report6",
        "report-7": "report7",
        "test": "tests",
    }
    return aliases.get(value, value)


def _set_finding(
    status: Status,
    rule_id: str,
    report: str,
    message: str,
    *,
    evidence: list[Any] | None = None,
) -> Finding:
    return Finding(
        status=status,
        severity="error" if status == Status.FAIL else "warning" if status in {Status.WARNING, Status.REVIEW_REQUIRED} else "info",
        rule_id=rule_id,
        report=report,
        section=None,
        location="manifest",
        message=message,
        evidence=evidence or [],
        validator="cross_document",
        target_domain=report,
    )


def _json_value(value: Any) -> Any:
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, dict):
        return {str(key): _json_value(item) for key, item in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [_json_value(item) for item in value]
    if hasattr(value, "to_dict"):
        return _json_value(value.to_dict())
    return str(value)
