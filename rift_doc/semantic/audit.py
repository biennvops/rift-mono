"""Planning and execution orchestration for bounded semantic review."""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass, field, replace
from datetime import datetime, timezone
from importlib.metadata import PackageNotFoundError, version
from pathlib import Path
from typing import Any, Iterable

from ..document_set import DocumentSet
from ..repository.model import RepositorySnapshot
from ..results import Finding, Status
from ..spec import CapstoneSpec
from ..trace_model import MatchMethod, TraceGraph
from .cache import SemanticResultCache
from .evidence import EvidencePacketBuilder
from .model import (
    EvidencePacket,
    SemanticConfidence,
    SemanticPlan,
    SemanticResult,
    SemanticReviewTask,
    SemanticTaskType,
)
from .planner import SemanticReviewPlanner
from .prompts import PromptRenderer
from .providers import LLMProvider, LLMProviderError
from .result_validation import SemanticOutputError, validate_semantic_output


@dataclass(frozen=True)
class SemanticAuditOptions:
    max_tasks: int = 50
    max_input_tokens: int = 12_000
    max_cost: float | None = None
    task_types: tuple[SemanticTaskType | str, ...] | None = None
    entity_query: str | None = None
    excluded_paths: tuple[str, ...] = ()
    cache_enabled: bool = True
    cache_directory: Path = Path(".rift-doc-cache/semantic")

    def __post_init__(self) -> None:
        if self.max_tasks < 0:
            raise ValueError("semantic max_tasks cannot be negative")
        if self.max_input_tokens < 512:
            raise ValueError("semantic max_input_tokens must be at least 512")
        if self.max_cost is not None and self.max_cost < 0:
            raise ValueError("semantic max_cost cannot be negative")


@dataclass
class SemanticTaskExecution:
    task: SemanticReviewTask
    packet: EvidencePacket
    result: SemanticResult
    execution_status: str
    attempts: int = 0
    cached: bool = False
    errors: list[dict[str, str]] = field(default_factory=list)
    audit_metadata: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "task": self.task.to_dict(),
            "packet_id": self.packet.packet_id,
            "packet_hash": self.packet.packet_hash,
            "result": self.result.to_dict(),
            "execution_status": self.execution_status,
            "attempts": self.attempts,
            "cached": self.cached,
            "errors": list(self.errors),
            "audit_metadata": dict(self.audit_metadata),
        }


@dataclass
class SemanticAuditReport:
    plan: SemanticPlan
    executions: list[SemanticTaskExecution]
    findings: list[Finding]
    semantic_links: list[dict[str, Any]] = field(default_factory=list)
    metadata: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "plan": self.plan.to_dict(),
            "executions": [execution.to_dict() for execution in self.executions],
            "findings": [finding.to_dict() for finding in self.findings],
            "semantic_links": list(self.semantic_links),
            "metadata": dict(self.metadata),
        }


