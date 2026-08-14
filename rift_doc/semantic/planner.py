"""Selective semantic-review task generation over deterministic audit evidence."""

from __future__ import annotations

import re
from typing import Any, Iterable

from ..document_set import DocumentSet, _domain_alias
from ..extractors.docx import normalize_heading
from ..model import Document, Section
from ..results import Finding, Status
from ..spec import CapstoneSpec, SectionRule
from ..trace_model import TraceEntity, TraceGraph, TraceIndex, normalize_name
from .model import SemanticReviewTask, SemanticTaskType, stable_id


_DEFAULT_ALLOWED_STATUSES: dict[SemanticTaskType, tuple[str, ...]] = {
    SemanticTaskType.CONTENT_SUFFICIENCY: ("PASS", "FAIL", "WARNING", "REVIEW_REQUIRED"),
    SemanticTaskType.CROSS_DOCUMENT_CONSISTENCY: ("PASS", "FAIL", "REVIEW_REQUIRED"),
    SemanticTaskType.REQUIREMENT_TEST_ALIGNMENT: ("PASS", "FAIL", "REVIEW_REQUIRED"),
    SemanticTaskType.DESIGN_REQUIREMENT_ALIGNMENT: ("PASS", "FAIL", "REVIEW_REQUIRED"),
    SemanticTaskType.CLAIM_REPOSITORY_ALIGNMENT: ("PASS", "FAIL", "REVIEW_REQUIRED"),
    SemanticTaskType.FINAL_REPORT_FRESHNESS: ("PASS", "FAIL", "REVIEW_REQUIRED"),
    SemanticTaskType.QUALITY_OBJECTIVE_EVALUATION: ("PASS", "FAIL", "REVIEW_REQUIRED"),
    SemanticTaskType.USER_GUIDE_COVERAGE: ("PASS", "FAIL", "WARNING", "REVIEW_REQUIRED"),
    SemanticTaskType.ERROR_ABNORMAL_CASE_COVERAGE: ("PASS", "FAIL", "REVIEW_REQUIRED"),
}


