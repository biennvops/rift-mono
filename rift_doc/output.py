"""Human-readable and machine-readable validation output."""

from __future__ import annotations

import json
from typing import Any

from .engine import aggregate_results
from .model import SourceLocation
from .results import Finding, Status, ValidationResult
from .semantic import SemanticPlan


_STATUS_ORDER = {
    Status.FAIL: 0,
    Status.WARNING: 1,
    Status.REVIEW_REQUIRED: 2,
    Status.PASS: 3,
    Status.NOT_APPLICABLE: 4,
    Status.SKIPPED: 5,
}


def render_text(results: list[ValidationResult]) -> str:
    lines: list[str] = []
    for index, result in enumerate(results):
        if index:
            lines.append("")
        lines.append(result.source_path)
        findings = sorted(result.findings, key=lambda finding: _STATUS_ORDER[finding.status])
        repository_findings = [finding for finding in findings if finding.validator == "repository_evidence"]
        semantic_findings = [finding for finding in findings if finding.validator == "semantic_review"]
        regular_findings = [
            finding
            for finding in findings
            if finding.validator not in {"repository_evidence", "semantic_review"}
        ]
        for finding in regular_findings:
            lines.extend(_render_finding(finding))
        if repository_findings:
            lines.append("")
            lines.append("REPOSITORY EVIDENCE")
            lines.append("Repository support checks; this is not an FPT template violation domain.")
            for finding in repository_findings:
                lines.extend(_render_repository_finding(finding))
        if semantic_findings:
            lines.append("")
            lines.append("SEMANTIC REVIEW")
            lines.append("Bounded model review; deterministic findings above remain unchanged.")
            for finding in semantic_findings:
                lines.extend(_render_semantic_finding(finding))
        if result.format == "cross_document":
            lines.extend(_render_trace_summary(result))
        lines.append("")
        lines.append("Summary:")
        for status in Status:
            count = result.counts[status.value]
            lines.append(f"  {status.value}: {count}")
    if len(results) > 1:
        summary = aggregate_results(results)
        lines.append("")
        lines.append("Batch summary:")
        for status in Status:
            lines.append(f"  {status.value}: {summary['counts'][status.value]}")
    return "\n".join(lines)


def render_json(results: list[ValidationResult], *, pretty: bool = True) -> str:
    payload: Any
    if len(results) == 1:
        payload = results[0].to_dict()
    else:
        payload = {
            "results": [result.to_dict() for result in results],
            "summary": aggregate_results(results),
        }
    return json.dumps(payload, indent=2 if pretty else None, ensure_ascii=False, sort_keys=False)


def render_semantic_plan_text(plan: SemanticPlan) -> str:
    lines = [
        "SEMANTIC PLAN",
        "Dry run only; no provider was called.",
        f"Tasks: {len(plan.tasks)} selected / {plan.proposed_task_count} proposed",
        f"Omitted by task limit: {plan.omitted_task_count}",
        f"Estimated bounded input tokens: {plan.estimated_input_tokens}",
    ]
    for task, packet in zip(plan.tasks, plan.packets, strict=True):
        lines.extend(
            [
                "",
                f"{task.task_id}  {task.task_type.value}  {task.rule_id}",
                f"  {task.question}",
                (
                    f"  packet: {packet.packet_id}; evidence={len(packet.all_evidence)}; "
                    f"estimated_tokens={packet.estimated_input_tokens}; "
                    f"truncated={len(packet.truncated_evidence)}; excluded={len(packet.excluded_evidence)}"
                ),
            ]
        )
    return "\n".join(lines)


def render_semantic_plan_json(plan: SemanticPlan, *, pretty: bool = True) -> str:
    return json.dumps(plan.to_dict(), indent=2 if pretty else None, ensure_ascii=False, sort_keys=False)


