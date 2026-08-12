"""Structured repository claims, evidence, and reproducible snapshot models."""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Any


MAX_EVIDENCE_EXCERPT = 500


class EvidenceKind(str, Enum):
    FILE = "FILE"
    DIRECTORY = "DIRECTORY"
    MODULE = "MODULE"
    PACKAGE = "PACKAGE"
    SYMBOL = "SYMBOL"
    MANIFEST_ENTRY = "MANIFEST_ENTRY"
    TEST = "TEST"
    TEST_RESULT = "TEST_RESULT"
    CI_JOB = "CI_JOB"
    BUILD_TARGET = "BUILD_TARGET"
    RELEASE_ARTIFACT = "RELEASE_ARTIFACT"
    CONFIGURATION = "CONFIGURATION"


class RepositoryClaimKind(str, Enum):
    FUNCTION_OR_FEATURE = "FUNCTION_OR_FEATURE"
    ARCHITECTURE_COMPONENT = "ARCHITECTURE_COMPONENT"
    TEST_CLAIM = "TEST_CLAIM"
    DELIVERABLE_OR_PACKAGE = "DELIVERABLE_OR_PACKAGE"


class RepositoryEvidenceStatus(str, Enum):
    VERIFIED = "VERIFIED"
    PARTIALLY_VERIFIED = "PARTIALLY_VERIFIED"
    CONTRADICTED = "CONTRADICTED"
    NOT_FOUND = "NOT_FOUND"
    REVIEW_REQUIRED = "REVIEW_REQUIRED"
    NOT_APPLICABLE = "NOT_APPLICABLE"
    SKIPPED = "SKIPPED"


class RepositoryMatchMethod(str, Enum):
    EXPLICIT_IDENTIFIER = "EXPLICIT_IDENTIFIER"
    EXACT_NAME = "EXACT_NAME"
    MANUAL_MAPPING = "MANUAL_MAPPING"
    NORMALIZED_NAME = "NORMALIZED_NAME"
    AMBIGUOUS = "AMBIGUOUS"
    UNMATCHED = "UNMATCHED"
    NOT_APPLICABLE = "NOT_APPLICABLE"


class TestEvidenceState(str, Enum):
    IMPLEMENTATION_PRESENT = "IMPLEMENTATION_PRESENT"
    CI_CONFIGURED = "CI_CONFIGURED"
    RESULT_PRESENT = "RESULT_PRESENT"
    LATEST_RESULT_PASS = "LATEST_RESULT_PASS"
    LATEST_RESULT_FAIL = "LATEST_RESULT_FAIL"
    LATEST_RESULT_UNKNOWN = "LATEST_RESULT_UNKNOWN"


@dataclass(frozen=True)
class RepositoryLineRange:
    start: int
    end: int | None = None

    def __post_init__(self) -> None:
        if self.start < 1:
            raise ValueError("repository line ranges are one-based")
        if self.end is not None and self.end < self.start:
            raise ValueError("repository line range end precedes its start")

    def display(self) -> str:
        return str(self.start) if self.end in (None, self.start) else f"{self.start}-{self.end}"

    def to_dict(self) -> dict[str, int]:
        value = {"start": self.start}
        if self.end is not None:
            value["end"] = self.end
        return value


@dataclass(frozen=True)
class RepositoryEvidence:
    evidence_id: str
    kind: EvidenceKind
    path: str
    line_range: RepositoryLineRange | None = None
    symbol: str | None = None
    module: str | None = None
    metadata: dict[str, Any] = field(default_factory=dict)
    excerpt_or_signature: str | None = None

    def __post_init__(self) -> None:
        if not self.evidence_id:
            raise ValueError("repository evidence requires an evidence_id")
        if not self.path:
            raise ValueError("repository evidence requires a path")
        excerpt = self.excerpt_or_signature
        if excerpt is not None and len(excerpt) > MAX_EVIDENCE_EXCERPT:
            object.__setattr__(self, "excerpt_or_signature", excerpt[: MAX_EVIDENCE_EXCERPT - 3] + "...")

    @property
    def location(self) -> str:
        if self.line_range is None:
            return self.path
        return f"{self.path}:{self.line_range.display()}"

    def to_dict(self) -> dict[str, Any]:
        return {
            "evidence_id": self.evidence_id,
            "kind": self.kind.value,
            "path": self.path,
            "line_range": self.line_range.to_dict() if self.line_range else None,
            "location": self.location,
            "symbol": self.symbol,
            "module": self.module,
            "metadata": _json_value(self.metadata),
            "excerpt_or_signature": self.excerpt_or_signature,
        }


