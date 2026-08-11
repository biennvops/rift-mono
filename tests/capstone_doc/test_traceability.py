from __future__ import annotations

from pathlib import Path

from rift_doc.document_set import DocumentArtifact, DocumentSet, DocumentSetLoader
from rift_doc.model import Block, Cell, Document, Section, SourceLocation, Table
from rift_doc.results import Status
from rift_doc.spec import CapstoneSpec
from rift_doc.trace_entities import TraceEntityExtractor
from rift_doc.trace_model import TraceEntity, TraceGraph, TraceIndex, TraceLinkStatus, normalize_identifier, normalize_name
from rift_doc.validators.cross_document import CrossDocumentValidator


def _spec(*rules: dict, orphans: list[dict] | None = None) -> CapstoneSpec:
    reports = {f"report{number}": {"title": f"Report {number}", "sections": {}} for number in range(1, 8)}
    return CapstoneSpec(
        path=Path("test-spec.yaml"),
        data={
            "spec_version": "test",
            "source": {"authority": "test", "documents": []},
            "classification": {},
            "reports": reports,
            "workbooks": {},
            "source_ambiguities": [],
            "cross_document_traceability": list(rules),
            "cross_document_orphan_checks": list(orphans or []),
        },
        schema_path=Path("test-schema.json"),
    )


def _document(report: str, title: str, paragraphs: list[str]) -> Document:
    section_path = title
    location = SourceLocation(kind="docx_paragraph", paragraph_index=0)
    section = Section(
        title=title,
        normalized_title=normalize_name(title),
        numbering=None,
        level=1,
        source_location=location,
        path=section_path,
    )
    blocks = [Block(kind="heading", text=title, source_location=location, section_path=section_path)]
    for index, text in enumerate(paragraphs, start=1):
        block = Block(
            kind="paragraph",
            text=text,
            source_location=SourceLocation(kind="docx_paragraph", paragraph_index=index),
            section_path=section_path,
        )
        section.blocks.append(block)
        blocks.append(block)
    return Document(source_path=f"{report}.docx", sections=[section], raw_blocks=blocks)


def _set_for_documents(documents: dict[str, Document]) -> DocumentSet:
    result = DocumentSet(reports=dict(documents))
    for report, document in documents.items():
        result.add_artifact(DocumentArtifact(report, report, document))
    return result


def _combined_document(report: str, sections: list[tuple[str, str]]) -> Document:
    document = Document(source_path=f"{report}.docx")
    raw_blocks: list[Block] = []
    for section_index, (title, text) in enumerate(sections):
        path = title
        heading_location = SourceLocation(kind="docx_paragraph", paragraph_index=section_index * 2)
        section = Section(title, normalize_name(title), None, 1, heading_location, path=path)
        block = Block(
            kind="paragraph",
            text=text,
            source_location=SourceLocation(kind="docx_paragraph", paragraph_index=section_index * 2 + 1),
            section_path=path,
        )
        section.blocks.append(block)
        document.sections.append(section)
        raw_blocks.extend([Block("heading", title, heading_location, section_path=path), block])
    document.raw_blocks = raw_blocks
    return document


def test_document_set_duplicate_candidates_require_or_record_resolution(tmp_path: Path) -> None:
    spec = _spec()
    first = tmp_path / "first.docx"
    second = tmp_path / "second.docx"
    first.write_text("first", encoding="utf-8")
    second.write_text("second", encoding="utf-8")
    manifest = tmp_path / "set.yaml"
    manifest.write_text(
        "reports:\n  report1:\n    - first.docx\n    - second.docx\n",
        encoding="utf-8",
    )
    loader = DocumentSetLoader(spec, lambda path, report_id: Document(str(path)))
    unresolved = loader.load(manifest)
    assert unresolved.duplicate_inputs
    assert "report1" not in unresolved.selected_sources

    manifest.write_text(
        "reports:\n  report1:\n    candidates:\n      - first.docx\n      - second.docx\n    selected: second.docx\n",
        encoding="utf-8",
    )
    resolved = loader.load(manifest)
    assert resolved.selected_sources["report1"].endswith("second.docx")
    assert not resolved.duplicate_inputs


