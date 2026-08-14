"""Format-independent Phase 2 traceability models and conservative matching.

These models deliberately contain source evidence rather than document-format
objects.  They are also useful to later phases that need to attach repository
or other evidence to a document claim.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Callable, Iterable

from .model import SourceLocation


class MatchMethod(str, Enum):
    EXPLICIT_ID = "EXPLICIT_ID"
    EXACT_NORMALIZED_NAME = "EXACT_NORMALIZED_NAME"
    EXPLICIT_REFERENCE = "EXPLICIT_REFERENCE"
    STRUCTURAL_MAPPING = "STRUCTURAL_MAPPING"
    LLM_SEMANTIC = "LLM_SEMANTIC"
    AMBIGUOUS = "AMBIGUOUS"
    UNMATCHED = "UNMATCHED"


class TraceLinkStatus(str, Enum):
    VERIFIED = "VERIFIED"
    MISSING = "MISSING"
    AMBIGUOUS = "AMBIGUOUS"
    NOT_APPLICABLE = "NOT_APPLICABLE"
    TRACE_PRESENT = "TRACE_PRESENT"
    RESULT_PRESENT = "RESULT_PRESENT"
    ACHIEVEMENT_REVIEW_REQUIRED = "ACHIEVEMENT_REVIEW_REQUIRED"
    CONSISTENT = "CONSISTENT"
    STALE_OR_CONTRADICTED = "STALE_OR_CONTRADICTED"
    REVIEW_REQUIRED = "REVIEW_REQUIRED"


@dataclass
class TraceEntity:
    """A deterministic, source-backed claim or named concept."""

    entity_id: str
    kind: str
    canonical_name: str
    identifiers: list[str] = field(default_factory=list)
    aliases: list[str] = field(default_factory=list)
    source_report: str = ""
    source_section: str | None = None
    source_location: SourceLocation | str | None = None
    evidence: list[Any] = field(default_factory=list)
    metadata: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "entity_id": self.entity_id,
            "kind": self.kind,
            "canonical_name": self.canonical_name,
            "identifiers": list(self.identifiers),
            "aliases": list(self.aliases),
            "source_report": self.source_report,
            "source_section": self.source_section,
            "source_location": _json_value(self.source_location),
            "evidence": [_json_value(item) for item in self.evidence],
            "metadata": _json_value(self.metadata),
        }

    @property
    def comparison_names(self) -> list[str]:
        return [self.canonical_name, *self.aliases]


@dataclass
class TraceEdge:
    """A verified deterministic relation in the traceability graph."""

    from_entity: str
    to_entity: str
    rule_id: str
    match_method: MatchMethod | str
    confidence_class: MatchMethod | str
    evidence: list[Any] = field(default_factory=list)
    metadata: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "from_entity": self.from_entity,
            "to_entity": self.to_entity,
            "rule_id": _enum_value(self.rule_id),
            "match_method": _enum_value(self.match_method),
            "confidence_class": _enum_value(self.confidence_class),
            "evidence": [_json_value(item) for item in self.evidence],
            "metadata": _json_value(self.metadata),
        }


@dataclass
class TraceGraph:
    nodes: list[TraceEntity] = field(default_factory=list)
    edges: list[TraceEdge] = field(default_factory=list)
    metadata: dict[str, Any] = field(default_factory=dict)

    def add_node(self, entity: TraceEntity) -> TraceEntity:
        self.nodes.append(entity)
        return entity

    def add_edge(self, edge: TraceEdge) -> TraceEdge:
        self.edges.append(edge)
        return edge

    def node(self, entity_id: str) -> TraceEntity | None:
        return next((item for item in self.nodes if item.entity_id == entity_id), None)

    def nodes_for(self, *, domain: str | None = None, kind: str | None = None) -> list[TraceEntity]:
        return [
            item
            for item in self.nodes
            if (domain is None or item.metadata.get("domain", item.source_report) == domain)
            and (kind is None or item.kind == kind)
        ]

    def to_dict(self) -> dict[str, Any]:
        return {
            "nodes": [node.to_dict() for node in self.nodes],
            "edges": [edge.to_dict() for edge in self.edges],
            "metadata": _json_value(self.metadata),
        }


@dataclass(frozen=True)
class MatchResult:
    status: TraceLinkStatus
    method: MatchMethod
    candidates: tuple[TraceEntity, ...] = ()
    reason: str | None = None


class TraceIndex:
    """Cached indexes for one graph; matching never scans all paragraphs."""

    def __init__(self, graph: TraceGraph) -> None:
        self.graph = graph
        self.by_domain_kind: dict[tuple[str, str], list[TraceEntity]] = {}
        self.by_identifier: dict[tuple[str, str], list[TraceEntity]] = {}
        self.by_name: dict[tuple[str, str, str], list[TraceEntity]] = {}
        for entity in graph.nodes:
            domain = str(entity.metadata.get("domain", entity.source_report))
            self.by_domain_kind.setdefault((domain, entity.kind), []).append(entity)
            for identifier in entity.identifiers:
                self.by_identifier.setdefault((domain, identifier), []).append(entity)
            for name in entity.comparison_names:
                normalized = normalize_name(name)
                if normalized:
                    self.by_name.setdefault((domain, entity.kind, normalized), []).append(entity)

    def candidates(self, domain: str, kinds: Iterable[str]) -> list[TraceEntity]:
        result: list[TraceEntity] = []
        seen: set[str] = set()
        for kind in kinds:
            for entity in self.by_domain_kind.get((domain, kind), []):
                if entity.entity_id not in seen:
                    result.append(entity)
                    seen.add(entity.entity_id)
        return result

    def duplicate_identifiers(self) -> list[tuple[str, str, list[TraceEntity]]]:
        duplicates: list[tuple[str, str, list[TraceEntity]]] = []
        grouped: dict[tuple[str, str, str], list[TraceEntity]] = {}
        for (domain, identifier), entities in self.by_identifier.items():
            for entity in entities:
                grouped.setdefault((domain, entity.kind, identifier), []).append(entity)
        for (domain, _kind, identifier), entities in grouped.items():
            unique = {entity.entity_id for entity in entities}
            if len(unique) > 1:
                duplicates.append((domain, identifier, _unique_entities(entities)))
        return duplicates

    def match(
        self,
        source: TraceEntity,
        *,
        target_domain: str,
        target_kinds: Iterable[str],
        candidate_filter: Callable[[TraceEntity], bool] | None = None,
    ) -> MatchResult:
        kinds = tuple(dict.fromkeys(str(kind) for kind in target_kinds if str(kind)))
        candidates = self.candidates(target_domain, kinds)
        if candidate_filter is not None:
            candidates = [candidate for candidate in candidates if candidate_filter(candidate)]
        if not candidates:
            return MatchResult(
                status=TraceLinkStatus.MISSING,
                method=MatchMethod.UNMATCHED,
                reason=f"No {', '.join(kinds) or 'trace'} entities were extracted in {target_domain}.",
            )

        # An explicit ID is authoritative.  A target with a different explicit
        # ID is never merged solely because its label resembles the source.
        if source.identifiers:
            by_id = [
                candidate
                for candidate in candidates
                if set(source.identifiers).intersection(candidate.identifiers)
            ]
            by_id = _unique_entities(by_id)
            if len(by_id) == 1:
                return MatchResult(TraceLinkStatus.VERIFIED, MatchMethod.EXPLICIT_ID, tuple(by_id))
            if len(by_id) > 1:
                return MatchResult(
                    TraceLinkStatus.AMBIGUOUS,
                    MatchMethod.AMBIGUOUS,
                    tuple(by_id),
                    "The source identifier resolves to multiple target entities.",
                )

        source_names = {normalize_name(name) for name in source.comparison_names if normalize_name(name)}
        name_candidates: list[TraceEntity] = []
        for kind in kinds:
            for name in source_names:
                name_candidates.extend(
                    candidate
                    for candidate in self.by_name.get((target_domain, kind, name), [])
                    if candidate_filter is None or candidate_filter(candidate)
                )
        name_candidates = _unique_entities(name_candidates)
        if len(name_candidates) == 1:
            target = name_candidates[0]
            # If both sides carry IDs and none matched, similar names are a
            # reviewable conflict, not a confident edge.
            if source.identifiers and target.identifiers:
                return MatchResult(
                    TraceLinkStatus.AMBIGUOUS,
                    MatchMethod.AMBIGUOUS,
                    (target,),
                    "Names match but explicit identifiers do not.",
                )
            return MatchResult(TraceLinkStatus.VERIFIED, MatchMethod.EXACT_NORMALIZED_NAME, (target,))
        if len(name_candidates) > 1:
            return MatchResult(
                TraceLinkStatus.AMBIGUOUS,
                MatchMethod.AMBIGUOUS,
                tuple(name_candidates),
                "The normalized name resolves to multiple target entities.",
            )

        # An explicit source reference may appear in the target evidence even
        # when the target extractor could not classify it as its own ID.
        references = []
        for target in candidates:
            text = "\n".join(_evidence_text(target.evidence))
            compact_text = "".join(character for character in text.upper() if character.isalnum())
            if source.identifiers and any(
                identifier in text.upper()
                or "".join(character for character in identifier.upper() if character.isalnum()) in compact_text
                for identifier in source.identifiers
            ):
                references.append(target)
        references = _unique_entities(references)
        if len(references) == 1:
            return MatchResult(TraceLinkStatus.VERIFIED, MatchMethod.EXPLICIT_REFERENCE, tuple(references))
        if len(references) > 1:
            return MatchResult(
                TraceLinkStatus.AMBIGUOUS,
                MatchMethod.AMBIGUOUS,
                tuple(references),
                "The source identifier is referenced by multiple target entities.",
            )
        return MatchResult(
            TraceLinkStatus.MISSING,
            MatchMethod.UNMATCHED,
            (),
            f"No deterministic ID, reference, or exact normalized-name match in {target_domain}.",
        )


def normalize_identifier(value: str) -> str:
    """Conservatively normalize an explicit identifier.

    Prefix and numeric width are retained: ``FE01`` and ``FE-01`` agree, while
    explicitly distinct ``FE-01`` and ``FE-1`` do not silently collapse.
    """

    import re
    import unicodedata

    text = unicodedata.normalize("NFKC", str(value or "")).strip().upper()
    text = re.sub(r"\s+", " ", text)
    match = re.fullmatch(r"([A-Z][A-Z_-]{0,31}?)\s*[-_./ ]?\s*(\d{1,8})", text)
    if match:
        return f"{match.group(1)}-{match.group(2)}"
    text = re.sub(r"[\s_./]+", "-", text)
    text = re.sub(r"-+", "-", text).strip("-")
    return text


def normalize_name(value: str) -> str:
    """Normalize a label for exact, punctuation-tolerant comparison."""

    import re
    import unicodedata

    text = unicodedata.normalize("NFKC", str(value or "")).replace("\u00a0", " ")
    text = re.sub(r"^\s*(?:[IVXLCDM]+|\d+(?:\.\d+)*)[.)]?\s+", "", text, flags=re.IGNORECASE)
    text = text.casefold()
    text = re.sub(r"[\W_]+", " ", text, flags=re.UNICODE)
    return re.sub(r"\s+", " ", text).strip()


def _unique_entities(items: Iterable[TraceEntity]) -> list[TraceEntity]:
    result: list[TraceEntity] = []
    seen: set[str] = set()
    for item in items:
        if item.entity_id in seen:
            continue
        result.append(item)
        seen.add(item.entity_id)
    return result


def _evidence_text(items: Iterable[Any]) -> Iterable[str]:
    for item in items:
        if isinstance(item, dict):
            for key in ("text", "original_text", "value"):
                if item.get(key) is not None:
                    yield str(item[key])
        elif item is not None:
            yield str(item)


def _enum_value(value: Any) -> Any:
    return value.value if isinstance(value, Enum) else value


def _json_value(value: Any) -> Any:
    if isinstance(value, Enum):
        return value.value
    if isinstance(value, SourceLocation):
        return value.to_dict()
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, dict):
        return {str(key): _json_value(item) for key, item in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [_json_value(item) for item in value]
    if hasattr(value, "to_dict"):
        return _json_value(value.to_dict())
    return str(value)