class SemanticReviewPlanner:
    """Generate only configured or deterministically-triggered bounded tasks."""

    def __init__(self, spec: CapstoneSpec) -> None:
        self.spec = spec

    def plan(
        self,
        document_set: DocumentSet,
        graph: TraceGraph,
        deterministic_findings: Iterable[Finding],
        *,
        task_types: Iterable[SemanticTaskType | str] | None = None,
        entity_query: str | None = None,
        max_tasks: int = 50,
    ) -> tuple[list[SemanticReviewTask], int]:
        if max_tasks < 0:
            raise ValueError("max_tasks cannot be negative")
        findings = list(deterministic_findings)
        tasks: list[SemanticReviewTask] = []
        covered_findings: set[str] = set()
        for raw_rule in self.spec.semantic_review_rules:
            generation = str(raw_rule.get("generation", "findings")).casefold()
            if generation == "sections":
                tasks.extend(self._section_tasks(raw_rule, document_set))
            elif generation == "relationships":
                tasks.extend(self._relationship_tasks(raw_rule, graph))
            elif generation in {"findings", "repository_findings"}:
                generated = self._finding_tasks(raw_rule, findings)
                tasks.extend(generated)
                covered_findings.update(
                    str(task.metadata.get("finding_reference"))
                    for task in generated
                    if task.metadata.get("finding_reference")
                )

        for finding in findings:
            reference = finding_reference(finding)
            if reference in covered_findings or finding.status != Status.REVIEW_REQUIRED:
                continue
            task_type = _task_type_for_finding(finding)
            if task_type is None:
                continue
            tasks.append(self._task_from_finding(finding, task_type))

        tasks = _deduplicate_tasks(tasks)
        selected_types = _task_type_values(task_types)
        if selected_types is not None:
            tasks = [task for task in tasks if task.task_type in selected_types]
        if entity_query:
            query = normalize_name(entity_query)
            tasks = [task for task in tasks if _task_matches_query(task, query)]
        proposed = len(tasks)
        return tasks[:max_tasks], max(0, proposed - max_tasks)

    def _section_tasks(
        self,
        raw_rule: dict[str, Any],
        document_set: DocumentSet,
    ) -> list[SemanticReviewTask]:
        domain = _domain_alias(str(raw_rule.get("source_domain", "")))
        configured_ids = _string_values(raw_rule.get("section_rules", raw_rule.get("section_rule", [])))
        section_rules = [
            rule
            for rule in self.spec.iter_section_rules(domain)
            if not configured_ids or rule.rule_id in configured_ids
        ]
        tasks: list[SemanticReviewTask] = []
        for artifact in document_set.domain_artifacts(domain):
            if not isinstance(artifact.document, Document):
                continue
            for section_rule in section_rules:
                for section in artifact.document.all_sections():
                    if not _section_matches_rule(section, section_rule):
                        continue
                    source_ref = f"document:{domain}:{artifact.document.source_path}:{section.path}"
                    contract_ref = f"contract:{section_rule.path}"
                    metadata = self._rule_metadata(raw_rule)
                    metadata.update(
                        {
                            "generation": "sections",
                            "source_domain": domain,
                            "source_path": artifact.document.source_path,
                            "source_section": section.path,
                            "section_rule_id": section_rule.rule_id,
                            "section_rule_path": section_rule.path,
                            "contract_requirement": section_rule.data.get("source_requirement")
                            or self.spec.report(domain).get("source_requirement"),
                            "requirement": section_rule.data.get("requirement", "MUST"),
                        }
                    )
                    question = _render_question(
                        str(raw_rule.get("question", "Is the supplied section semantically sufficient for its contract requirement?")),
                        report=domain,
                        section=section.path or section.title,
                        source_name=section.title,
                        target_names="",
                    )
                    tasks.append(
                        self._task(
                            raw_rule,
                            question=question,
                            evidence_refs=(source_ref, contract_ref),
                            metadata=metadata,
                        )
                    )
        return tasks

    def _relationship_tasks(
        self,
        raw_rule: dict[str, Any],
        graph: TraceGraph,
    ) -> list[SemanticReviewTask]:
        source_domain = _domain_alias(str(raw_rule.get("source_domain", "")))
        target_domain = _domain_alias(str(raw_rule.get("target_domain", "")))
        source_kinds = set(_string_values(raw_rule.get("source_kinds", raw_rule.get("source_kind", []))))
        target_kinds = tuple(_string_values(raw_rule.get("target_kinds", raw_rule.get("target_kind", []))))
        sources = [
            entity
            for entity in graph.nodes
            if _domain_alias(str(entity.metadata.get("domain", entity.source_report))) == source_domain
            and (not source_kinds or entity.kind in source_kinds)
        ]
        target_pool = [
            entity
            for entity in graph.nodes
            if _domain_alias(str(entity.metadata.get("domain", entity.source_report))) == target_domain
            and (not target_kinds or entity.kind in target_kinds)
        ]
        index = TraceIndex(graph)
        tasks: list[SemanticReviewTask] = []
        for source in sources:
            match = index.match(
                source,
                target_domain=target_domain,
                target_kinds=target_kinds or tuple({item.kind for item in target_pool}),
            )
            candidates = list(match.candidates)
            if not candidates and raw_rule.get("review_unmatched", False):
                candidates = _semantic_candidates(source, target_pool)
            candidate_limit = max(1, int(raw_rule.get("max_candidates", 3)))
            candidates = candidates[:candidate_limit]
            if not candidates:
                continue
            source_ref = f"trace:{source.entity_id}"
            target_refs = tuple(f"trace:{candidate.entity_id}" for candidate in candidates)
            metadata = self._rule_metadata(raw_rule)
            metadata.update(
                {
                    "generation": "relationships",
                    "source_domain": source_domain,
                    "target_domain": target_domain,
                    "source_entity_id": source.entity_id,
                    "source_entity_name": source.canonical_name,
                    "target_entity_ids": [candidate.entity_id for candidate in candidates],
                    "target_entity_names": [candidate.canonical_name for candidate in candidates],
                    "deterministic_match_method": match.method.value,
                    "requirement": raw_rule.get("requirement", "MUST"),
                }
            )
            question = _render_question(
                str(raw_rule.get("question", "Are the supplied source and target claims semantically aligned?")),
                report=source_domain,
                section=source.source_section or "",
                source_name=source.canonical_name,
                target_names=", ".join(candidate.canonical_name for candidate in candidates),
            )
            tasks.append(
                self._task(
                    raw_rule,
                    question=question,
                    evidence_refs=(source_ref, *target_refs),
                    metadata=metadata,
                )
            )
        return tasks

    def _finding_tasks(
        self,
        raw_rule: dict[str, Any],
        findings: list[Finding],
    ) -> list[SemanticReviewTask]:
        validators = set(_string_values(raw_rule.get("finding_validators", [])))
        statuses = set(_string_values(raw_rule.get("finding_statuses", ["REVIEW_REQUIRED"])))
        prefixes = tuple(_string_values(raw_rule.get("finding_rule_prefixes", [])))
        reports = {_domain_alias(value) for value in _string_values(raw_rule.get("finding_reports", []))}
        tasks: list[SemanticReviewTask] = []
        for finding in findings:
            if validators and finding.validator not in validators:
                continue
            if statuses and finding.status.value not in statuses:
                continue
            if prefixes and not finding.rule_id.startswith(prefixes):
                continue
            if reports and _domain_alias(finding.report) not in reports:
                continue
            task_type = _task_type(raw_rule.get("task_type"))
            task = self._task_from_finding(finding, task_type, raw_rule=raw_rule)
            tasks.append(task)
        return tasks

    def _task_from_finding(
        self,
        finding: Finding,
        task_type: SemanticTaskType,
        *,
        raw_rule: dict[str, Any] | None = None,
    ) -> SemanticReviewTask:
        raw_rule = raw_rule or {
            "id": f"SEM-{finding.rule_id}",
            "task_type": task_type.value,
        }
        reference = finding_reference(finding)
        evidence_refs = [f"finding:{reference}"]
        source = finding.source_entity if isinstance(finding.source_entity, dict) else None
        if source and source.get("entity_id"):
            evidence_refs.append(f"trace:{source['entity_id']}")
        for candidate in finding.candidate_entities:
            if isinstance(candidate, dict) and candidate.get("entity_id"):
                evidence_refs.append(f"trace:{candidate['entity_id']}")
            elif isinstance(candidate, dict) and candidate.get("evidence_id"):
                evidence_refs.append(f"repository:{candidate['evidence_id']}")
        metadata = self._rule_metadata(raw_rule)
        metadata.update(
            {
                "generation": "findings",
                "finding_reference": reference,
                "trigger_rule_id": finding.rule_id,
                "source_domain": finding.report,
                "source_section": finding.section,
                "target_domain": finding.target_domain,
                "requirement": finding.metadata.get("requirement", "MUST"),
                "requires_visual": finding.rule_id.endswith(".semantic")
                and any(isinstance(item, dict) and item.get("relationship_id") for item in finding.evidence),
            }
        )
        default_question = (
            f"Review the bounded evidence for deterministic finding {finding.rule_id}: {finding.message} "
            "Does the evidence resolve the semantic uncertainty?"
        )
        question = _render_question(
            str(raw_rule.get("question", default_question)),
            report=finding.report,
            section=finding.section or "",
            source_name=str(source.get("canonical_name", "")) if source else finding.message,
            target_names=", ".join(
                str(item.get("canonical_name", item.get("symbol", "")))
                for item in finding.candidate_entities
                if isinstance(item, dict)
            ),
        )
        return self._task(
            raw_rule,
            question=question,
            evidence_refs=tuple(dict.fromkeys(evidence_refs)),
            metadata=metadata,
        )

    def _task(
        self,
        raw_rule: dict[str, Any],
        *,
        question: str,
        evidence_refs: tuple[str, ...],
        metadata: dict[str, Any],
    ) -> SemanticReviewTask:
        rule_id = str(raw_rule.get("id", raw_rule.get("rule_id", "SEM-UNNAMED")))
        task_type = _task_type(raw_rule.get("task_type"))
        required_context = tuple(_string_values(raw_rule.get("required_context", [])))
        task_id = stable_id("semantic-task", rule_id, task_type.value, evidence_refs, question)
        return SemanticReviewTask(
            task_id=task_id,
            rule_id=rule_id,
            task_type=task_type,
            question=question,
            evidence_refs=evidence_refs,
            required_context=required_context,
            expected_output_schema=str(raw_rule.get("expected_output_schema", "semantic-result.v1")),
            metadata=metadata,
        )

    @staticmethod
    def _rule_metadata(raw_rule: dict[str, Any]) -> dict[str, Any]:
        task_type = _task_type(raw_rule.get("task_type"))
        allowed = _string_values(raw_rule.get("allowed_statuses", _DEFAULT_ALLOWED_STATUSES[task_type]))
        return {
            "prompt_version": str(raw_rule.get("prompt_version", _default_prompt(task_type))),
            "allowed_statuses": allowed,
            "rule_requirement": str(raw_rule.get("requirement", "MUST")).upper(),
            "requires_visual": bool(raw_rule.get("requires_visual", False)),
            "requires_two_sided_contradiction": task_type
            in {
                SemanticTaskType.CROSS_DOCUMENT_CONSISTENCY,
                SemanticTaskType.REQUIREMENT_TEST_ALIGNMENT,
                SemanticTaskType.DESIGN_REQUIREMENT_ALIGNMENT,
                SemanticTaskType.CLAIM_REPOSITORY_ALIGNMENT,
                SemanticTaskType.FINAL_REPORT_FRESHNESS,
            },
        }


