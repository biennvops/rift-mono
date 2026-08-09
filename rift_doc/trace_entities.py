"""Deterministic trace-entity extraction from Phase 1 normalized models."""

from __future__ import annotations

from collections import defaultdict
import re
from typing import Any, Iterable

from .classification import ContentClassifier
from .document_set import DocumentArtifact, DocumentSet, _domain_alias
from .model import Block, Cell, ContentClass, Document, NormalizedDocument, Section, Sheet, Table, Workbook
from .spec import CapstoneSpec
from .trace_model import TraceEntity, TraceGraph, normalize_identifier, normalize_name


_IDENTIFIER_RE = re.compile(
    r"(?<![A-Za-z0-9])([A-Za-z]{1,16}\s*[-_./]?\s*\d{1,8})(?![A-Za-z0-9])"
)
_EXCLUDED_ID_PREFIXES = {
    "REPORT",
    "SECTION",
    "PART",
    "PHASE",
    "ITERATION",
    "WEEK",
    "VERSION",
    "TABLE",
    "FIGURE",
    "PAGE",
    "ROW",
    "COLUMN",
    "FUNCTION",
    "FEATURE",
    "WORKFLOW",
}

_KIND_HINTS: dict[str, tuple[str, ...]] = {
    "feature": ("major features", "feature requirements", "features", "scope"),
    "wbs_item": ("wbs", "scope estimation", "project deliverables", "deliverables"),
    "use_case": ("use cases", "use case", "use case descriptions", "user requirements"),
    "function": ("functional requirements", "feature requirements", "feature/function design", "detailed design", "functions", "function"),
    "actor": ("actors", "actor", "user requirements"),
    "external_interface": ("external interfaces", "external interface", "external api", "interfaces", "context"),
    "architecture_component": ("system architecture", "architecture", "architecture component", "components", "system design", "package diagram"),
    "entity_or_data_object": ("entity relationship", "erd", "database design", "data design", "data model", "data object", "data entities", "entities"),
    "quality_objective": ("project objectives", "quality objectives", "quality objective", "quality management", "quality attributes", "non-functional requirements", "non functional requirements"),
    "test_case_or_test_group": ("test cases", "test reports", "test strategy", "test statistics", "testing", "function"),
    "user_workflow": ("user manual", "workflow", "installation", "screen flow"),
    "deliverable": ("project deliverables", "deliverable package", "deliverables", "deliverable", "release package"),
    "tracking_item": ("wbs", "status report", "next week plan", "project tracking", "tracking", "project task", "work item"),
    "final_report_item": (),
}

_NAME_COLUMNS: dict[str, tuple[str, ...]] = {
    "feature": ("feature", "feature name", "name", "description"),
    "wbs_item": ("function/screen", "function / screen", "feature", "work item", "project task", "name", "description"),
    "use_case": ("use case", "use case name", "name", "function", "description"),
    "function": ("function name", "function", "feature", "requirement name", "name", "description"),
    "actor": ("actor", "actor name", "role", "name", "description"),
    "external_interface": ("interface", "external interface", "name", "system", "description"),
    "architecture_component": ("component", "module", "package", "service", "name", "description"),
    "entity_or_data_object": ("entity", "table", "data object", "object", "name", "description"),
    "quality_objective": ("objective", "quality objective", "metric", "attribute", "name", "description"),
    "test_case_or_test_group": ("test case id", "test case", "test requirement", "function name", "feature", "module", "description", "name"),
    "user_workflow": ("workflow", "user workflow", "use case", "procedure", "name", "description"),
    "deliverable": ("deliverable", "product", "artifact", "name", "description"),
    "tracking_item": ("project task", "project work item", "function/screen", "feature", "deliverable", "work item", "name", "description"),
    "final_report_item": ("name", "feature", "function", "deliverable", "description"),
}