def test_xt002_actor_use_case_trace() -> None:
    spec = _spec(
        {
            "id": "XT-002",
            "handler": "actor_use_case",
            "source_domain": "report3",
            "source_kind": ["actor", "use_case"],
            "targets": [
                {"domain": "report6", "kind": "user_workflow", "requirement": "MUST"},
                {"domain": "report5", "kind": "test_case_or_test_group", "requirement": "MUST", "test_levels": ["system", "acceptance"]},
            ],
        }
    )
    documents = {
        "report3": _combined_document("report3", [("Actors", "ACT-01 Administrator actor"), ("Use Cases", "UC-01 Sync use case")]),
        "report6": _document("report6", "Workflow", ["ACT-01 Administrator workflow", "UC-01 Sync workflow"]),
        "report5": _document("report5", "Test Cases", ["ACT-01 Administrator system test", "UC-01 Sync acceptance test"]),
    }
    result = CrossDocumentValidator(spec).audit(_set_for_documents(documents))
    assert not any(item.rule_id == "XT-002" and item.status == Status.FAIL for item in result.findings)


def test_xt003_interface_trace_and_design_orphan_are_conservative() -> None:
    spec = _spec(
        {
            "id": "XT-003",
            "handler": "external_interface",
            "source_domain": "report3",
            "source_kind": "external_interface",
            "targets": [
                {"domain": "report4", "kind": "architecture_component", "requirement": "MUST"},
                {"domain": "report5", "kind": "test_case_or_test_group", "requirement": "MUST", "test_levels": ["integration", "system"]},
            ],
        }
    )
    documents = {
        "report3": _document("report3", "External Interfaces", ["IF-01 External API Gateway"]),
        "report4": _document("report4", "System Architecture", ["IF-01 External API Gateway service"]),
        "report5": _document("report5", "Test Cases", ["IF-01 External API Gateway integration test"]),
    }
    result = CrossDocumentValidator(spec).audit(_set_for_documents(documents))
    assert any(item.rule_id == "XT-003" and item.status == Status.PASS for item in result.findings)


def test_test_level_is_extracted_independently_from_test_stage() -> None:
    document = _combined_document(
        "report5",
        [
            ("Test Reports", "IF-01 External API Gateway integration test"),
            ("Test Reports", "IF-02 External API Gateway test"),
        ],
    )
    entities = TraceEntityExtractor().extract(document, "report5", kinds=["test_case_or_test_group"])
    by_identifier = {entity.identifiers[0]: entity for entity in entities}
    assert by_identifier["IF-01"].metadata["test_stage"] == "result"
    assert by_identifier["IF-01"].metadata["test_level"] == "integration"
    assert by_identifier["IF-02"].metadata["test_stage"] == "result"
    assert by_identifier["IF-02"].metadata["test_level"] is None


def test_xt003_rejects_wrong_test_level_and_reviews_unknown_level() -> None:
    spec = _spec(
        {
            "id": "XT-003",
            "handler": "external_interface",
            "source_domain": "report3",
            "source_kind": "external_interface",
            "targets": [
                {"domain": "report4", "kind": "architecture_component", "requirement": "MUST"},
                {"domain": "report5", "kind": "test_case_or_test_group", "requirement": "MUST", "test_levels": ["integration", "system"]},
            ],
        }
    )
    wrong_level = CrossDocumentValidator(spec).audit(
        _set_for_documents(
            {
                "report3": _document("report3", "External Interfaces", ["IF-01 External API Gateway"]),
                "report4": _document("report4", "System Architecture", ["IF-01 External API Gateway service"]),
                "report5": _document("report5", "Test Cases", ["IF-01 External API Gateway unit test"]),
            }
        )
    )
    wrong_finding = next(item for item in wrong_level.findings if item.rule_id == "XT-003" and item.target_domain == "report5")
    assert wrong_finding.status == Status.FAIL

    unknown_level = CrossDocumentValidator(spec).audit(
        _set_for_documents(
            {
                "report3": _document("report3", "External Interfaces", ["IF-01 External API Gateway"]),
                "report4": _document("report4", "System Architecture", ["IF-01 External API Gateway service"]),
                "report5": _document("report5", "Test Cases", ["IF-01 External API Gateway test"]),
            }
        )
    )
    unknown_finding = next(item for item in unknown_level.findings if item.rule_id == "XT-003" and item.target_domain == "report5")
    assert unknown_finding.status == Status.REVIEW_REQUIRED