def _render_trace_summary(result: ValidationResult) -> list[str]:
    lines = ["", "Traceability summary:"]
    coverage = result.metadata.get("coverage", {})
    rendered = False
    for rule_id, entries in (coverage.items() if isinstance(coverage, dict) else ()):
        if not isinstance(entries, list) or not entries:
            continue
        if rule_id == "XT-001":
            lines.append("Feature Traceability")
            lines.append("  Legend: ✓ verified  ✗ required missing  ? review required  N/A not applicable")
            lines.append("  Feature                              " + "  ".join(f"R{index}" for index in range(2, 8)))
            for entry in entries:
                source = entry.get("source", {}) if isinstance(entry, dict) else {}
                name = source.get("canonical_name", source.get("entity_id", "source"))
                links = entry.get("links", {}) if isinstance(entry, dict) else {}
                marks = []
                for domain in ("report2", "report3", "report4", "report5", "report6", "report7"):
                    status = links.get(domain)
                    if status is None:
                        marks.append("—")
                    else:
                        marks.append({"VERIFIED": "✓", "NOT_APPLICABLE": "N/A", "MISSING": "✗", "AMBIGUOUS": "?", "REVIEW_REQUIRED": "?"}.get(str(status), "?"))
                lines.append(f"  {str(name)[:34]:34}  " + "  ".join(marks))
                rendered = True
        else:
            lines.append(f"{rule_id}: {len(entries)} source item(s)")
            for entry in entries[:8]:
                source = entry.get("source", {}) if isinstance(entry, dict) else {}
                links = entry.get("links", {}) if isinstance(entry, dict) else {}
                name = source.get("canonical_name", source.get("entity_id", "source"))
                link_text = ", ".join(f"{domain}={value}" for domain, value in links.items())
                lines.append(f"  - {name}: {link_text}")
                rendered = True
    freshness = result.metadata.get("freshness", [])
    if isinstance(freshness, list) and freshness:
        lines.append(f"Report 7 freshness: {len(freshness)} structured comparison(s)")
        rendered = True
    return lines if rendered else []


def _render_semantic_finding(finding: Finding) -> list[str]:
    label = "REVIEW" if finding.status == Status.REVIEW_REQUIRED else finding.status.value
    location = finding.section or "document"
    lines = [
        f"{label:<7} {finding.report} / {location}",
        f"        {finding.message}",
    ]
    reasoning = finding.metadata.get("reasoning_summary")
    if reasoning and reasoning != finding.message:
        lines.append(f"        rationale: {reasoning}")
    if finding.evidence:
        lines.append("        Evidence:")
        for evidence in finding.evidence[:5]:
            if not isinstance(evidence, dict):
                continue
            evidence_id = evidence.get("evidence_id", "evidence")
            report = evidence.get("report") or "repository"
            section = evidence.get("section_path")
            source_location = evidence.get("source_location")
            if isinstance(source_location, dict):
                source_location = source_location.get("display") or source_location.get("location")
            provenance = f"{report}" + (f" / {section}" if section else "")
            if source_location:
                provenance += f" @ {source_location}"
            lines.append(f"        - {evidence_id}: {provenance}")
    action = finding.metadata.get("recommended_action")
    if action:
        lines.append(f"        action: {action}")
    execution_status = finding.metadata.get("execution_status")
    if execution_status not in {None, "COMPLETED", "CACHED"}:
        lines.append(f"        execution: {execution_status}")
    return lines


def _render_repository_finding(finding: Finding) -> list[str]:
    evidence_status = str(finding.metadata.get("evidence_status", finding.status.value))
    label = "REVIEW" if evidence_status == "REVIEW_REQUIRED" else evidence_status
    source = finding.source_entity if isinstance(finding.source_entity, dict) else {}
    claim_id = source.get("claim_id", source.get("entity_id", "claim"))
    name = source.get("canonical_name", "")
    lines = [f"{label:<18} {claim_id} {name}".rstrip(), f"                    {finding.message}"]
    if finding.location:
        lines.append(f"                    documentation: {finding.report} @ {finding.location}")
    for location in finding.metadata.get("repository_locations", [])[:3]:
        lines.append(f"                    repository: {location}")
    method = finding.metadata.get("match_method")
    if method:
        lines.append(f"                    match: {method}")
    test_states = finding.metadata.get("test_states", [])
    if test_states:
        lines.append(f"                    test evidence: {', '.join(str(value) for value in test_states)}")
    return lines


def _render_finding(finding: Finding) -> list[str]:
    label = "REVIEW" if finding.status == Status.REVIEW_REQUIRED else finding.status.value
    prefix = f"{label:<7}"
    location = finding.section or "document"
    if finding.location:
        location_value = finding.location.display() if isinstance(finding.location, SourceLocation) else finding.location
        location += f" @ {location_value}"
    lines = [f"{prefix} {finding.report} / {location}", f"        {finding.message}"]
    if finding.spec_path:
        lines.append(f"        rule: {finding.rule_id} ({finding.spec_path})")
    if finding.evidence:
        for evidence in finding.evidence[:2]:
            if isinstance(evidence, dict) and "text" in evidence:
                text = " ".join(str(evidence["text"]).split())
                if len(text) > 260:
                    text = text[:257] + "..."
                lines.append(f"        evidence: {text}")
            elif isinstance(evidence, dict) and evidence.get("report"):
                label = evidence.get("name", evidence.get("entity_id", "evidence"))
                location = evidence.get("location")
                lines.append(f"        evidence: {evidence['report']} / {label}" + (f" @ {location}" if location else ""))
    return lines
