from __future__ import annotations

from pathlib import Path

import pytest

from rift_doc.repository import (
    EvidenceKind,
    RepositoryClaim,
    RepositoryClaimKind,
    RepositoryClaimProjector,
    RepositoryEvidence,
    RepositoryEvidenceLinker,
    RepositoryEvidenceStatus,
    RepositoryLineRange,
    RepositoryMappingConfig,
    RepositoryMappingError,
    RepositoryMatchMethod,
    RepositorySnapshot,
    TestEvidenceState as EvidenceTestState,
)
from rift_doc.spec import CapstoneSpec
from rift_doc.trace_model import TraceEntity, TraceGraph


def _claim(
    kind: RepositoryClaimKind,
    name: str,
    *,
    claim_id: str = "claim-1",
    identifiers: list[str] | None = None,
    metadata: dict | None = None,
) -> RepositoryClaim:
    return RepositoryClaim(
        claim_id=claim_id,
        kind=kind,
        canonical_name=name,
        identifiers=list(identifiers or []),
        documentation_evidence=[{"source_path": "report.docx", "location": "paragraph 4"}],
        metadata=dict(metadata or {}),
    )


def _evidence(
    kind: EvidenceKind,
    path: str,
    symbol: str | None = None,
    *,
    line: int | None = None,
    metadata: dict | None = None,
) -> RepositoryEvidence:
    return RepositoryEvidence(
        evidence_id=f"{kind.value}:{path}:{line or 0}:{symbol or ''}",
        kind=kind,
        path=path,
        line_range=RepositoryLineRange(line) if line else None,
        symbol=symbol,
        module=metadata.get("module") if metadata else None,
        metadata=dict(metadata or {}),
        excerpt_or_signature=symbol,
    )


def _snapshot(*items: RepositoryEvidence) -> RepositorySnapshot:
    snapshot = RepositorySnapshot(root="/repo")
    for item in items:
        if item.kind == EvidenceKind.SYMBOL:
            snapshot.symbols.append(item)
        elif item.kind == EvidenceKind.TEST:
            snapshot.tests.append(item)
        elif item.kind == EvidenceKind.TEST_RESULT:
            snapshot.test_results.append(item)
        elif item.kind == EvidenceKind.CI_JOB:
            snapshot.ci_configs.append(item)
        elif item.kind == EvidenceKind.CONFIGURATION:
            snapshot.configurations.append(item)
        elif item.kind in {EvidenceKind.MODULE, EvidenceKind.PACKAGE, EvidenceKind.DIRECTORY}:
            snapshot.modules.append(item)
        elif item.kind == EvidenceKind.BUILD_TARGET:
            snapshot.build_configs.append(item)
        elif item.kind == EvidenceKind.RELEASE_ARTIFACT:
            snapshot.release_artifacts.append(item)
        elif item.kind == EvidenceKind.MANIFEST_ENTRY:
            snapshot.manifests.append(item)
    return snapshot


def test_claim_projection_reuses_phase_two_trace_entity() -> None:
    spec = CapstoneSpec(
        path=Path("spec.yaml"),
        schema_path=Path("schema.json"),
        data={
            "repository_evidence_extension": {
                "finding_domain": "repository_evidence",
                "claims": {
                    "features": {
                        "claim_kind": "FUNCTION_OR_FEATURE",
                        "source_kinds": ["feature"],
                        "source_domains": ["report1"],
                        "expected_evidence_types": ["SYMBOL"],
                    }
                },
            }
        },
    )
    entity = TraceEntity(
        "report1:feature:FE-03:1",
        "feature",
        "Notification Sync",
        ["FE-03"],
        source_report="report1",
        source_section="Major Features",
        source_location="paragraph 4",
        evidence=[{"source_path": "report1.docx", "location": "paragraph 4"}],
        metadata={"domain": "report1"},
    )

    claims = RepositoryClaimProjector(spec).project(TraceGraph([entity]))

    assert len(claims) == 1
    assert claims[0].source_entity is entity
    assert claims[0].identifiers == ["FE-03"]
    assert claims[0].documentation_evidence[0]["source_path"] == "report1.docx"


def test_explicit_identifier_precedes_name_matching() -> None:
    explicit = _evidence(EvidenceKind.SYMBOL, "lib/new_sync.dart", "RenamedSync", metadata={"identifiers": ["FE-03"]})
    same_name = _evidence(EvidenceKind.SYMBOL, "lib/old_sync.dart", "Notification Sync")
    claim = _claim(
        RepositoryClaimKind.FUNCTION_OR_FEATURE,
        "Notification Sync",
        claim_id="FE-03",
        identifiers=["FE-03"],
    )

    match = RepositoryEvidenceLinker(_snapshot(explicit, same_name)).link(claim)

    assert match.status == RepositoryEvidenceStatus.VERIFIED
    assert match.match_method == RepositoryMatchMethod.EXPLICIT_IDENTIFIER
    assert [item.path for item in match.evidence] == ["lib/new_sync.dart"]