class SemanticAuditRunner:
    def __init__(
        self,
        spec: CapstoneSpec,
        *,
        options: SemanticAuditOptions | None = None,
        prompt_renderer: PromptRenderer | None = None,
        cache: SemanticResultCache | None = None,
    ) -> None:
        self.spec = spec
        self.options = options or SemanticAuditOptions()
        self.prompt_renderer = prompt_renderer or PromptRenderer()
        self.cache = cache or SemanticResultCache(self.options.cache_directory)

    def plan(
        self,
        document_set: DocumentSet,
        graph: TraceGraph,
        deterministic_findings: Iterable[Finding],
        *,
        repository_snapshot: RepositorySnapshot | None = None,
    ) -> SemanticPlan:
        findings = list(deterministic_findings)
        tasks, omitted = SemanticReviewPlanner(self.spec).plan(
            document_set,
            graph,
            findings,
            task_types=self.options.task_types,
            entity_query=self.options.entity_query,
            max_tasks=self.options.max_tasks,
        )
        builder = EvidencePacketBuilder(
            self.spec,
            max_input_tokens=self.options.max_input_tokens,
            excluded_paths=self.options.excluded_paths,
        )
        packets = [
            builder.build(
                task,
                document_set,
                graph,
                findings,
                repository_snapshot=repository_snapshot,
            )
            for task in tasks
        ]
        return SemanticPlan(
            tasks=tasks,
            packets=packets,
            proposed_task_count=len(tasks) + omitted,
            omitted_task_count=omitted,
            metadata={
                "dry_run": True,
                "max_tasks": self.options.max_tasks,
                "max_input_tokens_per_task": self.options.max_input_tokens,
                "max_cost": self.options.max_cost,
                "cache_enabled": self.options.cache_enabled,
                "network_access": False,
                "provider_called": False,
            },
        )

    def run(self, plan: SemanticPlan, provider: LLMProvider) -> SemanticAuditReport:
        provider.config.validate()
        if self.options.max_cost is not None and (
            provider.config.input_cost_per_million is None
            or provider.config.output_cost_per_million is None
        ):
            raise ValueError(
                "semantic --max-cost requires configured input and output cost-per-million values"
            )
        executions: list[SemanticTaskExecution] = []
        findings: list[Finding] = []
        semantic_links: list[dict[str, Any]] = []
        estimated_cost = 0.0
        for task, packet in zip(plan.tasks, plan.packets, strict=True):
            task_cost = _estimated_task_cost(packet, provider)
            if self.options.max_cost is not None and estimated_cost + task_cost > self.options.max_cost:
                execution = self._system_execution(
                    task,
                    packet,
                    "COST_LIMIT",
                    "Semantic review was not called because the configured cost limit would be exceeded.",
                )
            elif _has_required_evidence_gap(packet):
                execution = self._system_execution(
                    task,
                    packet,
                    "EVIDENCE_EXCLUDED",
                    "Required evidence was excluded or could not fit the configured packet budget.",
                )
            elif task.metadata.get("requires_visual") and (
                not packet.provenance.get("visual_evidence", {}).get("bytes_available")
                or not provider.supports_visual_evidence
            ):
                execution = self._system_execution(
                    task,
                    packet,
                    "VISUAL_EVIDENCE_UNAVAILABLE",
                    "The task requires visual evidence, but bounded image bytes or provider visual support are unavailable.",
                )
            else:
                execution = self._execute_provider(task, packet, provider)
                estimated_cost += task_cost
            executions.append(execution)
            finding = _semantic_finding(execution)
            findings.append(finding)
            link = _semantic_link(execution)
            if link is not None:
                semantic_links.append(link)

        counts = Counter(execution.result.status for execution in executions)
        execution_counts = Counter(execution.execution_status for execution in executions)
        metadata = {
            "domain": "semantic_review",
            "provider": provider.config.audit_metadata(),
            "task_count": len(executions),
            "status_counts": {
                status: counts.get(status, 0)
                for status in ("PASS", "FAIL", "WARNING", "REVIEW_REQUIRED")
            },
            "execution_status_counts": dict(sorted(execution_counts.items())),
            "estimated_cost": estimated_cost if _has_pricing(provider) else None,
            "network_access": provider.config.provider != "fake" and any(
                execution.attempts > 0 for execution in executions
            ),
            "deterministic_findings_preserved": True,
            "semantic_links_are_deterministic_edges": False,
        }
        return SemanticAuditReport(plan, executions, findings, semantic_links, metadata)

    def _execute_provider(
        self,
        task: SemanticReviewTask,
        packet: EvidencePacket,
        provider: LLMProvider,
    ) -> SemanticTaskExecution:
        prompt = self.prompt_renderer.render(task, packet)
        timestamp = datetime.now(timezone.utc).isoformat()
        repository_snapshot = packet.provenance.get("repository_snapshot") or {}
        vcs = repository_snapshot.get("vcs") or {} if isinstance(repository_snapshot, dict) else {}
        audit_metadata = {
            "provider": provider.config.provider,
            "model": provider.config.model,
            "prompt_version": prompt.version,
            "prompt_hash": prompt.prompt_hash,
            "task_type": task.task_type.value,
            "packet_hash": packet.packet_hash,
            "timestamp": timestamp,
            "tool_version": _tool_version(),
            "spec_version": self.spec.version,
            "repository_commit": vcs.get("commit_sha") if isinstance(vcs, dict) else None,
        }
        cache_key = SemanticResultCache.key(
            provider=provider.config.provider,
            model=provider.config.model,
            prompt_version=prompt.version,
            packet_hash=packet.packet_hash,
        )
        if self.options.cache_enabled:
            cached = self.cache.load(cache_key)
            if cached is not None:
                try:
                    result = validate_semantic_output(cached["result"], task, packet)
                except SemanticOutputError:
                    cached = None
                else:
                    metadata = {**audit_metadata, "cache_key": cache_key, "cache_hit": True}
                    result = replace(result, metadata=metadata)
                    return SemanticTaskExecution(
                        task,
                        packet,
                        result,
                        "CACHED",
                        attempts=0,
                        cached=True,
                        audit_metadata=metadata,
                    )

        errors: list[dict[str, str]] = []
        max_attempts = provider.config.retry_attempts + 1
        for attempt in range(1, max_attempts + 1):
            try:
                raw = provider.review(task, packet)
                result = validate_semantic_output(raw, task, packet)
            except SemanticOutputError as exc:
                errors.append({"attempt": str(attempt), "category": exc.category, "message": str(exc)})
                continue
            except LLMProviderError as exc:
                errors.append({"attempt": str(attempt), "category": "PROVIDER_ERROR", "message": str(exc)})
                continue
            metadata = {
                **audit_metadata,
                "cache_key": cache_key,
                "cache_hit": False,
                "attempt": attempt,
            }
            result = replace(result, metadata=metadata)
            if self.options.cache_enabled:
                self.cache.store(cache_key, result, audit_metadata=metadata)
            return SemanticTaskExecution(
                task,
                packet,
                result,
                "COMPLETED",
                attempts=attempt,
                errors=errors,
                audit_metadata=metadata,
            )

        final_category = errors[-1]["category"] if errors else "PROVIDER_ERROR"
        result = SemanticResult(
            status="REVIEW_REQUIRED",
            confidence=SemanticConfidence.LOW,
            summary="Semantic task execution did not produce a valid review result.",
            reasoning_summary=(
                "The provider failed or returned schema, citation, or policy-invalid output after the bounded retry limit."
            ),
            evidence_refs=(),
            recommended_action="Inspect provider/output diagnostics and rerun the bounded task.",
            metadata={**audit_metadata, "cache_key": cache_key, "cache_hit": False},
        )
        return SemanticTaskExecution(
            task,
            packet,
            result,
            "INVALID_OUTPUT" if final_category != "PROVIDER_ERROR" else "PROVIDER_ERROR",
            attempts=max_attempts,
            errors=errors,
            audit_metadata=result.metadata,
        )

    def _system_execution(
        self,
        task: SemanticReviewTask,
        packet: EvidencePacket,
        execution_status: str,
        explanation: str,
    ) -> SemanticTaskExecution:
        metadata = {
            "provider": "not_called",
            "model": None,
            "prompt_version": task.metadata.get("prompt_version"),
            "task_type": task.task_type.value,
            "packet_hash": packet.packet_hash,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "tool_version": _tool_version(),
            "spec_version": self.spec.version,
            "execution_status": execution_status,
        }
        result = SemanticResult(
            status="REVIEW_REQUIRED",
            confidence=SemanticConfidence.LOW,
            summary=explanation,
            reasoning_summary=explanation,
            evidence_refs=(),
            recommended_action="Provide safe bounded evidence or adjust the configured review controls.",
            metadata=metadata,
        )
        return SemanticTaskExecution(
            task,
            packet,
            result,
            execution_status,
            audit_metadata=metadata,
        )


