"""Typed tasks and bounded evidence packets for semantic review."""

from __future__ import annotations

from dataclasses import dataclass, field, replace
from enum import Enum
import hashlib
import json
from typing import Any, Iterable


class SemanticTaskType(str, Enum):
    CONTENT_SUFFICIENCY = "CONTENT_SUFFICIENCY"
    CROSS_DOCUMENT_CONSISTENCY = "CROSS_DOCUMENT_CONSISTENCY"
    REQUIREMENT_TEST_ALIGNMENT = "REQUIREMENT_TEST_ALIGNMENT"
    DESIGN_REQUIREMENT_ALIGNMENT = "DESIGN_REQUIREMENT_ALIGNMENT"
    CLAIM_REPOSITORY_ALIGNMENT = "CLAIM_REPOSITORY_ALIGNMENT"
    FINAL_REPORT_FRESHNESS = "FINAL_REPORT_FRESHNESS"
    QUALITY_OBJECTIVE_EVALUATION = "QUALITY_OBJECTIVE_EVALUATION"
    USER_GUIDE_COVERAGE = "USER_GUIDE_COVERAGE"
    ERROR_ABNORMAL_CASE_COVERAGE = "ERROR_ABNORMAL_CASE_COVERAGE"


class SemanticConfidence(str, Enum):
    HIGH = "HIGH"
    MEDIUM = "MEDIUM"
    LOW = "LOW"


@dataclass(frozen=True)
class SemanticReviewTask:
    task_id: str
    rule_id: str
    task_type: SemanticTaskType
    question: str
    evidence_refs: tuple[str, ...] = ()
    required_context: tuple[str, ...] = ()
    expected_output_schema: str = "semantic-result.v1"
    metadata: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "task_id": self.task_id,
            "rule_id": self.rule_id,
            "task_type": self.task_type.value,
            "question": self.question,
            "evidence_refs": list(self.evidence_refs),
            "required_context": list(self.required_context),
            "expected_output_schema": self.expected_output_schema,
            "metadata": _json_value(self.metadata),
        }


@dataclass(frozen=True)
class SemanticEvidence:
    evidence_id: str
    kind: str
    content: str
    priority: int
    report: str | None = None
    section_path: str | None = None
    source_path: str | None = None
    source_location: Any = None
    metadata: dict[str, Any] = field(default_factory=dict)
    truncated: bool = False

    @property
    def estimated_tokens(self) -> int:
        return estimate_tokens(json.dumps(self.to_dict(), ensure_ascii=False, sort_keys=True))

    def with_content(self, content: str, *, truncated: bool) -> "SemanticEvidence":
        return replace(self, content=content, truncated=truncated)

    def to_dict(self) -> dict[str, Any]:
        return {
            "evidence_id": self.evidence_id,
            "kind": self.kind,
            "content": self.content,
            "report": self.report,
            "section_path": self.section_path,
            "source_path": self.source_path,
            "source_location": _json_value(self.source_location),
            "metadata": _json_value(self.metadata),
            "truncated": self.truncated,
        }


