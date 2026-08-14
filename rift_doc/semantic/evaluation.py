"""Labeled semantic-review evaluation set and conservative regression metrics."""

from __future__ import annotations

from dataclasses import dataclass, field
import json
from pathlib import Path
from typing import Any, Mapping

from .model import EvidencePacket, SemanticEvidence, SemanticReviewTask, SemanticTaskType
from .providers import LLMProvider, LLMProviderError
from .result_validation import SemanticOutputError, validate_semantic_output


@dataclass(frozen=True)
class SemanticEvaluationCase:
    case_id: str
    task_type: SemanticTaskType
    packet_fixture: str
    expected_status: str
    required_evidence_refs: tuple[str, ...]
    expected_output_valid: bool = True
    expected_error_category: str | None = None
    contradiction_expected: bool = False
    fixture: dict[str, Any] = field(default_factory=dict)

    def task(self) -> SemanticReviewTask:
        raw = self.fixture.get("task", {})
        metadata = dict(raw.get("metadata", {})) if isinstance(raw.get("metadata"), dict) else {}
        metadata.setdefault("prompt_version", _default_prompt(self.task_type))
        metadata.setdefault("allowed_statuses", ["PASS", "FAIL", "WARNING", "REVIEW_REQUIRED"])
        return SemanticReviewTask(
            task_id=f"evaluation:{self.case_id}",
            rule_id=str(raw.get("rule_id", f"EVAL-{self.case_id.upper()}")),
            task_type=self.task_type,
            question=str(raw.get("question", "Review the bounded labeled evidence.")),
            evidence_refs=tuple(str(value) for value in raw.get("evidence_refs", [])),
            required_context=tuple(str(value) for value in raw.get("required_context", [])),
            metadata=metadata,
        )

    def packet(self, *, variant: bool = False) -> EvidencePacket:
        task = self.task()
        raw_evidence = self.fixture.get("variant_evidence" if variant else "evidence", [])
        evidence = [_fixture_evidence(value) for value in raw_evidence if isinstance(value, dict)]
        groups: dict[str, list[SemanticEvidence]] = {
            "contract_requirements": [],
            "document_evidence": [],
            "cross_document_evidence": [],
            "repository_evidence": [],
            "deterministic_findings": [],
        }
        for item, raw in zip(evidence, [value for value in raw_evidence if isinstance(value, dict)], strict=True):
            group = str(raw.get("group", "document_evidence"))
            if group not in groups:
                raise ValueError(f"evaluation case {self.case_id}: unknown evidence group {group!r}")
            groups[group].append(item)
        return EvidencePacket(
            packet_id=f"evaluation-packet:{self.case_id}" + (":variant" if variant else ""),
            task=task,
            provenance={
                "evaluation_case": self.case_id,
                "visual_evidence": self.fixture.get("visual_evidence", {}),
            },
            **groups,
        )

    @property
    def candidate_output(self) -> dict[str, Any]:
        value = self.fixture.get("candidate_output", {})
        return dict(value) if isinstance(value, dict) else {}


@dataclass(frozen=True)
class SemanticEvaluationMetrics:
    case_count: int
    output_validation_accuracy: float
    status_accuracy: float
    fabricated_citation_rate: float
    false_contradiction_rate: float
    insufficient_evidence_handling: float
    required_evidence_coverage: float
    case_results: tuple[dict[str, Any], ...]

    def to_dict(self) -> dict[str, Any]:
        return {
            "case_count": self.case_count,
            "output_validation_accuracy": self.output_validation_accuracy,
            "status_accuracy": self.status_accuracy,
            "fabricated_citation_rate": self.fabricated_citation_rate,
            "false_contradiction_rate": self.false_contradiction_rate,
            "insufficient_evidence_handling": self.insufficient_evidence_handling,
            "required_evidence_coverage": self.required_evidence_coverage,
            "case_results": list(self.case_results),
        }


