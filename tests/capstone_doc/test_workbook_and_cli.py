from __future__ import annotations

from pathlib import Path

from rift_doc.cli import main
from rift_doc.engine import ValidationEngine
from rift_doc.output import render_json, render_text
from rift_doc.model import Cell, ContentClass, Sheet
from rift_doc.results import Finding, Status, ValidationResult
from rift_doc.spec import CapstoneSpec
from rift_doc.validators.workbook import _real_data_rows

from .conftest import ROOT, SOURCE_TEMPLATES, create_docx


def test_official_project_tracking_template_wbs_samples_fail_completed_content() -> None:
    path = SOURCE_TEMPLATES / "Report3_Project Tracking.xlsx"
    if not path.exists():
        return
    spec = CapstoneSpec.load(ROOT / "capstone-doc-spec.v0.1.yaml")
    engine = ValidationEngine(spec)
    workbook = engine.extract(path, "report3_project_tracking")
    result = engine.validate_normalized(workbook, "report3_project_tracking")
    wbs = next(sheet for sheet in workbook.sheets if sheet.name == "WBS")
    rule = spec.workbook("report3_project_tracking")["sheets"]["WBS"]

    assert wbs.rows[7][1].classification == ContentClass.SAMPLE_RESIDUE
    assert _real_data_rows(wbs, [7], [], rule["allowed_values"]) == set()
    assert any(
        item.rule_id == "sheets[WBS].content" and item.status == Status.FAIL
        for item in result.findings
    )
    assert any(
        item.rule_id == "sample.residue"
        and item.spec_path.endswith("sheets[WBS].sample_row_signatures")
        for item in result.findings
    )


def test_customized_wbs_details_count_as_completed_content() -> None:
    path = SOURCE_TEMPLATES / "Report3_Project Tracking.xlsx"
    if not path.exists():
        return
    spec = CapstoneSpec.load(ROOT / "capstone-doc-spec.v0.1.yaml")
    engine = ValidationEngine(spec)
    workbook = engine.extract(path, "report3_project_tracking")
    wbs = next(sheet for sheet in workbook.sheets if sheet.name == "WBS")
    details = wbs.rows[7][4]
    details.value = "Rift-specific screen behavior and acceptance details."
    details.original_text = str(details.value)

    result = engine.validate_normalized(workbook, "report3_project_tracking")
    rule = spec.workbook("report3_project_tracking")["sheets"]["WBS"]
    assert wbs.rows[7][1].classification == ContentClass.REAL_CONTENT
    assert _real_data_rows(wbs, [7], [], rule["allowed_values"]) == {8}
    assert not any(
        item.rule_id == "sheets[WBS].content" and item.status == Status.FAIL
        for item in result.findings
    )


def test_real_data_rows_exclude_formula_and_sample_cells() -> None:
    rows = [
        [
            Cell(value="Header", row=1, column=1, classification=ContentClass.REAL_CONTENT),
            Cell(value="Status", row=1, column=2, classification=ContentClass.REAL_CONTENT),
        ],
        [Cell(value="cached formula", row=2, column=1, formula="=1+1", classification=ContentClass.REAL_CONTENT)],
        [Cell(value="official example", row=3, column=1, classification=ContentClass.SAMPLE_RESIDUE)],
        [Cell(value="Project row", row=4, column=1, classification=ContentClass.REAL_CONTENT)],
        [Cell(value="Pending", row=5, column=2, classification=ContentClass.REAL_CONTENT)],
    ]
    sheet = Sheet(name="Data", rows=rows)
    assert _real_data_rows(sheet, [1], [], {"Status": ["Pending"]}) == {4}


def test_report5_schema_headers_are_driven_by_yaml() -> None:
    spec = CapstoneSpec.load(ROOT / "capstone-doc-spec.v0.1.yaml")
    contract = spec.workbook("report5_test_report")
    assert contract["purpose"] == "Integration, system, and acceptance test case and tracking."
    assert contract["sheets"]["Test Cases"]["header_rows"] == [8]
    assert contract["sheets"]["Test Statistics"]["required_columns"] == [
        "No",
        "Module code",
        "Passed",
        "Failed",
        "Pending",
        "N/A",
        "Number of  test cases",
    ]
    assert contract["observed_schema"]["explicit_enumerations"]["feature_status"] == [
        "Passed",
        "Failed",
        "Pending",
        "N/A",
    ]
    for filename, report_id in (("Report5_Unit Test.xls", "report5_unit_test"), ("Report5_Test Report.xlsx", "report5_test_report")):
        path = SOURCE_TEMPLATES / filename
        if path.exists():
            result = ValidationEngine(spec).validate(path, report_id)
            assert not any("required_columns" in finding.rule_id for finding in result.findings)


def test_json_and_text_outputs_keep_finding_location_and_spec_path() -> None:
    result = ValidationResult(
        source_path="fixture.docx",
        report="demo",
        format="docx",
        findings=[
            Finding(
                status=Status.FAIL,
                severity="error",
                rule_id="required.content",
                report="demo",
                section="Required Section",
                location="paragraph 2",
                message="No completed content",
                evidence=[{"text": "[Provide content]"}],
                source_requirement="A required section must contain content.",
                spec_path="reports.demo.sections[required].content",
            )
        ],
    )
    payload = render_json([result])
    assert '"location": "paragraph 2"' in payload
    assert '"spec_path": "reports.demo.sections[required].content"' in payload
    text = render_text([result])
    assert "FAIL" in text
    assert "required.content" in text
    assert "paragraph 2" in text


def test_cli_exit_codes_for_pass_and_fail(minimal_spec_path: Path, tmp_path: Path, capsys) -> None:
    good = create_docx(tmp_path / "good.docx", required_text="Completed content", include_image=True, complete_optional=True)
    # Image Section has a required image in the minimal contract, so use a
    # contract copy that makes that evidence optional for the exit-code check.
    good_spec = tmp_path / "good-spec.yaml"
    good_spec.write_text(
        minimal_spec_path.read_text(encoding="utf-8").replace("            required: true\n            semantic_review: true", "            required: false\n            semantic_review: true"),
        encoding="utf-8",
    )
    assert main(["validate", "--spec", str(good_spec), "--report", "demo", str(good)]) == 0
    capsys.readouterr()

    bad = tmp_path / "bad.docx"
    from docx import Document as WordDocument

    word = WordDocument()
    word.add_heading("Required Section", level=1)
    word.save(bad)
    assert main(["validate", "--spec", str(good_spec), "--report", "demo", str(bad)]) == 1
    output = capsys.readouterr().out
    assert "FAIL" in output


def test_cli_invalid_contract_returns_code_two(tmp_path: Path, capsys) -> None:
    invalid = tmp_path / "invalid.yaml"
    invalid.write_text("reports: []\n", encoding="utf-8")
    document = tmp_path / "input.docx"
    create_docx(document, required_text="content")
    assert main(["validate", "--spec", str(invalid), str(document)]) == 2
    assert "invalid capstone specification" in capsys.readouterr().err
