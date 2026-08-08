from __future__ import annotations

from pathlib import Path

from docx import Document as WordDocument

from rift_doc.engine import ValidationEngine
from rift_doc.extractors.docx import extract_docx
from rift_doc.results import Status
from rift_doc.spec import CapstoneSpec

from .conftest import create_docx


def _engine(minimal_spec_path: Path) -> ValidationEngine:
    return ValidationEngine(CapstoneSpec.load(minimal_spec_path))


def test_heading_without_real_content_fails_required_content(minimal_spec_path: Path, tmp_path: Path) -> None:
    path = create_docx(tmp_path / "empty.docx")
    result = _engine(minimal_spec_path).validate(path, "demo")
    finding = next(item for item in result.findings if item.rule_id == "required.content")
    assert finding.status == Status.FAIL
    assert "no real completed content" in finding.message


def test_instruction_only_section_does_not_count_as_content(minimal_spec_path: Path, tmp_path: Path) -> None:
    path = create_docx(tmp_path / "instruction.docx", required_text="[Provide the completed section]")
    result = _engine(minimal_spec_path).validate(path, "demo")
    assert any(item.rule_id == "template.instruction" and item.status == Status.FAIL for item in result.findings)
    assert any(item.rule_id == "required.content" and item.status == Status.FAIL for item in result.findings)


def test_placeholder_embedded_in_real_prose_is_preserved_and_invalid(minimal_spec_path: Path, tmp_path: Path) -> None:
    path = create_docx(tmp_path / "placeholder.docx", required_text="The service handles <Feature Name> correctly.")
    result = _engine(minimal_spec_path).validate(path, "demo")
    finding = next(item for item in result.findings if item.rule_id == "placeholder.unresolved")
    assert finding.status == Status.FAIL
    assert "Feature Name" in finding.evidence[0]["text"]


def test_numbered_equivalent_heading_is_accepted(minimal_spec_path: Path, tmp_path: Path) -> None:
    document = WordDocument()
    document.add_heading("1 Required Section", level=1)
    document.add_paragraph("Completed content")
    document.add_heading("Recommended Section", level=1)
    document.add_paragraph("Recommended content")
    document.add_heading("Conditional Section", level=1)
    document.add_paragraph("Applicable content")
    document.add_heading("Image Section", level=1)
    document.add_paragraph("Image explanation")
    path = tmp_path / "numbered.docx"
    document.save(path)
    result = _engine(minimal_spec_path).validate(path, "demo")
    assert not any(item.rule_id == "required" and item.status == Status.FAIL for item in result.findings)
    assert any(item.rule_id == "required.content" and item.status == Status.PASS for item in result.findings)


def test_unmapped_numbered_heading_is_reviewable(minimal_spec_path: Path, tmp_path: Path) -> None:
    document = WordDocument()
    document.add_paragraph("9.1 Unmapped Section")
    path = tmp_path / "unmapped.docx"
    document.save(path)
    result = _engine(minimal_spec_path).validate(path, "demo")
    assert any(item.rule_id == "heading.unresolved" and item.status == Status.REVIEW_REQUIRED for item in result.findings)


def test_missing_must_and_should_have_different_statuses(minimal_spec_path: Path, tmp_path: Path) -> None:
    document = WordDocument()
    document.add_paragraph("Only unrelated prose")
    path = tmp_path / "missing.docx"
    document.save(path)
    result = _engine(minimal_spec_path).validate(path, "demo")
    assert next(item for item in result.findings if item.rule_id == "required").status == Status.FAIL
    should = next(item for item in result.findings if item.rule_id == "should")
    assert should.status == Status.WARNING
    assert should.severity == "warning"


def test_conditional_unknown_is_review_required(minimal_spec_path: Path, tmp_path: Path) -> None:
    document = WordDocument()
    document.add_heading("Required Section", level=1)
    document.add_paragraph("Completed content")
    path = tmp_path / "conditional-unknown.docx"
    document.save(path)
    result = _engine(minimal_spec_path).validate(path, "demo")
    conditional = next(item for item in result.findings if item.rule_id == "conditional")
    assert conditional.status == Status.REVIEW_REQUIRED


def test_conditional_true_missing_section_fails(minimal_spec_path: Path, tmp_path: Path) -> None:
    document = WordDocument()
    document.add_heading("Required Section", level=1)
    document.add_paragraph("Completed content")
    path = tmp_path / "conditional-true.docx"
    document.save(path)
    spec_path = tmp_path / "conditional-true.yaml"
    spec_path.write_text(
        minimal_spec_path.read_text(encoding="utf-8").replace("type: unknown", "type: always_true"),
        encoding="utf-8",
    )
    result = ValidationEngine(CapstoneSpec.load(spec_path)).validate(path, "demo")
    conditional = next(item for item in result.findings if item.rule_id == "conditional")
    assert conditional.status == Status.FAIL


def test_conditional_explicit_na_is_not_applicable(minimal_spec_path: Path, tmp_path: Path) -> None:
    document = WordDocument()
    document.add_heading("Required Section", level=1)
    document.add_paragraph("Completed content")
    document.add_paragraph("The conditional section is not applicable because this product has no such component.")
    path = tmp_path / "conditional-na.docx"
    document.save(path)
    result = _engine(minimal_spec_path).validate(path, "demo")
    conditional = next(item for item in result.findings if item.rule_id == "conditional")
    assert conditional.status == Status.NOT_APPLICABLE
    assert conditional.evidence[0]["text"].startswith("The conditional section")


def test_image_presence_is_pass_but_semantics_remain_reviewable(minimal_spec_path: Path, tmp_path: Path) -> None:
    path = create_docx(tmp_path / "image.docx", required_text="Completed content", include_image=True)
    result = _engine(minimal_spec_path).validate(path, "demo")
    assert any(item.rule_id == "with_image.evidence.0" and item.status == Status.PASS for item in result.findings)
    assert any(item.rule_id == "with_image.evidence.0.semantic" and item.status == Status.REVIEW_REQUIRED for item in result.findings)


def test_table_with_only_headers_is_not_completed_content(minimal_spec_path: Path, tmp_path: Path) -> None:
    document = WordDocument()
    document.add_heading("Required Section", level=1)
    document.add_paragraph("Content exists")
    document.add_heading("Image Section", level=1)
    table = document.add_table(rows=1, cols=2)
    table.cell(0, 0).text = "Header A"
    table.cell(0, 1).text = "Header B"
    path = tmp_path / "header-table.docx"
    document.save(path)
    # The base contract does not require a table for Image Section.  Verify the
    # normalized table helper directly through the section evidence path by
    # adding a small contract rule in a copy of the fixture contract.
    spec_text = minimal_spec_path.read_text(encoding="utf-8").replace(
        "        content: true\n        evidence:\n          - type: image",
        "        content: true\n        evidence:\n          - type: table\n            required: true\n          - type: image",
    )
    spec_path = tmp_path / "table-spec.yaml"
    spec_path.write_text(spec_text, encoding="utf-8")
    result = ValidationEngine(CapstoneSpec.load(spec_path)).validate(path, "demo")
    finding = next(item for item in result.findings if item.rule_id == "with_image.evidence.0")
    assert finding.status == Status.FAIL