class TraceEntityExtractor:
    """Extract only named, structurally anchored entities.

    The extractor has category-level heuristics (actors, workflows, and so on),
    but never contains a project feature list.  Optional ``trace_entities``
    configuration in a report can narrow a category to exact sections or table
    columns when a project needs stronger determinism.
    """

    def __init__(self, spec: CapstoneSpec | None = None) -> None:
        self.spec = spec
        self._sequence: defaultdict[tuple[str, str], int] = defaultdict(int)

    def extract_document_set(self, document_set: DocumentSet) -> TraceGraph:
        self._sequence.clear()
        requests = self._requests()
        graph = TraceGraph(metadata={"matching": "deterministic", "normalization": "identifier-and-exact-name"})
        artifacts = list(document_set.iter_active_artifacts())
        if not artifacts:
            artifacts = self._fallback_artifacts(document_set)
        for artifact in artifacts:
            logical_domain = _logical_artifact_domain(artifact.domain, artifact.artifact_id)
            self._classify_if_needed(artifact.document, logical_domain)
            kinds = self._kinds_for_artifact(logical_domain, artifact.artifact_id, requests)
            if not kinds:
                continue
            for entity in self.extract(
                artifact.document,
                logical_domain,
                kinds=kinds,
                artifact_domain=artifact.artifact_id,
            ):
                graph.add_node(entity)
        graph.metadata["node_count"] = len(graph.nodes)
        graph.metadata["domains"] = sorted({str(node.metadata.get("domain", node.source_report)) for node in graph.nodes})
        return graph

    def extract(
        self,
        document: NormalizedDocument,
        source_report: str,
        kind: str | None = None,
        *,
        kinds: Iterable[str] | None = None,
        artifact_domain: str | None = None,
    ) -> list[TraceEntity]:
        logical_domain = _domain_alias(source_report)
        selected_source = kinds if kinds is not None else (kind,) if kind is not None else _KIND_HINTS
        selected_kinds = tuple(dict.fromkeys(str(kind) for kind in selected_source if str(kind)))
        entities: list[TraceEntity] = []
        seen: set[tuple[str, str, str]] = set()
        for kind in selected_kinds:
            if isinstance(document, Document):
                extracted = self._extract_document_kind(document, logical_domain, kind, artifact_domain)
            elif isinstance(document, Workbook):
                extracted = self._extract_workbook_kind(document, logical_domain, kind, artifact_domain)
            else:
                extracted = []
            for entity in extracted:
                key = (entity.kind, normalize_name(entity.canonical_name), _location_key(entity.source_location))
                if not key[1] or key in seen:
                    continue
                seen.add(key)
                entity.entity_id = self._entity_id(entity)
                entities.append(entity)
        return entities

    def _classify_if_needed(self, document: NormalizedDocument, logical_domain: str) -> None:
        if self.spec is None:
            return
        config = dict(self.spec.classification_config)
        for key in ("placeholder_patterns", "instruction_patterns", "sample_fingerprints"):
            patterns = config.get(key)
            if not isinstance(patterns, list):
                continue
            config[key] = [
                pattern
                for pattern in patterns
                if not isinstance(pattern, dict) or not pattern.get("applies_to") or logical_domain in pattern.get("applies_to", [])
            ]
        classifier = ContentClassifier.from_config(config)
        if isinstance(document, Document):
            for block in _document_blocks(document):
                if block.classification is None:
                    classifier.classify_block(block)
            for table in document.tables:
                for row in table.rows:
                    for cell in row:
                        if cell.classification is None:
                            classifier.classify_cell(cell)
        elif isinstance(document, Workbook):
            for sheet in document.sheets:
                for row in sheet.rows:
                    for cell in row:
                        if cell.classification is None:
                            classifier.classify_cell(cell)

    def _requests(self) -> dict[str, set[str]]:
        requests: defaultdict[str, set[str]] = defaultdict(set)
        if self.spec is None:
            for domain in [f"report{index}" for index in range(1, 8)]:
                requests[domain].update(_KIND_HINTS)
            requests["tracking"].update({"tracking_item", "deliverable"})
            requests["tests"].update({"test_case_or_test_group"})
            return requests
        for rule in self.spec.iter_trace_rules():
            requests[_domain_alias(rule.source_domain)].update(rule.source_kinds)
            for target in rule.targets:
                requests[_domain_alias(target.domain)].update(target.kinds)
        for rule in self.spec.iter_orphan_rules():
            requests[_domain_alias(rule.source_domain)].update(rule.source_kinds)
            requests[_domain_alias(rule.target_domain)].update(rule.target_kinds)
        # Report 7 freshness uses stable source concepts even if the contract
        # only names final_report_item as the target kind.
        if "report7" in requests:
            requests["report7"].update({"final_report_item", "feature", "function", "actor", "use_case", "external_interface", "architecture_component", "deliverable"})
        return requests

    def _kinds_for_artifact(self, domain: str, artifact_id: str, requests: dict[str, set[str]]) -> set[str]:
        result = set(requests.get(domain, set()))
        artifact = _domain_alias(artifact_id)
        result.update(requests.get(artifact, set()))
        if domain in {"tests", "report5"} or artifact.startswith("report5") or artifact.startswith("test"):
            result.update(requests.get("report5", set()))
            result.add("test_case_or_test_group")
        if domain == "tracking" or artifact.startswith("tracking"):
            result.update(requests.get("tracking", set()))
            result.add("tracking_item")
        return result

    def _fallback_artifacts(self, document_set: DocumentSet) -> list[DocumentArtifact]:
        artifacts: list[DocumentArtifact] = []
        for report_id, document in document_set.reports.items():
            artifacts.append(DocumentArtifact(report_id, report_id, document))
        for index, workbook in enumerate(document_set.tracking_workbooks, start=1):
            artifacts.append(DocumentArtifact(f"tracking{index}", "tracking", workbook))
        for index, workbook in enumerate(document_set.test_workbooks, start=1):
            artifacts.append(DocumentArtifact(f"test{index}", "tests", workbook))
        return artifacts

    def _extract_document_kind(
        self,
        document: Document,
        logical_domain: str,
        kind: str,
        artifact_domain: str | None,
    ) -> list[TraceEntity]:
        config = self._kind_config(logical_domain, kind)
        scopes = self._scopes(document, logical_domain, kind, config)
        entities: list[TraceEntity] = []
        for section in scopes:
            entities.extend(self._section_heading_entities(document, section, logical_domain, kind, artifact_domain, config))
            for block in self._direct_or_descendant_blocks(section, document, config):
                if block.kind != "paragraph" or not block.text.strip():
                    continue
                if block.classification and str(getattr(block.classification, "value", block.classification)) in {"placeholder", "template_instruction", "sample_residue"}:
                    continue
                if not self._text_is_candidate(block.text, kind, block.style_name, config):
                    continue
                entity = self._entity_from_text(
                    kind,
                    block.text,
                    logical_domain,
                    artifact_domain,
                    source_section=block.section_path or section.path,
                    source_location=block.source_location,
                    evidence=[self._block_evidence(block, document.source_path)],
                    metadata={
                    "extraction": "paragraph",
                    "test_stage": _test_stage_for_section(block.section_path) if kind == "test_case_or_test_group" else None,
                },
                )
                if entity:
                    entities.append(entity)
            for table in self._tables_for_scope(document, section, config):
                entities.extend(self._table_entities(table, logical_domain, kind, artifact_domain, document.source_path, config))
        # A final report often consolidates stable IDs in prose without
        # retaining each source section's exact heading.  Only explicit-ID
        # claims are admitted from outside the configured semantic scopes.
        if kind == "final_report_item":
            for block in _document_blocks(document):
                if block.kind == "heading" or not block.text.strip():
                    continue
                if not _extract_identifiers(block.text):
                    continue
                entity = self._entity_from_text(
                    kind,
                    block.text,
                    logical_domain,
                    artifact_domain,
                    source_section=block.section_path,
                    source_location=block.source_location,
                    evidence=[self._block_evidence(block, document.source_path)],
                    metadata={"extraction": "explicit_id_claim"},
                )
                if entity:
                    entities.append(entity)
        # A source report's named section headings are useful when it has no
        # tables.  Restrict this fallback to semantically specific headings.
        if not entities and kind in {"feature", "function", "use_case", "user_workflow", "deliverable", "external_interface", "architecture_component", "entity_or_data_object"}:
            for section in document.all_sections():
                if not self._section_is_specific_entity(section, kind):
                    continue
                entity = self._entity_from_text(
                    kind,
                    section.title,
                    logical_domain,
                    artifact_domain,
                    source_section=section.path,
                    source_location=section.source_location,
                    evidence=[self._section_evidence(section, document.source_path)],
                    metadata={"extraction": "specific_heading"},
                )
                if entity:
                    entities.append(entity)
        return self._deduplicate_entities(entities)

    def _deduplicate_entities(self, entities: list[TraceEntity]) -> list[TraceEntity]:
        result: list[TraceEntity] = []
        for entity in entities:
            duplicate_index = None
            for index, existing in enumerate(result):
                same_name = normalize_name(entity.canonical_name) == normalize_name(existing.canonical_name)
                related_scope = _related_sections(entity.source_section, existing.source_section)
                if not related_scope or not same_name:
                    continue
                extraction = str(entity.metadata.get("extraction", ""))
                existing_extraction = str(existing.metadata.get("extraction", ""))
                if {extraction, existing_extraction}.issubset({"table_row"}):
                    continue
                if extraction == "section_heading" or existing_extraction == "section_heading":
                    duplicate_index = index
                    break
                if same_name and _location_key(entity.source_location) == _location_key(existing.source_location):
                    duplicate_index = index
                    break
            if duplicate_index is None:
                result.append(entity)
                continue
            existing = result[duplicate_index]
            existing.evidence.extend(item for item in entity.evidence if item not in existing.evidence)
            existing.aliases = list(dict.fromkeys([*existing.aliases, *entity.aliases]))
            if existing.metadata.get("extraction") != "section_heading" and entity.metadata.get("extraction") == "section_heading":
                result[duplicate_index] = entity
                entity.evidence.extend(item for item in existing.evidence if item not in entity.evidence)
        return result

    def _extract_workbook_kind(
        self,
        workbook: Workbook,
        logical_domain: str,
        kind: str,
        artifact_domain: str | None,
    ) -> list[TraceEntity]:
        entities: list[TraceEntity] = []
        for sheet in workbook.sheets:
            if kind in {"test_case_or_test_group", "function", "feature"} and re.search(r"^(?:Feature|Function)\s*\d+", sheet.name, re.IGNORECASE):
                entity = self._entity_from_text(
                    kind if kind != "test_case_or_test_group" else "test_case_or_test_group",
                    sheet.name,
                    logical_domain,
                    artifact_domain,
                    source_section=sheet.name,
                    source_location=sheet.source_location,
                    evidence=[self._sheet_evidence(sheet, workbook.source_path)],
                    metadata={"extraction": "sheet_name", "test_stage": "result" if kind == "test_case_or_test_group" else None},
                )
                if entity:
                    entities.append(entity)
            rows, headers = _sheet_rows_and_headers(sheet)
            for row_number, row in rows:
                if _row_is_non_content(row):
                    continue
                fields = _row_fields(headers, row)
                text = " | ".join(str(cell.value) for cell in row if not cell.is_empty)
                if not text.strip():
                    continue
                name = _field_value(fields, _NAME_COLUMNS.get(kind, ()))
                if not name:
                    if kind == "tracking_item" and sheet.name.casefold() not in {"wbs", "wx"}:
                        continue
                    name = text
                if not self._text_is_candidate(name, kind, None, {}):
                    continue
                ids = _extract_identifiers(text)
                id_value = _field_value(fields, ("id", "code", "#", "no", "number", "test case id", "function code"))
                if id_value and str(id_value).strip().isdigit():
                    prefix = {"tracking_item": "WBS", "test_case_or_test_group": "TC", "function": "FN"}.get(kind)
                    if prefix:
                        ids.append(normalize_identifier(f"{prefix}-{str(id_value).strip()}"))
                metadata = {
                    "extraction": "workbook_row",
                    "sheet": sheet.name,
                    "row": row_number,
                    "fields": {key: value for key, value in fields.items() if value not in (None, "")},
                }
                metadata.update(_metadata_from_fields(fields, kind))
                if kind == "test_case_or_test_group":
                    metadata.setdefault("test_stage", _test_stage(sheet.name, fields))
                entity = self._entity_from_text(
                    kind,
                    str(name),
                    logical_domain,
                    artifact_domain,
                    source_section=sheet.name,
                    source_location=_row_location(row, sheet, row_number),
                    evidence=[self._row_evidence(row, workbook.source_path, sheet.name, row_number)],
                    metadata=metadata,
                    identifiers=ids,
                    aliases=[str(value) for key, value in fields.items() if key.casefold() in {"feature", "function name", "function/screen", "requirement name"} and value not in (None, "")],
                )
                if entity:
                    entities.append(entity)
        return entities

    def _section_heading_entities(
        self,
        document: Document,
        section: Section,
        logical_domain: str,
        kind: str,
        artifact_domain: str | None,
        config: dict[str, Any],
    ) -> list[TraceEntity]:
        entities: list[TraceEntity] = []
        for child in section.all_descendants():
            if child is section or not self._heading_is_candidate(child, section, kind, config):
                continue
            entity = self._entity_from_text(
                kind,
                child.title,
                logical_domain,
                artifact_domain,
                source_section=child.path,
                source_location=child.source_location,
                evidence=[self._section_evidence(child, document.source_path)],
                metadata={"extraction": "section_heading"},
            )
            if entity:
                entities.append(entity)
        return entities

    def _scopes(self, document: Document, logical_domain: str, kind: str, config: dict[str, Any]) -> list[Section]:
        explicit = config.get("sections", config.get("section_titles"))
        if isinstance(explicit, str):
            explicit = [explicit]
        if isinstance(explicit, list) and explicit:
            wanted = {normalize_name(str(value)) for value in explicit}
            return [section for section in document.all_sections() if normalize_name(section.title) in wanted]
        hints = _KIND_HINTS.get(kind, ())
        if kind == "final_report_item":
            # Specific report sections are selected below for stable names and
            # explicit IDs; the broad scope is intentionally not all prose.
            return [section for section in document.all_sections() if _section_contains_any(section, ("major features", "functional requirements", "actors", "use cases", "external interfaces", "architecture", "database", "deliverables", "workflow"))]
        sections = [section for section in document.all_sections() if _section_contains_any(section, hints)]
        if not sections and logical_domain in {"report1", "report2", "report3", "report4", "report5", "report6", "report7"}:
            # A configured report may use a heading alias that is not covered
            # by a generic hint.  The fallback only considers headings, never
            # arbitrary paragraphs across the document.
            sections = [section for section in document.all_sections() if self._section_is_specific_entity(section, kind)]
        return _minimal_scopes(sections)

    def _kind_config(self, logical_domain: str, kind: str) -> dict[str, Any]:
        if self.spec is None or logical_domain not in self.spec.reports:
            return {}
        report = self.spec.report(logical_domain)
        raw = report.get("trace_entities", {})
        if not isinstance(raw, dict):
            return {}
        value = raw.get(kind, {})
        if isinstance(value, str):
            return {"sections": [value]}
        return value if isinstance(value, dict) else {}

    def _direct_or_descendant_blocks(self, section: Section, document: Document, config: dict[str, Any]) -> Iterable[Block]:
        scope = str(config.get("scope", "subtree"))
        paths = {section.path} if scope == "section" else {item.path for item in section.all_sections()}
        return (block for block in _document_blocks(document) if block.section_path in paths)

    def _tables_for_scope(self, document: Document, section: Section, config: dict[str, Any]) -> list[Table]:
        scope = str(config.get("scope", "subtree"))
        paths = {section.path} if scope == "section" else {item.path for item in section.all_sections()}
        return [table for table in document.tables if table.parent_section in paths]

    def _table_entities(
        self,
        table: Table,
        logical_domain: str,
        kind: str,
        artifact_domain: str | None,
        source_path: str,
        config: dict[str, Any],
    ) -> list[TraceEntity]:
        if not table.rows:
            return []
        header_row = table.rows[0]
        headers = [normalize_name(cell.original_text or str(cell.value)) for cell in header_row]
        result: list[TraceEntity] = []
        start = 1 if _looks_like_header(headers) else 0
        for row in table.rows[start:]:
            if _row_is_non_content(row):
                continue
            fields = _row_fields(headers, row)
            text = " | ".join(cell.original_text for cell in row if not cell.is_empty)
            if not text.strip():
                continue
            name = _field_value(fields, config.get("name_columns", _NAME_COLUMNS.get(kind, ())))
            if not name:
                name = _field_value(fields, _NAME_COLUMNS.get(kind, ())) or text
            if not self._text_is_candidate(name, kind, None, config):
                continue
            ids = _extract_identifiers(text)
            id_value = _field_value(fields, ("id", "identifier", "code", "#", "no", "number", "ref", "reference"))
            if id_value and str(id_value).strip().isdigit():
                prefix = {"wbs_item": "WBS", "test_case_or_test_group": "TC", "function": "FN"}.get(kind)
                if prefix:
                    ids.append(normalize_identifier(f"{prefix}-{id_value}"))
            metadata = {"extraction": "table_row", "fields": {key: value for key, value in fields.items() if value not in (None, "")}}
            metadata.update(_metadata_from_fields(fields, kind))
            if kind == "test_case_or_test_group":
                metadata.setdefault("test_stage", _test_stage_for_section(table.parent_section))
            if kind == "test_case_or_test_group":
                metadata.setdefault("test_stage", "case")
            entity = self._entity_from_text(
                kind,
                str(name),
                logical_domain,
                artifact_domain,
                source_section=table.parent_section,
                source_location=row[0].source_location if row else table.source_location,
                evidence=[self._table_row_evidence(row, table, source_path)],
                metadata=metadata,
                identifiers=ids,
                aliases=[str(value) for key, value in fields.items() if key in {"feature", "function name", "function/screen", "requirement name", "description"} and value not in (None, "")],
            )
            if entity:
                result.append(entity)
        return result

    def _entity_from_text(
        self,
        kind: str,
        text: str,
        logical_domain: str,
        artifact_domain: str | None,
        *,
        source_section: str | None,
        source_location: Any,
        evidence: list[Any],
        metadata: dict[str, Any] | None = None,
        identifiers: Iterable[str] = (),
        aliases: Iterable[str] = (),
    ) -> TraceEntity | None:
        raw = " ".join(str(text or "").split()).strip()
        if not raw or _looks_like_non_entity(raw):
            return None
        found = list(dict.fromkeys([*identifiers, *_extract_identifiers(raw)]))
        canonical = _clean_entity_name(raw, found)
        if not canonical and found:
            canonical = found[0]
        if not canonical:
            return None
        entity_metadata = dict(metadata or {})
        entity_metadata.setdefault("raw_text", raw)
        entity_metadata.setdefault("domain", logical_domain)
        if artifact_domain:
            entity_metadata.setdefault("artifact_domain", artifact_domain)
        entity_metadata.setdefault("user_facing", _user_facing(raw))
        entity_metadata.setdefault("measurable", _is_measurable(raw))
        entity = TraceEntity(
            entity_id="",
            kind=kind,
            canonical_name=canonical,
            identifiers=list(dict.fromkeys(normalize_identifier(value) for value in found if normalize_identifier(value))),
            aliases=list(dict.fromkeys(str(value) for value in aliases if str(value).strip() and normalize_name(str(value)) != normalize_name(canonical))),
            source_report=logical_domain,
            source_section=source_section,
            source_location=source_location,
            evidence=evidence,
            metadata=entity_metadata,
        )
        return entity

    def _entity_id(self, entity: TraceEntity) -> str:
        domain = str(entity.metadata.get("domain", entity.source_report))
        key = entity.identifiers[0] if entity.identifiers else normalize_name(entity.canonical_name) or "entity"
        sequence_key = (domain, entity.kind)
        self._sequence[sequence_key] += 1
        return f"{domain}:{entity.kind}:{key}:{self._sequence[sequence_key]}"

    def _text_is_candidate(self, text: str, kind: str, style_name: str | None, config: dict[str, Any]) -> bool:
        value = " ".join(str(text or "").split()).strip()
        if not value or _looks_like_non_entity(value):
            return False
        if len(value) > int(config.get("max_length", 500)) and not _extract_identifiers(value):
            return False
        if kind in {"feature", "function", "use_case", "actor", "external_interface", "architecture_component", "entity_or_data_object", "user_workflow", "deliverable", "tracking_item"}:
            identifiers = _extract_identifiers(value)
            if len(value) > 260 and not identifiers and not _looks_like_list_item(value, style_name):
                return False
            if kind in {"feature", "function", "use_case", "actor", "external_interface", "architecture_component", "entity_or_data_object"} and len(value) > 140 and not identifiers and not _looks_like_list_item(value, style_name):
                return False
        return True

    def _heading_is_candidate(self, section: Section, parent: Section, kind: str, config: dict[str, Any]) -> bool:
        if normalize_name(section.title) == normalize_name(parent.title):
            return False
        title = " ".join(section.title.split())
        if _looks_like_non_entity(title) or len(title) > 220:
            return False
        if _extract_identifiers(title):
            return True
        normalized_title = normalize_name(title)
        if kind == "user_workflow" and "workflow" in normalized_title and normalized_title not in {"workflow", "user manual"}:
            return True
        if kind == "use_case" and "use case" in normalized_title and normalized_title != "use cases":
            return True
        if kind == "actor" and "actor" in normalized_title and normalized_title != "actors":
            return True
        if kind in {"feature", "function", "external_interface", "architecture_component", "entity_or_data_object", "deliverable"}:
            return not _section_contains_any(section, _KIND_HINTS.get(kind, ()))
        return False

    def _section_is_specific_entity(self, section: Section, kind: str) -> bool:
        title = normalize_name(section.title)
        if not title or _section_contains_any(section, _KIND_HINTS.get(kind, ())):
            return False
        if _extract_identifiers(section.title):
            return True
        return kind in {"feature", "function", "use_case", "user_workflow"} and bool(re.search(r"\b(?:feature|function|use case|workflow)\b", title))

    @staticmethod
    def _block_evidence(block: Block, source_path: str) -> dict[str, Any]:
        return {
            "kind": "paragraph",
            "text": block.original_text or block.text,
            "location": block.source_location.to_dict() if block.source_location else None,
            "section": block.section_path,
            "source_path": source_path,
        }

    @staticmethod
    def _section_evidence(section: Section, source_path: str) -> dict[str, Any]:
        return {
            "kind": "heading",
            "text": section.title,
            "location": section.source_location.to_dict() if section.source_location else None,
            "section": section.path,
            "source_path": source_path,
        }

    @staticmethod
    def _table_row_evidence(row: list[Cell], table: Table, source_path: str) -> dict[str, Any]:
        return {
            "kind": "table_row",
            "text": [cell.original_text for cell in row],
            "location": row[0].source_location.to_dict() if row and row[0].source_location else table.source_location.to_dict() if table.source_location else None,
            "section": table.parent_section,
            "source_path": source_path,
        }

    @staticmethod
    def _row_evidence(row: list[Cell], source_path: str, sheet_name: str, row_number: int) -> dict[str, Any]:
        return {
            "kind": "workbook_row",
            "text": [cell.original_text for cell in row],
            "location": row[0].source_location.to_dict() if row and row[0].source_location else {"sheet_name": sheet_name, "row": row_number},
            "sheet": sheet_name,
            "row": row_number,
            "source_path": source_path,
        }

    @staticmethod
    def _sheet_evidence(sheet: Sheet, source_path: str) -> dict[str, Any]:
        return {
            "kind": "sheet",
            "text": sheet.name,
            "location": sheet.source_location.to_dict() if sheet.source_location else None,
            "source_path": source_path,
        }


