from __future__ import annotations

from pathlib import Path

import pytest

from rift_doc.repository import (
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
)
from rift_doc.spec import CapstoneSpec


def test_repository_evidence_serializes_bounded_location() -> None:
    evidence = RepositoryEvidence(
        evidence_id="symbol:lib/sync.dart:3:syncNotifications",
        kind=EvidenceKind.SYMBOL,
        path="lib/sync.dart",
        line_range=RepositoryLineRange(3, 7),
        symbol="syncNotifications",
        excerpt_or_signature="x" * 800,
    )
    payload = evidence.to_dict()
    assert payload["location"] == "lib/sync.dart:3-7"
    assert len(payload["excerpt_or_signature"]) == 500
    with pytest.raises(ValueError):
        RepositoryLineRange(0)


def test_repository_match_serializes_doc_and_repository_evidence() -> None:
    claim = RepositoryClaim(
        claim_id="FE-03",
        kind=RepositoryClaimKind.FUNCTION_OR_FEATURE,
        canonical_name="Notification Sync",
        identifiers=["FE-03"],
        documentation_evidence=[{"source_path": "report.docx", "location": "paragraph 4"}],
        expected_evidence_types=[EvidenceKind.SYMBOL],
    )
    evidence = RepositoryEvidence("symbol:sync", EvidenceKind.SYMBOL, "lib/sync.dart", symbol="sync")
    match = RepositoryEvidenceMatch(
        claim,
        RepositoryEvidenceStatus.VERIFIED,
        RepositoryMatchMethod.EXACT_NAME,
        [evidence],
    )
    payload = match.to_dict()
    assert payload["claim"]["documentation_evidence"][0]["source_path"] == "report.docx"
    assert payload["evidence"][0]["path"] == "lib/sync.dart"


def test_snapshot_audit_metadata_records_git_state() -> None:
    snapshot = RepositorySnapshot(
        root="/work/rift",
        vcs_metadata=RepositoryVcsMetadata(commit_sha="abc123", dirty=False, branch="main"),
    )
    assert snapshot.audit_metadata == {
        "root": "/work/rift",
        "vcs": {"provider": "git", "commit_sha": "abc123", "dirty": False, "branch": "main"},
        "artifact_root": None,
    }


def test_current_contract_defines_four_repository_claim_mappings() -> None:
    root = Path(__file__).resolve().parents[2]
    extension = CapstoneSpec.load(root / "capstone-doc-spec.v0.1.yaml").repository_evidence_extension
    claim_kinds = {item["claim_kind"] for item in extension["claims"].values()}
    assert claim_kinds == {kind.value for kind in RepositoryClaimKind}
