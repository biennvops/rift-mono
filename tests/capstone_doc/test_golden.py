from __future__ import annotations

import json
from pathlib import Path

from rift_doc.engine import ValidationEngine
from rift_doc.spec import CapstoneSpec

from .conftest import create_docx


def test_minimal_empty_golden_findings(minimal_spec_path: Path, tmp_path: Path) -> None:
    expected = json.loads((Path(__file__).parent / "golden" / "minimal_empty.expected.json").read_text(encoding="utf-8"))
    path = create_docx(tmp_path / expected["document"])
    result = ValidationEngine(CapstoneSpec.load(minimal_spec_path)).validate(path, expected["report"])
    by_rule = {finding.rule_id: finding.status.value for finding in result.findings}
    for rule_id in expected["must_fail_rules"]:
        assert rule_id in by_rule
    for rule_id, status in expected["must_have_statuses"].items():
        assert by_rule[rule_id] == status
