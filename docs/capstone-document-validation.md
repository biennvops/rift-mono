# Capstone document validation

Rift includes a deterministic Phase 1 validator for the FPT SEP490 capstone
reports and tracking workbooks. It performs structural extraction and contract
checks only. It does not call a network service, render documents, use OCR, or
make semantic claims about diagrams, implementation, or repository evidence.

## Contract

The current machine-readable contract is:

- [`capstone-doc-spec.v0.1.yaml`](../capstone-doc-spec.v0.1.yaml)
- [`capstone-doc-spec.schema.json`](../capstone-doc-spec.schema.json)

`CapstoneSpec.load()` parses the YAML and validates it against the JSON Schema
before any input document is opened. Unknown future fields are retained because
the contract schema permits them unless a future schema revision forbids them.
Source ambiguities and their resolutions remain available through
`spec.source_ambiguities` and in JSON validation metadata.

The supplied Report 5 workbooks were inspected directly. The contract records
only visible facts:

- `Report5_Unit Test.xls`: `Guideline`, `Cover`, `Functions`, `Statistics`,
  function sheets, and `Example`; `Functions` row 10 and `Statistics` row 11
  are the visible tabular headers. Function-sheet matrix/result rows and merged
  regions are recorded under `workbooks.report5_unit_test.observed_schema`.
- `Report5_Test Report.xlsx`: `Cover`, `Test Cases`, `Test Statistics`, and
  feature sheets; `Test Cases` row 8, `Test Statistics` row 10, and feature
  row 10 are the visible test-case headers.

The Student Guide's purposes are kept distinct: the Unit Test workbook is for
unit-test case specification/tracking, while the Test Report workbook is for
integration, system, and acceptance test case/tracking.

## Installation and commands

From the repository root, install the package and test extra in a Python 3.12+
environment:

```bash
python -m pip install -e '.[test]'
```

Validate one report:

```bash
rift-doc validate \
  --spec capstone-doc-spec.v0.1.yaml \
  --report report4 \
  path/to/RIFT_Report4.docx
```

The report id is inferred from the filename when `--report` is omitted. Batch
validation accepts a directory:

```bash
rift-doc validate \
  --spec capstone-doc-spec.v0.1.yaml \
  --input path/to/current-reports/
```

Machine-readable output and strict CI behavior are available independently:

```bash
rift-doc validate --spec capstone-doc-spec.v0.1.yaml \
  --report report5_test_report --format json path/to/tests.xlsx

rift-doc validate --spec capstone-doc-spec.v0.1.yaml \
  --strict --input path/to/current-reports/
```

Inspect normalized structure while debugging extraction:

```bash
rift-doc inspect --spec capstone-doc-spec.v0.1.yaml \
  path/to/document.docx
rift-doc inspect path/to/workbook.xlsx --format json
```

Exit codes are `0` for no error-level FAIL findings, `1` for completed
validation with such findings, and `2` for invalid contracts, unsupported input,
or parser/internal errors. `--strict` also treats warnings and
`REVIEW_REQUIRED` findings as failures.

## Model and validation boundary

Extractors return `Document` or `Workbook` normalized models. DOCX extraction
preserves paragraph order, heading style/numbering metadata, section paths,
tables/cells, and embedded-image relationships. Spreadsheet extraction
preserves sheet names, cells, formulas separately from values, merged regions,
and detected/configured header rows. Source workbooks are never re-saved.

The content classifier is intentionally conservative. It preserves original
text and assigns `real_content`, `placeholder`, `template_instruction`,
`sample_residue`, or `empty`. Sample residue is only recognized from
fingerprints in the YAML contract; arbitrary project prose is not broadly
classified as sample text.

Structural rules are generic mechanics driven by the YAML report/workbook
objects. They support required and repeatable sections, child sections,
MUST/SHOULD/MAY/CONDITIONAL requirements, content and table/image evidence,
explicit N/A rationales, and configured per-feature sections. A heading alone,
a header-only table, or template-only content does not satisfy a content rule.
Image presence can PASS while also producing `REVIEW_REQUIRED`, because Phase 1
cannot prove that an image is the requested diagram or that its semantics are
correct.

`CrossDocumentValidator` is deliberately empty in Phase 1. Later traceability,
repository evidence, and semantic validators can consume the same normalized
model and finding format without adding format-specific parsing to the rule
engine.

## Tests

The focused suite uses synthetic DOCX/XLSX fixtures for core behavior and uses
the supplied Report 5 originals when present for real XLS/XLSX extraction
regressions:

```bash
pytest
```
