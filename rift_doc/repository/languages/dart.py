"""Dart/Flutter declaration and package:test definition indexing."""

from __future__ import annotations

import re

from ..model import EvidenceKind
from .base import AdapterResult, deduplicate, evidence_for_symbol, line_number, source_line


_DECLARATION_RE = re.compile(
    r"(?m)^\s*(?:abstract\s+|base\s+|final\s+|sealed\s+)?(?:class|enum|mixin|extension|typedef)\s+([A-Za-z_]\w*)"
    r"|^\s*(?:[A-Za-z_]\w*(?:<[^\n=;{}]+>)?[?]?\s+)?([A-Za-z_]\w*)\s*\([^;{}]*\)\s*(?:async\*?|sync\*?)?\s*(?:=>|\{)"
)
_TEST_RE = re.compile(r"\b(?:test|testWidgets)\s*\(\s*(['\"])(.*?)\1", re.DOTALL)


class DartAdapter:
    language = "dart"
    suffixes = frozenset({".dart"})

    def scan(self, path: str, text: str) -> AdapterResult:
        result = AdapterResult()
        for match in _DECLARATION_RE.finditer(text):
            symbol = match.group(1) or match.group(2)
            if not symbol or symbol in {"if", "for", "while", "switch", "catch", "test", "testWidgets", "group", "setUp", "tearDown"}:
                continue
            line = line_number(text, match.start())
            result.symbols.append(
                evidence_for_symbol(
                    path=path,
                    line=line,
                    symbol=symbol,
                    language=self.language,
                    signature=source_line(text, line),
                    metadata={"symbol_type": "declaration"},
                )
            )
        for match in _TEST_RE.finditer(text):
            name = " ".join(match.group(2).split())
            line = line_number(text, match.start())
            result.tests.append(
                evidence_for_symbol(
                    path=path,
                    line=line,
                    symbol=name,
                    language=self.language,
                    signature=source_line(text, line),
                    kind=EvidenceKind.TEST,
                    metadata={
                        "framework": "flutter_test" if match.group(0).lstrip().startswith("testWidgets") else "package:test",
                        "test_name": name,
                    },
                )
            )
        result.symbols = deduplicate(result.symbols)
        result.tests = deduplicate(result.tests)
        return result
