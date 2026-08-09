"""Deterministic cross-document traceability validation (Phase 2)."""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
import re
from typing import Any, Iterable

from ..document_set import DocumentArtifact, DocumentSet, _domain_alias
from ..model import Document, NormalizedDocument, Workbook
from ..results import Finding, Status, ValidationResult
from ..spec import CapstoneSpec, OrphanRule, TraceRule, TraceTargetRule
from ..trace_entities import TraceEntityExtractor, _document_blocks
from ..trace_model import (
    MatchMethod,
    MatchResult,
    TraceEntity,
    TraceGraph,
    TraceIndex,
    TraceLinkStatus,
    TraceEdge,
    _unique_entities,
    normalize_name,
)


@dataclass(frozen=True)
class _StructuredValue:
    semantic_field: str
    value: str
    location: str | None
    section: str | None


_SUPPORTED_HANDLERS = {
    "feature_coverage": "feature_coverage",
    "feature_trace": "feature_coverage",
    "actor_use_case": "actor_use_case",
    "actor_usecase": "actor_use_case",
    "external_interface": "external_interface",
    "interface_trace": "external_interface",
    "data_entity": "data_entity",
    "entity_data": "data_entity",
    "quality_objective": "quality_objective",
    "deliverable": "deliverable",
    "deliverables": "deliverable",
    "freshness": "freshness",
    "xt-001": "feature_coverage",
    "xt-002": "actor_use_case",
    "xt-003": "external_interface",
    "xt-004": "data_entity",
    "xt-005": "quality_objective",
    "xt-006": "deliverable",
}


