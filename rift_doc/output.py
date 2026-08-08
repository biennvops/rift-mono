"""Human-readable and machine-readable validation output."""

from __future__ import annotations

import json
from typing import Any

from .engine import aggregate_results
from .model import SourceLocation
from .results import Finding, Status, ValidationResult


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
        for finding in findings:
            lines.extend(_render_finding(finding))
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
    return lines
