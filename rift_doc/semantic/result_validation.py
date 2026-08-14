"""Strict semantic output schema, citation, and deterministic status policy."""

from __future__ import annotations

import json
from typing import Any, Mapping

from .model import EvidencePacket, SemanticConfidence, SemanticResult, SemanticReviewTask


SEMANTIC_RESULT_SCHEMA: dict[str, Any] = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "type": "object",
    "required": [
        "status",
        "confidence",
        "summary",
        "reasoning_summary",
        "evidence_refs",
        "unsupported_claims",
        "contradictions",
        "recommended_action",
    ],
    "properties": {
        "status": {"enum": ["PASS", "FAIL", "WARNING", "REVIEW_REQUIRED"]},
        "confidence": {"enum": ["HIGH", "MEDIUM", "LOW"]},
        "summary": {"type": "string", "minLength": 1, "maxLength": 2000},
        "reasoning_summary": {"type": "string", "minLength": 1, "maxLength": 4000},
        "evidence_refs": {
            "type": "array",
            "items": {"type": "string", "minLength": 1},
            "uniqueItems": True,
        },
        "unsupported_claims": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["claim", "evidence_refs"],
                "properties": {
                    "claim": {"type": "string", "minLength": 1},
                    "evidence_refs": {
                        "type": "array",
                        "minItems": 1,
                        "items": {"type": "string", "minLength": 1},
                        "uniqueItems": True,
                    },
                },
                "additionalProperties": False,
            },
        },
        "contradictions": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["summary", "left_evidence_refs", "right_evidence_refs"],
                "properties": {
                    "summary": {"type": "string", "minLength": 1},
                    "left_evidence_refs": {
                        "type": "array",
                        "minItems": 1,
                        "items": {"type": "string", "minLength": 1},
                        "uniqueItems": True,
                    },
                    "right_evidence_refs": {
                        "type": "array",
                        "minItems": 1,
                        "items": {"type": "string", "minLength": 1},
                        "uniqueItems": True,
                    },
                },
                "additionalProperties": False,
            },
        },
        "recommended_action": {"type": "string", "maxLength": 2000},
    },
    "additionalProperties": False,
}


class SemanticOutputError(ValueError):
    def __init__(self, message: str, *, category: str = "INVALID_OUTPUT") -> None:
        self.category = category
        super().__init__(message)


def validate_semantic_output(
    raw: str | bytes | Mapping[str, Any],
    task: SemanticReviewTask,
    packet: EvidencePacket,
) -> SemanticResult:
    payload = _parse_payload(raw)
    try:
        import jsonschema
    except ImportError as exc:  # pragma: no cover - packaging failure
        raise RuntimeError("jsonschema is required for semantic output validation") from exc
    errors = sorted(
        jsonschema.Draft202012Validator(SEMANTIC_RESULT_SCHEMA).iter_errors(payload),
        key=lambda error: list(error.absolute_path),
    )
    if errors:
        error = errors[0]
        path = ".".join(str(value) for value in error.absolute_path) or "$"
        raise SemanticOutputError(
            f"semantic output does not satisfy semantic-result.v1 at {path}: {error.message}",
            category="SCHEMA_INVALID",
        )

    status = str(payload["status"])
    allowed = {str(value) for value in task.metadata.get("allowed_statuses", [])}
    if allowed and status not in allowed:
        raise SemanticOutputError(
            f"semantic status {status!r} is not allowed by rule {task.rule_id}; allowed: {', '.join(sorted(allowed))}",
            category="STATUS_POLICY_INVALID",
        )

    evidence_refs = tuple(str(value) for value in payload["evidence_refs"])
    if status in {"PASS", "FAIL", "WARNING"} and not evidence_refs:
        raise SemanticOutputError(
            f"semantic {status} must cite at least one packet evidence ID",
            category="CITATION_REQUIRED",
        )
    nested_refs: list[str] = []
    contradiction_sides: list[tuple[set[str], set[str]]] = []
    for claim in payload["unsupported_claims"]:
        nested_refs.extend(str(value) for value in claim["evidence_refs"])
    for contradiction in payload["contradictions"]:
        left = {str(value) for value in contradiction["left_evidence_refs"]}
        right = {str(value) for value in contradiction["right_evidence_refs"]}
        if left.intersection(right):
            raise SemanticOutputError(
                "contradiction sides must cite distinct evidence IDs",
                category="CONTRADICTION_CITATION_INVALID",
            )
        nested_refs.extend(left)
        nested_refs.extend(right)
        contradiction_sides.append((left, right))
    cited = {*evidence_refs, *nested_refs}
    unknown = sorted(cited.difference(packet.evidence_ids))
    if unknown:
        raise SemanticOutputError(
            "semantic output cites evidence absent from the packet: " + ", ".join(unknown),
            category="FABRICATED_CITATION",
        )
    if task.metadata.get("requires_two_sided_contradiction", False):
        for left, right in contradiction_sides:
            _validate_contradiction_origins(left, right, packet)
    if payload["contradictions"] and status != "FAIL":
        raise SemanticOutputError(
            "confirmed contradictions require FAIL status",
            category="STATUS_POLICY_INVALID",
        )

    return SemanticResult(
        status=status,
        confidence=SemanticConfidence(str(payload["confidence"])),
        summary=str(payload["summary"]),
        reasoning_summary=str(payload["reasoning_summary"]),
        evidence_refs=evidence_refs,
        unsupported_claims=tuple(dict(value) for value in payload["unsupported_claims"]),
        contradictions=tuple(dict(value) for value in payload["contradictions"]),
        recommended_action=str(payload["recommended_action"]),
    )


def _parse_payload(raw: str | bytes | Mapping[str, Any]) -> dict[str, Any]:
    if isinstance(raw, Mapping):
        return {str(key): value for key, value in raw.items()}
    if isinstance(raw, bytes):
        try:
            raw = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise SemanticOutputError("semantic output is not UTF-8", category="JSON_INVALID") from exc
    if not isinstance(raw, str):
        raise SemanticOutputError(
            f"semantic provider returned unsupported output type {type(raw).__name__}",
            category="JSON_INVALID",
        )
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise SemanticOutputError(
            f"semantic output is not one JSON object: {exc.msg}",
            category="JSON_INVALID",
        ) from exc
    if not isinstance(payload, dict):
        raise SemanticOutputError("semantic output must be one JSON object", category="JSON_INVALID")
    return payload


def _validate_contradiction_origins(
    left: set[str],
    right: set[str],
    packet: EvidencePacket,
) -> None:
    by_id = {item.evidence_id: item for item in packet.all_evidence}

    def origins(values: set[str]) -> set[tuple[Any, ...]]:
        return {
            (
                by_id[value].report,
                by_id[value].source_path,
                by_id[value].section_path,
                by_id[value].kind,
            )
            for value in values
            if value in by_id
        }

    left_origins = origins(left)
    right_origins = origins(right)
    if not left_origins or not right_origins or left_origins == right_origins:
        raise SemanticOutputError(
            "contradiction must cite provenance-distinct evidence from both sides",
            category="CONTRADICTION_CITATION_INVALID",
        )