def _document_blocks(document: Document) -> list[Block]:
    if document.raw_blocks:
        return list(document.raw_blocks)
    blocks: list[Block] = []
    seen: set[int] = set()
    for section in document.all_sections():
        for block in section.blocks:
            if id(block) in seen:
                continue
            seen.add(id(block))
            blocks.append(block)
    return blocks


def _extract_identifiers(text: str) -> list[str]:
    result: list[str] = []
    for match in _IDENTIFIER_RE.finditer(str(text or "")):
        raw = " ".join(match.group(1).split())
        prefix_match = re.match(r"([A-Za-z]+)", raw)
        if prefix_match and prefix_match.group(1).upper() in _EXCLUDED_ID_PREFIXES:
            continue
        normalized = normalize_identifier(raw)
        if normalized and normalized not in result:
            result.append(normalized)
    return result


def _clean_entity_name(text: str, identifiers: Iterable[str]) -> str:
    value = " ".join(str(text or "").split()).strip(" -:;|\t")
    for identifier in identifiers:
        identifier_text = str(identifier)
        if "-" in identifier_text and identifier_text.rsplit("-", 1)[-1].isdigit():
            prefix, number = identifier_text.rsplit("-", 1)
            raw_identifier = rf"{re.escape(prefix)}\s*[-_./ ]?\s*{re.escape(number)}"
        else:
            raw_identifier = re.escape(identifier_text)
        value = re.sub(rf"(?<!\w){raw_identifier}(?!\w)", " ", value, flags=re.IGNORECASE)
    value = re.sub(r"^\s*(?:id|code|name|feature|function|actor|use case|workflow|deliverable|component|entity|table|interface|objective|metric)\s*[:#=-]\s*", "", value, flags=re.IGNORECASE)
    value = re.sub(r"\b(?:user[- ]?facing|non[- ]?user[- ]?facing)\b", " ", value, flags=re.IGNORECASE)
    value = re.sub(r"^[\s\-–—:;,.#]+|[\s\-–—:;,.|]+$", "", value)
    value = re.sub(r"\(\s*\)|\[\s*\]", " ", value)
    value = re.sub(r"\s+", " ", value).strip()
    return value[:500]