def test_explicit_identifier_reference_without_implementation_requires_review() -> None:
    reference = _evidence(
        EvidenceKind.CONFIGURATION,
        "core/SyncService.cs",
        line=3,
        metadata={
            "identifiers": ["FE-03"],
            "configuration_type": "explicit_identifier_reference",
        },
    )
    claim = _claim(
        RepositoryClaimKind.FUNCTION_OR_FEATURE,
        "Notification Sync",
        claim_id="FE-03",
        identifiers=["FE-03"],
    )

    match = RepositoryEvidenceLinker(_snapshot(reference)).link(claim)

    assert match.status == RepositoryEvidenceStatus.REVIEW_REQUIRED
    assert match.match_method == RepositoryMatchMethod.EXPLICIT_IDENTIFIER
    assert match.evidence == [reference]


def test_function_feature_exact_and_conservative_normalized_matching() -> None:
    exact = _evidence(EvidenceKind.SYMBOL, "lib/direct.dart", "Notification Sync")
    exact_match = RepositoryEvidenceLinker(_snapshot(exact)).link(
        _claim(RepositoryClaimKind.FUNCTION_OR_FEATURE, "Notification Sync")
    )
    assert exact_match.match_method == RepositoryMatchMethod.EXACT_NAME

    normalized = _evidence(EvidenceKind.SYMBOL, "lib/sync.dart", "NotificationSyncService")
    normalized_match = RepositoryEvidenceLinker(_snapshot(normalized)).link(
        _claim(RepositoryClaimKind.FUNCTION_OR_FEATURE, "Notification Sync")
    )
    assert normalized_match.status == RepositoryEvidenceStatus.VERIFIED
    assert normalized_match.match_method == RepositoryMatchMethod.NORMALIZED_NAME


def test_two_candidate_symbols_require_review() -> None:
    service = _evidence(EvidenceKind.SYMBOL, "lib/service.dart", "NotificationSyncService")
    engine = _evidence(EvidenceKind.SYMBOL, "lib/engine.dart", "NotificationSyncEngine")

    match = RepositoryEvidenceLinker(_snapshot(service, engine)).link(
        _claim(RepositoryClaimKind.FUNCTION_OR_FEATURE, "Notification Sync")
    )

    assert match.status == RepositoryEvidenceStatus.REVIEW_REQUIRED
    assert match.match_method == RepositoryMatchMethod.AMBIGUOUS
    assert len(match.evidence) == 2


def test_component_renamed_and_mapped_explicitly() -> None:
    package = _evidence(EvidenceKind.PACKAGE, "daemon-cs/Rift.Daemon.Core/Core.csproj", "Rift.Daemon.Core")
    mappings = RepositoryMappingConfig.from_dict(
        {
            "repository_mapping": {
                "components": {
                    "Core Daemon": {"packages": ["Rift.Daemon.Core"]},
                }
            }
        },
        source_path="mapping.yaml",
    )

    match = RepositoryEvidenceLinker(_snapshot(package), mappings).link(
        _claim(RepositoryClaimKind.ARCHITECTURE_COMPONENT, "Core Daemon")
    )

    assert match.status == RepositoryEvidenceStatus.VERIFIED
    assert match.match_method == RepositoryMatchMethod.MANUAL_MAPPING
    assert match.metadata["manual_mapping"] is True
    assert match.metadata["mapping"]["source_path"] == "mapping.yaml"


def test_invalid_mapping_is_schema_rejected() -> None:
    with pytest.raises(RepositoryMappingError, match="invalid repository mapping"):
        RepositoryMappingConfig.from_dict(
            {"repository_mappings": {"components": {"Core": {"unknown": ["value"]}}}}
        )


def test_not_found_does_not_become_contradicted() -> None:
    match = RepositoryEvidenceLinker(_snapshot()).link(
        _claim(RepositoryClaimKind.FUNCTION_OR_FEATURE, "Missing Feature")
    )
    assert match.status == RepositoryEvidenceStatus.NOT_FOUND
    assert "not proof" in (match.reason or "")


def test_explicit_conflict_and_version_mismatch_are_contradicted() -> None:
    conflict_mapping = RepositoryMappingConfig.from_dict(
        {
            "repository_mappings": {
                "deliverables": {
                    "Legacy Installer": {"contradicts": "The release manifest replaces this with Rift.pkg."},
                }
            }
        }
    )
    explicit = RepositoryEvidenceLinker(_snapshot(), conflict_mapping).link(
        _claim(RepositoryClaimKind.DELIVERABLE_OR_PACKAGE, "Legacy Installer")
    )
    assert explicit.status == RepositoryEvidenceStatus.CONTRADICTED

    package = _evidence(
        EvidenceKind.PACKAGE,
        "pubspec.yaml",
        "rift",
        metadata={"version": "2.0.0"},
    )
    version = RepositoryEvidenceLinker(_snapshot(package)).link(
        _claim(RepositoryClaimKind.DELIVERABLE_OR_PACKAGE, "rift", metadata={"version": "1.0.0"})
    )
    assert version.status == RepositoryEvidenceStatus.CONTRADICTED
    assert version.metadata["version_conflict"] == {"documented": "1.0.0", "repository": "2.0.0"}


