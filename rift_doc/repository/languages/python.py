"""Python declaration and pytest/unittest definition indexing."""

from __future__ import annotations

import ast

from ..model import EvidenceKind, RepositoryLineRange, RepositoryEvidence
from .base import AdapterResult, extract_identifiers, module_for_path


class PythonAdapter:
    language = "python"
    suffixes = frozenset({".py"})

    def scan(self, path: str, text: str) -> AdapterResult:
        result = AdapterResult()
        try:
            tree = ast.parse(text)
        except SyntaxError:
            return result
        lines = text.splitlines()
        for node in ast.walk(tree):
            if not isinstance(node, (ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
                continue
            line = node.lineno
            signature = lines[line - 1].strip() if line <= len(lines) else node.name
            evidence = RepositoryEvidence(
                evidence_id=f"symbol:{path}:{line}:{node.name}",
                kind=EvidenceKind.SYMBOL,
                path=path,
                line_range=RepositoryLineRange(line),
                symbol=node.name,
                module=module_for_path(path),
                metadata={
                    "language": self.language,
                    "symbol_type": "class" if isinstance(node, ast.ClassDef) else "function",
                    "identifiers": extract_identifiers(signature),
                },
                excerpt_or_signature=signature,
            )
            result.symbols.append(evidence)
            if not isinstance(node, ast.ClassDef) and node.name.startswith("test_"):
                result.tests.append(
                    RepositoryEvidence(
                        evidence_id=f"test:{path}:{line}:{node.name}",
                        kind=EvidenceKind.TEST,
                        path=path,
                        line_range=RepositoryLineRange(line),
                        symbol=node.name,
                        module=module_for_path(path),
                        metadata={
                            "language": self.language,
                            "framework": "pytest_or_unittest",
                            "test_name": node.name,
                            "identifiers": extract_identifiers(signature),
                        },
                        excerpt_or_signature=signature,
                    )
                )
        return result