def _semantic_finding(execution: SemanticTaskExecution) -> Finding:
    task = execution.task
    result = execution.result
    status = Status(result.status)
    severity = "error" if status == Status.FAIL else "warning" if status in {Status.WARNING, Status.REVIEW_REQUIRED} else "info"
    evidence_by_id = {item.evidence_id: item for item in execution.packet.all_evidence}
    cited = [evidence_by_id[value] for value in result.evidence_refs if value in evidence_by_id]
    contract = execution.packet.contract_requirements[0].content if execution.packet.contract_requirements else None
    return Finding.from_location(
        status=status,
        severity=severity,
        rule_id=task.rule_id,
        report=str(task.metadata.get("source_domain", "semantic_review")),
        section=task.metadata.get("source_section"),
        location=_first_location(cited),
        message=result.summary,
        evidence=[item.to_dict() for item in cited],
        source_requirement=contract,
        spec_path=task.metadata.get("section_rule_path") or "semantic_review_extension",
        metadata={
            "domain": "semantic_review",
            "task_id": task.task_id,
            "task_type": task.task_type.value,
            "confidence": result.confidence.value,
            "reasoning_summary": result.reasoning_summary,
            "unsupported_claims": list(result.unsupported_claims),
            "contradictions": list(result.contradictions),
            "recommended_action": result.recommended_action,
            "execution_status": execution.execution_status,
            "audit": result.metadata,
        },
        validator="semantic_review",
        source_entity={
            "entity_id": task.metadata.get("source_entity_id"),
            "canonical_name": task.metadata.get("source_entity_name"),
            "task_id": task.task_id,
        },
        target_domain=task.metadata.get("target_domain"),
        candidate_entities=[item.to_dict() for item in cited],
    )


