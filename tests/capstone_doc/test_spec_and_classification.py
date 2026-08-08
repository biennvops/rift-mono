from __future__ import annotations

from pathlib import Path

import pytest

from rift_doc.classification import ContentClassifier
from rift_doc.extractors.docx import normalize_heading
from rift_doc.spec import CapstoneSpec, SpecValidationError


def test_spec_loads_and_preserves_unknown_fields() -> None:
    spec = CapstoneSpec.load("capstone-doc-spec.v0.1.yaml")
    assert spec.version == "0.1.0"
    assert len(spec.reports) == 7
    assert spec.workbook("report5_unit_test")["purpose"] == "Unit-test case specification and tracking."
    assert spec.source_ambiguities[0]["id"] == "OPEN-001"
    assert spec.source_ambiguities[0]["status"] == "resolved"


def test_invalid_spec_reports_contract_path(tmp_path: Path) -> None:
    path = tmp_path / "invalid.yaml"
    path.write_text(
        """\
$schema: capstone-doc-spec.schema.json
spec_version: test
source: {authority: test, documents: []}
classification: {}
reports:
  demo:
    title: Demo
    sections:
      bad:
        title: Bad
        requirement: INVALID
workbooks: {}
source_ambiguities: []
""",
        encoding="utf-8",
    )
    with pytest.raises(SpecValidationError) as error:
        CapstoneSpec.load(path)
    assert "$.reports.demo.sections.bad.requirement" in str(error.value)


def test_heading_normalization_is_numbering_only() -> None:
    assert normalize_heading("3. Functional Requirements") == "functional requirements"
    assert normalize_heading("3 Functional Requirements") == "functional requirements"
    assert normalize_heading("Functional Requirements") == "functional requirements"
    assert normalize_heading("Functionally Required") != "functional requirements"


def test_classifier_distinguishes_empty_placeholder_instruction_and_sample() -> None:
    classifier = ContentClassifier.from_config(
        {
            "sample_fingerprints": [
                {"id": "known", "pattern": r"\bOfficial Sample\b"},
            ]
        }
    )
    assert classifier.classify("   ").classification.value == "empty"
    assert classifier.classify("real project prose").classification.value == "real_content"
    assert classifier.classify("real prose <Feature Name> remains").classification.value == "placeholder"
    assert classifier.classify("<Project Name>").classification.value == "placeholder"
    assert classifier.classify("[Provide the diagram]").classification.value == "template_instruction"
    assert classifier.classify("[a legitimate bracketed project label]").classification.value == "real_content"
    assert classifier.classify("Official Sample").classification.value == "sample_residue"
    assert classifier.classify("real prose Official Sample").classification.value == "sample_residue"


def test_source_ambiguities_are_available_to_consumers() -> None:
    spec = CapstoneSpec.load("capstone-doc-spec.v0.1.yaml")
    ids = {item["id"] for item in spec.source_ambiguities}
    assert {"report7_naming_inconsistency", "report4_class_specifications_no_skeleton_heading"} <= ids
