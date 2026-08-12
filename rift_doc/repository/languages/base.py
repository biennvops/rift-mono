"""Common interfaces and helpers for repository language adapters."""

from __future__ import annotations

from dataclasses import dataclass, field
import re
from typing import Iterable, Protocol

from ..model import EvidenceKind, RepositoryEvidence, RepositoryLineRange
from ...trace_model import normalize_identifier


_IDENTIFIER_RE = re.compile(r"(?<![A-Za-z0-9])([A-Za-z]{1,16}\s*[-_./]?\s*\d{1,8})(?![A-Za-z0-9])")


@dataclass
class AdapterResult:
    symbols: list[RepositoryEvidence] = field(default_factory=list)
    tests: list[RepositoryEvidence] = field(default_factory=list)


class LanguageAdapter(Protocol):
    language: str
    suffixes: frozenset[str]

    def scan(self, path: str, text: str) -> AdapterResult:
        ...


def evidence_for_symbol(
    *,
    path: str,
    line: int,
    symbol: str,
    language: str,
    signature: str,
    kind: EvidenceKind = EvidenceKind.SYMBOL,
    metadata: dict[str, object] | None = None,
) -> RepositoryEvidence:
    values = {"language": language, "identifiers": extract_identifiers(signature)}
    values.update(metadata or {})
    return RepositoryEvidence(
        evidence_id=f"{kind.value.casefold()}:{path}:{line}:{symbol}",
        kind=kind,
        path=path,
        line_range=RepositoryLineRange(line),
        symbol=symbol,
        module=module_for_path(path),
        metadata=values,
        excerpt_or_signature=" ".join(signature.split()),
    )


def extract_identifiers(value: str) -> list[str]:
    return list(
        dict.fromkeys(
            normalized
            for match in _IDENTIFIER_RE.finditer(str(value or ""))
            for normalized in [normalize_identifier(match.group(1))]
            if normalized
        )
    )


def line_number(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def source_line(text: str, line: int) -> str:
    lines = text.splitlines()
    return lines[line - 1] if 0 < line <= len(lines) else ""


def module_for_path(path: str) -> str | None:
    parts = path.replace("\\", "/").split("/")
    if len(parts) <= 1:
        return None
    for marker in ("lib", "src", "test", "tests"):
        if marker in parts:
            index = parts.index(marker)
            if index:
                return "/".join(parts[:index])
    return "/".join(parts[:-1])


def deduplicate(items: Iterable[RepositoryEvidence]) -> list[RepositoryEvidence]:
    result: list[RepositoryEvidence] = []
    seen: set[str] = set()
    for item in items:
        if item.evidence_id in seen:
            continue
        seen.add(item.evidence_id)
        result.append(item)
    return result