def finding_reference(finding: Finding) -> str:
    return stable_id(
        "finding",
        finding.validator,
        finding.rule_id,
        finding.report,
        finding.section,
        finding.location,
        finding.message,
    )


def _task_type(value: Any) -> SemanticTaskType:
    try:
        return SemanticTaskType(str(value).upper())
    except ValueError as exc:
        raise ValueError(f"unknown semantic task type {value!r}") from exc


def _task_type_values(
    values: Iterable[SemanticTaskType | str] | None,
) -> set[SemanticTaskType] | None:
    if values is None:
        return None
    return {_task_type(value.value if isinstance(value, SemanticTaskType) else value) for value in values}


def _task_type_for_finding(finding: Finding) -> SemanticTaskType | None:
    if finding.validator == "repository_evidence":
        return SemanticTaskType.CLAIM_REPOSITORY_ALIGNMENT
    if finding.rule_id.startswith("R7-FRESHNESS"):
        return SemanticTaskType.FINAL_REPORT_FRESHNESS
    if finding.rule_id.startswith("XT-005"):
        return SemanticTaskType.QUALITY_OBJECTIVE_EVALUATION
    if finding.validator == "cross_document":
        return SemanticTaskType.CROSS_DOCUMENT_CONSISTENCY
    if finding.validator == "structural" and (
        finding.rule_id.endswith(".semantic")
        or "conditional" in finding.message.casefold()
        or "semantic" in finding.message.casefold()
    ):
        return SemanticTaskType.CONTENT_SUFFICIENCY
    return None


