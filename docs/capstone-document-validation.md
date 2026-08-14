# Capstone document validation

Rift includes audit tooling for the FPT SEP490 capstone reports, tracking
workbooks, cross-document traceability, local repository evidence, and optional
bounded semantic review. Phase 1 performs structural extraction and contract
checks, Phase 2 links claims across the document set, and Phase 3 checks
selected claims against a local worktree and optional package artifacts. These
three deterministic phases do not use a network or LLM service, run repository
builds/tests, or make semantic claims about diagrams or implementation
correctness. Phase 4 is opt-in and reviews only bounded evidence produced by
Phases 1–3; offline deterministic validation remains the default.

## Contract

The current machine-readable contract is:

- [`capstone-doc-spec.v0.1.yaml`](../capstone-doc-spec.v0.1.yaml)
- [`capstone-doc-spec.schema.json`](../capstone-doc-spec.schema.json)

`CapstoneSpec.load()` parses the YAML and validates it against the JSON Schema
before any input document is opened. The contract's
`repository_evidence_extension` defines the four initial claim projections:
function/feature to implementation, architecture component to module/package,
test claim to executable test evidence, and deliverable to package/artifact.
Unknown future fields are retained because the contract schema permits them
unless a future schema revision forbids them. Source ambiguities and their
resolutions remain available through `spec.source_ambiguities` and in JSON
validation metadata.

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

The Phase 2 `CrossDocumentValidator` consumes the same normalized models and
source locations. It builds deterministic trace entities and a graph before
executing the contract's `cross_document_traceability` rules. Explicit IDs are
matched first, then exact normalized names; conflicting or ambiguous matches
become `REVIEW_REQUIRED`. No DOCX/XLS file is parsed a second time and no
network or LLM service is used.

Validate one audit set with a manifest (paths may retain their original names):

```bash
rift-doc validate-set --spec capstone-doc-spec.v0.1.yaml --manifest capstone.yaml
rift-doc trace --spec capstone-doc-spec.v0.1.yaml --manifest capstone.yaml --format json --show-graph
```

A minimal manifest can use the original filenames directly:

```yaml
project: Rift
reports:
  report1: path/to/Report1_Project Introduction.docx
  report2: path/to/Report2_Project Management Plan.docx
  report3: path/to/Report3_Software Requirement Specification.docx
  report4: path/to/Report4_Software Design Document.docx
  report5: path/to/Report5_Test Documentation.docx
  report6: path/to/Report6_Software User Guides.docx
  report7: path/to/Report7_Final Project Report.docx
tracking:
  - path/to/Report3_Project Tracking.xlsx
tests:
  unit: path/to/Report5_Unit Test.xls
  other: path/to/Report5_Test Report.xlsx
```

A manifest may omit reports while an audit is being assembled. Missing inputs
are retained as explicit cross-document findings. If a logical report has
multiple candidates, mark one candidate `selected: true`, provide a
`resolutions` entry, or configure `latest_version`/`latest_modified`; otherwise
selection remains `REVIEW_REQUIRED`. The supported rule shape is typed by
`CapstoneSpec.iter_trace_rules()`. Unknown handler names are reported as
configuration failures rather than ignored. `DocumentSet`, `TraceEntity`, and
`TraceGraph` are public models; Phase 3 projects repository claims from this
same graph rather than reparsing documentation.

## Repository evidence

Inspect a local repository adapter/index without loading capstone documents:

```bash
rift-doc repo-inspect --repo ../rift-mono
rift-doc repo-inspect --repo ../rift-mono --format json
```

Run repository evidence as part of the complete set audit, or by itself:

```bash
rift-doc validate-set --manifest capstone.yaml --repo ../rift-mono
rift-doc evidence --manifest capstone.yaml --repo ../rift-mono \
  --artifacts path/to/final-package --format json
```

`--kind function|architecture|test|deliverable` and `--claim FE-03` bound an
evidence audit to selected projections. `--artifacts` is independent of source
control and may point at a generated final-package directory; generated
binaries do not need to be committed.

Repository inventory uses local Git metadata when available and falls back to a
plain source tree. It follows Git's tracked/unignored file list in a worktree,
skips dependency caches and build outputs, supports configured exclusions, and
records commit SHA and dirty state. It statically parses the build/package and
source formats present in Rift, including .NET/C#, Dart/Flutter, Python,
Gradle/Kotlin, Swift/Xcode, Java, and native host files. It does not invoke
those toolchains or execute arbitrary repository code.

Project labels that differ from code names use an explicit YAML mapping:

```yaml
repository_mappings:
  features:
    FE-03:
      symbols: [syncNotifications]
      paths: [daemon-dart/lib/src/notification_sync]
  components:
    "Core Daemon":
      packages: [Rift.Daemon.Core]
  tests:
    TC-041:
      tests: [dismisses remote notification]
      executable_required: true
  deliverables:
    "macOS package":
      artifacts: ["dist/*.pkg"]
excluded_paths: [capstone-documents/source-templates]
```

