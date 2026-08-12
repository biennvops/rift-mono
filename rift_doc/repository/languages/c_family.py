"""Java, C, C++, and Objective-C declaration indexing used by Rift hosts."""

from __future__ import annotations

import re

from .base import AdapterResult, deduplicate, evidence_for_symbol


_JAVA_RE = re.compile(r"\b(?:class|interface|enum|record)\s+([A-Za-z_]\w*)|\b(?:public|protected|private|static|final|synchronized|native|abstract|\s)+[\w<>,.?\[\]]+\s+([A-Za-z_]\w*)\s*\(")
_CLIKE_RE = re.compile(r"^\s*(?:[A-Za-z_]\w*(?:\s*[*&]\s*|\s+))+([A-Za-z_]\w*)\s*\([^;]*\)\s*(?:\{|$)")
_TYPE_RE = re.compile(r"\b(?:class|struct|enum|namespace)\s+([A-Za-z_]\w*)")


class JavaAdapter:
    language = "java"
    suffixes = frozenset({".java"})

    def scan(self, path: str, text: str) -> AdapterResult:
        result = AdapterResult()
        for line_number, line in enumerate(text.splitlines(), start=1):
            for match in _JAVA_RE.finditer(line):
                symbol = match.group(1) or match.group(2)
                if not symbol or symbol in {"if", "for", "while", "switch", "catch"}:
                    continue
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
        result.symbols = deduplicate(result.symbols)
        return result


class CLikeAdapter:
    language = "c_family"
    suffixes = frozenset({".c", ".cc", ".cpp", ".cxx", ".h", ".hpp", ".m", ".mm"})

    def scan(self, path: str, text: str) -> AdapterResult:
        result = AdapterResult()
        for line_number, line in enumerate(text.splitlines(), start=1):
            matches = [*_TYPE_RE.finditer(line), *_CLIKE_RE.finditer(line)]
            for match in matches:
                symbol = match.group(1)
                if symbol in {"if", "for", "while", "switch", "catch"}:
                    continue
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
        result.symbols = deduplicate(result.symbols)
        return result
