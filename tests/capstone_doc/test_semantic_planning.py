from __future__ import annotations

from pathlib import Path

from rift_doc.document_set import DocumentArtifact, DocumentSet
from rift_doc.model import Block, ContentClass, Document, Image, Section, SourceLocation
from rift_doc.repository import EvidenceKind, RepositoryEvidence, RepositorySnapshot
from rift_doc.results import Finding, Status
from rift_doc.semantic import EvidencePacketBuilder, SemanticReviewPlanner, SemanticTaskType
from rift_doc.spec import CapstoneSpec
from rift_doc.trace_model import TraceEntity, TraceGraph


def _spec(rules: list[dict[str, object]]) -> CapstoneSpec:
    return CapstoneSpec(
        path=Path("spec.yaml"),
        schema_path=Path("schema.json"),
        data={
            "spec_version": "test-semantic-1",
            "reports": {
                "report3": {
                    "title": "Requirements",
                    "source_requirement": "Requirements describe behavior.",
                    "sections": {
                        "feature_requirements": {
                            "title": "Feature Requirements",
                            "requirement": "MUST",
                            "content": True,
                            "match": {"regex": r"^3\.\d+\s+.+$"},
                        }
                    },
                },
                "report4": {"title": "Design", "sections": {}},
                "report5": {"title": "Tests", "sections": {}},
                "report7": {"title": "Final", "sections": {}},
            },
            "semantic_review_extension": {
                "source_precedence": {
                    "authoritative_sources": ["report3", "report4", "report5"],
                    "final_consumer": "report7",
                },
                "rules": rules,
            },
        },
    )


def _document_set(*, long_text: bool = False, image: bool = False) -> DocumentSet:
    text = ("Notification forwarding behavior and validation rules. " * 500) if long_text else (
        "A trusted sender forwards a notification. Invalid payloads are rejected and reported to the user."
    )
    heading_location = SourceLocation("docx_paragraph", paragraph_index=1)
    body_location = SourceLocation("docx_paragraph", paragraph_index=2)
    section = Section(
        title="3.2 Notification Sync",
        normalized_title="3.2 notification sync",
        numbering="3.2",
        level=2,
        source_location=heading_location,
        path="3.2 Notification Sync",
        blocks=[],
    )
    blocks = [
        Block(
            "heading",
            "3.2 Notification Sync",
            source_location=heading_location,
            section_path=section.path,
        ),
        Block(
            "paragraph",
            text,
            source_location=body_location,
            section_path=section.path,
            classification=ContentClass.REAL_CONTENT,
        ),
        Block(
            "paragraph",
            "Unrelated appendix content that must not be selected.",
            source_location=SourceLocation("docx_paragraph", paragraph_index=9),
            section_path="Appendix",
            classification=ContentClass.REAL_CONTENT,
        ),
    ]
    document = Document("report3.docx", sections=[section], raw_blocks=blocks)
    if image:
        document.images.append(
            Image(
                relationship_id="rId5",
                description="Architecture",
                source_location=body_location,
                parent_section=section.path,
                filename="architecture.png",
            )
        )
    result = DocumentSet()
    result.add_artifact(DocumentArtifact("report3", "report3", document))
    return result


def _graph() -> TraceGraph:
    requirement = TraceEntity(
        "report3:function:FE-03:1",
        "function",
        "Notification Sync",
        ["FE-03"],
        source_report="report3",
        source_section="3.2 Notification Sync",
        source_location="paragraph 2",
        evidence=[
            {
                "kind": "paragraph",
                "text": "FE-03 forwards notifications and rejects malformed payloads.",
                "source_path": "report3.docx",
                "location": {"display": "paragraph 2"},
            }
        ],
        metadata={"domain": "report3"},
    )
    test = TraceEntity(
        "report5:test:TC-41:1",
        "test_case_or_test_group",
        "Notification Sync",
        ["FE-03", "TC-41"],
        source_report="report5",
        source_section="Feature 3",
        source_location="sheet Feature 3!A11",
        evidence=[
            {
                "kind": "cell",
                "text": "TC-41 forwards a valid notification",
                "source_path": "report5.xlsx",
                "location": {"display": "sheet Feature 3!A11"},
            }
        ],
        metadata={"domain": "report5"},
    )
    return TraceGraph([requirement, test])