def test_xt004_data_entity_trace_accepts_explicit_design_mapping() -> None:
    spec = _spec(
        {
            "id": "XT-004",
            "handler": "data_entity",
            "source_domain": "report3",
            "source_kind": "entity_or_data_object",
            "targets": [{"domain": "report4", "kind": "entity_or_data_object", "requirement": "MUST"}],
        }
    )
    documents = {
        "report3": _document("report3", "Entity Relationship Diagram", ["ENT-01 Device"]),
        "report4": _document("report4", "Database Design", ["ENT-01 Device table"]),
    }
    result = CrossDocumentValidator(spec).audit(_set_for_documents(documents))
    assert any(item.rule_id == "XT-004" and item.status == Status.PASS for item in result.findings)


def test_xt005_quality_results_do_not_assert_achievement() -> None:
    spec = _spec(
        {
            "id": "XT-005",
            "handler": "quality_objective",
            "source_domain": "report2",
            "source_kind": "quality_objective",
            "target_domain": "report5",
            "targets": [
                {"domain": "report5", "kind": "test_case_or_test_group", "role": "strategy", "requirement": "MUST"},
                {"domain": "report5", "kind": "test_case_or_test_group", "role": "result", "requirement": "CONDITIONAL", "condition": "measurable"},
            ],
        }
    )
    documents = {
        "report2": _document("report2", "Project Objectives", ["QO-01 90% test coverage target"]),
        "report5": _combined_document("report5", [("Test Strategy", "QO-01 coverage strategy"), ("Test Reports", "QO-01 coverage result")]),
    }
    result = CrossDocumentValidator(spec).audit(_set_for_documents(documents))
    objective = result.metadata["quality_objectives"][0]
    assert objective["strategy"] == "TRACE_PRESENT"
    assert objective["result"] == "RESULT_PRESENT"
    assert objective["achievement"] == "ACHIEVEMENT_REVIEW_REQUIRED"
    assert not any(item.status == Status.FAIL for item in result.findings)


def _structured_document(report: str, tables: list[tuple[str, str, str]]) -> Document:
    document = Document(source_path=f"{report}.docx")
    for index, (section, label, value) in enumerate(tables):
        document.tables.append(
            Table(
                rows=[[Cell(value=label), Cell(value=value)]],
                parent_section=section,
                source_location=SourceLocation(kind="docx_table", table_index=index),
            )
        )
    return document


def test_report7_freshness_uses_source_report_sections() -> None:
    spec = _spec(
        {
            "id": "R7-FRESHNESS",
            "handler": "freshness",
            "source_domain": "report1",
            "source_kind": "feature",
            "freshness": {
                "sources": ["report1", "report2"],
                "kinds": ["feature"],
                "target": "report7",
                "target_kinds": ["final_report_item"],
                "section_map": {
                    "report1": ["I. Project Introduction"],
                    "report2": ["II. Project Management Plan"],
                },
            },
            "targets": [{"domain": "report7", "kind": "final_report_item", "requirement": "MUST"}],
        }
    )
    source = _structured_document("report1", [])
    source.metadata["version"] = "1.0"
    final = _structured_document(
        "report7",
        [
            ("I. Project Introduction", "Version", "1.0"),
            ("II. Project Management Plan", "Version", "9.0"),
        ],
    )
    result = CrossDocumentValidator(spec).audit(_set_for_documents({"report1": source, "report7": final}))
    assert not any(item.rule_id == "R7-FRESHNESS" and item.metadata.get("consistency") == "STALE_OR_CONTRADICTED" for item in result.findings)

    final.tables[0].rows[0][1].value = "2.0"
    final.tables[0].rows[0][1].original_text = "2.0"
    stale = CrossDocumentValidator(spec).audit(_set_for_documents({"report1": source, "report7": final}))
    stale_finding = next(item for item in stale.findings if item.rule_id == "R7-FRESHNESS" and item.metadata.get("consistency") == "STALE_OR_CONTRADICTED")
    assert stale_finding.metadata["consistency"] == "STALE_OR_CONTRADICTED"
    assert stale_finding.metadata["target_section"] == "I. Project Introduction"