class CrossDocumentValidator:
    """Build a trace graph and execute contract-defined traceability rules.

    ``validate`` retains the Phase 1 extension-point return type (a list of
    findings).  ``audit`` is the richer Phase 2 API and returns a
    ``ValidationResult`` containing graph, coverage, and freshness metadata.
    """

    def __init__(self, spec: CapstoneSpec | None = None) -> None:
        self.spec = spec
        self.extractor = TraceEntityExtractor(spec)

    def validate(self, documents: DocumentSet | dict[str, NormalizedDocument]) -> list[Finding]:
        return self.audit(documents).findings

    def build_graph(self, documents: DocumentSet | dict[str, NormalizedDocument]) -> TraceGraph:
        return self.extractor.extract_document_set(self._as_document_set(documents))

    def audit(self, documents: DocumentSet | dict[str, NormalizedDocument]) -> ValidationResult:
        document_set = self._as_document_set(documents)
        if self.spec is None:
            return ValidationResult(
                source_path=document_set.source_manifest_path or "document-set",
                report="document_set",
                format="cross_document",
                metadata={"document_set": document_set.to_dict(), "trace_graph": TraceGraph().to_dict()},
            )

        graph = self.extractor.extract_document_set(document_set)
        index = TraceIndex(graph)
        findings: list[Finding] = list(document_set.load_findings)
        findings.extend(self._missing_target_domain_findings(document_set, list(self.spec.iter_trace_rules())))
        coverage: dict[str, Any] = {}
        freshness: list[dict[str, Any]] = []
        quality: list[dict[str, Any]] = []

        findings.extend(self._duplicate_identifier_findings(index))
        rules = list(self.spec.iter_trace_rules())
        for rule in rules:
            handler = _SUPPORTED_HANDLERS.get(rule.handler.casefold(), _SUPPORTED_HANDLERS.get(rule.rule_id.casefold()))
            if handler is None:
                findings.append(
                    self._finding(
                        status=Status.FAIL,
                        severity="error",
                        rule_id=rule.rule_id,
                        report=rule.source_domain or "document_set",
                        message=f"Unknown cross-document rule handler {rule.handler!r}; the rule was not silently ignored.",
                        spec_path=rule.path,
                        metadata={"configuration_error": True, "handler": rule.handler},
                    )
                )
                continue
            if handler == "feature_coverage":
                rule_coverage, rule_findings = self._run_trace_rule(document_set, graph, index, rule)
                coverage[rule.rule_id] = rule_coverage
                findings.extend(rule_findings)
                if _truthy((rule.data or {}).get("freshness")) or rule.rule_id.casefold() == "xt-006":
                    fresh, fresh_findings = self._run_freshness(document_set, graph, index, rule)
                    freshness.extend(fresh)
                    findings.extend(fresh_findings)
            elif handler == "quality_objective":
                rule_quality, rule_findings = self._run_quality_objectives(document_set, graph, index, rule)
                quality.extend(rule_quality)
                coverage[rule.rule_id] = rule_quality
                findings.extend(rule_findings)
            elif handler == "deliverable":
                rule_coverage, rule_findings = self._run_trace_rule(document_set, graph, index, rule)
                coverage[rule.rule_id] = rule_coverage
                findings.extend(rule_findings)
                findings.extend(self._run_deliverable_reverse_checks(document_set, graph, index, rule))
                if _truthy((rule.data or {}).get("freshness")) or rule.rule_id.casefold() == "xt-006":
                    fresh, fresh_findings = self._run_freshness(document_set, graph, index, rule)
                    freshness.extend(fresh)
                    findings.extend(fresh_findings)
            else:
                rule_coverage, rule_findings = self._run_trace_rule(document_set, graph, index, rule)
                coverage[rule.rule_id] = rule_coverage
                findings.extend(rule_findings)
                if handler == "external_interface":
                    orphan_findings = self._run_directional_interface_checks(document_set, graph, index, rule)
                    findings.extend(orphan_findings)
                elif handler == "data_entity":
                    findings.extend(self._run_directional_data_checks(document_set, graph, index, rule))

        for orphan_rule in self.spec.iter_orphan_rules():
            findings.extend(self._run_orphan_rule(document_set, graph, index, orphan_rule))

        # An explicit report7 freshness rule is supported, while the XT-006
        # handler above supplies the normal contract configuration.
        for rule in rules:
            if _SUPPORTED_HANDLERS.get(rule.handler.casefold()) == "freshness":
                fresh, fresh_findings = self._run_freshness(document_set, graph, index, rule)
                freshness.extend(fresh)
                findings.extend(fresh_findings)

        metadata = {
            "spec_version": self.spec.version,
            "document_set": document_set.to_dict(),
            "trace_graph": graph.to_dict(),
            "coverage": coverage,
            "freshness": freshness,
            "quality_objectives": quality,
            "entity_count": len(graph.nodes),
            "edge_count": len(graph.edges),
        }
        return ValidationResult(
            source_path=document_set.source_manifest_path or "document-set",
            report="document_set",
            format="cross_document",
            findings=findings,
            metadata=metadata,
        )

    def _as_document_set(self, documents: DocumentSet | dict[str, NormalizedDocument]) -> DocumentSet:
        if isinstance(documents, DocumentSet):
            return documents
        result = DocumentSet(reports=dict(documents), source_manifest={"reports": sorted(documents)})
        for report_id, document in documents.items():
            result.add_artifact(DocumentArtifact(str(report_id), str(report_id), document))
        return result

    def _missing_target_domain_findings(self, document_set: DocumentSet, rules: list[TraceRule]) -> list[Finding]:
        findings: list[Finding] = []
        already_reported = {finding.report for finding in document_set.load_findings if finding.rule_id == "SET-002"}
        seen: set[str] = set()
        for rule in rules:
            for target in rule.targets:
                domain = _domain_alias(target.domain)
                if target.requirement not in {"MUST", "SHOULD", "CONDITIONAL"} or domain in seen or self._domain_present(document_set, domain):
                    continue
                if domain in already_reported:
                    continue
                seen.add(domain)
                findings.append(
                    self._finding(
                        status=Status.WARNING,
                        severity="warning",
                        rule_id="SET-007",
                        report="document_set",
                        message=f"Target domain {domain!r} is not present in the audit set; dependent trace rules may be incomplete.",
                        target_domain=domain,
                        spec_path="cross_document_traceability",
                        metadata={"missing_domain": domain, "dependent_rules": [rule.rule_id]},
                    )
                )
        return findings

    def _run_trace_rule(
        self,
        document_set: DocumentSet,
        graph: TraceGraph,
        index: TraceIndex,
        rule: TraceRule,
    ) -> tuple[list[dict[str, Any]], list[Finding]]:
        source_domain = _domain_alias(rule.source_domain)
        source_entities = _entities_for(graph, source_domain, rule.source_kinds)
        if not source_entities:
            if not self._domain_present(document_set, source_domain):
                return [], [
                    self._finding(
                        status=Status.FAIL,
                        severity="error",
                        rule_id=rule.rule_id,
                        report=source_domain,
                        message=f"Source domain {source_domain!r} is missing; {rule.rule_id} cannot be evaluated.",
                        target_domain=source_domain,
                        spec_path=rule.path,
                    )
                ]
            return [], [
                self._finding(
                    status=Status.REVIEW_REQUIRED,
                    severity="warning",
                    rule_id=rule.rule_id,
                    report=source_domain,
                    message=f"No deterministic source entities of kind {', '.join(rule.source_kinds)} were extracted from {source_domain}; review the source structure or add trace_entities configuration.",
                    target_domain=source_domain,
                    spec_path=rule.path,
                )
            ]

        summary: list[dict[str, Any]] = []
        findings: list[Finding] = []
        for source in source_entities:
            links: dict[str, str] = {}
            link_details: dict[str, Any] = {}
            for target in rule.targets:
                status, match, finding = self._check_link(document_set, index, rule, source, target)
                links[target.domain] = status.value
                link_details[target.domain] = {
                    "status": status.value,
                    "match_method": match.method.value,
                    "target_entities": [candidate.to_dict() for candidate in match.candidates],
                    "reason": match.reason,
                }
                if finding is not None:
                    findings.append(finding)
                if status == TraceLinkStatus.VERIFIED and match.candidates:
                    metadata_finding = self._metadata_conflict_finding(rule, source, target, match.candidates[0])
                    if metadata_finding is not None:
                        findings.append(metadata_finding)
                    for candidate in match.candidates[:1]:
                        graph.add_edge(
                            TraceEdge(
                                from_entity=source.entity_id,
                                to_entity=candidate.entity_id,
                                rule_id=rule.rule_id,
                                match_method=match.method,
                                confidence_class=match.method,
                                evidence=_link_evidence(source, candidate),
                            )
                        )
            summary.append(
                {
                    "source": source.to_dict(),
                    "links": links,
                    "link_details": link_details,
                }
            )
        return summary, findings

    def _check_link(
        self,
        document_set: DocumentSet,
        index: TraceIndex,
        rule: TraceRule,
        source: TraceEntity,
        target: TraceTargetRule,
    ) -> tuple[TraceLinkStatus, MatchResult, Finding | None]:
        target_domain = _domain_alias(target.domain)
        applicability = _evaluate_applicability(source, target.condition)
        if applicability is False:
            match = MatchResult(TraceLinkStatus.NOT_APPLICABLE, MatchMethod.STRUCTURAL_MAPPING, reason="Configured applicability is deterministically false.")
            return TraceLinkStatus.NOT_APPLICABLE, match, self._link_finding(rule, source, target, TraceLinkStatus.NOT_APPLICABLE, match)
        if target.allow_explicit_na and self._has_explicit_na(document_set, target_domain, source, target):
            match = MatchResult(TraceLinkStatus.NOT_APPLICABLE, MatchMethod.STRUCTURAL_MAPPING, reason="An explicit N/A rationale is present in the target scope.")
            return TraceLinkStatus.NOT_APPLICABLE, match, self._link_finding(rule, source, target, TraceLinkStatus.NOT_APPLICABLE, match)
        if applicability is None and target.condition is not None:
            match = MatchResult(
                TraceLinkStatus.REVIEW_REQUIRED,
                MatchMethod.AMBIGUOUS,
                reason="Target applicability cannot be determined from normalized evidence.",
            )
            return TraceLinkStatus.REVIEW_REQUIRED, match, self._link_finding(rule, source, target, TraceLinkStatus.REVIEW_REQUIRED, match)
        if not self._domain_present(document_set, target_domain):
            match = MatchResult(TraceLinkStatus.MISSING, MatchMethod.UNMATCHED, reason=f"Target domain {target_domain!r} is missing.")
            status = _missing_status(target.requirement)
            return status, match, self._link_finding(rule, source, target, status, match)
        match = self._match_target(index, source, target, target_domain)
        status = match.status
        if match.status == TraceLinkStatus.MISSING:
            status = _missing_status(target.requirement)
        finding = self._link_finding(rule, source, target, status, match)
        return status, match, finding

    def _match_target(
        self,
        index: TraceIndex,
        source: TraceEntity,
        target: TraceTargetRule,
        target_domain: str,
    ) -> MatchResult:
        if not target.role and not target.test_levels:
            return index.match(source, target_domain=target_domain, target_kinds=target.kinds)

        def state(candidate: TraceEntity) -> bool | None:
            return _target_constraint_state(candidate, target)

        matching = index.match(
            source,
            target_domain=target_domain,
            target_kinds=target.kinds,
            candidate_filter=lambda candidate: state(candidate) is True,
        )
        unknown = index.match(
            source,
            target_domain=target_domain,
            target_kinds=target.kinds,
            candidate_filter=lambda candidate: state(candidate) is None,
        )
        if matching.status in {TraceLinkStatus.VERIFIED, TraceLinkStatus.AMBIGUOUS} and unknown.status in {
            TraceLinkStatus.VERIFIED,
            TraceLinkStatus.AMBIGUOUS,
        }:
            candidates = _unique_entities([*matching.candidates, *unknown.candidates])
            return MatchResult(
                TraceLinkStatus.REVIEW_REQUIRED,
                MatchMethod.AMBIGUOUS,
                tuple(candidates),
                "A matching test candidate has an indeterminate configured level or role.",
            )
        if matching.status in {TraceLinkStatus.VERIFIED, TraceLinkStatus.AMBIGUOUS}:
            return matching
        if unknown.status in {TraceLinkStatus.VERIFIED, TraceLinkStatus.AMBIGUOUS}:
            return MatchResult(
                TraceLinkStatus.REVIEW_REQUIRED,
                MatchMethod.AMBIGUOUS,
                unknown.candidates,
                "A matching test candidate has an indeterminate configured level or role.",
            )
        return matching

    def _link_finding(
        self,
        rule: TraceRule,
        source: TraceEntity,
        target: TraceTargetRule,
        status: TraceLinkStatus,
        match: MatchResult,
    ) -> Finding:
        effective_requirement = target.requirement
        if effective_requirement == "CONDITIONAL" and _evaluate_applicability(source, target.condition) is True:
            effective_requirement = "MUST"
        finding_status, severity = _finding_status(status, effective_requirement)
        candidates = [candidate.to_dict() for candidate in match.candidates]
        if status == TraceLinkStatus.VERIFIED:
            message = f"Verified {source.kind} {source.canonical_name!r} in {target.domain} by {match.method.value}."
        elif status == TraceLinkStatus.NOT_APPLICABLE:
            message = f"{source.kind.capitalize()} {source.canonical_name!r} has no required link to {target.domain}: {match.reason or 'not applicable'}."
        elif status in {TraceLinkStatus.AMBIGUOUS, TraceLinkStatus.REVIEW_REQUIRED}:
            message = f"Review {source.kind} {source.canonical_name!r} → {target.domain}: {match.reason or 'multiple deterministic candidates remain'}."
        else:
            message = f"Missing required trace link for {source.kind} {source.canonical_name!r} in {target.domain}."
        return self._finding(
            status=finding_status,
            severity=severity,
            rule_id=rule.rule_id,
            report=source.source_report,
            section=source.source_section,
            location=source.source_location,
            message=message,
            evidence=_link_evidence(source, *match.candidates[:2]),
            source_entity=source,
            target_domain=target.domain,
            candidate_entities=candidates,
            source_requirement=f"{target.requirement} traceability link from {rule.source_domain} to {target.domain}.",
            spec_path=rule.path,
            metadata={
                "trace_status": status.value,
                "match_method": match.method.value,
                "requirement": target.requirement,
                "test_levels": list(target.test_levels),
                "role": target.role,
                "reason": match.reason,
            },
        )

    def _metadata_conflict_finding(
        self,
        rule: TraceRule,
        source: TraceEntity,
        target: TraceTargetRule,
        candidate: TraceEntity,
    ) -> Finding | None:
        if source.kind != "deliverable" and "deliverable" not in target.kinds and "tracking_item" not in target.kinds:
            return None
        conflicts: list[dict[str, Any]] = []
        for field in ("version", "status", "state"):
            source_value = source.metadata.get(field)
            target_value = candidate.metadata.get(field)
            if source_value in (None, "") or target_value in (None, ""):
                continue
            if normalize_name(str(source_value)) != normalize_name(str(target_value)):
                conflicts.append({"field": field, "source": source_value, "target": target_value})
        if not conflicts:
            return None
        return self._finding(
            status=Status.REVIEW_REQUIRED,
            severity="warning",
            rule_id=f"{rule.rule_id}.metadata",
            report=source.source_report,
            section=source.source_section,
            location=source.source_location,
            message=f"Deterministic deliverable metadata differs between {source.source_report} and {target.domain}.",
            evidence=_link_evidence(source, candidate),
            source_entity=source,
            target_domain=target.domain,
            candidate_entities=[candidate.to_dict()],
            spec_path=rule.path,
            metadata={"consistency": TraceLinkStatus.STALE_OR_CONTRADICTED.value, "conflicts": conflicts},
        )

    def _run_deliverable_reverse_checks(
        self,
        document_set: DocumentSet,
        graph: TraceGraph,
        index: TraceIndex,
        rule: TraceRule,
    ) -> list[Finding]:
        final_target = next((target for target in rule.targets if "final_report_item" in target.kinds), None)
        final_domain = _domain_alias(final_target.domain) if final_target else ""
        final_items = [
            entity
            for entity in _entities_for(graph, final_domain, ("final_report_item",))
            if "deliverable" in normalize_name(entity.source_section or "")
            or "release package" in normalize_name(entity.source_section or "")
        ]
        planning_targets = [target for target in rule.targets if target is not final_target]
        planning: list[TraceEntity] = []
        for target in planning_targets:
            planning.extend(_entities_for(graph, _domain_alias(target.domain), target.kinds))
        target_label = "/".join(target.domain for target in planning_targets) or "planning"
        findings: list[Finding] = []
        for item in final_items:
            if _best_match_against(item, planning).status == TraceLinkStatus.VERIFIED:
                continue
            findings.append(
                self._finding(
                    status=Status.REVIEW_REQUIRED,
                    severity="warning",
                    rule_id=f"{rule.rule_id}.orphan_final",
                    report=final_domain,
                    section=item.source_section,
                    location=item.source_location,
                    message=f"Final deliverable {item.canonical_name!r} is not represented in configured planning/tracking domains.",
                    evidence=_link_evidence(item),
                    source_entity=item,
                    target_domain=target_label,
                    spec_path=rule.path,
                    metadata={"direction": "final_to_plan"},
                )
            )
        return findings

    def _run_quality_objectives(
        self,
        document_set: DocumentSet,
        graph: TraceGraph,
        index: TraceIndex,
        rule: TraceRule,
    ) -> tuple[list[dict[str, Any]], list[Finding]]:
        source_domain = _domain_alias(rule.source_domain)
        objectives = _entities_for(graph, source_domain, rule.source_kinds or ("quality_objective",))
        findings: list[Finding] = []
        summary: list[dict[str, Any]] = []
        if not objectives:
            return [], [
                self._finding(
                    status=Status.REVIEW_REQUIRED if self._domain_present(document_set, source_domain) else Status.FAIL,
                    severity="warning" if self._domain_present(document_set, source_domain) else "error",
                    rule_id=rule.rule_id,
                    report=source_domain,
                    message="No deterministic quality objectives were extracted.",
                    spec_path=rule.path,
                )
            ]
        for objective in objectives:
            target_results: list[dict[str, Any]] = []
            role_results: dict[str, list[str]] = defaultdict(list)
            for target in rule.targets:
                status, match, finding = self._check_link(document_set, index, rule, objective, target)
                role = _target_role(target)
                if finding is not None:
                    if role == "result" and status == TraceLinkStatus.VERIFIED:
                        finding.status = Status.REVIEW_REQUIRED
                        finding.severity = "warning"
                        finding.message = (
                            f"Result evidence is present in {target.domain} for quality objective "
                            f"{objective.canonical_name!r}; deterministic tooling does not assert achievement."
                        )
                    elif role == "strategy" and status == TraceLinkStatus.VERIFIED:
                        finding.message = (
                            f"Quality objective {objective.canonical_name!r} is addressed by "
                            f"{target.domain} strategy evidence."
                        )
                    finding.metadata.update(
                        {
                            "stage": role,
                            "quality_dimension": (
                                "RESULT_PRESENT" if role == "result" and status == TraceLinkStatus.VERIFIED
                                else "TRACE_PRESENT" if status == TraceLinkStatus.VERIFIED
                                else status.value
                            ),
                        }
                    )
                    if role == "result" and status == TraceLinkStatus.VERIFIED:
                        finding.metadata["achievement"] = "ACHIEVEMENT_REVIEW_REQUIRED"
                    findings.append(finding)
                if status == TraceLinkStatus.VERIFIED and match.candidates:
                    graph.add_edge(
                        TraceEdge(
                            from_entity=objective.entity_id,
                            to_entity=match.candidates[0].entity_id,
                            rule_id=rule.rule_id,
                            match_method=match.method,
                            confidence_class=match.method,
                            evidence=_link_evidence(objective, match.candidates[0]),
                            metadata={"role": role},
                        )
                    )
                dimension = (
                    "RESULT_PRESENT" if role == "result" and status == TraceLinkStatus.VERIFIED
                    else "TRACE_PRESENT" if status == TraceLinkStatus.VERIFIED
                    else status.value
                )
                if role:
                    role_results[role].append(dimension)
                target_results.append(
                    {
                        "role": role,
                        "domain": target.domain,
                        "status": dimension,
                        "match_method": match.method.value,
                        "target_entities": [candidate.to_dict() for candidate in match.candidates],
                        "reason": match.reason,
                        "requirement": target.requirement,
                    }
                )
            strategy_status = _first_role_status(role_results, "strategy")
            result_status = _first_role_status(role_results, "result")
            achievement_status = (
                "ACHIEVEMENT_REVIEW_REQUIRED" if result_status == "RESULT_PRESENT" else None
            )
            summary.append(
                {
                    "source": objective.to_dict(),
                    "strategy": strategy_status,
                    "result": result_status,
                    "achievement": achievement_status,
                    "targets": target_results,
                }
            )
        return summary, findings

    def _run_directional_interface_checks(self, document_set: DocumentSet, graph: TraceGraph, index: TraceIndex, rule: TraceRule) -> list[Finding]:
        findings: list[Finding] = []
        design_target = next((target for target in rule.targets if "architecture_component" in target.kinds), None)
        design_domain = _domain_alias(design_target.domain) if design_target else ""
        design_entities = _entities_for(graph, design_domain, ("architecture_component", "external_interface"))
        requirement_entities = _entities_for(graph, _domain_alias(rule.source_domain), ("external_interface",))
        for design in design_entities:
            if not requirement_entities:
                break
            design_text = " ".join([design.canonical_name, str(design.metadata.get("raw_text", ""))]).casefold()
            if not re.search(r"\b(?:external|remote|api|service|platform|operating system|os integration|storage|paired device|dependency|endpoint)\b", design_text):
                continue
            match = _best_match_against(design, requirement_entities)
            if match.status == TraceLinkStatus.MISSING:
                findings.append(
                    self._finding(
                        status=Status.REVIEW_REQUIRED,
                        severity="warning",
                        rule_id=f"{rule.rule_id}.orphan_design",
                        report=design_domain,
                        section=design.source_section,
                        location=design.source_location,
                        message=f"Design introduces external dependency/component {design.canonical_name!r} with no identifiable Report 3 interface.",
                        evidence=_link_evidence(design),
                        source_entity=design,
                        target_domain=rule.source_domain,
                        spec_path=rule.path,
                        metadata={"direction": "design_to_requirements"},
                    )
                )
        return findings

    def _run_directional_data_checks(self, document_set: DocumentSet, graph: TraceGraph, index: TraceIndex, rule: TraceRule) -> list[Finding]:
        findings: list[Finding] = []
        data_target = next((target for target in rule.targets if "entity_or_data_object" in target.kinds), None)
        design_domain = _domain_alias(data_target.domain) if data_target else ""
        source_entities = _entities_for(graph, _domain_alias(rule.source_domain), ("entity_or_data_object",))
        design_entities = _entities_for(graph, design_domain, ("entity_or_data_object",))
        source_names = {normalize_name(entity.canonical_name) for entity in source_entities}
        for entity in design_entities:
            if entity.identifiers and any(identifier in {item for source in source_entities for item in source.identifiers} for identifier in entity.identifiers):
                continue
            if normalize_name(entity.canonical_name) in source_names:
                continue
            findings.append(
                self._finding(
                    status=Status.REVIEW_REQUIRED,
                    severity="warning",
                    rule_id=f"{rule.rule_id}.orphan_design",
                    report=design_domain,
                    section=entity.source_section,
                    location=entity.source_location,
                    message=f"Report 4 data design item {entity.canonical_name!r} has no identifiable Report 3 entity.",
                    evidence=_link_evidence(entity),
                    source_entity=entity,
                    target_domain=rule.source_domain,
                    spec_path=rule.path,
                    metadata={"direction": "data_design_to_requirements"},
                )
            )
        return findings

    def _run_orphan_rule(self, document_set: DocumentSet, graph: TraceGraph, index: TraceIndex, rule: OrphanRule) -> list[Finding]:
        source_entities = _entities_for(graph, _domain_alias(rule.source_domain), rule.source_kinds)
        findings: list[Finding] = []
        for source in source_entities:
            match = index.match(source, target_domain=_domain_alias(rule.target_domain), target_kinds=rule.target_kinds)
            if match.status == TraceLinkStatus.VERIFIED:
                continue
            status = Status.REVIEW_REQUIRED if rule.status.upper() == "REVIEW_REQUIRED" else _status_from_string(rule.status)
            findings.append(
                self._finding(
                    status=status,
                    severity=rule.severity,
                    rule_id=rule.rule_id,
                    report=source.source_report,
                    section=source.source_section,
                    location=source.source_location,
                    message=f"Orphan check: {source.kind} {source.canonical_name!r} has no identifiable {rule.target_domain} source.",
                    evidence=_link_evidence(source, *match.candidates[:3]),
                    source_entity=source,
                    target_domain=rule.target_domain,
                    candidate_entities=[candidate.to_dict() for candidate in match.candidates],
                    spec_path=rule.path,
                    metadata={"match_method": match.method.value, "reason": match.reason},
                )
            )
        return findings

    def _run_freshness(
        self,
        document_set: DocumentSet,
        graph: TraceGraph,
        index: TraceIndex,
        rule: TraceRule,
    ) -> tuple[list[dict[str, Any]], list[Finding]]:
        config = (rule.data or {}).get("freshness", {})
        if config is True:
            config = {}
        if not isinstance(config, dict):
            config = {}
        configured_target = next((target for target in rule.targets if "final_report_item" in target.kinds), rule.targets[-1] if rule.targets else None)
        source_domains = config.get("sources", [rule.source_domain])
        source_kinds = config.get("kinds", list(rule.source_kinds))
        target_domain = _domain_alias(str(config.get("target", configured_target.domain if configured_target else "")))
        target_kinds = tuple(str(value) for value in config.get("target_kinds", configured_target.kinds if configured_target else ("final_report_item",)))
        freshness_rule_id = str(config.get("rule_id", "R7-FRESHNESS"))
        target_entities = _entities_for(graph, target_domain, target_kinds)
        summary: list[dict[str, Any]] = []
        findings: list[Finding] = []
        source_domain_values = source_domains if isinstance(source_domains, list) else [source_domains]
        source_entities: list[TraceEntity] = []
        for source_domain in source_domain_values:
            source_entities.extend(_entities_for(graph, _domain_alias(str(source_domain)), source_kinds))
            for source in _entities_for(graph, _domain_alias(str(source_domain)), source_kinds):
                match = _best_match_against(source, target_entities)
                if match.status == TraceLinkStatus.VERIFIED:
                    state = TraceLinkStatus.CONSISTENT
                    findings.append(
                        self._finding(
                            status=Status.PASS,
                            severity="info",
                            rule_id=freshness_rule_id,
                            report=source.source_report,
                            section=source.source_section,
                            location=source.source_location,
                            message=f"Report 7 contains a deterministic current representation of {source.canonical_name!r}.",
                            evidence=_link_evidence(source, *match.candidates[:1]),
                            source_entity=source,
                            target_domain=target_domain,
                            candidate_entities=[candidate.to_dict() for candidate in match.candidates],
                            spec_path=rule.path,
                            metadata={"consistency": state.value, "match_method": match.method.value},
                        )
                    )
                elif match.status == TraceLinkStatus.MISSING:
                    state = TraceLinkStatus.STALE_OR_CONTRADICTED
                    findings.append(
                        self._finding(
                            status=Status.REVIEW_REQUIRED,
                            severity="warning",
                            rule_id=freshness_rule_id,
                            report=source.source_report,
                            section=source.source_section,
                            location=source.source_location,
                            message=f"Target domain {target_domain} has no deterministic representation of source item {source.canonical_name!r}.",
                            evidence=_link_evidence(source),
                            source_entity=source,
                            target_domain=target_domain,
                            spec_path=rule.path,
                            metadata={"consistency": state.value},
                        )
                    )
                else:
                    state = TraceLinkStatus.REVIEW_REQUIRED
                    findings.append(
                        self._finding(
                            status=Status.REVIEW_REQUIRED,
                            severity="warning",
                            rule_id=freshness_rule_id,
                            report=source.source_report,
                            section=source.source_section,
                            location=source.source_location,
                            message=f"Target domain {target_domain} has ambiguous candidates for source item {source.canonical_name!r}; freshness requires review.",
                            evidence=_link_evidence(source, *match.candidates[:3]),
                            source_entity=source,
                            target_domain=target_domain,
                            candidate_entities=[candidate.to_dict() for candidate in match.candidates],
                            spec_path=rule.path,
                            metadata={"consistency": state.value, "match_method": match.method.value},
                        )
                    )
                summary.append({"source": source.to_dict(), "status": state.value, "candidates": [candidate.to_dict() for candidate in match.candidates]})

        for target in target_entities:
            if not target.identifiers:
                continue
            reverse_match = _best_match_against(target, source_entities)
            if reverse_match.status == TraceLinkStatus.VERIFIED:
                continue
            findings.append(
                self._finding(
                    status=Status.REVIEW_REQUIRED,
                    severity="warning",
                    rule_id=freshness_rule_id,
                    report=target.source_report,
                    section=target.source_section,
                    location=target.source_location,
                    message=f"Final-state item {target.canonical_name!r} has no identifiable representation in the configured latest source domains.",
                    evidence=_link_evidence(target, *reverse_match.candidates[:3]),
                    source_entity=target,
                    target_domain=",".join(str(value) for value in source_domain_values),
                    candidate_entities=[candidate.to_dict() for candidate in reverse_match.candidates],
                    spec_path=rule.path,
                    metadata={"consistency": TraceLinkStatus.STALE_OR_CONTRADICTED.value, "direction": "final_to_source"},
                )
            )

        findings.extend(self._freshness_metadata_findings(document_set, rule, source_domain_values, target_domain))
        return summary, findings

    def _freshness_metadata_findings(
        self,
        document_set: DocumentSet,
        rule: TraceRule,
        source_domains: Iterable[str],
        target_domain: str,
    ) -> list[Finding]:
        final_documents = document_set.domain_documents(target_domain)
        if not final_documents:
            return []
        freshness_config = (rule.data or {}).get("freshness", {})
        if not isinstance(freshness_config, dict):
            freshness_config = {}
        freshness_rule_id = str(freshness_config.get("rule_id", "R7-FRESHNESS"))
        source_domain_values = [_domain_alias(str(value)) for value in source_domains]
        final_values = _structured_values(final_documents)
        findings: list[Finding] = []
        for source_domain in source_domain_values:
            source_documents = document_set.domain_documents(source_domain)
            if not source_documents:
                continue
            source_values = _structured_values(source_documents)
            for source_value in source_values:
                candidates = _freshness_target_values(
                    final_values,
                    source_value.semantic_field,
                    source_domain,
                    source_domain_values,
                    self.spec,
                    freshness_config,
                )
                if not candidates:
                    continue
                if len(candidates) > 1:
                    findings.append(
                        self._finding(
                            status=Status.REVIEW_REQUIRED,
                            severity="warning",
                            rule_id=freshness_rule_id,
                            report=source_domain,
                            section=source_value.section,
                            location=source_value.location,
                            message=(
                                f"Report 7 has multiple structured candidates for {source_value.semantic_field!r} "
                                f"in the {source_domain} consolidation; freshness requires review."
                            ),
                            evidence=[
                                {
                                    "report": target_domain,
                                    "label": candidate.semantic_field,
                                    "value": candidate.value,
                                    "location": candidate.location,
                                    "section": candidate.section,
                                }
                                for candidate in candidates
                            ],
                            target_domain=target_domain,
                            spec_path=rule.path,
                            metadata={
                                "consistency": TraceLinkStatus.REVIEW_REQUIRED.value,
                                "semantic_field": source_value.semantic_field,
                                "candidate_count": len(candidates),
                            },
                        )
                    )
                    continue
                final_value = candidates[0]
                if normalize_name(source_value.value) == normalize_name(final_value.value):
                    continue
                findings.append(
                    self._finding(
                        status=Status.REVIEW_REQUIRED,
                        severity="warning",
                        rule_id=freshness_rule_id,
                        report=source_domain,
                        section=source_value.section,
                        location=source_value.location,
                        message=(
                            f"Report 7 structured value for {source_value.semantic_field!r} differs from "
                            f"{source_domain}: {source_value.value!r} versus {final_value.value!r}."
                        ),
                        evidence=[
                            {
                                "report": source_domain,
                                "label": source_value.semantic_field,
                                "value": source_value.value,
                                "location": source_value.location,
                                "section": source_value.section,
                            },
                            {
                                "report": target_domain,
                                "label": final_value.semantic_field,
                                "value": final_value.value,
                                "location": final_value.location,
                                "section": final_value.section,
                            },
                        ],
                        target_domain=target_domain,
                        spec_path=rule.path,
                        metadata={
                            "consistency": TraceLinkStatus.STALE_OR_CONTRADICTED.value,
                            "semantic_field": source_value.semantic_field,
                            "source_section": source_value.section,
                            "target_section": final_value.section,
                        },
                    )
                )
        return findings

    def _duplicate_identifier_findings(self, index: TraceIndex) -> list[Finding]:
        findings: list[Finding] = []
        for domain, identifier, entities in index.duplicate_identifiers():
            findings.append(
                self._finding(
                    status=Status.REVIEW_REQUIRED,
                    severity="warning",
                    rule_id="TRACE-ID-001",
                    report=domain,
                    section=None,
                    location=entities[0].source_location if entities else "trace graph",
                    message=f"Explicit identifier {identifier!r} is duplicated within semantic domain {domain!r}; links are not merged automatically.",
                    evidence=_link_evidence(*entities),
                    source_entity=entities[0] if entities else None,
                    target_domain=domain,
                    candidate_entities=[entity.to_dict() for entity in entities],
                    metadata={"identifier": identifier, "domain": domain},
                )
            )
        return findings

    def _has_explicit_na(self, document_set: DocumentSet, domain: str, source: TraceEntity, target: TraceTargetRule) -> bool:
        hints = " ".join(target.kinds).casefold()
        source_tokens = {token for token in normalize_name(source.canonical_name).split() if len(token) > 2}
        for document in document_set.domain_documents(domain):
            for text, section in _document_text(document):
                value = text.casefold()
                if not re.search(r"\b(?:n/?a|not applicable|does not apply|no database|no persistent)\b", value):
                    continue
                if source.identifiers and any(identifier.casefold() in value for identifier in source.identifiers):
                    return True
                if source_tokens and source_tokens.intersection(set(normalize_name(text).split())):
                    return True
                if "entity" in hints or "data" in hints:
                    if any(word in normalize_name(section or "") for word in ("database", "erd", "data")):
                        return True
        return False

    def _domain_present(self, document_set: DocumentSet, domain: str) -> bool:
        domain = _domain_alias(domain)
        if domain in {_domain_alias(key) for key in document_set.reports}:
            return True
        return bool(document_set.domain_artifacts(domain)) or (domain == "report5" and bool(document_set.test_workbooks)) or (domain == "tracking" and bool(document_set.tracking_workbooks))

    @staticmethod
    def _finding(
        *,
        status: Status,
        severity: str,
        rule_id: str,
        report: str,
        message: str,
        section: str | None = None,
        location: Any = None,
        evidence: Iterable[Any] = (),
        source_entity: TraceEntity | dict[str, Any] | None = None,
        target_domain: str | None = None,
        candidate_entities: Iterable[Any] = (),
        source_requirement: str | None = None,
        spec_path: str | None = None,
        metadata: dict[str, Any] | None = None,
    ) -> Finding:
        source_value = source_entity.to_dict() if isinstance(source_entity, TraceEntity) else source_entity
        return Finding.from_location(
            status=status,
            severity=severity,
            rule_id=rule_id,
            report=report,
            section=section,
            location=location,
            message=message,
            evidence=evidence,
            source_requirement=source_requirement,
            spec_path=spec_path,
            metadata=metadata,
            validator="cross_document",
            source_entity=source_value,
            target_domain=target_domain,
            candidate_entities=candidate_entities,
        )