def _looks_like_non_entity(text: str) -> bool:
    value = normalize_name(text)
    if not value:
        return True
    if value in {
        "n a", "na", "not applicable", "none", "nil", "total", "subtotal", "status", "description", "name", "value",
        "major features", "project deliverables", "deliverable package", "feature requirements", "functional requirements",
        "test cases", "test reports", "test strategy", "user manual", "actors", "use cases", "external interfaces",
        "database design", "system architecture", "quality management", "wbs", "feature", "function", "workflow", "deliverable", "entity", "component",
    }:
        return True
    if re.fullmatch(r"[\d\W]+", text):
        return True
    return False


def _looks_like_list_item(text: str, style_name: str | None) -> bool:
    return bool(style_name and "list" in style_name.casefold()) or bool(re.match(r"^\s*(?:[-*•]|\d+[.)])\s+", text))


def _user_facing(text: str) -> bool | None:
    value = text.casefold()
    if re.search(r"\b(?:non[- ]?user[- ]?facing|background|daemon|service[- ]only|internal[- ]only|without\s+(?:a\s+)?ui|no\s+ui)\b", value):
        return False
    if re.search(r"\b(?:user[- ]?facing|user interface|\bui\b|screen|manual|workflow|actor|click|display)\b", value):
        return True
    return None


