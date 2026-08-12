"""Repository-evidence findings over Phase 2 claims and one repository snapshot."""

from __future__ import annotations

from collections import Counter
from pathlib import PurePosixPath
from typing import Any, Iterable

from .claims import RepositoryClaimProjector
from .linker import RepositoryEvidenceLinker
from .mappings import RepositoryMappingConfig
from .model import (
    EvidenceKind,
    RepositoryClaim,
    RepositoryClaimKind,
    RepositoryEvidence,
    RepositoryEvidenceMatch,
    RepositoryEvidenceStatus,
    RepositorySnapshot,
)
from ..results import Finding, Status, ValidationResult
from ..spec import CapstoneSpec
from ..trace_model import TraceGraph


_STATUS_TO_FINDING = {
    RepositoryEvidenceStatus.VERIFIED: (Status.PASS, "info"),
    RepositoryEvidenceStatus.PARTIALLY_VERIFIED: (Status.WARNING, "warning"),
    RepositoryEvidenceStatus.CONTRADICTED: (Status.FAIL, "error"),
    RepositoryEvidenceStatus.NOT_FOUND: (Status.WARNING, "warning"),
    RepositoryEvidenceStatus.REVIEW_REQUIRED: (Status.REVIEW_REQUIRED, "warning"),
    RepositoryEvidenceStatus.NOT_APPLICABLE: (Status.NOT_APPLICABLE, "info"),
    RepositoryEvidenceStatus.SKIPPED: (Status.SKIPPED, "info"),
}
_RULE_IDS = {
    RepositoryClaimKind.FUNCTION_OR_FEATURE: "REPO-FUNCTION",
    RepositoryClaimKind.ARCHITECTURE_COMPONENT: "REPO-ARCHITECTURE",
    RepositoryClaimKind.TEST_CLAIM: "REPO-TEST",
    RepositoryClaimKind.DELIVERABLE_OR_PACKAGE: "REPO-DELIVERABLE",
}


class RepositoryEvidenceAuditor:
    def __init__(self, spec: CapstoneSpec) -> None:
        self.spec = spec
        self.projector = RepositoryClaimProjector(spec)

    def audit(
        self,
        graph: TraceGraph,
        snapshot: RepositorySnapshot,
        *,
        mappings: RepositoryMappingConfig | None = None,
        kinds: Iterable[RepositoryClaimKind | str] | None = None,
        claim_query: str | None = None,
    ) -> ValidationResult:
        selected_kinds = tuple(kinds) if kinds is not None else None
        claims = self.projector.project(graph, kinds=selected_kinds, claim_query=claim_query)
        matches = RepositoryEvidenceLinker(snapshot, mappings).link_all(claims)
        findings = [self._finding(match, snapshot) for match in matches]
        reverse_metadata: dict[str, Any] = {}
        if selected_kinds is None and claim_query is None:
            reverse_findings, reverse_metadata = self._reverse_findings(matches, snapshot)
            findings.extend(reverse_findings)
        counts = Counter(match.status.value for match in matches)
        metadata = {
            "domain": "repository_evidence",
            "spec_path": "repository_evidence_extension",
            "repository_snapshot": snapshot.audit_metadata,
            "inventory": {
                "counts": snapshot.metadata.get("counts", {}),
                "languages": snapshot.metadata.get("languages", {}),
                "inventory_source": snapshot.metadata.get("inventory_source"),
                "duration_ms": snapshot.metadata.get("duration_ms"),
                "network_access": snapshot.metadata.get("network_access", False),
                "repository_code_executed": snapshot.metadata.get("repository_code_executed", False),
            },
            "claim_count": len(claims),
            "evidence_status_counts": {
                status.value: counts.get(status.value, 0)
                for status in RepositoryEvidenceStatus
            },
            "matches": [match.to_dict() for match in matches],
            "evidence_packets": [_compact_packet(match) for match in matches],
            "reverse_checks": reverse_metadata,
            "mapping": {
                "source_path": mappings.source_path if mappings else None,
                "entry_count": len(mappings.entries) if mappings else 0,
            },
        }
        return ValidationResult(
            source_path=snapshot.root,
            report="repository_evidence",
            format="repository_evidence",
            findings=findings,
            metadata=metadata,
        )

    def _finding(
        self,
        match: RepositoryEvidenceMatch,
        snapshot: RepositorySnapshot,
    ) -> Finding:
        claim = match.claim
        status, severity = _STATUS_TO_FINDING[match.status]
        location = _document_location(claim)
        evidence = [*claim.documentation_evidence, *(item.to_dict() for item in match.evidence)]
        metadata = {
            "domain": "repository_evidence",
            "evidence_status": match.status.value,
            "claim_kind": claim.kind.value,
            "match_method": match.match_method.value,
            "test_states": [state.value for state in match.test_states],
            "repository_snapshot": snapshot.audit_metadata,
            "repository_locations": [item.location for item in match.evidence],
            "reason": match.reason,
            **match.metadata,
        }
        return Finding.from_location(
            status=status,
            severity=severity,
            rule_id=_RULE_IDS[claim.kind],
            report=str(claim.metadata.get("source_report", "documentation")),
            section=claim.metadata.get("source_section"),
            location=location,
            message=_finding_message(match),
            evidence=evidence,
            source_requirement="Repository evidence extension; this is not an FPT template requirement.",
            spec_path="repository_evidence_extension",
            metadata=metadata,
            validator="repository_evidence",
            source_entity=claim.to_dict(),
            target_domain="repository_evidence",
            candidate_entities=[item.to_dict() for item in match.evidence],
        )

    def _reverse_findings(
        self,
        matches: list[RepositoryEvidenceMatch],
        snapshot: RepositorySnapshot,
    ) -> tuple[list[Finding], dict[str, Any]]:
        represented = {
            evidence.evidence_id
            for match in matches
            for evidence in match.evidence
        }
        max_findings = _reverse_finding_limit(self.spec)
        packages = [
            item
            for item in snapshot.modules
            if item.kind == EvidenceKind.PACKAGE and item.evidence_id not in represented
        ]
        tests = [
            item
            for item in snapshot.tests
            if item.evidence_id not in represented
        ]
        findings: list[Finding] = []
        for evidence in packages[:max_findings]:
            findings.append(self._reverse_finding(evidence, "REPO-ARCHITECTURE-ORPHAN", "package/component"))
        remaining = max(0, max_findings - len(findings))
        for evidence in tests[:remaining]:
            findings.append(self._reverse_finding(evidence, "REPO-TEST-ORPHAN", "executable test"))
        metadata = {
            "unrepresented_packages": [item.to_dict() for item in packages],
            "unrepresented_tests": [item.to_dict() for item in tests],
            "unrepresented_package_count": len(packages),
            "unrepresented_test_count": len(tests),
            "finding_limit": max_findings,
            "findings_emitted": len(findings),
        }
        return findings, metadata

    @staticmethod
    def _reverse_finding(
        evidence: RepositoryEvidence,
        rule_id: str,
        label: str,
    ) -> Finding:
        return Finding.from_location(
            status=Status.REVIEW_REQUIRED,
            severity="warning",
            rule_id=rule_id,
            report="repository",
            section=None,
            location=evidence.location,
            message=(
                f"Repository {label} {evidence.symbol or evidence.module or PurePosixPath(evidence.path).name!r} "
                "has no deterministic representation in the projected documentation claims."
            ),
            evidence=[evidence.to_dict()],
            source_requirement="Reverse repository coverage review; this is not an FPT template requirement.",
            spec_path="repository_evidence_extension",
            metadata={
                "domain": "repository_evidence",
                "evidence_status": RepositoryEvidenceStatus.REVIEW_REQUIRED.value,
                "match_method": "REVERSE_UNREPRESENTED",
                "repository_locations": [evidence.location],
                "direction": "repository_to_documentation",
            },
            validator="repository_evidence",
            source_entity={
                "claim_id": evidence.evidence_id,
                "canonical_name": evidence.symbol or evidence.module or PurePosixPath(evidence.path).name,
                "kind": label,
            },
            target_domain="documentation",
            candidate_entities=[evidence.to_dict()],
        )