@dataclass(frozen=True)
class RepositoryVcsMetadata:
    provider: str = "git"
    commit_sha: str | None = None
    dirty: bool | None = None
    branch: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "provider": self.provider,
            "commit_sha": self.commit_sha,
            "dirty": self.dirty,
            "branch": self.branch,
        }


@dataclass
class RepositorySnapshot:
    root: str
    vcs_metadata: RepositoryVcsMetadata | None = None
    manifests: list[RepositoryEvidence] = field(default_factory=list)
    source_files: list[RepositoryEvidence] = field(default_factory=list)
    modules: list[RepositoryEvidence] = field(default_factory=list)
    symbols: list[RepositoryEvidence] = field(default_factory=list)
    tests: list[RepositoryEvidence] = field(default_factory=list)
    test_results: list[RepositoryEvidence] = field(default_factory=list)
    ci_configs: list[RepositoryEvidence] = field(default_factory=list)
    configurations: list[RepositoryEvidence] = field(default_factory=list)
    build_configs: list[RepositoryEvidence] = field(default_factory=list)
    release_artifacts: list[RepositoryEvidence] = field(default_factory=list)
    generated_indexes: dict[str, Any] = field(default_factory=dict)
    metadata: dict[str, Any] = field(default_factory=dict)

    @property
    def audit_metadata(self) -> dict[str, Any]:
        return {
            "root": self.root,
            "vcs": self.vcs_metadata.to_dict() if self.vcs_metadata else None,
            "artifact_root": self.metadata.get("artifact_root"),
        }

    def all_evidence(self) -> list[RepositoryEvidence]:
        result: list[RepositoryEvidence] = []
        seen: set[str] = set()
        for collection in (
            self.manifests,
            self.source_files,
            self.modules,
            self.symbols,
            self.tests,
            self.test_results,
            self.ci_configs,
            self.configurations,
            self.build_configs,
            self.release_artifacts,
        ):
            for evidence in collection:
                if evidence.evidence_id not in seen:
                    seen.add(evidence.evidence_id)
                    result.append(evidence)
        return result

    def to_dict(self) -> dict[str, Any]:
        return {
            "root": self.root,
            "vcs_metadata": self.vcs_metadata.to_dict() if self.vcs_metadata else None,
            "manifests": [item.to_dict() for item in self.manifests],
            "source_files": [item.to_dict() for item in self.source_files],
            "modules": [item.to_dict() for item in self.modules],
            "symbols": [item.to_dict() for item in self.symbols],
            "tests": [item.to_dict() for item in self.tests],
            "test_results": [item.to_dict() for item in self.test_results],
            "ci_configs": [item.to_dict() for item in self.ci_configs],
            "configurations": [item.to_dict() for item in self.configurations],
            "build_configs": [item.to_dict() for item in self.build_configs],
            "release_artifacts": [item.to_dict() for item in self.release_artifacts],
            "generated_indexes": _json_value(self.generated_indexes),
            "metadata": _json_value(self.metadata),
        }


@dataclass
class RepositoryClaim:
    claim_id: str
    kind: RepositoryClaimKind
    canonical_name: str
    identifiers: list[str] = field(default_factory=list)
    documentation_evidence: list[Any] = field(default_factory=list)
    expected_evidence_types: list[EvidenceKind] = field(default_factory=list)
    metadata: dict[str, Any] = field(default_factory=dict)
    source_entity: Any = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "claim_id": self.claim_id,
            "kind": self.kind.value,
            "canonical_name": self.canonical_name,
            "identifiers": list(self.identifiers),
            "documentation_evidence": _json_value(self.documentation_evidence),
            "expected_evidence_types": [kind.value for kind in self.expected_evidence_types],
            "metadata": _json_value(self.metadata),
            "source_entity": _json_value(self.source_entity),
        }


@dataclass
class RepositoryEvidenceMatch:
    claim: RepositoryClaim
    status: RepositoryEvidenceStatus
    match_method: RepositoryMatchMethod
    evidence: list[RepositoryEvidence] = field(default_factory=list)
    reason: str | None = None
    test_states: list[TestEvidenceState] = field(default_factory=list)
    metadata: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "claim": self.claim.to_dict(),
            "status": self.status.value,
            "match_method": self.match_method.value,
            "evidence": [item.to_dict() for item in self.evidence],
            "reason": self.reason,
            "test_states": [state.value for state in self.test_states],
            "metadata": _json_value(self.metadata),
        }


def _json_value(value: Any) -> Any:
    if isinstance(value, Enum):
        return value.value
    if hasattr(value, "to_dict"):
        return value.to_dict()
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, dict):
        return {str(key): _json_value(item) for key, item in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [_json_value(item) for item in value]
    return str(value)