@dataclass
class EvidencePacket:
    packet_id: str
    task: SemanticReviewTask
    contract_requirements: list[SemanticEvidence] = field(default_factory=list)
    document_evidence: list[SemanticEvidence] = field(default_factory=list)
    cross_document_evidence: list[SemanticEvidence] = field(default_factory=list)
    repository_evidence: list[SemanticEvidence] = field(default_factory=list)
    deterministic_findings: list[SemanticEvidence] = field(default_factory=list)
    provenance: dict[str, Any] = field(default_factory=dict)
    budget: dict[str, Any] = field(default_factory=dict)
    truncated_evidence: list[dict[str, Any]] = field(default_factory=list)
    excluded_evidence: list[dict[str, Any]] = field(default_factory=list)

    @property
    def all_evidence(self) -> list[SemanticEvidence]:
        return [
            *self.contract_requirements,
            *self.document_evidence,
            *self.cross_document_evidence,
            *self.repository_evidence,
            *self.deterministic_findings,
        ]

    @property
    def evidence_ids(self) -> set[str]:
        return {item.evidence_id for item in self.all_evidence}

    @property
    def estimated_input_tokens(self) -> int:
        budgeted = self.budget.get("estimated_input_tokens")
        if isinstance(budgeted, int) and budgeted > 0:
            return budgeted
        from .prompts import PromptRenderer

        return PromptRenderer().render(self.task, self).estimated_input_tokens

    @property
    def packet_hash(self) -> str:
        payload = self.to_dict(include_packet_id=False)
        return hashlib.sha256(
            json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest()

    def model_payload(self) -> dict[str, Any]:
        """Return only the bounded task and evidence sent to a provider."""

        return {
            "task": self.task.to_dict(),
            "contract_requirements": [item.to_dict() for item in self.contract_requirements],
            "document_evidence": [item.to_dict() for item in self.document_evidence],
            "cross_document_evidence": [item.to_dict() for item in self.cross_document_evidence],
            "repository_evidence": [item.to_dict() for item in self.repository_evidence],
            "deterministic_findings": [item.to_dict() for item in self.deterministic_findings],
            "provenance": _json_value(self.provenance),
            "excluded_evidence": _json_value(self.excluded_evidence),
        }

    def to_dict(self, *, include_packet_id: bool = True) -> dict[str, Any]:
        value = {
            **self.model_payload(),
            "budget": _json_value(self.budget),
            "truncated_evidence": _json_value(self.truncated_evidence),
        }
        if include_packet_id:
            value = {
                "packet_id": self.packet_id,
                **value,
                "packet_hash": self.packet_hash,
            }
        return value


@dataclass(frozen=True)
class SemanticResult:
    status: str
    confidence: SemanticConfidence
    summary: str
    reasoning_summary: str
    evidence_refs: tuple[str, ...]
    unsupported_claims: tuple[dict[str, Any], ...] = ()
    contradictions: tuple[dict[str, Any], ...] = ()
    recommended_action: str = ""
    metadata: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "status": self.status,
            "confidence": self.confidence.value,
            "summary": self.summary,
            "reasoning_summary": self.reasoning_summary,
            "evidence_refs": list(self.evidence_refs),
            "unsupported_claims": _json_value(self.unsupported_claims),
            "contradictions": _json_value(self.contradictions),
            "recommended_action": self.recommended_action,
            "metadata": _json_value(self.metadata),
        }


@dataclass
class SemanticPlan:
    tasks: list[SemanticReviewTask]
    packets: list[EvidencePacket]
    proposed_task_count: int
    omitted_task_count: int = 0
    metadata: dict[str, Any] = field(default_factory=dict)

    @property
    def estimated_input_tokens(self) -> int:
        return sum(packet.estimated_input_tokens for packet in self.packets)

    def to_dict(self) -> dict[str, Any]:
        return {
            "proposed_task_count": self.proposed_task_count,
            "selected_task_count": len(self.tasks),
            "omitted_task_count": self.omitted_task_count,
            "estimated_input_tokens": self.estimated_input_tokens,
            "tasks": [task.to_dict() for task in self.tasks],
            "packets": [packet.to_dict() for packet in self.packets],
            "metadata": _json_value(self.metadata),
        }


def stable_id(prefix: str, *values: Any, length: int = 16) -> str:
    encoded = json.dumps(_json_value(values), ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return f"{prefix}-{hashlib.sha256(encoded.encode('utf-8')).hexdigest()[:length]}"


def estimate_tokens(value: str) -> int:
    """Conservative deterministic approximation used only for hard budgeting."""

    return max(1, (len(value.encode("utf-8")) + 3) // 4)


def unique_evidence(items: Iterable[SemanticEvidence]) -> list[SemanticEvidence]:
    result: list[SemanticEvidence] = []
    seen: set[str] = set()
    for item in items:
        if item.evidence_id in seen:
            continue
        seen.add(item.evidence_id)
        result.append(item)
    return result


def _json_value(value: Any) -> Any:
    if isinstance(value, Enum):
        return value.value
    if hasattr(value, "to_dict"):
        return _json_value(value.to_dict())
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, dict):
        return {str(key): _json_value(item) for key, item in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [_json_value(item) for item in value]
    return str(value)
