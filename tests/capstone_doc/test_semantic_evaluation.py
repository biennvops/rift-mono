from __future__ import annotations

from rift_doc.semantic import (
    FakeLLMProvider,
    SemanticEvaluationHarness,
    SemanticEvaluationSet,
    SemanticResultCache,
    SemanticTaskType,
)


def test_default_evaluation_set_covers_all_ten_golden_scenarios() -> None:
    evaluation_set = SemanticEvaluationSet.load()

    assert evaluation_set.version == "1.0.0"
    assert [case.case_id for case in evaluation_set.cases] == [
        "valid-pass-with-citation",
        "contradiction-two-reports",
        "insufficient-evidence-review-required",
        "fabricated-citation-rejected",
        "invalid-severity-rejected",
        "report7-semantic-staleness",
        "requirement-test-mismatch",
        "repository-claim-mismatch",
        "ambiguous-semantic-feature-name",
        "cache-invalidated-by-packet-change",
    ]
    assert {
        SemanticTaskType.CONTENT_SUFFICIENCY,
        SemanticTaskType.CROSS_DOCUMENT_CONSISTENCY,
        SemanticTaskType.FINAL_REPORT_FRESHNESS,
        SemanticTaskType.REQUIREMENT_TEST_ALIGNMENT,
        SemanticTaskType.CLAIM_REPOSITORY_ALIGNMENT,
    }.issubset({case.task_type for case in evaluation_set.cases})


def test_golden_candidate_outputs_match_labels_and_expected_rejections() -> None:
    metrics = SemanticEvaluationHarness().evaluate()

    assert metrics.case_count == 10
    assert metrics.output_validation_accuracy == 1.0
    assert metrics.status_accuracy == 1.0
    assert metrics.false_contradiction_rate == 0.0
    assert metrics.insufficient_evidence_handling == 1.0
    assert metrics.required_evidence_coverage == 1.0
    assert metrics.fabricated_citation_rate > 0.0
    by_id = {value["case_id"]: value for value in metrics.case_results}
    assert by_id["fabricated-citation-rejected"]["error_category"] == "FABRICATED_CITATION"
    assert by_id["invalid-severity-rejected"]["error_category"] == "STATUS_POLICY_INVALID"


def test_harness_accepts_fake_provider_without_live_api_calls() -> None:
    evaluation_set = SemanticEvaluationSet.load()
    outputs = {case.case_id: case.candidate_output for case in evaluation_set.cases}

    def response(task: object, packet: object) -> dict[str, object]:
        case_id = task.task_id.removeprefix("evaluation:")
        return outputs[case_id]

    provider = FakeLLMProvider(response)
    metrics = SemanticEvaluationHarness(evaluation_set).run(provider)

    assert len(provider.calls) == 10
    assert metrics.output_validation_accuracy == 1.0
    assert provider.config.is_local_endpoint is True


def test_packet_change_invalidates_evaluation_cache_key() -> None:
    evaluation_set = SemanticEvaluationSet.load()
    case = next(
        value
        for value in evaluation_set.cases
        if value.case_id == "cache-invalidated-by-packet-change"
    )
    original = case.packet()
    changed = case.packet(variant=True)

    original_key = SemanticResultCache.key(
        provider="fake",
        model="evaluation-model",
        prompt_version="requirement_test_alignment.v1",
        packet_hash=original.packet_hash,
    )
    changed_key = SemanticResultCache.key(
        provider="fake",
        model="evaluation-model",
        prompt_version="requirement_test_alignment.v1",
        packet_hash=changed.packet_hash,
    )

    assert original.packet_hash != changed.packet_hash
    assert original_key != changed_key


def test_metrics_expose_false_contradictions_and_fabricated_citations() -> None:
    evaluation_set = SemanticEvaluationSet.load()
    outputs = {case.case_id: case.candidate_output for case in evaluation_set.cases}
    outputs["valid-pass-with-citation"] = {
        **outputs["valid-pass-with-citation"],
        "status": "FAIL",
        "evidence_refs": ["invented-evidence"],
        "contradictions": [
            {
                "summary": "Invented contradiction.",
                "left_evidence_refs": ["invented-left"],
                "right_evidence_refs": ["invented-right"],
            }
        ],
    }

    metrics = SemanticEvaluationHarness(evaluation_set).evaluate(outputs)

    assert metrics.fabricated_citation_rate > 0.0
    assert metrics.false_contradiction_rate > 0.0
    result = next(
        value for value in metrics.case_results if value["case_id"] == "valid-pass-with-citation"
    )
    assert set(result["fabricated_evidence_refs"]) == {
        "invented-evidence",
        "invented-left",
        "invented-right",
    }