def _entities_for(graph: TraceGraph, domain: str, kinds: Iterable[str]) -> list[TraceEntity]:
    wanted = {str(kind) for kind in kinds}
    return [entity for entity in graph.nodes if _domain_alias(str(entity.metadata.get("domain", entity.source_report))) == _domain_alias(domain) and entity.kind in wanted]


def _evaluate_applicability(source: TraceEntity, condition: Any) -> bool | None:
    if condition is None:
        return True
    if isinstance(condition, bool):
        return condition
    if isinstance(condition, str):
        value = condition.casefold().replace("-", "_").replace(" ", "_")
        if value in {"always", "true", "applicable"}:
            return True
        if value in {"never", "false", "not_applicable"}:
            return False
        if value in {"user_facing", "userfacing"}:
            return source.metadata.get("user_facing") if isinstance(source.metadata.get("user_facing"), bool) else None
        if value in {"measurable", "measurable_objective"}:
            return source.metadata.get("measurable") if isinstance(source.metadata.get("measurable"), bool) else None
        return None
    if isinstance(condition, dict):
        condition_type = str(condition.get("type", condition.get("when", ""))).casefold()
        if condition_type in {"true", "always_true"}:
            return True
        if condition_type in {"false", "always_false"}:
            return False
        return _evaluate_applicability(source, condition_type)
    return None