def test_test_source_ci_and_result_are_separate_states() -> None:
    test = _evidence(
        EvidenceKind.TEST,
        "daemon-dart/test/notification_sync_test.dart",
        "syncs notifications",
        metadata={"test_name": "syncs notifications"},
    )
    ci = _evidence(
        EvidenceKind.CI_JOB,
        ".github/workflows/ci.yml",
        "test-dart",
        metadata={
            "invokes_tests": True,
            "commands": ["dart test"],
            "working_directories": ["daemon-dart"],
        },
    )
    result = _evidence(
        EvidenceKind.TEST_RESULT,
        "results/junit.xml",
        metadata={"test_names": ["syncs notifications"], "latest_result": "PASS"},
    )

    match = RepositoryEvidenceLinker(_snapshot(test, ci, result)).link(
        _claim(RepositoryClaimKind.TEST_CLAIM, "syncs notifications")
    )

    assert match.status == RepositoryEvidenceStatus.VERIFIED
    assert match.test_states == [
        EvidenceTestState.IMPLEMENTATION_PRESENT,
        EvidenceTestState.CI_CONFIGURED,
        EvidenceTestState.RESULT_PRESENT,
        EvidenceTestState.LATEST_RESULT_PASS,
    ]
    assert {item.kind for item in match.evidence} == {EvidenceKind.TEST, EvidenceKind.CI_JOB, EvidenceKind.TEST_RESULT}


def test_recorded_result_only_contradicts_an_explicit_documented_outcome() -> None:
    test = _evidence(EvidenceKind.TEST, "daemon-dart/test/sync_test.dart", "syncs notifications")
    failed_result = _evidence(
        EvidenceKind.TEST_RESULT,
        "results/junit.xml",
        metadata={"test_names": ["syncs notifications"], "latest_result": "FAIL"},
    )
    contradicted = RepositoryEvidenceLinker(_snapshot(test, failed_result)).link(
        _claim(RepositoryClaimKind.TEST_CLAIM, "syncs notifications", metadata={"status": "Passed"})
    )
    assert contradicted.status == RepositoryEvidenceStatus.CONTRADICTED
    assert contradicted.metadata["test_result_conflict"] == {"documented": "PASS", "repository": "FAIL"}

    no_claimed_outcome = RepositoryEvidenceLinker(_snapshot(test, failed_result)).link(
        _claim(RepositoryClaimKind.TEST_CLAIM, "syncs notifications")
    )
    assert no_claimed_outcome.status == RepositoryEvidenceStatus.VERIFIED
    assert EvidenceTestState.LATEST_RESULT_FAIL in no_claimed_outcome.test_states


def test_test_source_without_ci_or_result_does_not_imply_them() -> None:
    test = _evidence(EvidenceKind.TEST, "test/sync_test.dart", "syncs notifications")
    unrelated_ci = _evidence(
        EvidenceKind.CI_JOB,
        ".github/workflows/ci.yml",
        "test-other",
        metadata={
            "invokes_tests": True,
            "commands": ["dart test"],
            "working_directories": ["other-package"],
        },
    )
    match = RepositoryEvidenceLinker(_snapshot(test, unrelated_ci)).link(
        _claim(RepositoryClaimKind.TEST_CLAIM, "syncs notifications")
    )
    assert match.test_states == [EvidenceTestState.IMPLEMENTATION_PRESENT]


def test_manual_test_has_no_executable_requirement() -> None:
    match = RepositoryEvidenceLinker(_snapshot()).link(
        _claim(
            RepositoryClaimKind.TEST_CLAIM,
            "Verify desktop notification appearance",
            metadata={"executable_required": False},
        )
    )
    assert match.status == RepositoryEvidenceStatus.NOT_APPLICABLE
    assert match.match_method == RepositoryMatchMethod.NOT_APPLICABLE


def test_deliverable_present_in_artifacts_or_partially_supported_by_directory() -> None:
    artifact = _evidence(EvidenceKind.RELEASE_ARTIFACT, "dist/Rift.pkg", "Rift")
    verified = RepositoryEvidenceLinker(_snapshot(artifact)).link(
        _claim(RepositoryClaimKind.DELIVERABLE_OR_PACKAGE, "Rift")
    )
    assert verified.status == RepositoryEvidenceStatus.VERIFIED

    directory = _evidence(EvidenceKind.DIRECTORY, "apps/rift", "Rift")
    partial = RepositoryEvidenceLinker(_snapshot(directory)).link(
        _claim(RepositoryClaimKind.DELIVERABLE_OR_PACKAGE, "Rift")
    )
    assert partial.status == RepositoryEvidenceStatus.PARTIALLY_VERIFIED
