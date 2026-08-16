"""Deterministic, provenance-preserving semantic evidence packet construction."""

from __future__ import annotations

from fnmatch import fnmatch
import json
from pathlib import PurePosixPath
from typing import Any, Iterable

from ..document_set import DocumentSet, _domain_alias
from ..model import Block, Document, Section, Table
from ..repository.model import RepositoryEvidence, RepositorySnapshot
from ..results import Finding
from ..spec import CapstoneSpec
from ..trace_model import TraceEntity, TraceGraph
from .model import EvidencePacket, SemanticEvidence, SemanticReviewTask, stable_id
from .planner import finding_reference
from .prompts import PromptRenderer


_DEFAULT_SECRET_PATTERNS = (
    ".env",
    ".env.*",
    "*.credentials",
    "*credentials*",
    "*.key",
    "*.p12",
    "*.pfx",
    "id_rsa*",
    "id_ed25519*",
    "*private*.pem",
    "*_key.pem",
)
_MIN_PACKET_TOKENS = 512


class EvidencePacketBuilder:
    """Select exact sections and directly linked evidence under a hard budget."""

    def __init__(
        self,
        spec: CapstoneSpec,
        *,
        max_input_tokens: int = 12_000,
        excluded_paths: Iterable[str] = (),
        prompt_renderer: PromptRenderer | None = None,
    ) -> None:
        if max_input_tokens < _MIN_PACKET_TOKENS:
            raise ValueError(f"max_input_tokens must be at least {_MIN_PACKET_TOKENS}")
        self.spec = spec
        self.max_input_tokens = max_input_tokens
        self.excluded_paths = tuple(str(value) for value in excluded_paths if str(value))
        self.prompt_renderer = prompt_renderer or PromptRenderer()

    def build(
        self,
        task: SemanticReviewTask,
        document_set: DocumentSet,
        graph: TraceGraph,
        deterministic_findings: Iterable[Finding],
        *,
        repository_snapshot: RepositorySnapshot | None = None,
    ) -> EvidencePacket:
        findings = list(deterministic_findings)
        excluded: list[dict[str, Any]] = []
        categories: dict[str, list[SemanticEvidence]] = {
            "contract_requirements": [],
            "document_evidence": [],
            "cross_document_evidence": [],
            "repository_evidence": [],
            "deterministic_findings": [],
        }

        self._add_contract_evidence(task, categories)
        self._add_exact_section_evidence(task, document_set, categories, excluded)
        self._add_trace_evidence(task, graph, categories, excluded)
        self._add_finding_evidence(task, findings, categories, excluded)
        if repository_snapshot is not None:
            self._add_repository_references(task, repository_snapshot, categories, excluded)
        excluded = _unique_exclusions(excluded)

        provenance = {
            "spec_version": self.spec.version,
            "spec_path": str(self.spec.path),
            "source_precedence": self.spec.semantic_review_extension.get("source_precedence", {}),
            "document_set_manifest": document_set.source_manifest_path,
            "selected_sources": document_set.selected_sources,
            "repository_snapshot": repository_snapshot.audit_metadata if repository_snapshot else None,
            "visual_evidence": {
                "requested": bool(task.metadata.get("requires_visual")),
                "selected": any(
                    item.kind == "image_reference"
                    for values in categories.values()
                    for item in values
                ),
                "bytes_available": False,
            },
        }
        packet = EvidencePacket(
            packet_id="pending",
            task=task,
            provenance=provenance,
            excluded_evidence=excluded,
        )
        budgeted, truncated = self._apply_budget(task, categories, provenance, excluded)
        for category, values in budgeted.items():
            setattr(packet, category, values)
        packet.truncated_evidence = truncated
        packet.budget = {
            "strategy": "priority_then_source_order",
            "max_input_tokens": self.max_input_tokens,
            "priority_order": [
                "exact section",
                "contract requirement",
                "direct trace entities",
                "repository evidence",
                "parent/child context",
                "deterministic finding",
            ],
        }
        packet.packet_id = stable_id(
            "packet",
            task.task_id,
            [(item.evidence_id, item.content, item.truncated) for item in packet.all_evidence],
        )
        packet.budget["estimated_input_tokens"] = self._estimated_input_tokens(task, packet)
        packet.budget["evidence_count"] = len(packet.all_evidence)
        return packet

    def _add_contract_evidence(
        self,
        task: SemanticReviewTask,
        categories: dict[str, list[SemanticEvidence]],
    ) -> None:
        requirement = str(task.metadata.get("contract_requirement") or "").strip()
        if not requirement:
            requirement = task.question
        path = str(
            task.metadata.get("section_rule_path")
            or task.metadata.get("trigger_rule_id")
            or task.rule_id
        )
        categories["contract_requirements"].append(
            SemanticEvidence(
                evidence_id=stable_id("contract", path, requirement),
                kind="contract_requirement",
                content=requirement,
                priority=2,
                report=task.metadata.get("source_domain"),
                section_path=task.metadata.get("source_section"),
                source_path=str(self.spec.path),
                source_location=path,
                metadata={
                    "requirement": task.metadata.get("requirement", task.metadata.get("rule_requirement")),
                    "spec_path": path,
                },
            )
        )

    def _add_exact_section_evidence(
        self,
        task: SemanticReviewTask,
        document_set: DocumentSet,
        categories: dict[str, list[SemanticEvidence]],
        excluded: list[dict[str, Any]],
    ) -> None:
        source_path = task.metadata.get("source_path")
        section_path = task.metadata.get("source_section")
        source_domain = _domain_alias(str(task.metadata.get("source_domain", "")))
        if not source_path or not section_path:
            return
        for artifact in document_set.domain_artifacts(source_domain):
            document = artifact.document
            if document.source_path != source_path or not isinstance(document, Document):
                continue
            if not self._path_allowed(document.source_path):
                excluded.append(self._excluded(document.source_path, "configured or secret-class path", required=True))
                return
            section = next((item for item in document.all_sections() if item.path == section_path), None)
            if section is None:
                return
            categories["document_evidence"].extend(
                self._section_evidence(document, section, source_domain, priority=1, scope="exact")
            )
            categories["document_evidence"].extend(
                self._context_evidence(document, section, source_domain)
            )

    def _section_evidence(
        self,
        document: Document,
        section: Section,
        report: str,
        *,
        priority: int,
        scope: str,
    ) -> list[SemanticEvidence]:
        result: list[SemanticEvidence] = []
        for block in document.raw_blocks:
            if block.section_path != section.path or block.kind == "heading" or not block.text.strip():
                continue
            result.append(self._block_evidence(document, report, block, priority=priority, scope=scope))
        for index, table in enumerate(document.tables):
            if table.parent_section != section.path:
                continue
            result.append(self._table_evidence(document, report, table, index, priority=priority, scope=scope))
        for image in document.images:
            if image.parent_section != section.path:
                continue
            location = image.source_location.to_dict() if image.source_location else None
            result.append(
                SemanticEvidence(
                    evidence_id=stable_id(
                        "image",
                        document.source_path,
                        section.path,
                        image.relationship_id,
                        location,
                    ),
                    kind="image_reference",
                    content=json.dumps(
                        {
                            "description": image.description,
                            "filename": image.filename,
                            "width": image.width,
                            "height": image.height,
                        },
                        ensure_ascii=False,
                        sort_keys=True,
                    ),
                    priority=priority,
                    report=report,
                    section_path=section.path,
                    source_path=document.source_path,
                    source_location=location,
                    metadata={"scope": scope, "visual_available": False},
                )
            )
        return result

    def _context_evidence(
        self,
        document: Document,
        section: Section,
        report: str,
    ) -> list[SemanticEvidence]:
        result: list[SemanticEvidence] = []
        if section.parent_path:
            parent = next((item for item in document.all_sections() if item.path == section.parent_path), None)
            if parent is not None:
                parent_blocks = [
                    block
                    for block in document.raw_blocks
                    if block.section_path == parent.path and block.kind != "heading" and block.text.strip()
                ]
                if parent_blocks:
                    result.append(
                        self._block_evidence(
                            document,
                            report,
                            parent_blocks[-1],
                            priority=5,
                            scope="parent_context",
                        )
                    )
        for child in section.children:
            child_block = next(
                (
                    block
                    for block in document.raw_blocks
                    if block.section_path == child.path and block.kind != "heading" and block.text.strip()
                ),
                None,
            )
            content = child.title if child_block is None else f"{child.title}\n{child_block.original_text or child_block.text}"
            result.append(
                SemanticEvidence(
                    evidence_id=stable_id("context", document.source_path, child.path, content),
                    kind="section_context",
                    content=content,
                    priority=5,
                    report=report,
                    section_path=child.path,
                    source_path=document.source_path,
                    source_location=child.source_location,
                    metadata={"scope": "child_context"},
                )
            )
        return result

    def _block_evidence(
        self,
        document: Document,
        report: str,
        block: Block,
        *,
        priority: int,
        scope: str,
    ) -> SemanticEvidence:
        location = block.source_location.to_dict() if block.source_location else None
        content = block.original_text or block.text
        return SemanticEvidence(
            evidence_id=stable_id("doc", document.source_path, block.section_path, location, content),
            kind="document_block",
            content=content,
            priority=priority,
            report=report,
            section_path=block.section_path,
            source_path=document.source_path,
            source_location=location,
            metadata={
                "block_kind": block.kind,
                "classification": block.classification.value if block.classification else None,
                "scope": scope,
            },
        )

    def _table_evidence(
        self,
        document: Document,
        report: str,
        table: Table,
        index: int,
        *,
        priority: int,
        scope: str,
    ) -> SemanticEvidence:
        location = table.source_location.to_dict() if table.source_location else None
        content = "\n".join(" | ".join(cell.original_text for cell in row) for row in table.rows)
        return SemanticEvidence(
            evidence_id=stable_id("table", document.source_path, index, location, content),
            kind="document_table",
            content=content,
            priority=priority,
            report=report,
            section_path=table.parent_section,
            source_path=document.source_path,
            source_location=location,
            metadata={"dimensions": table.dimensions, "scope": scope, "table_index": index},
        )

    def _add_trace_evidence(
        self,
        task: SemanticReviewTask,
        graph: TraceGraph,
        categories: dict[str, list[SemanticEvidence]],
        excluded: list[dict[str, Any]],
    ) -> None:
        entity_ids = [reference.removeprefix("trace:") for reference in task.evidence_refs if reference.startswith("trace:")]
        entity_ids.extend(
            str(value)
            for value in [task.metadata.get("source_entity_id"), *task.metadata.get("target_entity_ids", [])]
            if value
        )
        for entity_id in dict.fromkeys(entity_ids):
            entity = graph.node(entity_id)
            if entity is None:
                continue
            categories["cross_document_evidence"].extend(
                self._entity_evidence(entity, excluded)
            )

    def _entity_evidence(
        self,
        entity: TraceEntity,
        excluded: list[dict[str, Any]],
    ) -> list[SemanticEvidence]:
        result: list[SemanticEvidence] = []
        summary_content = json.dumps(
            {
                "entity_id": entity.entity_id,
                "kind": entity.kind,
                "canonical_name": entity.canonical_name,
                "identifiers": entity.identifiers,
                "aliases": entity.aliases,
            },
            ensure_ascii=False,
            sort_keys=True,
        )
        result.append(
            SemanticEvidence(
                evidence_id=stable_id("trace", entity.entity_id, "summary"),
                kind="trace_entity",
                content=summary_content,
                priority=3,
                report=entity.source_report,
                section_path=entity.source_section,
                source_location=entity.source_location,
                metadata={"entity_id": entity.entity_id, "entity_kind": entity.kind},
            )
        )
        for index, raw in enumerate(entity.evidence):
            if isinstance(raw, dict):
                source_path = str(raw.get("source_path")) if raw.get("source_path") else None
                if source_path and not self._path_allowed(source_path):
                    excluded.append(self._excluded(source_path, "configured or secret-class path", required=True))
                    continue
                content = _evidence_content(raw)
                location = raw.get("location", raw.get("source_location"))
                kind = str(raw.get("kind", "trace_excerpt"))
                section = str(raw.get("section", entity.source_section)) if raw.get("section", entity.source_section) else None
            else:
                source_path = None
                content = str(raw)
                location = entity.source_location
                kind = "trace_excerpt"
                section = entity.source_section
            if not content.strip():
                continue
            result.append(
                SemanticEvidence(
                    evidence_id=stable_id("trace-evidence", entity.entity_id, index, content, location),
                    kind=kind,
                    content=content,
                    priority=3,
                    report=entity.source_report,
                    section_path=section,
                    source_path=source_path,
                    source_location=location,
                    metadata={"entity_id": entity.entity_id},
                )
            )
        return result

    def _add_finding_evidence(
        self,
        task: SemanticReviewTask,
        findings: list[Finding],
        categories: dict[str, list[SemanticEvidence]],
        excluded: list[dict[str, Any]],
    ) -> None:
        requested = task.metadata.get("finding_reference")
        if not requested:
            return
        finding = next((item for item in findings if finding_reference(item) == requested), None)
        if finding is None:
            return
        content = json.dumps(
            {
                "status": finding.status.value,
                "severity": finding.severity,
                "rule_id": finding.rule_id,
                "message": finding.message,
                "source_requirement": finding.source_requirement,
                "target_domain": finding.target_domain,
                "metadata": finding.metadata,
            },
            ensure_ascii=False,
            sort_keys=True,
            default=str,
        )
        categories["deterministic_findings"].append(
            SemanticEvidence(
                evidence_id=stable_id("deterministic", requested, content),
                kind="deterministic_finding",
                content=content,
                priority=6,
                report=finding.report,
                section_path=finding.section,
                source_location=finding.location,
                metadata={
                    "finding_reference": requested,
                    "validator": finding.validator,
                    "deterministic_status": finding.status.value,
                },
            )
        )
        if isinstance(finding.source_entity, dict):
            source_entity = finding.source_entity
            source_content = json.dumps(
                {
                    key: source_entity.get(key)
                    for key in ("entity_id", "claim_id", "kind", "canonical_name", "identifiers", "aliases")
                    if source_entity.get(key) not in (None, "", [])
                },
                ensure_ascii=False,
                sort_keys=True,
                default=str,
            )
            categories["cross_document_evidence"].append(
                SemanticEvidence(
                    evidence_id=stable_id("finding-source", requested, source_content),
                    kind="finding_source_claim",
                    content=source_content,
                    priority=3,
                    report=finding.report,
                    section_path=finding.section,
                    source_location=finding.location,
                    metadata={"finding_reference": requested},
                )
            )
            documentation = source_entity.get("documentation_evidence", [])
            for index, raw in enumerate(documentation if isinstance(documentation, list) else []):
                if not isinstance(raw, dict):
                    continue
                source_path = str(raw.get("source_path")) if raw.get("source_path") else None
                if source_path and not self._path_allowed(source_path):
                    excluded.append(self._excluded(source_path, "configured or secret-class path", required=True))
                    continue
                excerpt = _evidence_content(raw)
                if not excerpt.strip():
                    continue
                categories["document_evidence"].append(
                    SemanticEvidence(
                        evidence_id=stable_id("finding-doc", requested, index, excerpt),
                        kind=str(raw.get("kind", "documentation_claim")),
                        content=excerpt,
                        priority=3,
                        report=str(raw.get("report", finding.report)),
                        section_path=raw.get("section", finding.section),
                        source_path=source_path,
                        source_location=raw.get("location", raw.get("source_location")),
                        metadata={"finding_reference": requested},
                    )
                )
        for index, raw in enumerate(finding.candidate_entities):
            if not isinstance(raw, dict) or not raw.get("evidence_id"):
                continue
            item = self._repository_dict_evidence(raw, priority=4)
            if item.source_path and not self._path_allowed(item.source_path):
                excluded.append(self._excluded(item.source_path, "configured or secret-class path", required=True))
                continue
            categories["repository_evidence"].append(item)

    def _add_repository_references(
        self,
        task: SemanticReviewTask,
        snapshot: RepositorySnapshot,
        categories: dict[str, list[SemanticEvidence]],
        excluded: list[dict[str, Any]],
    ) -> None:
        requested = {
            reference.removeprefix("repository:")
            for reference in task.evidence_refs
            if reference.startswith("repository:")
        }
        if not requested:
            return
        for item in snapshot.all_evidence():
            if item.evidence_id not in requested:
                continue
            if not self._path_allowed(item.path):
                excluded.append(self._excluded(item.path, "configured or secret-class path", required=True))
                continue
            categories["repository_evidence"].append(self._repository_evidence(item))

    @staticmethod
    def _repository_evidence(item: RepositoryEvidence) -> SemanticEvidence:
        return SemanticEvidence(
            evidence_id=stable_id("repo", item.evidence_id),
            kind=f"repository_{item.kind.value.casefold()}",
            content=item.excerpt_or_signature or item.symbol or item.module or item.path,
            priority=4,
            source_path=item.path,
            source_location=item.location,
            metadata={
                "repository_evidence_id": item.evidence_id,
                "symbol": item.symbol,
                "module": item.module,
                **item.metadata,
            },
        )

    @staticmethod
    def _repository_dict_evidence(raw: dict[str, Any], *, priority: int) -> SemanticEvidence:
        content = str(
            raw.get("excerpt_or_signature")
            or raw.get("symbol")
            or raw.get("module")
            or raw.get("path")
            or ""
        )
        return SemanticEvidence(
            evidence_id=stable_id("repo", raw.get("evidence_id")),
            kind=f"repository_{str(raw.get('kind', 'evidence')).casefold()}",
            content=content,
            priority=priority,
            source_path=str(raw.get("path")) if raw.get("path") else None,
            source_location=raw.get("location", raw.get("line_range")),
            metadata={
                "repository_evidence_id": raw.get("evidence_id"),
                "symbol": raw.get("symbol"),
                "module": raw.get("module"),
                **(raw.get("metadata", {}) if isinstance(raw.get("metadata"), dict) else {}),
            },
        )

    def _apply_budget(
        self,
        task: SemanticReviewTask,
        categories: dict[str, list[SemanticEvidence]],
        provenance: dict[str, Any],
        excluded: list[dict[str, Any]],
    ) -> tuple[dict[str, list[SemanticEvidence]], list[dict[str, Any]]]:
        result = {key: [] for key in categories}
        packet = EvidencePacket(
            "budget-check",
            task,
            provenance=provenance,
            excluded_evidence=excluded,
        )
        fixed_prompt_tokens = self._estimated_input_tokens(task, packet)
        if fixed_prompt_tokens > self.max_input_tokens:
            raise ValueError(
                f"semantic task {task.task_id} requires {fixed_prompt_tokens} input tokens "
                f"before evidence, exceeding the {self.max_input_tokens}-token limit"
            )
        for category, values in result.items():
            setattr(packet, category, values)

        truncated: list[dict[str, Any]] = []
        ordered: list[tuple[int, int, str, SemanticEvidence]] = []
        sequence = 0
        seen: set[str] = set()
        for category, values in categories.items():
            for item in values:
                if item.evidence_id in seen:
                    continue
                seen.add(item.evidence_id)
                ordered.append((item.priority, sequence, category, item))
                sequence += 1
        ordered.sort(key=lambda value: (value[0], value[1]))
        for _priority, _sequence, category, item in ordered:
            result[category].append(item)
            if self._estimated_input_tokens(task, packet) <= self.max_input_tokens:
                continue
            result[category].pop()

            bounded = self._largest_fitting_item(task, packet, category, item)
            if bounded is not None and len(bounded.content) >= 80:
                result[category].append(bounded)
                truncated.append(
                    {
                        "evidence_id": item.evidence_id,
                        "original_characters": len(item.content),
                        "included_characters": len(bounded.content),
                        "included": True,
                    }
                )
                continue
            truncated.append(
                {
                    "evidence_id": item.evidence_id,
                    "original_characters": len(item.content),
                    "included_characters": 0,
                    "included": False,
                    "required": item.priority <= 4,
                }
            )
        return result, truncated

    def _largest_fitting_item(
        self,
        task: SemanticReviewTask,
        packet: EvidencePacket,
        category: str,
        item: SemanticEvidence,
    ) -> SemanticEvidence | None:
        low = 0
        high = max(0, len(item.content) - 1)
        best: SemanticEvidence | None = None
        values = getattr(packet, category)
        while low <= high:
            length = (low + high) // 2
            content = item.content[:length].rstrip() + "…"
            candidate = item.with_content(content, truncated=True)
            values.append(candidate)
            fits = self._estimated_input_tokens(task, packet) <= self.max_input_tokens
            values.pop()
            if fits:
                best = candidate
                low = length + 1
            else:
                high = length - 1
        return best

    def _estimated_input_tokens(
        self,
        task: SemanticReviewTask,
        packet: EvidencePacket,
    ) -> int:
        return self.prompt_renderer.render(task, packet).estimated_input_tokens

    def _path_allowed(self, value: str) -> bool:
        path = str(value).replace("\\", "/")
        name = PurePosixPath(path).name
        patterns = (*_DEFAULT_SECRET_PATTERNS, *self.excluded_paths)
        return not any(
            fnmatch(path.casefold(), pattern.replace("\\", "/").casefold())
            or fnmatch(name.casefold(), pattern.casefold())
            for pattern in patterns
        )

    @staticmethod
    def _excluded(path: str, reason: str, *, required: bool) -> dict[str, Any]:
        return {
            "path": path,
            "reason": reason,
            "required_for_task": required,
        }


def _evidence_content(raw: dict[str, Any]) -> str:
    for key in ("text", "original_text", "value", "excerpt_or_signature", "signature"):
        if raw.get(key) not in (None, ""):
            return str(raw[key])
    compact = {
        str(key): value
        for key, value in raw.items()
        if key not in {"source_path", "location", "source_location", "metadata"}
    }
    return json.dumps(compact, ensure_ascii=False, sort_keys=True, default=str)


def _unique_exclusions(values: list[dict[str, Any]]) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    seen: set[tuple[Any, ...]] = set()
    for value in values:
        key = (value.get("path"), value.get("reason"), value.get("required_for_task"))
        if key in seen:
            continue
        seen.add(key)
        result.append(value)
    return result
