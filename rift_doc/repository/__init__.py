"""Local repository evidence inspection and claim-linking APIs."""

from .audit import RepositoryEvidenceAuditor
from .claims import RepositoryClaimProjector
from .inventory import InventoryOptions, RepositoryInventory
from .linker import RepositoryEvidenceIndex, RepositoryEvidenceLinker
from .mappings import RepositoryMappingConfig, RepositoryMappingEntry, RepositoryMappingError
from .model import (
    EvidenceKind,
    RepositoryClaim,
    RepositoryClaimKind,
    RepositoryEvidence,
    RepositoryEvidenceMatch,
    RepositoryEvidenceStatus,
    RepositoryLineRange,
    RepositoryMatchMethod,
    RepositorySnapshot,
    RepositoryVcsMetadata,
    TestEvidenceState,
)

__all__ = [
    "EvidenceKind",
    "InventoryOptions",
    "RepositoryClaim",
    "RepositoryClaimProjector",
    "RepositoryClaimKind",
    "RepositoryEvidence",
    "RepositoryEvidenceAuditor",
    "RepositoryEvidenceIndex",
    "RepositoryEvidenceLinker",
    "RepositoryEvidenceMatch",
    "RepositoryEvidenceStatus",
    "RepositoryLineRange",
    "RepositoryMatchMethod",
    "RepositoryInventory",
    "RepositoryMappingConfig",
    "RepositoryMappingEntry",
    "RepositoryMappingError",
    "RepositorySnapshot",
    "RepositoryVcsMetadata",
    "TestEvidenceState",
]