def _finding_status(status: TraceLinkStatus, requirement: str) -> tuple[Status, str]:
    if status == TraceLinkStatus.VERIFIED:
        return Status.PASS, "info"
    if status == TraceLinkStatus.NOT_APPLICABLE:
        return Status.NOT_APPLICABLE, "info"
    if status in {TraceLinkStatus.AMBIGUOUS, TraceLinkStatus.REVIEW_REQUIRED}:
        return Status.REVIEW_REQUIRED, "warning"
    if status == TraceLinkStatus.MISSING:
        requirement_value = str(requirement or "MUST").upper()
        if requirement_value == "MUST":
            return Status.FAIL, "error"
        if requirement_value == "SHOULD":
            return Status.WARNING, "warning"
        if requirement_value == "MAY":
            return Status.SKIPPED, "info"
        return Status.REVIEW_REQUIRED, "warning"
    return Status.REVIEW_REQUIRED, "warning"


def _missing_status(requirement: str) -> TraceLinkStatus:
    requirement = str(requirement or "MUST").upper()
    if requirement == "MAY":
        return TraceLinkStatus.NOT_APPLICABLE
    return TraceLinkStatus.MISSING


def _status_from_string(value: str) -> Status:
    try:
        return Status[str(value).upper()]
    except KeyError:
        return Status.REVIEW_REQUIRED