def _is_measurable(text: str) -> bool | None:
    value = text.casefold()
    if re.search(r"(?:\d+(?:\.\d+)?\s*%|\d+(?:\.\d+)?\s*(?:ms|s|sec|seconds?|minutes?|hours?|days?)|target|threshold|within|at least|no more than|coverage|defect|availability|reliability|performance|timeliness)", value):
        return True
    if any(word in value.split() for word in ("quality", "usability", "maintainability")):
        return None
    return False


def _section_contains_any(section: Section, hints: Iterable[str]) -> bool:
    title = normalize_name(section.title)
    return any(normalize_name(hint) and normalize_name(hint) in title for hint in hints)


def _minimal_scopes(sections: list[Section]) -> list[Section]:
    paths = {section.path for section in sections}
    return [section for section in sections if not any(parent.path in paths for parent in _ancestors(section, sections))]


def _ancestors(section: Section, candidates: list[Section]) -> Iterable[Section]:
    parent_path = section.parent_path
    lookup = {candidate.path: candidate for candidate in candidates}
    while parent_path:
        parent = lookup.get(parent_path)
        if parent is None:
            break
        yield parent
        parent_path = parent.parent_path


def _tables_for_section(document: Document, section: Section) -> list[Table]:
    paths = {item.path for item in section.all_sections()}
    return [table for table in document.tables if table.parent_section in paths]


