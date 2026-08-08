"""Validation statuses, findings, and serialization."""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Iterable

from .model import SourceLocation


class Status(str, Enum):
    PASS = "PASS"
    FAIL = "FAIL"
    WARNING = "WARNING"
    REVIEW_REQUIRED = "REVIEW_REQUIRED"
    SKIPPED = "SKIPPED"
    NOT_APPLICABLE = "NOT_APPLICABLE"


@dataclass
class Finding:
    status: Status
    severity: str
    rule_id: str
    report: str
    section: str | None
    location: str | None
    message: str
    evidence: list[Any] = field(default_factory=list)
    source_requirement: str | None = None
    spec_path: str | None = None
    metadata: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_location(
        cls,
        *,
        status: Status,
        severity: str,
        rule_id: str,
        report: str,
        section: str | None,
        location: SourceLocation | str | None,
        message: str,
        evidence: Iterable[Any] = (),
        source_requirement: str | None = None,
        spec_path: str | None = None,
        metadata: dict[str, Any] | None = None,
    ) -> "Finding":
        if isinstance(location, SourceLocation):
            display_location = location.display()
        else:
            display_location = location
        return cls(
            status=status,
            severity=severity,
            rule_id=rule_id,
            report=report,
            section=section,
            location=display_location,
            message=message,
            evidence=list(evidence),
            source_requirement=source_requirement,
            spec_path=spec_path,
            metadata=metadata or {},
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "status": self.status.value,
            "severity": self.severity,
            "rule_id": self.rule_id,
            "report": self.report,
            "section": self.section,
            "location": _json_value(self.location),
            "message": self.message,
            "evidence": [_json_value(item) for item in self.evidence],
            "source_requirement": self.source_requirement,
            "spec_path": self.spec_path,
            "metadata": _json_value(self.metadata),
        }


@dataclass
class ValidationResult:
    source_path: str
    report: str
    format: str
    findings: list[Finding] = field(default_factory=list)
    metadata: dict[str, Any] = field(default_factory=dict)

    def add(self, finding: Finding) -> Finding:
        self.findings.append(finding)
        return finding

    @property
    def counts(self) -> dict[str, int]:
        counter = Counter(finding.status.value for finding in self.findings)
        return {status.value: counter.get(status.value, 0) for status in Status}

    @property
    def has_errors(self) -> bool:
        return any(finding.status == Status.FAIL and finding.severity == "error" for finding in self.findings)

    @property
    def has_strict_issues(self) -> bool:
        return any(
            finding.status in {Status.FAIL, Status.WARNING, Status.REVIEW_REQUIRED}
            for finding in self.findings
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "source_path": self.source_path,
            "report": self.report,
            "format": self.format,
            "counts": self.counts,
            "findings": [finding.to_dict() for finding in self.findings],
            "metadata": _json_value(self.metadata),
        }


def _json_value(value: Any) -> Any:
    if isinstance(value, Enum):
        return value.value
    if isinstance(value, SourceLocation):
        return value.to_dict()
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, dict):
        return {str(key): _json_value(item) for key, item in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [_json_value(item) for item in value]
    return str(value)
