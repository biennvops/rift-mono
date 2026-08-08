"""Generic, YAML-driven structural/template validation for DOCX documents."""

from __future__ import annotations

import re
from typing import Any, Iterable

from ..classification import ContentClassifier
from ..extractors.docx import normalize_heading
from ..model import Block, ContentClass, Document, Section, Table
from ..results import Finding, Status, ValidationResult
from ..spec import CapstoneSpec, SectionRule


class StructuralValidator:
    """Validate a normalized DOCX using only generic contract mechanics."""

    def __init__(self, spec: CapstoneSpec) -> None:
        self.spec = spec

    def known_headings(self, report_id: str) -> dict[str, int]:
        headings: dict[str, int] = {}
        for rule in self.spec.iter_section_rules(report_id):
            title = rule.data.get("title")
            if isinstance(title, str):
                headings[title] = int(rule.data.get("level", _default_heading_level(title)))
            for alias in rule.data.get("aliases", []):
                if isinstance(alias, str):
                    headings[alias] = int(rule.data.get("level", _default_heading_level(alias)))
        return headings

    def validate(self, document: Document, report_id: str) -> ValidationResult:
        result = ValidationResult(
            source_path=document.source_path,
            report=report_id,
            format=document.format,
            metadata={
                "spec_version": self.spec.version,
                "source_ambiguities": self.spec.source_ambiguities,
            },
        )
        classifier = ContentClassifier.from_config(self._classification_for_report(report_id))
        self._classify(document, classifier)
        self._validate_classifications(document, report_id, result)
        self._validate_unresolved_headings(document, report_id, result)
        roots = document.sections
        sections = self.spec.report(report_id).get("sections", {})
        if isinstance(sections, dict):
            for rule_id, raw_rule in sections.items():
                if isinstance(raw_rule, dict):
                    rule = SectionRule(
                        report_id=report_id,
                        rule_id=str(rule_id),
                        path=f"reports.{report_id}.sections[{rule_id}]",
                        data=raw_rule,
                    )
                    self._validate_rule(document, rule, roots, result)
        return result

    def _classification_for_report(self, report_id: str) -> dict[str, Any]:
        config = dict(self.spec.classification_config)
        for key in ("placeholder_patterns", "instruction_patterns", "sample_fingerprints"):
            patterns = config.get(key)
            if not isinstance(patterns, list):
                continue
            selected = []
            for pattern in patterns:
                if not isinstance(pattern, dict):
                    selected.append(pattern)
                    continue
                applies_to = pattern.get("applies_to")
                if not applies_to or report_id in applies_to:
                    selected.append(pattern)
            config[key] = selected
        return config

    def _classify(self, document: Document, classifier: ContentClassifier) -> None:
        for block in document.raw_blocks:
            classifier.classify_block(block)
        for table in document.tables:
            classifier.classify_table(table)

    def _validate_unresolved_headings(self, document: Document, report_id: str, result: ValidationResult) -> None:
        rules = [rule.data for rule in self.spec.iter_section_rules(report_id)]
        for block in document.raw_blocks:
            if block.kind != "heading" or self._heading_matches_contract(block, rules):
                continue
            result.add(
                Finding.from_location(
                    status=Status.REVIEW_REQUIRED,
                    severity="warning",
                    rule_id="heading.unresolved",
                    report=report_id,
                    section=block.section_path,
                    location=block.source_location,
                    message="Heading was detected but is not explicitly mapped by a configured title, alias, or pattern; review its structural mapping.",
                    evidence=[{"text": block.original_text, "numbering": block.numbering}],
                    source_requirement="Equivalent headings are accepted only when deterministically mapped by the contract.",
                    spec_path=f"reports.{report_id}.sections",
                )
            )

    def _heading_matches_contract(self, block: Block, rules: list[dict[str, Any]]) -> bool:
        normalized = normalize_heading(block.text)
        for rule in rules:
            accepted = {normalize_heading(str(rule.get("title", "")))}
            accepted.update(normalize_heading(str(alias)) for alias in rule.get("aliases", []) if isinstance(alias, str))
            if normalized in accepted and normalized:
                return True
            match = rule.get("match")
            if isinstance(match, dict) and match.get("regex"):
                try:
                    if re.search(str(match["regex"]), block.text, re.IGNORECASE):
                        excluded = [str(value).casefold() for value in match.get("exclude_prefixes", [])]
                        if not any(block.text.casefold().startswith(prefix) for prefix in excluded):
                            return True
                except re.error:
                    continue
        return False

    def _validate_classifications(self, document: Document, report_id: str, result: ValidationResult) -> None:
        for block in document.raw_blocks:
            if block.kind == "heading" or not (block.original_text or "").strip():
                continue
            if block.classification in {
                ContentClass.PLACEHOLDER,
                ContentClass.TEMPLATE_INSTRUCTION,
                ContentClass.SAMPLE_RESIDUE,
            }:
                self._add_classification_finding(
                    result,
                    report_id,
                    block.classification,
                    block.original_text or block.text,
                    block.section_path,
                    block.source_location,
                )
        for table in document.tables:
            for row in table.rows:
                for cell in row:
                    if cell.is_empty or cell.classification not in {
                        ContentClass.PLACEHOLDER,
                        ContentClass.TEMPLATE_INSTRUCTION,
                        ContentClass.SAMPLE_RESIDUE,
                    }:
                        continue
                    self._add_classification_finding(
                        result,
                        report_id,
                        cell.classification,
                        cell.original_text,
                        table.parent_section,
                        cell.source_location,
                    )

    def _add_classification_finding(
        self,
        result: ValidationResult,
        report_id: str,
        classification: ContentClass,
        text: str,
        section: str | None,
        location: Any,
    ) -> None:
        labels = {
            ContentClass.PLACEHOLDER: ("placeholder.unresolved", "Unresolved placeholder remains", "classification.placeholder_patterns"),
            ContentClass.TEMPLATE_INSTRUCTION: ("template.instruction", "Template instruction remains", "classification.instruction_patterns"),
            ContentClass.SAMPLE_RESIDUE: ("sample.residue", "Known official sample residue remains", "classification.sample_fingerprints"),
        }
        rule_id, label, classification_path = labels[classification]
        quote = " ".join(text.split())
        if len(quote) > 360:
            quote = quote[:357] + "..."
        result.add(
            Finding.from_location(
                status=Status.FAIL,
                severity="error",
                rule_id=rule_id,
                report=report_id,
                section=section,
                location=location,
                message=f"{label}: {quote!r}",
                evidence=[{"text": text, "classification": classification.value}],
                source_requirement="Completed reports must not retain unresolved template instructions, placeholders, or configured sample material.",
                spec_path=classification_path,
            )
        )

    def _validate_rule(
        self,
        document: Document,
        rule: SectionRule,
        parent_sections: list[Section],
        result: ValidationResult,
        context_section: Section | None = None,
    ) -> None:
        data = rule.data
        requirement = str(data.get("requirement", "MUST")).upper()
        candidates = self._candidate_sections(parent_sections, data)
        repeatable = bool(data.get("repeatable") or data.get("per_feature_required"))
        minimum = int(data.get("min_occurrences", 1 if repeatable else 1))

        if not candidates:
            if bool(data.get("allow_explicit_na")) and self._has_explicit_na(document, parent_sections):
                self._add_not_applicable(
                    result,
                    rule,
                    "Required content is explicitly marked not applicable with a rationale.",
                    parent_sections,
                    context_section,
                )
            elif requirement == "CONDITIONAL":
                condition = self._evaluate_condition(document, data.get("condition"), parent_sections)
                if condition is False:
                    self._add_not_applicable(result, rule, "Configured condition was deterministically false.", parent_sections, context_section)
                elif condition is True:
                    self._add_missing(
                        result,
                        rule,
                        Status.FAIL,
                        "The conditional requirement is applicable, but its required section was not detected.",
                        parent_sections,
                        context_section,
                    )
                else:
                    self._add_missing(
                        result,
                        rule,
                        Status.REVIEW_REQUIRED,
                        "The conditional section is absent and applicability cannot be determined structurally.",
                        parent_sections,
                        context_section,
                    )
            elif requirement == "MAY":
                self._add_missing(result, rule, Status.SKIPPED, "Optional section was not detected.", parent_sections, context_section)
            else:
                status = Status.FAIL if requirement == "MUST" else Status.WARNING
                self._add_missing(result, rule, status, "Required section was not detected.", parent_sections, context_section)
            return

        if len(candidates) < minimum:
            status = Status.FAIL if requirement == "MUST" else Status.WARNING
            self._add_missing(
                result,
                rule,
                status,
                f"Expected at least {minimum} matching section(s); detected {len(candidates)}.",
                parent_sections,
                context_section,
            )

        # A present conditional section is deterministic evidence that the
        # author chose to provide the conditional material, so normal structural
        # checks apply to it.  Its semantic correctness remains reviewable.
        selected = candidates if repeatable else candidates[:1]
        for section in selected:
            self._validate_section_content(document, rule, section, result)
            children = data.get("children", {})
            if isinstance(children, dict):
                for child_id, child_data in children.items():
                    if not isinstance(child_data, dict):
                        continue
                    child_rule = SectionRule(
                        report_id=rule.report_id,
                        rule_id=str(child_id),
                        path=f"{rule.path}.children[{child_id}]",
                        data=child_data,
                        parent_rule_id=rule.rule_id,
                    )
                    self._validate_rule(document, child_rule, section.children, result, section)

    def _candidate_sections(self, parents: list[Section], data: dict[str, Any]) -> list[Section]:
        candidates = list(parents)
        match = data.get("match")
        if isinstance(match, dict) and match.get("regex"):
            try:
                pattern = re.compile(str(match["regex"]), re.IGNORECASE)
            except re.error:
                return []
            excluded = [str(value).casefold() for value in match.get("exclude_prefixes", [])]
            return [
                section
                for section in candidates
                if pattern.search(section.title)
                and not any(section.title.casefold().startswith(prefix) for prefix in excluded)
            ]

        accepted = {normalize_heading(str(data.get("title", "")))}
        accepted.update(normalize_heading(str(alias)) for alias in data.get("aliases", []) if isinstance(alias, str))
        return [section for section in candidates if section.normalized_title in accepted and "" not in accepted]

    def _validate_section_content(
        self,
        document: Document,
        rule: SectionRule,
        section: Section,
        result: ValidationResult,
    ) -> None:
        requirement = str(rule.data.get("requirement", "MUST")).upper()
        result.add(
            Finding.from_location(
                status=Status.PASS,
                severity="info",
                rule_id=f"{rule.rule_id}.section",
                report=rule.report_id,
                section=section.path,
                location=section.source_location,
                message="Required section detected.",
                source_requirement=self._rule_source_requirement(rule),
                spec_path=rule.path,
            )
        )
        content = rule.data.get("content")
        content_required = bool(content is True or (isinstance(content, dict) and content.get("required", True)))
        explicit_na = (
            bool(rule.data.get("allow_explicit_na"))
            and self._section_has_explicit_na(section)
            and not self._section_has_substantive_content(document, section)
        )
        if explicit_na:
            self._add_not_applicable(result, rule, "Section contains an explicit N/A rationale.", [section])
            return
        has_content = self._has_real_content(document, section, content)
        if content_required and not has_content:
            if bool(rule.data.get("allow_explicit_na")) and self._section_has_explicit_na(section):
                self._add_not_applicable(result, rule, "Section contains an explicit N/A rationale.", [section])
            else:
                status = Status.WARNING if requirement == "SHOULD" else Status.FAIL
                result.add(
                    Finding.from_location(
                        status=status,
                        severity="error" if status == Status.FAIL else "warning",
                        rule_id=f"{rule.rule_id}.content",
                        report=rule.report_id,
                        section=section.path,
                        location=section.source_location,
                        message="Section heading was detected, but no real completed content was detected.",
                        evidence=self._section_evidence(document, section),
                        source_requirement=self._rule_source_requirement(rule),
                        spec_path=f"{rule.path}.content",
                    )
                )
        elif content_required:
            result.add(
                Finding.from_location(
                    status=Status.PASS,
                    severity="info",
                    rule_id=f"{rule.rule_id}.content",
                    report=rule.report_id,
                    section=section.path,
                    location=section.source_location,
                    message="Completed content detected.",
                    evidence=self._section_evidence(document, section),
                    source_requirement=self._rule_source_requirement(rule),
                    spec_path=f"{rule.path}.content",
                )
            )
        for index, evidence_rule in enumerate(rule.data.get("evidence", []) or []):
            if isinstance(evidence_rule, str):
                evidence_rule = {"type": evidence_rule, "required": True}
            if not isinstance(evidence_rule, dict):
                continue
            self._validate_evidence(document, rule, section, evidence_rule, index, result)

    def _validate_evidence(
        self,
        document: Document,
        rule: SectionRule,
        section: Section,
        evidence_rule: dict[str, Any],
        index: int,
        result: ValidationResult,
    ) -> None:
        evidence_type = str(evidence_rule.get("type", "")).casefold()
        required = bool(evidence_rule.get("required", True))
        minimum = int(evidence_rule.get("min", 1 if required else 0))
        tables = self._tables_for_section(document, section)
        images = self._images_for_section(document, section)
        if evidence_type == "table":
            count = sum(1 for table in tables if _table_has_real_body(table))
            description = evidence_rule.get("description", "structured table evidence")
        elif evidence_type == "image":
            count = len(images)
            description = evidence_rule.get("description", "embedded image evidence")
        elif evidence_type in {"content", "prose", "text"}:
            count = 1 if self._has_real_content(document, section, {"scope": "subtree"}) else 0
            description = evidence_rule.get("description", "completed content evidence")
        else:
            result.add(
                Finding.from_location(
                    status=Status.REVIEW_REQUIRED,
                    severity="warning",
                    rule_id=f"{rule.rule_id}.evidence.{index}",
                    report=rule.report_id,
                    section=section.path,
                    location=section.source_location,
                    message=f"Evidence type {evidence_type!r} is not implemented by Phase 1.",
                    source_requirement=evidence_rule.get("source_requirement") or self._rule_source_requirement(rule),
                    spec_path=f"{rule.path}.evidence[{index}]",
                )
            )
            return

        if not required and count == 0 and "min" not in evidence_rule:
            result.add(
                Finding.from_location(
                    status=Status.SKIPPED,
                    severity="info",
                    rule_id=f"{rule.rule_id}.evidence.{index}",
                    report=rule.report_id,
                    section=section.path,
                    location=section.source_location,
                    message=f"Optional {description} was not detected.",
                    source_requirement=evidence_rule.get("source_requirement") or self._rule_source_requirement(rule),
                    spec_path=f"{rule.path}.evidence[{index}]",
                )
            )
        elif count < minimum:
            if required:
                requirement = str(rule.data.get("requirement", "MUST")).upper()
                status = Status.WARNING if requirement == "SHOULD" else Status.FAIL
            else:
                status = Status.REVIEW_REQUIRED if count else Status.SKIPPED
            result.add(
                Finding.from_location(
                    status=status,
                    severity="error" if status == Status.FAIL else "warning",
                    rule_id=f"{rule.rule_id}.evidence.{index}",
                    report=rule.report_id,
                    section=section.path,
                    location=section.source_location,
                    message=f"{description.capitalize()} was not detected (detected {count}, required {minimum}).",
                    evidence=self._section_evidence(document, section),
                    source_requirement=evidence_rule.get("source_requirement") or self._rule_source_requirement(rule),
                    spec_path=f"{rule.path}.evidence[{index}]",
                )
            )
        else:
            result.add(
                Finding.from_location(
                    status=Status.PASS,
                    severity="info",
                    rule_id=f"{rule.rule_id}.evidence.{index}",
                    report=rule.report_id,
                    section=section.path,
                    location=section.source_location,
                    message=f"{description.capitalize()} detected.",
                    evidence=self._section_evidence(document, section),
                    source_requirement=evidence_rule.get("source_requirement") or self._rule_source_requirement(rule),
                    spec_path=f"{rule.path}.evidence[{index}]",
                )
            )
            if evidence_type == "image" and evidence_rule.get("semantic_review"):
                result.add(
                    Finding.from_location(
                        status=Status.REVIEW_REQUIRED,
                        severity="warning",
                        rule_id=f"{rule.rule_id}.evidence.{index}.semantic",
                        report=rule.report_id,
                        section=section.path,
                        location=section.source_location,
                        message="Image evidence exists, but deterministic validation cannot prove its diagram identity or semantic correctness.",
                        evidence=[image.to_dict() for image in images],
                        source_requirement=evidence_rule.get("source_requirement") or self._rule_source_requirement(rule),
                        spec_path=f"{rule.path}.evidence[{index}]",
                    )
                )

    def _rule_source_requirement(self, rule: SectionRule) -> str | None:
        value = rule.data.get("source_requirement")
        if isinstance(value, str) and value.strip():
            return value
        report_value = self.spec.report(rule.report_id).get("source_requirement")
        return report_value if isinstance(report_value, str) else None

    def _has_real_content(self, document: Document, section: Section, content_rule: Any) -> bool:
        scope = content_rule.get("scope", "subtree") if isinstance(content_rule, dict) else "subtree"
        sections = list(section.all_sections()) if scope == "subtree" else [section]
        paths = {item.path for item in sections}
        for block in document.raw_blocks:
            if block.section_path not in paths or block.kind == "heading":
                continue
            if block.kind == "paragraph" and block.classification == ContentClass.REAL_CONTENT and block.text.strip():
                return True
        for table in document.tables:
            if table.parent_section in paths and _table_has_real_body(table):
                return True
        return False

    def _section_evidence(self, document: Document, section: Section) -> list[Any]:
        evidence: list[Any] = []
        for block in section.all_blocks():
            if block.kind == "paragraph" and block.text.strip():
                evidence.append({
                    "kind": "paragraph",
                    "text": block.original_text,
                    "classification": block.classification.value if block.classification else None,
                    "location": block.source_location.to_dict() if block.source_location else None,
                })
            if len(evidence) >= 4:
                break
        for table in self._tables_for_section(document, section):
            if len(evidence) >= 6:
                break
            evidence.append({
                "kind": "table",
                "dimensions": {"rows": table.dimensions[0], "columns": table.dimensions[1]},
                "location": table.source_location.to_dict() if table.source_location else None,
            })
        for image in self._images_for_section(document, section):
            if len(evidence) >= 8:
                break
            evidence.append({"kind": "image", **image.to_dict()})
        return evidence

    def _tables_for_section(self, document: Document, section: Section) -> list[Table]:
        paths = {item.path for item in section.all_sections()}
        return [table for table in document.tables if table.parent_section in paths]

    def _images_for_section(self, document: Document, section: Section) -> list[Any]:
        paths = {item.path for item in section.all_sections()}
        return [image for image in document.images if image.parent_section in paths]

    def _evaluate_condition(self, document: Document, condition: Any, parents: list[Section]) -> bool | None:
        if not isinstance(condition, dict):
            return None
        condition_type = str(condition.get("type", "unknown")).casefold()
        if condition_type in {"true", "always_true"}:
            return True
        if condition_type in {"false", "always_false"}:
            return False
        if condition_type in {"document_contains_any", "document_contains"}:
            patterns = condition.get("patterns", [])
            if not patterns and condition.get("pattern"):
                patterns = [condition["pattern"]]
            text = "\n".join(block.text for block in document.raw_blocks)
            for pattern in patterns:
                try:
                    if re.search(str(pattern), text, re.IGNORECASE):
                        return True
                except re.error:
                    continue
            return False
        if condition_type in {"document_contains_none", "document_not_contains"}:
            value = self._evaluate_condition(document, {"type": "document_contains_any", "patterns": condition.get("patterns", [condition.get("pattern", "")])}, parents)
            return None if value is None else not value
        if condition_type == "section_present":
            title = condition.get("title")
            if not title:
                return None
            target = normalize_heading(str(title))
            return any(section.normalized_title == target for section in document.all_sections())
        return None

    def _has_explicit_na(self, document: Document, parents: list[Section]) -> bool:
        if not parents:
            text = "\n".join(block.text for block in document.raw_blocks)
            return _looks_like_na_rationale(text)
        return any(self._section_has_explicit_na(parent) for parent in parents)

    def _section_has_explicit_na(self, section: Section) -> bool:
        return _looks_like_na_rationale("\n".join(block.text for block in section.all_blocks()))

    def _section_has_substantive_content(self, document: Document, section: Section) -> bool:
        paths = {item.path for item in section.all_sections()}
        for block in document.raw_blocks:
            if block.section_path in paths and block.kind == "paragraph" and block.classification == ContentClass.REAL_CONTENT:
                if block.text.strip() and not _looks_like_na_rationale(block.text):
                    return True
        return any(table.parent_section in paths and _table_has_real_body(table) for table in document.tables)

    def _add_missing(
        self,
        result: ValidationResult,
        rule: SectionRule,
        status: Status,
        message: str,
        parents: list[Section],
        context_section: Section | None = None,
    ) -> None:
        severity = "error" if status == Status.FAIL else "warning" if status in {Status.WARNING, Status.REVIEW_REQUIRED} else "info"
        context = context_section
        result.add(
            Finding.from_location(
                status=status,
                severity=severity,
                rule_id=rule.rule_id,
                report=rule.report_id,
                section=context.path if context else None,
                location=context.source_location if context else "document",
                message=message,
                source_requirement=self._rule_source_requirement(rule),
                spec_path=rule.path,
            )
        )

    def _add_not_applicable(
        self,
        result: ValidationResult,
        rule: SectionRule,
        message: str,
        parents: list[Section],
        context_section: Section | None = None,
    ) -> None:
        context = context_section
        result.add(
            Finding.from_location(
                status=Status.NOT_APPLICABLE,
                severity="info",
                rule_id=rule.rule_id,
                report=rule.report_id,
                section=context.path if context else None,
                location=context.source_location if context else "document",
                message=message,
                evidence=self._na_evidence([context] if context else parents),
                source_requirement=self._rule_source_requirement(rule),
                spec_path=rule.path,
            )
        )

    def _na_evidence(self, sections: list[Section]) -> list[Any]:
        evidence: list[Any] = []
        for section in sections:
            for block in section.all_blocks():
                if block.kind != "heading" and _looks_like_na_rationale(block.text):
                    evidence.append({
                        "text": block.original_text,
                        "location": block.source_location.to_dict() if block.source_location else None,
                    })
        return evidence


def _default_heading_level(title: str) -> int:
    value = title.strip()
    if re.match(r"^[IVXLCDM]+\.", value, re.IGNORECASE):
        return 1
    match = re.match(r"^(\d+(?:\.\d+)*)", value)
    return len(match.group(1).split(".")) + 1 if match else 2


def _table_has_real_body(table: Table) -> bool:
    if len(table.rows) < 2:
        return False
    # A header-only table is not evidence of completed content.  One or more
    # non-empty cells after the first row is sufficient; classifiers remove
    # configured placeholders/instructions/sample residue first.
    for row in table.rows[1:]:
        for cell in row:
            if not cell.is_empty and cell.classification == ContentClass.REAL_CONTENT:
                return True
    return False


def _looks_like_na_rationale(text: str) -> bool:
    compact = " ".join(text.split())
    if len(compact) < 20:
        return False
    return bool(re.search(r"\b(?:N/?A|not applicable|does not apply|not relevant)\b", compact, re.IGNORECASE)) and bool(
        re.search(r"\b(?:because|since|as|therefore|rationale|instead|storage|design|scope)\b", compact, re.IGNORECASE)
    )