def _link_evidence(source: TraceEntity, *targets: TraceEntity) -> list[Any]:
    evidence: list[Any] = []
    for label, entity in [(source.source_report, source), *[(target.source_report, target) for target in targets]]:
        evidence.append(
            {
                "report": label,
                "entity_id": entity.entity_id,
                "kind": entity.kind,
                "name": entity.canonical_name,
                "location": entity.source_location.to_dict() if hasattr(entity.source_location, "to_dict") else entity.source_location,
                "evidence": entity.evidence,
            }
        )
    return evidence


def _best_match_against(source: TraceEntity, targets: list[TraceEntity]) -> MatchResult:
    by_id = [target for target in targets if source.identifiers and set(source.identifiers).intersection(target.identifiers)]
    if len(by_id) == 1:
        return MatchResult(TraceLinkStatus.VERIFIED, MatchMethod.EXPLICIT_ID, tuple(by_id))
    if len(by_id) > 1:
        return MatchResult(TraceLinkStatus.AMBIGUOUS, MatchMethod.AMBIGUOUS, tuple(by_id), "Explicit identifier has multiple candidates.")
    names = [target for target in targets if normalize_name(source.canonical_name) in {normalize_name(name) for name in target.comparison_names}]
    if len(names) == 1:
        if source.identifiers and names[0].identifiers:
            return MatchResult(TraceLinkStatus.AMBIGUOUS, MatchMethod.AMBIGUOUS, tuple(names), "Names match but explicit IDs differ.")
        return MatchResult(TraceLinkStatus.VERIFIED, MatchMethod.EXACT_NORMALIZED_NAME, tuple(names))
    if len(names) > 1:
        return MatchResult(TraceLinkStatus.AMBIGUOUS, MatchMethod.AMBIGUOUS, tuple(names), "Exact normalized name has multiple candidates.")
    return MatchResult(TraceLinkStatus.MISSING, MatchMethod.UNMATCHED, (), "No exact ID or normalized-name match.")