def _semantic_link(execution: SemanticTaskExecution) -> dict[str, Any] | None:
    task = execution.task
    if task.task_type != SemanticTaskType.CROSS_DOCUMENT_CONSISTENCY or execution.result.status != "PASS":
        return None
    source_id = task.metadata.get("source_entity_id")
    target_ids = set(task.metadata.get("target_entity_ids", []))
    if not source_id or not target_ids:
        return None
    evidence_by_id = {item.evidence_id: item for item in execution.packet.all_evidence}
    cited_entity_ids = {
        evidence_by_id[value].metadata.get("entity_id")
        for value in execution.result.evidence_refs
        if value in evidence_by_id
    }
    selected_targets = sorted(target_ids.intersection(cited_entity_ids))
    if source_id not in cited_entity_ids or len(selected_targets) != 1:
        return None
    return {
        "from_entity": source_id,
        "to_entity": selected_targets[0],
        "rule_id": task.rule_id,
        "match_method": MatchMethod.LLM_SEMANTIC.value,
        "confidence_class": MatchMethod.LLM_SEMANTIC.value,
        "model_confidence": execution.result.confidence.value,
        "evidence_refs": list(execution.result.evidence_refs),
        "deterministic_graph_mutated": False,
    }


def _first_location(items: list[Any]) -> str | None:
    for item in items:
        value = item.source_location
        if isinstance(value, dict) and value.get("display"):
            return str(value["display"])
        if value:
            return str(value)
    return None


def _has_required_evidence_gap(packet: EvidencePacket) -> bool:
    return any(item.get("required_for_task") for item in packet.excluded_evidence) or any(
        item.get("required") and not item.get("included")
        for item in packet.truncated_evidence
    )


def _estimated_task_cost(packet: EvidencePacket, provider: LLMProvider) -> float:
    input_rate = provider.config.input_cost_per_million or 0.0
    output_rate = provider.config.output_cost_per_million or 0.0
    return (
        packet.estimated_input_tokens * input_rate
        + provider.config.max_output_tokens * output_rate
    ) * (provider.config.retry_attempts + 1) / 1_000_000


def _has_pricing(provider: LLMProvider) -> bool:
    return (
        provider.config.input_cost_per_million is not None
        and provider.config.output_cost_per_million is not None
    )


def _tool_version() -> str:
    try:
        return version("rift-capstone-doc-tooling")
    except PackageNotFoundError:
        return "0.1.0"