def _finding_message(match: RepositoryEvidenceMatch) -> str:
    claim = match.claim
    if match.status == RepositoryEvidenceStatus.VERIFIED:
        return f"Verified repository evidence for {claim.kind.value.casefold()} {claim.canonical_name!r}. {match.reason or ''}".strip()
    if match.status == RepositoryEvidenceStatus.PARTIALLY_VERIFIED:
        return f"Partially verified {claim.canonical_name!r}: source/package structure exists, but no stronger package/artifact evidence was located."
    if match.status == RepositoryEvidenceStatus.CONTRADICTED:
        return f"Repository evidence contradicts {claim.canonical_name!r}: {match.reason or 'direct conflict located'}."
    if match.status == RepositoryEvidenceStatus.NOT_FOUND:
        return f"Repository evidence was not found for {claim.canonical_name!r}. {match.reason or ''}".strip()
    if match.status == RepositoryEvidenceStatus.REVIEW_REQUIRED:
        return f"Repository evidence for {claim.canonical_name!r} requires review: {match.reason or 'ambiguous candidates'}."
    if match.status == RepositoryEvidenceStatus.NOT_APPLICABLE:
        return f"Executable repository evidence is not applicable to {claim.canonical_name!r}: {match.reason or ''}".strip()
    return f"Repository evidence was skipped for {claim.canonical_name!r}: {match.reason or ''}".strip()


def _document_location(claim: RepositoryClaim) -> str | None:
    value = claim.metadata.get("source_location")
    if isinstance(value, dict):
        display = value.get("display")
        return str(display) if display else None
    return str(value) if value not in (None, "") else None


def _compact_packet(match: RepositoryEvidenceMatch) -> dict[str, Any]:
    claim = match.claim
    return {
        "claim": {
            "claim_id": claim.claim_id,
            "kind": claim.kind.value,
            "canonical_name": claim.canonical_name,
            "identifiers": list(claim.identifiers),
            "source_report": claim.metadata.get("source_report"),
            "source_section": claim.metadata.get("source_section"),
            "source_location": claim.metadata.get("source_location"),
        },
        "documentation_evidence": claim.documentation_evidence[:3],
        "repository_evidence": [item.to_dict() for item in match.evidence[:5]],
        "deterministic_finding": {
            "status": match.status.value,
            "match_method": match.match_method.value,
            "reason": match.reason,
            "test_states": [state.value for state in match.test_states],
        },
    }


def _reverse_finding_limit(spec: CapstoneSpec) -> int:
    extension = spec.repository_evidence_extension
    reverse = extension.get("reverse_checks", {})
    if isinstance(reverse, dict):
        value = reverse.get("max_findings")
        if isinstance(value, int) and value >= 0:
            return value
    return 50