def _target_role(target: TraceTargetRule) -> str | None:
    if target.role is None:
        return None
    value = normalize_name(target.role)
    return value or None


def _first_role_status(role_results: dict[str, list[str]], role: str) -> str | None:
    values = role_results.get(role, [])
    if not values:
        return None
    if len(set(values)) == 1:
        return values[0]
    return "REVIEW_REQUIRED"


def _target_constraint_state(candidate: TraceEntity, target: TraceTargetRule) -> bool | None:
    if target.role:
        actual_stage = _test_stage_value(candidate)
        required_role = _target_role(target)
        if required_role in {"strategy", "result", "case"}:
            if actual_stage is None:
                return None
            if actual_stage != required_role:
                return False
        else:
            return None
    if target.test_levels:
        actual_level = _test_level_value(candidate.metadata.get("test_level"))
        if actual_level is None:
            raw_levels = candidate.metadata.get("test_levels")
            if isinstance(raw_levels, (list, tuple, set)) and len(raw_levels) == 1:
                actual_level = _test_level_value(next(iter(raw_levels)))
        if actual_level is None:
            return None
        required_levels = {_normalize_test_level(level) for level in target.test_levels}
        if actual_level not in required_levels:
            return False
    return True


def _test_stage_value(entity: TraceEntity) -> str | None:
    actual = normalize_name(str(entity.metadata.get("test_stage", "")))
    if actual in {"strategy", "result", "case"}:
        return actual
    section = normalize_name(entity.source_section or "")
    if "test strategy" in section or "testing types" in section or "test levels" in section:
        return "strategy"
    if any(value in section for value in ("test report", "test statistics", "result", "results")):
        return "result"
    return None