def test_report7_freshness_reviews_multiple_values_in_source_section() -> None:
    spec = _spec(
        {
            "id": "R7-FRESHNESS",
            "handler": "freshness",
            "source_domain": "report1",
            "source_kind": "feature",
            "freshness": {
                "sources": ["report1"],
                "kinds": ["feature"],
                "target": "report7",
                "target_kinds": ["final_report_item"],
                "section_map": {"report1": ["I. Project Introduction"]},
            },
            "targets": [{"domain": "report7", "kind": "final_report_item", "requirement": "MUST"}],
        }
    )
    source = _structured_document("report1", [])
    source.metadata["version"] = "1.0"
    final = _structured_document(
        "report7",
        [
            ("I. Project Introduction", "Version", "1.0"),
            ("I. Project Introduction", "Version", "1.1"),
        ],
    )
    result = CrossDocumentValidator(spec).audit(_set_for_documents({"report1": source, "report7": final}))
    finding = next(item for item in result.findings if item.rule_id == "R7-FRESHNESS" and item.metadata.get("consistency") == "REVIEW_REQUIRED")
    assert finding.metadata["consistency"] == "REVIEW_REQUIRED"
    assert finding.metadata["candidate_count"] == 2


def test_xt006_deliverables_cover_final_products() -> None:
    spec = _spec(
        {
            "id": "XT-006",
            "handler": "deliverable",
            "source_domain": "report2",
            "source_kind": "deliverable",
            "targets": [
                {"domain": "report6", "kind": "deliverable", "requirement": "MUST"},
                {"domain": "report7", "kind": "final_report_item", "requirement": "MUST"},
            ],
        }
    )
    documents = {
        "report2": _document("report2", "Project Deliverables", ["DEL-01 Release Package"]),
        "report6": _document("report6", "Deliverable Package", ["DEL-01 Release Package"]),
        "report7": _document("report7", "Deliverable Package", ["DEL-01 Release Package"]),
    }
    result = CrossDocumentValidator(spec).audit(_set_for_documents(documents))
    assert not any(item.rule_id == "XT-006" and item.status == Status.FAIL for item in result.findings)


def test_identifier_and_name_normalization_is_conservative() -> None:
    assert normalize_identifier("FE-01") == normalize_identifier("fe01")
    assert normalize_identifier("FE-01") != normalize_identifier("FE-1")
    assert normalize_name("Notification Sync") == normalize_name("notification-sync")


def test_explicit_id_match_respects_target_kinds() -> None:
    source = TraceEntity("source", "external_interface", "External API", ["IF-01"], metadata={"domain": "report3"})
    wrong_kind = TraceEntity("target", "function", "External API", ["IF-01"], metadata={"domain": "report4"})
    match = TraceIndex(TraceGraph([source, wrong_kind])).match(
        source,
        target_domain="report4",
        target_kinds=["architecture_component"],
    )
    assert match.status == TraceLinkStatus.MISSING
    assert not match.candidates


def test_explicit_id_match_precedes_exact_name() -> None:
    source = TraceEntity("source", "feature", "Notification Sync", ["FE-01"], metadata={"domain": "report1"})
    target = TraceEntity("target", "function", "Renamed Sync", ["FE-01"], metadata={"domain": "report3"})
    match = TraceIndex(TraceGraph([source, target])).match(source, target_domain="report3", target_kinds=["function"])
    assert match.status == TraceLinkStatus.VERIFIED
    assert match.candidates[0].entity_id == "target"


def test_different_ids_with_same_name_are_ambiguous() -> None:
    source = TraceEntity("source", "feature", "Same Name", ["FE-01"], metadata={"domain": "report1"})
    target = TraceEntity("target", "function", "Same Name", ["FE-02"], metadata={"domain": "report3"})
    match = TraceIndex(TraceGraph([source, target])).match(source, target_domain="report3", target_kinds=["function"])
    assert match.status == TraceLinkStatus.AMBIGUOUS
    assert match.method.value == "AMBIGUOUS"