Pass mappings with `--mapping repository-mapping.yaml`. The configuration is
schema-validated and every mapped finding records the mapping source and match
method; the tool never learns or writes mappings automatically.

Evidence statuses are `VERIFIED`, `PARTIALLY_VERIFIED`, `CONTRADICTED`,
`NOT_FOUND`, `REVIEW_REQUIRED`, `NOT_APPLICABLE`, and `SKIPPED`. `NOT_FOUND`
means only that deterministic evidence was not located. It is not converted to
a false-documentation claim. `CONTRADICTED` requires direct conflict evidence,
such as an explicit mapped conflict or a matched manifest version mismatch.
These findings use the `repository_evidence` validator/domain and are not FPT
template violations.

For tests, executable source, CI configuration, and recorded result artifacts
are separate evidence states: `IMPLEMENTATION_PRESENT`, `CI_CONFIGURED`, and
`RESULT_PRESENT` with latest result pass/fail/unknown. A source test does not
imply CI execution or a passing result. Tests explicitly documented or mapped
as manual are `NOT_APPLICABLE` to executable-test evidence. Symbol/package
existence likewise does not prove behavioral correctness.

Human output includes document and repository locations. JSON also includes
snapshot metadata, match methods, bounded excerpts, and compact evidence
packets for later semantic review.

## Bounded semantic review

Phase 4 consumes normalized excerpts, trace entities, deterministic findings,
and targeted Phase 3 repository evidence. It never reparses raw reports or asks
a provider to inspect a complete repository. The contract's
`semantic_review_extension` declares explicit task types, questions, source
precedence, allowed statuses, and versioned prompts. Initial rules cover content
sufficiency, cross-document consistency, requirement/test and
design/requirement alignment, repository claims, Report 7 freshness, quality
objectives, user workflows, and abnormal/error cases.

Inspect the proposed work before configuring a provider:

```bash
rift-doc semantic-plan --manifest capstone.yaml --repo ../rift-mono
rift-doc semantic-plan --manifest capstone.yaml \
  --task requirement-test-alignment --entity FE-03 --format json
```

`semantic-plan` performs Phases 1–3, lists packet evidence counts and estimated
input sizes, and never calls a provider. Every packet prioritizes the exact
section, contract requirement, directly linked trace/repository evidence, and
only then immediate context. `--max-tasks` and `--max-input-tokens` are hard
limits; truncation and exclusions remain visible in packet metadata.

The initial concrete adapter uses an OpenAI-compatible chat-completions
endpoint. Configure credentials through an environment variable, never a CLI
value or checked-in file:

```bash
export RIFT_DOC_LLM_MODEL='review-model'
export RIFT_DOC_LLM_ENDPOINT='https://provider.example/v1/chat/completions'
export RIFT_DOC_LLM_API_KEY='...'

rift-doc validate-set --manifest capstone.yaml --repo ../rift-mono --semantic
rift-doc semantic --manifest capstone.yaml \
  --task requirement-test-alignment --entity FE-03
```

Provider settings also accept `RIFT_DOC_LLM_PROVIDER`,
`RIFT_DOC_LLM_TEMPERATURE`, `RIFT_DOC_LLM_MAX_OUTPUT_TOKENS`,
`RIFT_DOC_LLM_TIMEOUT`, `RIFT_DOC_LLM_RETRIES`, and
`RIFT_DOC_LLM_API_KEY_ENV`. Matching CLI options override those values.
`--semantic-local-only` rejects non-loopback endpoints. `--max-cost` requires
input/output cost-per-million configuration; task/token limits remain available
when provider pricing is unknown.

Model output must satisfy `semantic-result.v1`. PASS/FAIL/WARNING results must
cite packet evidence IDs, contradiction results must cite provenance-distinct
evidence from both sides, and each rule constrains its allowed statuses. Invalid
JSON/schema, fabricated citations, or forbidden status output is retried only up
to the configured bound and then becomes an execution-level
`REVIEW_REQUIRED`; the tool does not invent a semantic conclusion.

Semantic findings use the `semantic_review` validator/domain and are appended
after unmodified deterministic findings. Accepted same-concept links are
recorded as lower-trust `LLM_SEMANTIC` metadata and never inserted into the
deterministic trace graph. Human output renders a separate `SEMANTIC REVIEW`
section; JSON records provider/model, prompt version/hash, packet hash,
timestamp, tool/spec version, and repository commit.

Successful schema-valid results are cached by provider, model, prompt version,
and packet hash under `.rift-doc-cache/semantic`; use `--no-cache` or
`--semantic-cache` as needed. Prompt/evidence changes invalidate the key.
Default guardrails exclude `.env`, credentials, private-key classes, and
configurable `--semantic-exclude` paths before external review. If required
sensitive evidence is excluded, or a visual task has only an image reference
and no bounded image bytes, the result is conservatively `REVIEW_REQUIRED`.
Document and source text is always treated as untrusted evidence, never as
instructions to the provider or the audit tool.

## Tests

The focused suite uses synthetic DOCX/XLSX fixtures for core behavior and uses
the supplied Report 5 originals when present for real XLS/XLSX extraction
regressions:

```bash
pytest
```