def test_planner_generates_explicit_section_relationship_and_review_tasks() -> None:
    spec = _spec(
        [
            {
                "id": "SEM-CONTENT",
                "task_type": "CONTENT_SUFFICIENCY",
                "generation": "sections",
                "source_domain": "report3",
                "section_rules": ["feature_requirements"],
                "question": "Is {source_name} sufficient?",
            },
            {
                "id": "SEM-ALIGN",
                "task_type": "REQUIREMENT_TEST_ALIGNMENT",
                "generation": "relationships",
                "source_domain": "report3",
                "source_kinds": ["function"],
                "target_domain": "report5",
                "target_kinds": ["test_case_or_test_group"],
                "question": "Does {target_names} test {source_name}?",
            },
        ]
    )
    finding = Finding(
        Status.REVIEW_REQUIRED,
        "warning",
        "R7-FRESHNESS",
        "report3",
        "Feature",
        "paragraph 2",
        "Final narrative may be stale.",
        validator="cross_document",
        target_domain="report7",
    )

    tasks, omitted = SemanticReviewPlanner(spec).plan(_document_set(), _graph(), [finding])

    assert omitted == 0
    assert {task.task_type for task in tasks} == {
        SemanticTaskType.CONTENT_SUFFICIENCY,
        SemanticTaskType.REQUIREMENT_TEST_ALIGNMENT,
        SemanticTaskType.FINAL_REPORT_FRESHNESS,
    }
    alignment = next(task for task in tasks if task.task_type == SemanticTaskType.REQUIREMENT_TEST_ALIGNMENT)
    assert alignment.metadata["deterministic_match_method"] == "EXPLICIT_ID"
    assert alignment.evidence_refs == (
        "trace:report3:function:FE-03:1",
        "trace:report5:test:TC-41:1",
    )


def test_planner_skips_simple_deterministic_failure_and_enforces_filters() -> None:
    spec = _spec(
        [
            {
                "id": "SEM-CONTENT",
                "task_type": "CONTENT_SUFFICIENCY",
                "generation": "sections",
                "source_domain": "report3",
                "section_rules": ["feature_requirements"],
                "question": "Review {source_name}",
            },
            {
                "id": "SEM-ALIGN",
                "task_type": "REQUIREMENT_TEST_ALIGNMENT",
                "generation": "relationships",
                "source_domain": "report3",
                "source_kinds": ["function"],
                "target_domain": "report5",
                "target_kinds": ["test_case_or_test_group"],
                "question": "Review {source_name}",
            },
        ]
    )
    missing = Finding(Status.FAIL, "error", "required.section", "report3", None, None, "Section missing")

    tasks, omitted = SemanticReviewPlanner(spec).plan(
        _document_set(),
        _graph(),
        [missing],
        task_types=[SemanticTaskType.REQUIREMENT_TEST_ALIGNMENT],
        entity_query="FE-03",
        max_tasks=1,
    )

    assert len(tasks) == 1
    assert omitted == 0
    assert tasks[0].task_type == SemanticTaskType.REQUIREMENT_TEST_ALIGNMENT
    assert all(task.metadata.get("trigger_rule_id") != "required.section" for task in tasks)


def test_packet_uses_exact_section_and_preserves_provenance() -> None:
    rules = [
        {
            "id": "SEM-CONTENT",
            "task_type": "CONTENT_SUFFICIENCY",
            "generation": "sections",
            "source_domain": "report3",
            "section_rules": ["feature_requirements"],
            "question": "Review {source_name}",
        }
    ]
    spec = _spec(rules)
    documents = _document_set()
    task = SemanticReviewPlanner(spec).plan(documents, _graph(), [])[0][0]

    packet = EvidencePacketBuilder(spec, max_input_tokens=2_000).build(task, documents, _graph(), [])

    assert packet.document_evidence
    assert "Unrelated appendix" not in "\n".join(item.content for item in packet.document_evidence)
    block = next(item for item in packet.document_evidence if item.kind == "document_block")
    assert block.report == "report3"
    assert block.section_path == "3.2 Notification Sync"
    assert block.source_path == "report3.docx"
    assert block.source_location["display"] == "paragraph 2"
    assert packet.provenance["source_precedence"]["final_consumer"] == "report7"
    assert packet.packet_hash == packet.packet_hash