def _section_matches_rule(section: Section, rule: SectionRule) -> bool:
    match = rule.data.get("match")
    if isinstance(match, dict) and match.get("regex"):
        try:
            if not re.search(str(match["regex"]), section.title, re.IGNORECASE):
                return False
        except re.error:
            return False
        excluded = [str(value).casefold() for value in match.get("exclude_prefixes", [])]
        return not any(section.title.casefold().startswith(prefix) for prefix in excluded)
    accepted = {normalize_heading(str(rule.data.get("title", "")))}
    accepted.update(
        normalize_heading(str(alias))
        for alias in rule.data.get("aliases", [])
        if isinstance(alias, str)
    )
    return bool(section.normalized_title and section.normalized_title in accepted)


def _semantic_candidates(source: TraceEntity, targets: list[TraceEntity]) -> list[TraceEntity]:
    source_tokens = set(normalize_name(" ".join(source.comparison_names)).split())
    ranked: list[tuple[float, str, TraceEntity]] = []
    for target in targets:
        target_tokens = set(normalize_name(" ".join(target.comparison_names)).split())
        overlap = source_tokens.intersection(target_tokens)
        if not overlap:
            continue
        score = len(overlap) / max(1, len(source_tokens.union(target_tokens)))
        ranked.append((score, target.entity_id, target))
    ranked.sort(key=lambda item: (-item[0], item[1]))
    return [item[2] for item in ranked]