def test_entity_extraction_retains_source_evidence_and_ids() -> None:
    document = _document("report1", "Major Features", ["FE-03 Notification Sync"])
    entities = TraceEntityExtractor().extract(document, "report1", kinds=["feature"])
    assert len(entities) == 1
    entity = entities[0]
    assert entity.identifiers == ["FE-03"]
    assert entity.canonical_name == "Notification Sync"
    assert entity.source_location.display() == "paragraph 1"
    assert entity.evidence[0]["source_path"] == "report1.docx"


def test_feature_rule_creates_graph_edges_and_missing_findings() -> None:
    spec = _spec(
        {
            "id": "XT-001",
            "handler": "feature_coverage",
            "source_domain": "report1",
            "source_kind": "feature",
            "targets": [
                {"domain": "report2", "kind": "wbs_item", "requirement": "MUST"},
                {"domain": "report3", "kind": "function", "requirement": "MUST"},
            ],
        }
    )
    documents = {
        "report1": _document("report1", "Major Features", ["FE-01 Notification Sync"]),
        "report2": _document("report2", "WBS", ["FE-01 Notification Sync"]),
        "report3": _document("report3", "Functional Requirements", ["FE-01 Notification Sync"]),
    }
    result = CrossDocumentValidator(spec).audit(_set_for_documents(documents))
    assert result.metadata["trace_graph"]["edges"]
    assert any(item.rule_id == "XT-001" and item.status == Status.PASS for item in result.findings)
    assert not any(item.rule_id == "XT-001" and item.status == Status.FAIL and item.target_domain == "report3" for item in result.findings)
    assert result.findings[0].validator == "cross_document"


def test_ambiguous_trace_is_review_required_not_fail() -> None:
    spec = _spec(
        {
            "id": "XT-001",
            "handler": "feature_coverage",
            "source_domain": "report1",
            "source_kind": "feature",
            "targets": [{"domain": "report2", "kind": "wbs_item", "requirement": "MUST"}],
        }
    )
    documents = {
        "report1": _document("report1", "Major Features", ["FE-01 Same Name"]),
        "report2": _document("report2", "WBS", ["FE-02 Same Name", "FE-03 Same Name"]),
    }
    result = CrossDocumentValidator(spec).audit(_set_for_documents(documents))
    finding = next(item for item in result.findings if item.rule_id == "XT-001")
    assert finding.status == Status.REVIEW_REQUIRED
    assert len(finding.candidate_entities) == 2


def test_duplicate_ids_are_reported_without_merging() -> None:
    spec = _spec(
        {
            "id": "XT-001",
            "handler": "feature_coverage",
            "source_domain": "report1",
            "source_kind": "feature",
            "targets": [{"domain": "report2", "kind": "wbs_item", "requirement": "MUST"}],
        }
    )
    documents = {
        "report1": _document("report1", "Major Features", ["FE-01 First", "FE-01 Second"]),
        "report2": _document("report2", "WBS", ["FE-01 First"]),
    }
    result = CrossDocumentValidator(spec).audit(_set_for_documents(documents))
    assert any(item.rule_id == "TRACE-ID-001" for item in result.findings)
    assert len(result.metadata["trace_graph"]["nodes"]) >= 3


def test_conditional_false_link_is_not_applicable() -> None:
    spec = _spec(
        {
            "id": "XT-001",
            "handler": "feature_coverage",
            "source_domain": "report1",
            "source_kind": "feature",
            "targets": [
                {"domain": "report6", "kind": "user_workflow", "condition": "user_facing", "requirement": "CONDITIONAL"}
            ],
        }
    )
    documents = {
        "report1": _document("report1", "Major Features", ["FE-01 Background Sync"]),
        "report6": _document("report6", "User Manual", ["No workflow"]),
    }
    result = CrossDocumentValidator(spec).audit(_set_for_documents(documents))
    finding = next(item for item in result.findings if item.rule_id == "XT-001")
    assert finding.status == Status.NOT_APPLICABLE


def test_configured_orphan_check_is_executed() -> None:
    spec = _spec(
        orphans=[
            {
                "id": "ORPHAN-TEST",
                "source_domain": "report5",
                "source_kind": "test_case_or_test_group",
                "target_domain": "report3",
                "target_kind": ["function", "feature"],
                "status": "REVIEW_REQUIRED",
                "severity": "warning",
            }
        ]
    )
    result = CrossDocumentValidator(spec).audit(
        _set_for_documents(
            {
                "report3": _document("report3", "Functional Requirements", ["FE-01 Sync"]),
                "report5": _document("report5", "Test Cases", ["TC-01 Unrelated integration test"]),
            }
        )
    )
    assert any(item.rule_id == "ORPHAN-TEST" and item.status == Status.REVIEW_REQUIRED for item in result.findings)


