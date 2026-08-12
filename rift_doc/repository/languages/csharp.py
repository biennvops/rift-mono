"""C# symbol and xUnit/NUnit/MSTest definition indexing."""

from __future__ import annotations

import re

from ..model import EvidenceKind
from .base import AdapterResult, deduplicate, evidence_for_symbol


_TYPE_RE = re.compile(
    r"\b(?:class|interface|record(?:\s+(?:class|struct))?|struct|enum)\s+([A-Za-z_]\w*)"
)
_METHOD_RE = re.compile(
    r"^\s*(?:public|private|protected|internal|static|virtual|override|abstract|sealed|async|extern|new|partial|unsafe|\s)+"
    r"(?:[A-Za-z_]\w*(?:[.<>,?\[\]\s]+)?|void)\s+([A-Za-z_]\w*)\s*(?:<[^;{]+>)?\s*\("
)
_TEST_ATTRIBUTE_RE = re.compile(r"\[(?:Fact|Theory|Test|TestCase(?:\([^]]*\))?|TestMethod)\b")


class CSharpAdapter:
    language = "csharp"
    suffixes = frozenset({".cs"})

    def scan(self, path: str, text: str) -> AdapterResult:
        result = AdapterResult()
        context: list[str] = []
        test_attribute = False
        for line_number, line in enumerate(text.splitlines(), start=1):
            stripped = line.strip()
            if stripped.startswith("//") or stripped.startswith("///") or stripped.startswith("["):
                context.append(stripped)
                context = context[-4:]
            elif stripped:
                context = context[-2:]

            if _TEST_ATTRIBUTE_RE.search(line):
                test_attribute = True

            type_match = _TYPE_RE.search(line)
            if type_match:
                symbol = type_match.group(1)
                result.symbols.append(
                    evidence_for_symbol(
                        path=path,
                        line=line_number,
                        symbol=symbol,
                        language=self.language,
                        signature=" ".join([*context, stripped]),
                        metadata={"symbol_type": "type"},
                    )
                )

            method_match = _METHOD_RE.search(line)
            if not method_match:
                continue
            symbol = method_match.group(1)
            signature = " ".join([*context, stripped])
            result.symbols.append(
                evidence_for_symbol(
                    path=path,
                    line=line_number,
                    symbol=symbol,
                    language=self.language,
                    signature=signature,
                    metadata={"symbol_type": "method"},
                )
            )
            if test_attribute:
                framework = "xunit" if re.search(r"\[(?:Fact|Theory)\b", signature) else "nunit_or_mstest"
                result.tests.append(
                    evidence_for_symbol(
                        path=path,
                        line=line_number,
                        symbol=symbol,
                        language=self.language,
                        signature=signature,
                        kind=EvidenceKind.TEST,
                        metadata={"framework": framework, "test_name": symbol},
                    )
                )
            test_attribute = False
            context.clear()
        result.symbols = deduplicate(result.symbols)
        result.tests = deduplicate(result.tests)
        return result