def _deduplicate_tasks(tasks: list[SemanticReviewTask]) -> list[SemanticReviewTask]:
    result: list[SemanticReviewTask] = []
    seen: set[tuple[Any, ...]] = set()
    for task in tasks:
        if task.task_type == SemanticTaskType.CONTENT_SUFFICIENCY and task.metadata.get("source_section"):
            key = (
                task.task_type.value,
                task.metadata.get("source_domain"),
                task.metadata.get("source_section"),
            )
        else:
            key = (
                task.task_type.value,
                task.metadata.get("source_path"),
                task.metadata.get("source_section"),
                task.metadata.get("source_entity_id"),
                tuple(task.metadata.get("target_entity_ids", [])),
                task.metadata.get("finding_reference"),
            )
        if key in seen:
            continue
        seen.add(key)
        result.append(task)
    return result


def _task_matches_query(task: SemanticReviewTask, query: str) -> bool:
    if not query:
        return True
    values: list[Any] = [task.question, task.rule_id, *task.evidence_refs]
    for key in (
        "source_entity_id",
        "source_entity_name",
        "source_section",
        "source_domain",
        "target_domain",
    ):
        values.append(task.metadata.get(key))
    values.extend(task.metadata.get("target_entity_ids", []))
    values.extend(task.metadata.get("target_entity_names", []))
    return any(query in normalize_name(str(value)) for value in values if value)


def _string_values(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        return [value]
    if isinstance(value, (list, tuple, set)):
        return [str(item) for item in value if str(item)]
    return [str(value)]


def _render_question(template: str, **values: str) -> str:
    class _SafeValues(dict[str, str]):
        def __missing__(self, key: str) -> str:
            return "{" + key + "}"

    return template.format_map(_SafeValues(values))


def _default_prompt(task_type: SemanticTaskType) -> str:
    if task_type == SemanticTaskType.CONTENT_SUFFICIENCY:
        return "content_sufficiency.v1"
    if task_type in {
        SemanticTaskType.REQUIREMENT_TEST_ALIGNMENT,
        SemanticTaskType.DESIGN_REQUIREMENT_ALIGNMENT,
        SemanticTaskType.ERROR_ABNORMAL_CASE_COVERAGE,
        SemanticTaskType.QUALITY_OBJECTIVE_EVALUATION,
        SemanticTaskType.USER_GUIDE_COVERAGE,
    }:
        return "requirement_test_alignment.v1"
    if task_type == SemanticTaskType.CLAIM_REPOSITORY_ALIGNMENT:
        return "repository_alignment.v1"
    return "cross_document_consistency.v1"
