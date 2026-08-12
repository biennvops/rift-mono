"""Swift declaration and XCTest definition indexing."""

from __future__ import annotations

import re

from ..model import EvidenceKind
from .base import AdapterResult, deduplicate, evidence_for_symbol


_DECLARATION_RE = re.compile(r"\b(?:class|struct|enum|protocol|actor|func)\s+([A-Za-z_]\w*)")


class SwiftAdapter:
    language = "swift"
    suffixes = frozenset({".swift"})

    def scan(self, path: str, text: str) -> AdapterResult:
        result = AdapterResult()
        xctest_file = "XCTest" in text or "/Tests/" in f"/{path}" or path.endswith("Tests.swift")
        for line_number, line in enumerate(text.splitlines(), start=1):
            for match in _DECLARATION_RE.finditer(line):
                symbol = match.group(1)
                result.symbols.append(
                    evidence_for_symbol(
                        path=path,
                        line=line_number,
                        symbol=symbol,
                        language=self.language,
                        signature=line,
                        metadata={"symbol_type": "declaration"},
                    )
                )
                if xctest_file and "func" in line[: match.start(1)] and symbol.startswith("test"):
                    result.tests.append(
                        evidence_for_symbol(
                            path=path,
                            line=line_number,
                            symbol=symbol,
                            language=self.language,
                            signature=line,
                            kind=EvidenceKind.TEST,
                            metadata={"framework": "xctest", "test_name": symbol},
                        )
                    )
        result.symbols = deduplicate(result.symbols)
        result.tests = deduplicate(result.tests)
        return result