def _looks_like_header(headers: list[str]) -> bool:
    if not headers:
        return False
    words = {word for header in headers for word in header.split()}
    return len([header for header in headers if header]) >= 2 and bool(words.intersection({"id", "name", "description", "feature", "function", "actor", "status", "code", "deliverable", "entity", "workflow", "test"}))


def _row_is_non_content(row: list[Cell]) -> bool:
    non_empty = [cell for cell in row if not cell.is_empty]
    if not non_empty:
        return True
    return all(
        cell.classification in {ContentClass.PLACEHOLDER, ContentClass.TEMPLATE_INSTRUCTION, ContentClass.SAMPLE_RESIDUE}
        for cell in non_empty
    )


def _row_fields(headers: list[str], row: list[Cell]) -> dict[str, Any]:
    fields: dict[str, Any] = {}
    for index, cell in enumerate(row):
        key = headers[index] if index < len(headers) and headers[index] else f"column {index + 1}"
        fields[key] = cell.value if cell.value is not None else cell.original_text
    return fields


def _field_value(fields: dict[str, Any], names: Iterable[str]) -> Any:
    wanted = {normalize_name(name) for name in names}
    for key, value in fields.items():
        if normalize_name(key) in wanted and value is not None and str(value).strip():
            return value
    return None


def _metadata_from_fields(fields: dict[str, Any], kind: str) -> dict[str, Any]:
    metadata: dict[str, Any] = {}
    for key, value in fields.items():
        normalized = normalize_name(key)
        if normalized in {"status", "state", "version", "release", "planned", "deadline", "date", "testing round", "round 1", "round 2", "round 3"}:
            metadata[normalized.replace(" ", "_")] = value
    return metadata


