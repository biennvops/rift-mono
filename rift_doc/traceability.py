"""Public Phase 2 traceability API facade."""

from .document_set import ArtifactCandidate, DocumentArtifact, DocumentSet, DocumentSetLoader
from .trace_entities import TraceEntityExtractor
from .trace_model import (
    MatchMethod,
    MatchResult,
    TraceEdge,
    TraceEntity,
    TraceGraph,
    TraceIndex,
    TraceLinkStatus,
    normalize_identifier,
    normalize_name,
)
from .validators.cross_document import CrossDocumentValidator

__all__ = [
    "ArtifactCandidate",
    "CrossDocumentValidator",
    "DocumentArtifact",
    "DocumentSet",
    "DocumentSetLoader",
    "MatchMethod",
    "MatchResult",
    "TraceEdge",
    "TraceEntity",
    "TraceEntityExtractor",
    "TraceGraph",
    "TraceIndex",
    "TraceLinkStatus",
    "normalize_identifier",
    "normalize_name",
]