def _test_level_value(value: Any) -> str | None:
    if isinstance(value, str):
        normalized = normalize_name(value)
        aliases = {
            "unit": "unit",
            "unit test": "unit",
            "unit testing": "unit",
            "ut": "unit",
            "integration": "integration",
            "integration test": "integration",
            "integration testing": "integration",
            "system": "system",
            "system test": "system",
            "system testing": "system",
            "acceptance": "acceptance",
            "acceptance test": "acceptance",
            "acceptance testing": "acceptance",
            "uat": "acceptance",
            "user acceptance test": "acceptance",
        }
        return aliases.get(normalized)
    return None


def _normalize_test_level(value: Any) -> str:
    normalized = normalize_name(str(value or ""))
    return {
        "unit test": "unit",
        "unit testing": "unit",
        "ut": "unit",
        "integration test": "integration",
        "integration testing": "integration",
        "system test": "system",
        "system testing": "system",
        "acceptance test": "acceptance",
        "acceptance testing": "acceptance",
        "uat": "acceptance",
        "user acceptance test": "acceptance",
    }.get(normalized, normalized.replace(" ", "_"))


def _document_text(document: NormalizedDocument) -> Iterable[tuple[str, str | None]]:
    if isinstance(document, Document):
        for block in _document_blocks(document):
            yield block.text, block.section_path
        for table in document.tables:
            for row in table.rows:
                yield " | ".join(cell.original_text for cell in row), table.parent_section
    elif isinstance(document, Workbook):
        for sheet in document.sheets:
            for row in sheet.rows:
                yield " | ".join(cell.original_text for cell in row), sheet.name


