from __future__ import annotations

from pathlib import Path

from rift_doc.repository import (
    EvidenceKind,
    RepositoryEvidence,
    RepositoryEvidenceAuditor,
    RepositoryEvidenceStatus,
    RepositoryLineRange,
    RepositoryMappingConfig,
    RepositorySnapshot,
)
from rift_doc.results import Status
from rift_doc.spec import CapstoneSpec
from rift_doc.trace_model import TraceEntity, TraceGraph


def _spec() -> CapstoneSpec:
    return CapstoneSpec(
        path=Path("spec.yaml"),
        schema_path=Path("schema.json"),
        data={
            "repository_evidence_extension": {
                "finding_domain": "repository_evidence",
                "reverse_checks": {"max_findings": 10},
                "claims": {
                    "features": {
                        "claim_kind": "FUNCTION_OR_FEATURE",
                        "source_kinds": ["feature"],
                        "source_domains": ["report1"],
                        "expected_evidence_types": ["SYMBOL"],
                    },
                    "components": {
                        "claim_kind": "ARCHITECTURE_COMPONENT",
                        "source_kinds": ["architecture_component"],
                        "source_domains": ["report4"],
                        "expected_evidence_types": ["PACKAGE"],
                    },
                    "tests": {
                        "claim_kind": "TEST_CLAIM",
                        "source_kinds": ["test_case_or_test_group"],
                        "source_domains": ["report5"],
                        "expected_evidence_types": ["TEST", "CI_JOB", "TEST_RESULT"],
                    },
                    "deliverables": {
                        "claim_kind": "DELIVERABLE_OR_PACKAGE",
                        "source_kinds": ["deliverable"],
                        "source_domains": ["report2"],
                        "expected_evidence_types": ["RELEASE_ARTIFACT"],
                    },
                },
            }
        },
    )


def _entity(report: str, kind: str, name: str, identifier: str) -> TraceEntity:
    return TraceEntity(
        f"{report}:{kind}:{identifier}:1",
        kind,
        name,
        [identifier],
        source_report=report,
        source_section="Claims",
        source_location="paragraph 4",
        evidence=[
            {
                "kind": "paragraph",
                "text": f"{identifier} {name}",
                "source_path": f"{report}.docx",
                "location": {"display": "paragraph 4"},
            }
        ],
        metadata={"domain": report},
    )


def test_repository_audit_keeps_findings_out_of_template_domain() -> None:
    graph = TraceGraph([_entity("report1", "feature", "Notification Sync", "FE-03")])
    symbol = RepositoryEvidence(
        "symbol:sync",
        EvidenceKind.SYMBOL,
        "lib/notification_sync.dart",
        RepositoryLineRange(42),
        symbol="Notification Sync",
    )
    snapshot = RepositorySnapshot(root="/repo", symbols=[symbol])

    result = RepositoryEvidenceAuditor(_spec()).audit(graph, snapshot)

    finding = next(item for item in result.findings if item.rule_id == "REPO-FUNCTION")
    assert finding.status == Status.PASS
    assert finding.validator == "repository_evidence"
    assert finding.metadata["domain"] == "repository_evidence"
    assert finding.metadata["evidence_status"] == RepositoryEvidenceStatus.VERIFIED.value
    assert finding.source_requirement == "Repository evidence extension; this is not an FPT template requirement."
    assert finding.metadata["repository_locations"] == ["lib/notification_sync.dart:42"]
    payload = finding.to_dict()
    assert payload["source_entity"]["documentation_evidence"][0]["source_path"] == "report1.docx"
    assert payload["candidate_entities"][0]["path"] == "lib/notification_sync.dart"


def test_not_found_is_warning_and_contradiction_is_error() -> None:
    graph = TraceGraph(
        [
            _entity("report1", "feature", "Missing Feature", "FE-01"),
            _entity("report2", "deliverable", "Legacy Installer", "DEL-01"),
        ]
    )
    mappings = RepositoryMappingConfig.from_dict(
        {
            "repository_mappings": {
                "deliverables": {
                    "DEL-01": {"contradicts": "Release manifest names Rift.pkg instead."},
                }
            }
        }
    )

    result = RepositoryEvidenceAuditor(_spec()).audit(
        graph,
        RepositorySnapshot(root="/repo"),
        mappings=mappings,
    )

    missing = next(item for item in result.findings if item.rule_id == "REPO-FUNCTION")
    contradicted = next(item for item in result.findings if item.rule_id == "REPO-DELIVERABLE")
    assert missing.status == Status.WARNING
    assert missing.metadata["evidence_status"] == "NOT_FOUND"
    assert contradicted.status == Status.FAIL
    assert contradicted.metadata["evidence_status"] == "CONTRADICTED"
    assert result.has_errors


def test_audit_emits_compact_phase_four_evidence_packets() -> None:
    graph = TraceGraph([_entity("report1", "feature", "Notification Sync", "FE-03")])
    symbol = RepositoryEvidence(
        "symbol:sync",
        EvidenceKind.SYMBOL,
        "lib/sync.dart",
        RepositoryLineRange(7),
        symbol="Notification Sync",
        excerpt_or_signature="void syncNotifications()",
    )

    result = RepositoryEvidenceAuditor(_spec()).audit(graph, RepositorySnapshot(root="/repo", symbols=[symbol]))

    packet = result.metadata["evidence_packets"][0]
    assert packet["claim"]["claim_id"] == "FE-03"
    assert packet["documentation_evidence"]
    assert packet["repository_evidence"][0]["location"] == "lib/sync.dart:7"
    assert packet["deterministic_finding"]["status"] == "VERIFIED"


def test_reverse_checks_report_unrepresented_package_and_test_conservatively() -> None:
    package = RepositoryEvidence("package:core", EvidenceKind.PACKAGE, "core/core.csproj", symbol="Core")
    test = RepositoryEvidence("test:sync", EvidenceKind.TEST, "test/sync_test.dart", symbol="syncs notifications")

    result = RepositoryEvidenceAuditor(_spec()).audit(
        TraceGraph(),
        RepositorySnapshot(root="/repo", modules=[package], tests=[test]),
    )

    assert {item.rule_id for item in result.findings} == {"REPO-ARCHITECTURE-ORPHAN", "REPO-TEST-ORPHAN"}
    assert all(item.status == Status.REVIEW_REQUIRED for item in result.findings)
    assert result.metadata["reverse_checks"]["unrepresented_package_count"] == 1
    assert result.metadata["reverse_checks"]["unrepresented_test_count"] == 1


def test_claim_and_kind_filters_skip_reverse_noise() -> None:
    graph = TraceGraph(
        [
            _entity("report1", "feature", "Notification Sync", "FE-03"),
            _entity("report4", "architecture_component", "Core Daemon", "ARC-01"),
        ]
    )
    snapshot = RepositorySnapshot(
        root="/repo",
        symbols=[RepositoryEvidence("symbol:sync", EvidenceKind.SYMBOL, "lib/sync.dart", symbol="Notification Sync")],
        modules=[RepositoryEvidence("package:other", EvidenceKind.PACKAGE, "other.csproj", symbol="Other")],
    )

    result = RepositoryEvidenceAuditor(_spec()).audit(
        graph,
        snapshot,
        kinds=["FUNCTION_OR_FEATURE"],
        claim_query="FE-03",
    )

    assert result.metadata["claim_count"] == 1
    assert [item.rule_id for item in result.findings] == ["REPO-FUNCTION"]
    assert result.metadata["reverse_checks"] == {}
