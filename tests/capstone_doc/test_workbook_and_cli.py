from __future__ import annotations

from pathlib import Path

from rift_doc.cli import main
from rift_doc.engine import ValidationEngine
from rift_doc.output import render_json, render_text
from rift_doc.results import Finding, Status, ValidationResult
from rift_doc.spec import CapstoneSpec

from .conftest import ROOT, SOURCE_TEMPLATES, create_docx


def test_real_project_tracking_workbook_matches_observed_layout() -> None:
    path = SOURCE_TEMPLATES / "Report3_Project Tracking.xlsx"
    if not path.exists():
        return
    spec = CapstoneSpec.load(ROOT / "capstone-doc-spec.v0.1.yaml")
    result = ValidationEngine(spec).validate(path, "report3_project_tracking")
    assert not any(item.status == Status.FAIL for item in result.findings)


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
