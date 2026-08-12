"""Projection of Phase 2 trace entities into repository-evidence claims."""

from __future__ import annotations

from typing import Any, Iterable

from .model import EvidenceKind, RepositoryClaim, RepositoryClaimKind
from ..spec import CapstoneSpec
from ..trace_model import TraceEntity, TraceGraph, normalize_name


class RepositoryClaimProjector:
    """Reuse trace graph entities instead of reparsing documentation prose."""

    def __init__(self, spec: CapstoneSpec) -> None:
        self.spec = spec

    def project(
        self,
        graph: TraceGraph,
        *,
        kinds: Iterable[RepositoryClaimKind | str] | None = None,
        claim_query: str | None = None,
    ) -> list[RepositoryClaim]:
        allowed_kinds = {
            value.value if isinstance(value, RepositoryClaimKind) else str(value).upper()
            for value in kinds or RepositoryClaimKind
        }
        grouped: dict[tuple[str, str], RepositoryClaim] = {}
        extension = self.spec.repository_evidence_extension
        projections = extension.get("claims", {})
        if not isinstance(projections, dict):
            return []
        for projection_id, raw_projection in projections.items():
            if not isinstance(raw_projection, dict):
                continue
            try:
                claim_kind = RepositoryClaimKind(str(raw_projection.get("claim_kind")))
            except ValueError:
                continue
            if claim_kind.value not in allowed_kinds:
                continue
            source_kinds = {str(value) for value in raw_projection.get("source_kinds", [])}
            source_domains = {str(value) for value in raw_projection.get("source_domains", [])}
            expected = [
                EvidenceKind(str(value))
                for value in raw_projection.get("expected_evidence_types", [])
                if str(value) in EvidenceKind._value2member_map_
            ]
            for entity in graph.nodes:
                domain = str(entity.metadata.get("domain", entity.source_report))
                if entity.kind not in source_kinds or (source_domains and domain not in source_domains):
                    continue
                grouping_key = _claim_grouping_key(claim_kind, entity)
                existing = grouped.get(grouping_key)
                if existing is None:
                    claim_id = entity.identifiers[0] if entity.identifiers else entity.entity_id
                    metadata = {
                        "projection": str(projection_id),
                        "source_report": entity.source_report,
                        "source_section": entity.source_section,
                        "source_location": _location_value(entity.source_location),
                        "trace_entity_ids": [entity.entity_id],
                        "trace_kind": entity.kind,
                    }
                    metadata.update(_claim_metadata(entity, raw_projection))
                    grouped[grouping_key] = RepositoryClaim(
                        claim_id=claim_id,
                        kind=claim_kind,
                        canonical_name=entity.canonical_name,
                        identifiers=list(entity.identifiers),
                        documentation_evidence=_documentation_evidence(entity),
                        expected_evidence_types=expected,
                        metadata=metadata,
                        source_entity=entity,
                    )
                    continue
                existing.identifiers = list(dict.fromkeys([*existing.identifiers, *entity.identifiers]))
                existing.documentation_evidence.extend(
                    item for item in _documentation_evidence(entity) if item not in existing.documentation_evidence
                )
                existing.metadata["trace_entity_ids"].append(entity.entity_id)
                existing.metadata.setdefault("source_entities", []).append(entity.to_dict())
        claims = list(grouped.values())
        if claim_query:
            query = normalize_name(claim_query)
            claims = [
                claim
                for claim in claims
                if query == normalize_name(claim.claim_id)
                or query == normalize_name(claim.canonical_name)
                or query in {normalize_name(identifier) for identifier in claim.identifiers}
            ]
        return claims


def _claim_grouping_key(kind: RepositoryClaimKind, entity: TraceEntity) -> tuple[str, str]:
    key = entity.identifiers[0] if entity.identifiers else normalize_name(entity.canonical_name) or entity.entity_id
    return kind.value, key


def _claim_metadata(entity: TraceEntity, projection: dict[str, Any]) -> dict[str, Any]:
    metadata: dict[str, Any] = {}
    for key in ("version", "status", "state", "test_level", "test_stage", "fields", "raw_text"):
        value = entity.metadata.get(key)
        if value not in (None, "", {}):
            metadata[key] = value
    if entity.kind == "test_case_or_test_group":
        requirement = _test_execution_requirement(entity)
        if requirement is None and isinstance(projection.get("executable_default"), bool):
            requirement = bool(projection["executable_default"])
        metadata["executable_required"] = requirement
    return metadata


def _test_execution_requirement(entity: TraceEntity) -> bool | None:
    fields = entity.metadata.get("fields", {})
    relevant_values: list[str] = []
    if isinstance(fields, dict):
        for key, value in fields.items():
            normalized_key = normalize_name(str(key))
            if any(word in normalized_key for word in ("manual", "automation", "automated", "execution type", "test type", "executable")):
                relevant_values.append(str(value))
    relevant_values.append(str(entity.metadata.get("raw_text", "")))
    value = normalize_name(" ".join(relevant_values))
    if "manual" in value and not any(term in value for term in ("automated", "automation")):
        return False
    if any(term in value for term in ("automated", "automation", "executable test")):
        return True
    return None


def _documentation_evidence(entity: TraceEntity) -> list[Any]:
    evidence = list(entity.evidence)
    location = _location_value(entity.source_location)
    source_paths = [
        str(item.get("source_path"))
        for item in entity.evidence
        if isinstance(item, dict) and item.get("source_path")
    ]
    summary = {
        "report": entity.source_report,
        "source_path": source_paths[0] if source_paths else None,
        "section": entity.source_section,
        "location": location,
        "entity_id": entity.entity_id,
        "canonical_name": entity.canonical_name,
    }
    if summary not in evidence:
        evidence.append(summary)
    return evidence


def _location_value(value: Any) -> Any:
    if hasattr(value, "to_dict"):
        return value.to_dict()
    return value