class SemanticEvaluationSet:
    def __init__(self, cases: list[SemanticEvaluationCase], *, version: str, source_path: Path) -> None:
        self.cases = cases
        self.version = version
        self.source_path = source_path

    @classmethod
    def load(cls, path: str | Path | None = None) -> "SemanticEvaluationSet":
        source = Path(path) if path is not None else default_evaluation_set_path()
        try:
            data = json.loads(source.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise ValueError(f"could not load semantic evaluation set {source}: {exc}") from exc
        if not isinstance(data, dict) or not isinstance(data.get("cases"), list):
            raise ValueError(f"semantic evaluation set {source} must contain a cases array")
        base = source.parent
        cases: list[SemanticEvaluationCase] = []
        seen: set[str] = set()
        for index, raw in enumerate(data["cases"]):
            if not isinstance(raw, dict):
                raise ValueError(f"semantic evaluation case {index} must be an object")
            case_id = str(raw.get("case_id", ""))
            if not case_id or case_id in seen:
                raise ValueError(f"semantic evaluation case {index} has a missing or duplicate case_id")
            seen.add(case_id)
            fixture_name = str(raw.get("packet_fixture", ""))
            fixture_path = _safe_fixture_path(base, fixture_name)
            try:
                fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                raise ValueError(f"could not load packet fixture {fixture_path}: {exc}") from exc
            if not isinstance(fixture, dict):
                raise ValueError(f"packet fixture {fixture_path} must contain an object")
            try:
                task_type = SemanticTaskType(str(raw.get("task_type", "")))
            except ValueError as exc:
                raise ValueError(f"semantic evaluation case {case_id} has an invalid task_type") from exc
            cases.append(
                SemanticEvaluationCase(
                    case_id=case_id,
                    task_type=task_type,
                    packet_fixture=fixture_name,
                    expected_status=str(raw.get("expected_status", "REVIEW_REQUIRED")),
                    required_evidence_refs=tuple(str(value) for value in raw.get("required_evidence_refs", [])),
                    expected_output_valid=bool(raw.get("expected_output_valid", True)),
                    expected_error_category=str(raw["expected_error_category"])
                    if raw.get("expected_error_category")
                    else None,
                    contradiction_expected=bool(raw.get("contradiction_expected", False)),
                    fixture=fixture,
                )
            )
        return cls(cases, version=str(data.get("version", "unknown")), source_path=source)


class SemanticEvaluationHarness:
    def __init__(self, evaluation_set: SemanticEvaluationSet | None = None) -> None:
        self.evaluation_set = evaluation_set or SemanticEvaluationSet.load()

    def run(self, provider: LLMProvider) -> SemanticEvaluationMetrics:
        """Call a selected provider only when a caller explicitly invokes the harness."""

        outputs: dict[str, Any] = {}
        for case in self.evaluation_set.cases:
            try:
                outputs[case.case_id] = provider.review(case.task(), case.packet())
            except LLMProviderError as exc:
                outputs[case.case_id] = exc
        return self.evaluate(outputs)

    def evaluate(self, outputs: Mapping[str, Any] | None = None) -> SemanticEvaluationMetrics:
        supplied = (
            {case.case_id: case.candidate_output for case in self.evaluation_set.cases}
            if outputs is None
            else outputs
        )
        case_results: list[dict[str, Any]] = []
        validation_correct = 0
        valid_expected = 0
        status_correct = 0
        all_citations = 0
        fabricated_citations = 0
        non_contradiction_cases = 0
        false_contradictions = 0
        insufficient_cases = 0
        insufficient_correct = 0
        required_total = 0
        required_cited = 0

        for case in self.evaluation_set.cases:
            packet = case.packet()
            raw = supplied.get(case.case_id)
            output_payload = raw if isinstance(raw, Mapping) else {}
            cited = _all_citations(output_payload)
            all_citations += len(cited)
            fabricated = sorted(set(cited).difference(packet.evidence_ids))
            fabricated_citations += len(fabricated)
            required_total += len(case.required_evidence_refs)
            required_cited += len(set(case.required_evidence_refs).intersection(cited))
            actual_valid = False
            result = None
            error_category = "MISSING_OUTPUT" if raw is None else "PROVIDER_ERROR" if isinstance(raw, Exception) else None
            if error_category is None:
                try:
                    result = validate_semantic_output(raw, case.task(), packet)
                except SemanticOutputError as exc:
                    error_category = exc.category
                else:
                    actual_valid = True
            expected_validity_matched = actual_valid == case.expected_output_valid
            if expected_validity_matched and (
                actual_valid or case.expected_error_category is None or error_category == case.expected_error_category
            ):
                validation_correct += 1
            if case.expected_output_valid:
                valid_expected += 1
                if result is not None and result.status == case.expected_status:
                    status_correct += 1
            has_contradiction = bool(result.contradictions) if result is not None else bool(output_payload.get("contradictions"))
            if not case.contradiction_expected:
                non_contradiction_cases += 1
                if has_contradiction:
                    false_contradictions += 1
            if case.expected_status == "REVIEW_REQUIRED" and case.expected_output_valid:
                insufficient_cases += 1
                if result is not None and result.status == "REVIEW_REQUIRED":
                    insufficient_correct += 1
            case_results.append(
                {
                    "case_id": case.case_id,
                    "expected_output_valid": case.expected_output_valid,
                    "actual_output_valid": actual_valid,
                    "expected_status": case.expected_status,
                    "actual_status": result.status if result is not None else None,
                    "error_category": error_category,
                    "fabricated_evidence_refs": fabricated,
                    "required_evidence_refs_present": sorted(
                        set(case.required_evidence_refs).intersection(cited)
                    ),
                    "contradiction_expected": case.contradiction_expected,
                    "contradiction_returned": has_contradiction,
                }
            )

        count = len(self.evaluation_set.cases)
        return SemanticEvaluationMetrics(
            case_count=count,
            output_validation_accuracy=_ratio(validation_correct, count),
            status_accuracy=_ratio(status_correct, valid_expected),
            fabricated_citation_rate=_ratio(fabricated_citations, all_citations),
            false_contradiction_rate=_ratio(false_contradictions, non_contradiction_cases),
            insufficient_evidence_handling=_ratio(insufficient_correct, insufficient_cases),
            required_evidence_coverage=_ratio(required_cited, required_total),
            case_results=tuple(case_results),
        )


def default_evaluation_set_path() -> Path:
    return Path(__file__).resolve().parent / "evaluation" / "evaluation-set.v1.json"


def _fixture_evidence(raw: dict[str, Any]) -> SemanticEvidence:
    return SemanticEvidence(
        evidence_id=str(raw.get("evidence_id", "")),
        kind=str(raw.get("kind", "evaluation_evidence")),
        content=str(raw.get("content", "")),
        priority=int(raw.get("priority", 3)),
        report=str(raw["report"]) if raw.get("report") is not None else None,
        section_path=str(raw["section_path"]) if raw.get("section_path") is not None else None,
        source_path=str(raw["source_path"]) if raw.get("source_path") is not None else None,
        source_location=raw.get("source_location"),
        metadata=dict(raw.get("metadata", {})) if isinstance(raw.get("metadata"), dict) else {},
    )


def _safe_fixture_path(base: Path, value: str) -> Path:
    if not value:
        raise ValueError("semantic evaluation case has no packet_fixture")
    resolved_base = base.resolve()
    resolved = (base / value).resolve()
    try:
        resolved.relative_to(resolved_base)
    except ValueError as exc:
        raise ValueError(f"semantic packet fixture escapes evaluation directory: {value}") from exc
    return resolved


def _all_citations(raw: Mapping[str, Any]) -> set[str]:
    result = {str(value) for value in raw.get("evidence_refs", []) if str(value)}
    unsupported = raw.get("unsupported_claims", [])
    for claim in unsupported if isinstance(unsupported, list) else []:
        if isinstance(claim, dict):
            result.update(str(value) for value in claim.get("evidence_refs", []) if str(value))
    contradictions = raw.get("contradictions", [])
    for contradiction in contradictions if isinstance(contradictions, list) else []:
        if not isinstance(contradiction, dict):
            continue
        for key in ("left_evidence_refs", "right_evidence_refs"):
            result.update(str(value) for value in contradiction.get(key, []) if str(value))
    return result


def _default_prompt(task_type: SemanticTaskType) -> str:
    if task_type == SemanticTaskType.CONTENT_SUFFICIENCY:
        return "content_sufficiency.v1"
    if task_type == SemanticTaskType.CLAIM_REPOSITORY_ALIGNMENT:
        return "repository_alignment.v1"
    if task_type in {
        SemanticTaskType.CROSS_DOCUMENT_CONSISTENCY,
        SemanticTaskType.FINAL_REPORT_FRESHNESS,
    }:
        return "cross_document_consistency.v1"
    return "requirement_test_alignment.v1"


def _ratio(numerator: int, denominator: int) -> float:
    return numerator / denominator if denominator else 0.0