def test_data_entity_explicit_na_rationale_is_not_applicable() -> None:
    spec = _spec(
        {
            "id": "XT-004",
            "handler": "data_entity",
            "source_domain": "report3",
            "source_kind": "entity_or_data_object",
            "targets": [
                {
                    "domain": "report4",
                    "kind": "entity_or_data_object",
                    "requirement": "CONDITIONAL",
                    "allow_explicit_na": True,
                }
            ],
        }
    )
    result = CrossDocumentValidator(spec).audit(
        _set_for_documents(
            {
                "report3": _document("report3", "Entity Relationship Diagram", ["ENT-01 Device"]),
                "report4": _document("report4", "Database Design", ["ENT-01 Device: N/A - no persistent database"]),
            }
        )
    )
    finding = next(item for item in result.findings if item.rule_id == "XT-004")
    assert finding.status == Status.NOT_APPLICABLE


def test_data_entity_na_does_not_leak_to_unrelated_entities() -> None:
    spec = _spec(
        {
            "id": "XT-004",
            "handler": "data_entity",
            "source_domain": "report3",
            "source_kind": "entity_or_data_object",
            "targets": [
                {
                    "domain": "report4",
                    "kind": "entity_or_data_object",
                    "requirement": "CONDITIONAL",
                    "allow_explicit_na": True,
                }
            ],
        }
    )
    result = CrossDocumentValidator(spec).audit(
        _set_for_documents(
            {
                "report3": _combined_document(
                    "report3",
                    [
                        ("Entity Relationship Diagram", "ENT-01 User Session"),
                        ("Entity Relationship Diagram", "ENT-02 User Profile"),
                    ],
                ),
                "report4": _document(
                    "report4",
                    "Database Design",
                    ["ENT-01 User Session: N/A - no persistent database"],
                ),
            }
        )
    )
    device = next(item for item in result.findings if item.rule_id == "XT-004" and item.source_entity["identifiers"] == ["ENT-01"])
    session = next(item for item in result.findings if item.rule_id == "XT-004" and item.source_entity["identifiers"] == ["ENT-02"])
    assert device.status == Status.NOT_APPLICABLE
    assert session.status == Status.FAIL


def test_missing_report_is_reported_in_set_and_trace_results() -> None:
    spec = _spec(
        {
            "id": "XT-001",
            "handler": "feature_coverage",
            "source_domain": "report1",
            "source_kind": "feature",
            "targets": [{"domain": "report2", "kind": "wbs_item", "requirement": "MUST"}],
        }
    )
    document_set = _set_for_documents({"report1": _document("report1", "Major Features", ["FE-01 Sync"])})
    result = CrossDocumentValidator(spec).audit(document_set)
    assert any(item.rule_id == "SET-007" and item.target_domain == "report2" for item in result.findings)
    assert any(item.rule_id == "XT-001" and item.status == Status.FAIL for item in result.findings)