def _structured_values(documents: list[NormalizedDocument]) -> list[_StructuredValue]:
    labels = {
        "project name", "project code", "group", "team", "team members", "member", "members", "version", "test coverage", "test successful coverage",
        "sub total", "passed", "failed", "pending", "availability", "milestone",
    }
    values: list[_StructuredValue] = []
    for document in documents:
        for raw_label, raw_value in document.metadata.items():
            label = normalize_name(str(raw_label))
            if label in labels and raw_value not in (None, ""):
                values.append(_StructuredValue(label, str(raw_value), document.source_path, None))
        if isinstance(document, Document):
            for table in document.tables:
                for row in table.rows:
                    cells = [cell for cell in row if not cell.is_empty]
                    if len(cells) < 2:
                        continue
                    label = normalize_name(cells[0].original_text)
                    if label in labels:
                        values.append(
                            _StructuredValue(
                                label,
                                cells[1].original_text,
                                cells[0].source_location.display() if cells[0].source_location else table.parent_section,
                                table.parent_section,
                            )
                        )
        elif isinstance(document, Workbook):
            for sheet in document.sheets:
                for row in sheet.rows:
                    cells = [cell for cell in row if not cell.is_empty]
                    if len(cells) < 2:
                        continue
                    label = normalize_name(cells[0].original_text)
                    if label in labels:
                        values.append(
                            _StructuredValue(
                                label,
                                cells[1].original_text,
                                cells[0].source_location.display() if cells[0].source_location else sheet.name,
                                sheet.name,
                            )
                        )
    return values


def _freshness_target_values(
    values: list[_StructuredValue],
    semantic_field: str,
    source_domain: str,
    source_domains: list[str],
    spec: CapstoneSpec | None,
    config: dict[str, Any],
) -> list[_StructuredValue]:
    candidates = [value for value in values if value.semantic_field == semantic_field]
    explicit: list[_StructuredValue] = []
    unknown: list[_StructuredValue] = []
    for candidate in candidates:
        mapped_domain = _report7_section_domain(candidate.section, source_domains, spec, config)
        if mapped_domain == source_domain:
            explicit.append(candidate)
        elif mapped_domain is None:
            unknown.append(candidate)
    return [*explicit, *unknown] if explicit else unknown


def _report7_section_domain(
    section: str | None,
    source_domains: list[str],
    spec: CapstoneSpec | None,
    config: dict[str, Any],
) -> str | None:
    if not section:
        return None
    normalized_section = normalize_name(section)
    section_map = config.get("section_map", {})
    if isinstance(section_map, dict):
        for raw_domain, raw_sections in section_map.items():
            sections = raw_sections if isinstance(raw_sections, list) else [raw_sections]
            if any(normalize_name(str(value)) in normalized_section for value in sections if value):
                return _domain_alias(str(raw_domain))
    roman_match = re.match(r"^([ivxlcdm]+)\b", str(section).strip(), re.IGNORECASE)
    if roman_match:
        roman_number = _roman_number(roman_match.group(1))
        for domain in source_domains:
            number_match = re.search(r"report[-_]?(\d+)$", domain, re.IGNORECASE)
            if number_match and int(number_match.group(1)) == roman_number:
                return domain
    if spec is not None:
        for domain in source_domains:
            try:
                report = spec.report(domain)
            except Exception:
                continue
            aliases = [domain, report.get("short_name"), report.get("title")]
            aliases.extend(spec.report_source_names(domain))
            if any(normalize_name(str(alias)) in normalized_section for alias in aliases if alias):
                return domain
    return None


def _roman_number(value: str) -> int | None:
    numerals = {"i": 1, "v": 5, "x": 10, "l": 50, "c": 100, "d": 500, "m": 1000}
    total = 0
    previous = 0
    for character in reversed(value.casefold()):
        current = numerals.get(character)
        if current is None:
            return None
        if current < previous:
            total -= current
        else:
            total += current
            previous = current
    return total


def _truthy(value: Any) -> bool:
    return value is True or str(value).casefold() in {"true", "yes", "1"}