def test_packet_budget_is_hard_and_records_truncation() -> None:
    spec = _spec(
        [
            {
                "id": "SEM-CONTENT",
                "task_type": "CONTENT_SUFFICIENCY",
                "generation": "sections",
                "source_domain": "report3",
                "section_rules": ["feature_requirements"],
                "question": "Review {source_name}",
            }
        ]
    )
    documents = _document_set(long_text=True)
    task = SemanticReviewPlanner(spec).plan(documents, _graph(), [])[0][0]

    packet = EvidencePacketBuilder(spec, max_input_tokens=800).build(task, documents, _graph(), [])

    assert packet.estimated_input_tokens <= 800
    assert packet.truncated_evidence
    assert any(item["original_characters"] > item["included_characters"] for item in packet.truncated_evidence)


def test_packet_excludes_secret_paths_and_records_required_gap() -> None:
    spec = _spec(
        [
            {
                "id": "SEM-REPO",
                "task_type": "CLAIM_REPOSITORY_ALIGNMENT",
                "generation": "findings",
                "finding_validators": ["repository_evidence"],
                "question": "Review {source_name}",
            }
        ]
    )
    evidence = RepositoryEvidence(
        "config:secret",
        EvidenceKind.CONFIGURATION,
        "service/.env.production",
        excerpt_or_signature="TOKEN=do-not-send",
    )
    finding = Finding(
        Status.REVIEW_REQUIRED,
        "warning",
        "REPO-FUNCTION",
        "report3",
        "Feature",
        "paragraph 2",
        "Repository evidence is ambiguous.",
        validator="repository_evidence",
        source_entity={
            "claim_id": "FE-03",
            "kind": "FUNCTION_OR_FEATURE",
            "canonical_name": "Notification Sync",
            "documentation_evidence": [
                {
                    "kind": "paragraph",
                    "text": "FE-03 Notification Sync is complete.",
                    "source_path": "report3.docx",
                    "section": "3.2 Notification Sync",
                    "location": {"display": "paragraph 2"},
                }
            ],
        },
        candidate_entities=[evidence.to_dict()],
    )
    task = SemanticReviewPlanner(spec).plan(_document_set(), _graph(), [finding])[0][0]

    packet = EvidencePacketBuilder(spec).build(
        task,
        _document_set(),
        _graph(),
        [finding],
        repository_snapshot=RepositorySnapshot(root="/repo", configurations=[evidence]),
    )

    assert not packet.repository_evidence
    assert any("Notification Sync is complete" in item.content for item in packet.document_evidence)
    assert packet.excluded_evidence == [
        {
            "path": "service/.env.production",
            "reason": "configured or secret-class path",
            "required_for_task": True,
        }
    ]
    assert "do-not-send" not in str(packet.to_dict())


def test_packet_records_unavailable_visual_reference() -> None:
    spec = _spec(
        [
            {
                "id": "SEM-CONTENT",
                "task_type": "CONTENT_SUFFICIENCY",
                "generation": "sections",
                "source_domain": "report3",
                "section_rules": ["feature_requirements"],
                "question": "Review {source_name}",
            }
        ]
    )
    documents = _document_set(image=True)
    task = SemanticReviewPlanner(spec).plan(documents, _graph(), [])[0][0]

    packet = EvidencePacketBuilder(spec).build(task, documents, _graph(), [])

    image = next(item for item in packet.document_evidence if item.kind == "image_reference")
    assert image.metadata["visual_available"] is False
    assert packet.provenance["visual_evidence"] == {
        "requested": False,
        "selected": True,
        "bytes_available": False,
    }


def test_current_contract_configures_every_initial_semantic_task_type() -> None:
    root = Path(__file__).resolve().parents[2]
    spec = CapstoneSpec.load(root / "capstone-doc-spec.v0.1.yaml")

    configured = {SemanticTaskType(rule["task_type"]) for rule in spec.semantic_review_rules}

    assert configured == set(SemanticTaskType)
