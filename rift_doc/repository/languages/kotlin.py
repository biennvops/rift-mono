"""Kotlin declaration and JUnit test definition indexing."""

from __future__ import annotations

import re

from ..model import EvidenceKind
from .base import AdapterResult, deduplicate, evidence_for_symbol


_DECLARATION_RE = re.compile(
    r"\b(?:class|interface|object|enum\s+class)\s+([A-Za-z_]\w*)"
    r"|\bfun\s+(?:([A-Za-z_]\w*)|`([^`]+)`)"
)
_TEST_RE = re.compile(r"@Test\b")


class KotlinAdapter:
    language = "kotlin"
    suffixes = frozenset({".kt", ".kts"})

    def scan(self, path: str, text: str) -> AdapterResult:
        result = AdapterResult()
        test_attribute = False
        for line_number, line in enumerate(text.splitlines(), start=1):
            test_attribute = test_attribute or bool(_TEST_RE.search(line))
            for match in _DECLARATION_RE.finditer(line):
                symbol = match.group(1) or match.group(2) or match.group(3)
                is_function = match.group(2) is not None or match.group(3) is not None
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
                if test_attribute and is_function:
                    result.tests.append(
                        evidence_for_symbol(
                            path=path,
                            line=line_number,
                            symbol=symbol,
                            language=self.language,
                            signature=line,
                            kind=EvidenceKind.TEST,
                            metadata={"framework": "junit", "test_name": symbol},
                        )
                    )
                    test_attribute = False
        result.symbols = deduplicate(result.symbols)
        result.tests = deduplicate(result.tests)
        return result