def _test_stage_for_section(section: str | None) -> str:
    value = normalize_name(section or "")
    if any(token in value for token in ("test strategy", "testing types", "test levels", "supporting tools")):
        return "strategy"
    if any(token in value for token in ("test report", "test statistics", "result")):
        return "result"
    return "case"


def _logical_artifact_domain(domain: str, artifact_id: str) -> str:
    value = _domain_alias(domain)
    artifact = _domain_alias(artifact_id)
    if value in {"tests", "test"} or artifact.startswith("test") or artifact.startswith("report5"):
        return "report5"
    return value


def _test_stage(sheet_name: str, fields: dict[str, Any]) -> str:
    value = " ".join(f"{key} {field}" for key, field in fields.items()).casefold()
    sheet_value = sheet_name.casefold()
    if any(token in value for token in ("integration", "system", "acceptance")) or any(token in sheet_value for token in ("feature", "report", "statistic", "result")):
        return "result"
    if "strategy" in sheet_value:
        return "strategy"
    return "case"


def _sheet_rows_and_headers(sheet: Sheet) -> tuple[list[tuple[int, list[Cell]]], list[str]]:
    header_row = min(sheet.detected_header_rows) if sheet.detected_header_rows else _detected_header(sheet)
    if header_row <= 0:
        header_row = 1
    header_cells = sheet.rows[header_row - 1] if 1 <= header_row <= len(sheet.rows) else []
    headers = [normalize_name(cell.original_text or str(cell.value)) for cell in header_cells]
    rows = [(number, row) for number, row in enumerate(sheet.rows[header_row:], start=header_row + 1)]
    return rows, headers


def _detected_header(sheet: Sheet) -> int:
    for number, row in enumerate(sheet.rows[:30], start=1):
        values = [normalize_name(cell.original_text or str(cell.value)) for cell in row if not cell.is_empty]
        if _looks_like_header(values):
            return number
    return 1


def _row_location(row: list[Cell], sheet: Sheet, row_number: int) -> Any:
    if row:
        return row[0].source_location
    return sheet.source_location


def _related_sections(left: str | None, right: str | None) -> bool:
    if not left or not right:
        return False
    left_value = str(left)
    right_value = str(right)
    return left_value == right_value or left_value.startswith(right_value + " / ") or right_value.startswith(left_value + " / ")


def _location_key(location: Any) -> str:
    if hasattr(location, "display"):
        return location.display()
    return str(location or "")