def test_complete_seven_report_fixture_has_no_trace_failures() -> None:
    spec = _spec(
        {
            "id": "XT-001",
            "handler": "feature_coverage",
            "source_domain": "report1",
            "source_kind": "feature",
            "targets": [
                {"domain": "report2", "kind": "wbs_item", "requirement": "MUST"},
                {"domain": "report3", "kind": "function", "requirement": "MUST"},
                {"domain": "report4", "kind": "function", "requirement": "MUST"},
                {"domain": "report5", "kind": "test_case_or_test_group", "requirement": "MUST"},
                {"domain": "report6", "kind": "user_workflow", "requirement": "MUST"},
                {"domain": "report7", "kind": "final_report_item", "requirement": "MUST"},
            ],
        },
        {
            "id": "XT-002",
            "handler": "actor_use_case",
            "source_domain": "report3",
            "source_kind": ["actor", "use_case"],
            "targets": [
                {"domain": "report6", "kind": "user_workflow", "requirement": "MUST"},
                {"domain": "report5", "kind": "test_case_or_test_group", "requirement": "MUST", "test_levels": ["system", "acceptance"]},
            ],
        },
        {
            "id": "XT-003",
            "handler": "external_interface",
            "source_domain": "report3",
            "source_kind": "external_interface",
            "targets": [
                {"domain": "report4", "kind": "architecture_component", "requirement": "MUST"},
                {"domain": "report5", "kind": "test_case_or_test_group", "requirement": "MUST", "test_levels": ["integration", "system"]},
            ],
        },
        {
            "id": "XT-004",
            "handler": "data_entity",
            "source_domain": "report3",
            "source_kind": "entity_or_data_object",
            "targets": [{"domain": "report4", "kind": "entity_or_data_object", "requirement": "MUST"}],
        },
        {
            "id": "XT-005",
            "handler": "quality_objective",
            "source_domain": "report2",
            "source_kind": "quality_objective",
            "targets": [
                {"domain": "report5", "kind": "test_case_or_test_group", "role": "strategy", "requirement": "MUST"},
                {"domain": "report5", "kind": "test_case_or_test_group", "role": "result", "requirement": "MUST", "condition": "measurable"},
            ],
        },
        {
            "id": "XT-006",
            "handler": "deliverable",
            "source_domain": "report2",
            "source_kind": "deliverable",
            "targets": [
                {"domain": "report6", "kind": "deliverable", "requirement": "MUST"},
                {"domain": "report7", "kind": "final_report_item", "requirement": "MUST"},
            ],
        },
    )
    documents = {
        "report1": _document("report1", "Major Features", ["FE-01 User-facing Sync"]),
        "report2": _combined_document("report2", [("WBS", "FE-01 User-facing Sync"), ("Project Objectives", "QO-01 90% test coverage target"), ("Project Deliverables", "DEL-01 Release Package")]),
        "report3": _combined_document("report3", [("Actors", "ACT-01 Administrator actor"), ("Use Cases", "UC-01 Sync use case"), ("External Interfaces", "IF-01 External API Gateway"), ("Functional Requirements", "FE-01 User-facing Sync"), ("Entity Relationship Diagram", "ENT-01 Device")]),
        "report4": _combined_document("report4", [("System Architecture", "FE-01 User-facing Sync"), ("System Architecture", "IF-01 External API Gateway service"), ("Database Design", "ENT-01 Device table"), ("Detailed Design", "FE-01 User-facing Sync")]),
        "report5": _combined_document("report5", [("Test Cases", "FE-01 User-facing Sync system test"), ("Test Cases", "ACT-01 Administrator acceptance test"), ("Test Cases", "UC-01 Sync system test"), ("Test Cases", "IF-01 External API Gateway integration test"), ("Test Strategy", "QO-01 coverage strategy"), ("Test Reports", "QO-01 coverage result")]),
        "report6": _combined_document("report6", [("Workflow", "FE-01 User-facing Sync workflow"), ("Workflow", "ACT-01 Administrator workflow"), ("Workflow", "UC-01 Sync workflow"), ("Deliverable Package", "DEL-01 Release Package")]),
        "report7": _combined_document("report7", [("Major Features", "FE-01 User-facing Sync"), ("Deliverable Package", "DEL-01 Release Package")]),
    }
    result = CrossDocumentValidator(spec).audit(_set_for_documents(documents))
    assert {f"XT-00{index}" for index in range(1, 7)} <= set(result.metadata["coverage"])
    assert not any(item.status == Status.FAIL for item in result.findings)


def test_finding_json_keeps_cross_document_fields() -> None:
    spec = _spec(
        {
            "id": "XT-001",
            "handler": "feature_coverage",
            "source_domain": "report1",
            "source_kind": "feature",
            "targets": [{"domain": "report2", "kind": "wbs_item", "requirement": "MUST"}],
        }
    )
    result = CrossDocumentValidator(spec).audit(_set_for_documents({"report1": _document("report1", "Major Features", ["FE-01 Sync"])}))
    payload = next(item.to_dict() for item in result.findings if item.rule_id == "XT-001")
    assert payload["validator"] == "cross_document"
    assert payload["target_domain"] == "report2"
    assert payload["source_entity"]["identifiers"] == ["FE-01"]
