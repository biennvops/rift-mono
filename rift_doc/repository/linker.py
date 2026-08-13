"""Conservative deterministic claim-to-repository evidence linking."""

from __future__ import annotations

import fnmatch
from dataclasses import replace
from pathlib import PurePosixPath
import re
import shlex
from typing import Any, Iterable

from .mappings import RepositoryMappingConfig, RepositoryMappingEntry
from .model import (
    EvidenceKind,
    RepositoryClaim,
    RepositoryClaimKind,
    RepositoryEvidence,
    RepositoryEvidenceMatch,
    RepositoryEvidenceStatus,
    RepositoryMatchMethod,
    RepositorySnapshot,
    TestEvidenceState,
)
from ..trace_model import normalize_identifier, normalize_name


_CANDIDATE_KINDS: dict[RepositoryClaimKind, frozenset[EvidenceKind]] = {
    RepositoryClaimKind.FUNCTION_OR_FEATURE: frozenset(
        {EvidenceKind.SYMBOL, EvidenceKind.MODULE, EvidenceKind.PACKAGE, EvidenceKind.CONFIGURATION}
    ),
    RepositoryClaimKind.ARCHITECTURE_COMPONENT: frozenset(
        {EvidenceKind.MODULE, EvidenceKind.PACKAGE, EvidenceKind.DIRECTORY, EvidenceKind.BUILD_TARGET, EvidenceKind.CONFIGURATION}
    ),
    RepositoryClaimKind.TEST_CLAIM: frozenset({EvidenceKind.TEST}),
    RepositoryClaimKind.DELIVERABLE_OR_PACKAGE: frozenset(
        {EvidenceKind.RELEASE_ARTIFACT, EvidenceKind.PACKAGE, EvidenceKind.MODULE, EvidenceKind.BUILD_TARGET, EvidenceKind.DIRECTORY}
    ),
}
_GENERIC_IMPLEMENTATION_WORDS = frozenset(
    {"app", "application", "client", "component", "core", "daemon", "engine", "feature", "handler", "manager", "module", "package", "platform", "service"}
)


def _expected_kinds(claim: RepositoryClaim) -> frozenset[EvidenceKind]:
    if claim.expected_evidence_types:
        return frozenset(claim.expected_evidence_types)
    if claim.kind == RepositoryClaimKind.TEST_CLAIM:
        return frozenset({EvidenceKind.TEST, EvidenceKind.CI_JOB, EvidenceKind.TEST_RESULT})
    return _CANDIDATE_KINDS[claim.kind]


def _candidate_kinds(claim: RepositoryClaim) -> frozenset[EvidenceKind]:
    expected = _expected_kinds(claim)
    if claim.kind == RepositoryClaimKind.TEST_CLAIM:
        return frozenset({EvidenceKind.TEST}) if EvidenceKind.TEST in expected else frozenset()
    return expected


class RepositoryEvidenceIndex:
    """Runtime indexes built once per snapshot."""

    def __init__(self, snapshot: RepositorySnapshot) -> None:
        self.snapshot = snapshot
        self.by_id = {item.evidence_id: item for item in snapshot.all_evidence()}
        self.by_identifier: dict[str, list[RepositoryEvidence]] = {}
        self.by_exact_name: dict[str, list[RepositoryEvidence]] = {}
        self.by_normalized_name: dict[str, list[RepositoryEvidence]] = {}
        for evidence in self.by_id.values():
            for identifier in evidence.metadata.get("identifiers", []):
                value = normalize_identifier(str(identifier))
                if value:
                    self.by_identifier.setdefault(value, []).append(evidence)
            for label in _evidence_labels(evidence):
                exact = _exact_name(label)
                normalized = _repository_name(label)
                if exact:
                    self.by_exact_name.setdefault(exact, []).append(evidence)
                if normalized:
                    self.by_normalized_name.setdefault(normalized, []).append(evidence)

    def candidates_for_kind(
        self,
        claim_kind: RepositoryClaimKind,
        allowed_kinds: frozenset[EvidenceKind] | None = None,
    ) -> list[RepositoryEvidence]:
        kinds = allowed_kinds if allowed_kinds is not None else _CANDIDATE_KINDS[claim_kind]
        return [item for item in self.by_id.values() if item.kind in kinds]


class RepositoryEvidenceLinker:
    def __init__(
        self,
        snapshot: RepositorySnapshot,
        mappings: RepositoryMappingConfig | None = None,
    ) -> None:
        self.snapshot = snapshot
        self.index = RepositoryEvidenceIndex(snapshot)
        self.mappings = mappings or RepositoryMappingConfig()

    def link_all(self, claims: Iterable[RepositoryClaim]) -> list[RepositoryEvidenceMatch]:
        return [self.link(claim) for claim in claims]

    def link(self, claim: RepositoryClaim) -> RepositoryEvidenceMatch:
        mapping = self.mappings.mapping_for(claim)
        if claim.kind == RepositoryClaimKind.TEST_CLAIM:
            executable_required = claim.metadata.get("executable_required")
            if mapping is not None and mapping.executable_required is not None:
                executable_required = mapping.executable_required
            if executable_required is False:
                return RepositoryEvidenceMatch(
                    claim,
                    RepositoryEvidenceStatus.NOT_APPLICABLE,
                    RepositoryMatchMethod.NOT_APPLICABLE,
                    reason="The documentation or explicit mapping classifies this as a manual test with no executable-test requirement.",
                    metadata=self._metadata(mapping),
                )

        if mapping is not None and mapping.contradicts:
            return RepositoryEvidenceMatch(
                claim,
                RepositoryEvidenceStatus.CONTRADICTED,
                RepositoryMatchMethod.MANUAL_MAPPING,
                reason=str(mapping.contradicts) if isinstance(mapping.contradicts, str) else "The explicit repository mapping records direct contradictory evidence.",
                metadata=self._metadata(mapping),
            )

        candidates = self._identifier_candidates(claim)
        method = RepositoryMatchMethod.EXPLICIT_IDENTIFIER
        if not candidates:
            candidates = self._exact_name_candidates(claim)
            method = RepositoryMatchMethod.EXACT_NAME
        if not candidates and mapping is not None:
            candidates = self._mapping_candidates(claim, mapping)
            method = RepositoryMatchMethod.MANUAL_MAPPING
            if not candidates:
                return RepositoryEvidenceMatch(
                    claim,
                    RepositoryEvidenceStatus.NOT_FOUND,
                    method,
                    reason="The explicit mapping targets were not present in this repository snapshot.",
                    metadata=self._metadata(mapping),
                )
        if not candidates:
            candidates = self._normalized_name_candidates(claim)
            method = RepositoryMatchMethod.NORMALIZED_NAME

        candidates = _unique(candidates)
        if not candidates:
            return RepositoryEvidenceMatch(
                claim,
                RepositoryEvidenceStatus.NOT_FOUND,
                RepositoryMatchMethod.UNMATCHED,
                reason="No deterministic identifier, exact name, mapping, or conservative normalized-name evidence was located; absence is not proof that the claim is false.",
                metadata=self._metadata(mapping),
            )

        primary = self._primary_candidates(claim, candidates)
        if method != RepositoryMatchMethod.MANUAL_MAPPING and len(primary) > 1:
            return RepositoryEvidenceMatch(
                claim,
                RepositoryEvidenceStatus.REVIEW_REQUIRED,
                RepositoryMatchMethod.AMBIGUOUS,
                evidence=primary,
                reason="Multiple repository candidates remain after deterministic matching.",
                metadata={**self._metadata(mapping), "candidate_count": len(primary), "candidate_method": method.value},
            )

        selected = candidates if method == RepositoryMatchMethod.MANUAL_MAPPING else primary
        selected = self._augment_evidence(claim, selected)
        if claim.kind == RepositoryClaimKind.FUNCTION_OR_FEATURE and all(
            _is_explicit_identifier_reference(item) for item in selected
        ):
            return RepositoryEvidenceMatch(
                claim,
                RepositoryEvidenceStatus.REVIEW_REQUIRED,
                method,
                selected,
                reason="An explicit identifier reference was located, but no implementation-level evidence was established.",
                metadata=self._metadata(mapping),
            )
        version_conflict = _version_conflict(claim, selected)
        if version_conflict is not None:
            return RepositoryEvidenceMatch(
                claim,
                RepositoryEvidenceStatus.CONTRADICTED,
                method,
                selected,
                reason="The documented version directly conflicts with the matched manifest/artifact version.",
                metadata={**self._metadata(mapping), "version_conflict": version_conflict},
            )

        states = self._test_states(claim, selected)
        result_conflict = _test_result_conflict(claim, selected)
        if result_conflict is not None:
            return RepositoryEvidenceMatch(
                claim,
                RepositoryEvidenceStatus.CONTRADICTED,
                method,
                selected,
                reason="The documented test result directly conflicts with the matched recorded result.",
                test_states=states,
                metadata={**self._metadata(mapping), "test_result_conflict": result_conflict},
            )
        status = RepositoryEvidenceStatus.VERIFIED
        if claim.kind == RepositoryClaimKind.DELIVERABLE_OR_PACKAGE and not any(
            item.kind in {EvidenceKind.RELEASE_ARTIFACT, EvidenceKind.PACKAGE, EvidenceKind.BUILD_TARGET}
            for item in selected
        ):
            status = RepositoryEvidenceStatus.PARTIALLY_VERIFIED
        return RepositoryEvidenceMatch(
            claim,
            status,
            method,
            selected,
            reason=_verified_reason(claim, selected, states),
            test_states=states,
            metadata=self._metadata(mapping),
        )

    def _identifier_candidates(self, claim: RepositoryClaim) -> list[RepositoryEvidence]:
        allowed = _candidate_kinds(claim)
        result: list[RepositoryEvidence] = []
        for identifier in claim.identifiers:
            result.extend(item for item in self.index.by_identifier.get(normalize_identifier(identifier), []) if item.kind in allowed)
        return _prefer_specific_kind(claim, result)

    def _exact_name_candidates(self, claim: RepositoryClaim) -> list[RepositoryEvidence]:
        allowed = _candidate_kinds(claim)
        key = _exact_name(claim.canonical_name)
        return _prefer_specific_kind(
            claim,
            [item for item in self.index.by_exact_name.get(key, []) if item.kind in allowed],
        )

    def _normalized_name_candidates(self, claim: RepositoryClaim) -> list[RepositoryEvidence]:
        allowed = _candidate_kinds(claim)
        names = {_repository_name(claim.canonical_name)}
        if claim.kind in {RepositoryClaimKind.FUNCTION_OR_FEATURE, RepositoryClaimKind.ARCHITECTURE_COMPONENT}:
            names.add(_without_generic_words(claim.canonical_name))
        result: list[RepositoryEvidence] = []
        for name in names:
            if name:
                result.extend(item for item in self.index.by_normalized_name.get(name, []) if item.kind in allowed)
        if claim.kind in {RepositoryClaimKind.FUNCTION_OR_FEATURE, RepositoryClaimKind.ARCHITECTURE_COMPONENT}:
            claim_core = _without_generic_words(claim.canonical_name)
            for item in self.index.candidates_for_kind(claim.kind, allowed):
                if claim_core and any(_without_generic_words(label) == claim_core for label in _evidence_labels(item)):
                    result.append(item)
        return _prefer_specific_kind(claim, result)

    def _mapping_candidates(
        self,
        claim: RepositoryClaim,
        mapping: RepositoryMappingEntry,
    ) -> list[RepositoryEvidence]:
        result: list[RepositoryEvidence] = []
        allowed = _candidate_kinds(claim)
        all_evidence = self.snapshot.all_evidence()
        for evidence in all_evidence:
            if evidence.kind not in allowed:
                continue
            labels = {_exact_name(value) for value in _evidence_labels(evidence)}
            normalized_path = evidence.path.replace("\\", "/").strip("/")
            if any(_path_matches(normalized_path, path) for path in mapping.paths):
                result.append(evidence)
            if mapping.symbols and evidence.kind == EvidenceKind.SYMBOL and any(_exact_name(value) in labels for value in mapping.symbols):
                result.append(evidence)
            if mapping.packages and evidence.kind in {EvidenceKind.PACKAGE, EvidenceKind.MODULE, EvidenceKind.BUILD_TARGET} and any(_exact_name(value) in labels for value in mapping.packages):
                result.append(evidence)
            if mapping.tests and evidence.kind == EvidenceKind.TEST and any(_exact_name(value) in labels for value in mapping.tests):
                result.append(evidence)
            if mapping.artifacts and evidence.kind == EvidenceKind.RELEASE_ARTIFACT and any(_path_matches(normalized_path, value) for value in mapping.artifacts):
                result.append(evidence)
        return _unique(result)

    def _primary_candidates(
        self,
        claim: RepositoryClaim,
        candidates: list[RepositoryEvidence],
    ) -> list[RepositoryEvidence]:
        preferred_order = {
            RepositoryClaimKind.FUNCTION_OR_FEATURE: (EvidenceKind.SYMBOL, EvidenceKind.CONFIGURATION, EvidenceKind.MODULE, EvidenceKind.PACKAGE),
            RepositoryClaimKind.ARCHITECTURE_COMPONENT: (EvidenceKind.PACKAGE, EvidenceKind.MODULE, EvidenceKind.BUILD_TARGET, EvidenceKind.DIRECTORY, EvidenceKind.CONFIGURATION),
            RepositoryClaimKind.TEST_CLAIM: (EvidenceKind.TEST,),
            RepositoryClaimKind.DELIVERABLE_OR_PACKAGE: (EvidenceKind.RELEASE_ARTIFACT, EvidenceKind.PACKAGE, EvidenceKind.BUILD_TARGET, EvidenceKind.MODULE, EvidenceKind.DIRECTORY),
        }[claim.kind]
        for kind in preferred_order:
            selected = [item for item in candidates if item.kind == kind]
            if selected:
                return selected
        return candidates

    def _augment_evidence(
        self,
        claim: RepositoryClaim,
        selected: list[RepositoryEvidence],
    ) -> list[RepositoryEvidence]:
        if claim.kind != RepositoryClaimKind.TEST_CLAIM:
            return selected
        result = list(selected)
        expected = _expected_kinds(claim)
        if EvidenceKind.CI_JOB in expected:
            result.extend(self._ci_evidence_for_tests(selected))
        if EvidenceKind.TEST_RESULT in expected:
            result.extend(self._result_evidence_for_claim(claim, selected))
        return _unique(result)

    def _ci_evidence_for_tests(self, tests: list[RepositoryEvidence]) -> list[RepositoryEvidence]:
        jobs = [item for item in self.snapshot.ci_configs if item.kind == EvidenceKind.CI_JOB and item.metadata.get("invokes_tests")]
        if not tests:
            return []
        test_roots = {_top_module(item.path) for item in tests}
        root_test_languages = {
            str(item.metadata.get("language"))
            for item in self.snapshot.tests
            if not _top_module(item.path) and item.metadata.get("language")
        }
        selected_languages = {
            str(item.metadata.get("language"))
            for item in tests
            if not _top_module(item.path) and item.metadata.get("language")
        }
        relevant: list[RepositoryEvidence] = []
        for job in jobs:
            invocations = _ci_command_invocations(job)
            for invocation in invocations:
                command = invocation["command"]
                if not _ci_invokes_tests(command):
                    continue
                directory = invocation["working_directory"]
                targeted_tests = _targeted_tests(command, self.snapshot.tests, directory)
                if targeted_tests:
                    if any(item.evidence_id in targeted_tests for item in tests):
                        relevant.append(job)
                        break
                    continue
                if any(root and (root in command or root == directory or directory.startswith(root + "/")) for root in test_roots):
                    command_languages = _ci_test_languages(command)
                    scope_languages = {
                        language
                        for item in self.snapshot.tests
                        if _top_module(item.path) in test_roots
                        for language in [_test_language(item)]
                        if language
                    }
                    selected_test_languages = {
                        language
                        for item in tests
                        for language in [_test_language(item)]
                        if language
                    }
                    if command_languages:
                        if command_languages.intersection(selected_test_languages):
                            relevant.append(job)
                            break
                    elif len(scope_languages) == 1 and scope_languages.intersection(selected_test_languages):
                        relevant.append(job)
                        break
                    continue
                if "" not in test_roots or directory:
                    continue
                command_languages = _ci_test_languages(command)
                if command_languages.intersection(selected_languages) or (
                    not command_languages and len(root_test_languages) <= 1
                ):
                    relevant.append(job)
                    break
        return relevant

    def _result_evidence_for_claim(
        self,
        claim: RepositoryClaim,
        tests: list[RepositoryEvidence],
    ) -> list[RepositoryEvidence]:
        names = {_repository_name(claim.canonical_name)}
        names.update(_repository_name(item.symbol or "") for item in tests)
        identifiers = {normalize_identifier(value) for value in claim.identifiers}
        result: list[RepositoryEvidence] = []
        for evidence in self.snapshot.test_results:
            test_names = {_repository_name(str(value)) for value in evidence.metadata.get("test_names", [])}
            evidence_ids = {normalize_identifier(str(value)) for value in evidence.metadata.get("identifiers", [])}
            matched_names = names.intersection(test_names)
            if matched_names or identifiers.intersection(evidence_ids):
                test_outcomes = {
                    _repository_name(str(name)): str(outcome).upper()
                    for name, outcome in evidence.metadata.get("test_outcomes", {}).items()
                }
                if matched_names and test_outcomes:
                    metadata = dict(evidence.metadata)
                    metadata["latest_result"] = _aggregate_result_values(
                        test_outcomes.get(name, "UNKNOWN") for name in matched_names
                    )
                    result.append(replace(evidence, metadata=metadata))
                else:
                    result.append(evidence)
        return _latest_test_results(result)

    def _test_states(
        self,
        claim: RepositoryClaim,
        evidence: list[RepositoryEvidence],
    ) -> list[TestEvidenceState]:
        if claim.kind != RepositoryClaimKind.TEST_CLAIM:
            return []
        result: list[TestEvidenceState] = []
        if any(item.kind == EvidenceKind.TEST for item in evidence):
            result.append(TestEvidenceState.IMPLEMENTATION_PRESENT)
        if any(item.kind == EvidenceKind.CI_JOB for item in evidence):
            result.append(TestEvidenceState.CI_CONFIGURED)
        test_results = [item for item in evidence if item.kind == EvidenceKind.TEST_RESULT]
        if test_results:
            result.append(TestEvidenceState.RESULT_PRESENT)
            latest_result = _aggregate_result_values(
                str(item.metadata.get("latest_result", "UNKNOWN")) for item in test_results
            )
            if latest_result == "FAIL":
                result.append(TestEvidenceState.LATEST_RESULT_FAIL)
            elif latest_result == "PASS":
                result.append(TestEvidenceState.LATEST_RESULT_PASS)
            else:
                result.append(TestEvidenceState.LATEST_RESULT_UNKNOWN)
        return result

    def _metadata(self, mapping: RepositoryMappingEntry | None) -> dict[str, Any]:
        value: dict[str, Any] = {"snapshot": self.snapshot.audit_metadata}
        if mapping is not None:
            value.update({"manual_mapping": True, "mapping": mapping.to_dict()})
        return value


def _evidence_labels(evidence: RepositoryEvidence) -> list[str]:
    values = [evidence.symbol, evidence.module, PurePosixPath(evidence.path).stem]
    for key in ("name", "test_name", "display_name", "package_identifier", "applicationId", "namespace"):
        value = evidence.metadata.get(key)
        if value not in (None, ""):
            values.append(str(value))
    return list(dict.fromkeys(str(value) for value in values if value not in (None, "")))


def _exact_name(value: str) -> str:
    return " ".join(str(value or "").split()).casefold()


def _repository_name(value: str) -> str:
    text = str(value or "")
    text = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", " ", text)
    text = re.sub(r"(?<=[A-Z])(?=[A-Z][a-z])", " ", text)
    return normalize_name(text)


def _without_generic_words(value: str) -> str:
    words = _repository_name(value).split()
    return " ".join(word for word in words if word not in _GENERIC_IMPLEMENTATION_WORDS)


def _prefer_specific_kind(claim: RepositoryClaim, items: Iterable[RepositoryEvidence]) -> list[RepositoryEvidence]:
    values = _unique(items)
    if claim.kind == RepositoryClaimKind.FUNCTION_OR_FEATURE:
        symbols = [item for item in values if item.kind in {EvidenceKind.SYMBOL, EvidenceKind.CONFIGURATION}]
        return symbols or values
    if claim.kind == RepositoryClaimKind.TEST_CLAIM:
        tests = [item for item in values if item.kind == EvidenceKind.TEST]
        return tests or values
    return values


def _path_matches(path: str, configured: str) -> bool:
    pattern = str(configured).replace("\\", "/").strip("/")
    if not pattern:
        return False
    return (
        path == pattern
        or path.startswith(pattern.rstrip("/") + "/")
        or fnmatch.fnmatchcase(path, pattern)
        or PurePosixPath(path).match(pattern)
    )


def _is_explicit_identifier_reference(evidence: RepositoryEvidence) -> bool:
    return (
        evidence.kind == EvidenceKind.CONFIGURATION
        and evidence.metadata.get("configuration_type") == "explicit_identifier_reference"
    )


def _version_conflict(claim: RepositoryClaim, evidence: Iterable[RepositoryEvidence]) -> dict[str, str] | None:
    documented = claim.metadata.get("version")
    if documented in (None, ""):
        return None
    versions = {
        str(item.metadata.get("version"))
        for item in evidence
        if item.metadata.get("version") not in (None, "")
    }
    if len(versions) == 1 and normalize_name(str(documented)) not in {normalize_name(value) for value in versions}:
        return {"documented": str(documented), "repository": next(iter(versions))}
    return None


def _test_result_conflict(
    claim: RepositoryClaim,
    evidence: Iterable[RepositoryEvidence],
) -> dict[str, str] | None:
    if claim.kind != RepositoryClaimKind.TEST_CLAIM:
        return None
    documented = normalize_name(str(claim.metadata.get("status", claim.metadata.get("state", ""))))
    if documented not in {"pass", "passed", "success", "successful", "fail", "failed"}:
        return None
    expected = "PASS" if documented in {"pass", "passed", "success", "successful"} else "FAIL"
    recorded = [
        str(item.metadata.get("latest_result", "UNKNOWN"))
        for item in evidence
        if item.kind == EvidenceKind.TEST_RESULT
    ]
    actual = _aggregate_result_values(recorded)
    if actual != "UNKNOWN" and actual != expected:
        return {"documented": expected, "repository": actual}
    return None


def _aggregate_result_values(values: Iterable[str]) -> str:
    outcomes = {str(value).upper() for value in values}
    if "FAIL" in outcomes:
        return "FAIL"
    if outcomes == {"PASS"}:
        return "PASS"
    return "UNKNOWN"


def _latest_test_results(results: list[RepositoryEvidence]) -> list[RepositoryEvidence]:
    if len(results) <= 1:
        return results
    timestamps = [item.metadata.get("modified_time_ns") for item in results]
    if not all(isinstance(value, int) for value in timestamps):
        return [_unknown_test_result(item) for item in results]
    latest_timestamp = max(timestamps)
    latest = [item for item in results if item.metadata.get("modified_time_ns") == latest_timestamp]
    if len(latest) != 1:
        return [_unknown_test_result(item) for item in latest]
    return latest


def _unknown_test_result(evidence: RepositoryEvidence) -> RepositoryEvidence:
    metadata = dict(evidence.metadata)
    metadata["latest_result"] = "UNKNOWN"
    return replace(evidence, metadata=metadata)


def _verified_reason(
    claim: RepositoryClaim,
    evidence: list[RepositoryEvidence],
    states: list[TestEvidenceState],
) -> str:
    if claim.kind == RepositoryClaimKind.TEST_CLAIM:
        return "Executable test source was located; CI configuration and recorded results are reported as separate evidence states."
    if claim.kind == RepositoryClaimKind.DELIVERABLE_OR_PACKAGE and any(item.kind == EvidenceKind.RELEASE_ARTIFACT for item in evidence):
        return "A matching artifact is present in the supplied artifact directory."
    return "Deterministic repository evidence was located for the documented claim; existence does not assert behavioral correctness."


def _top_module(path: str) -> str:
    parts = PurePosixPath(path).parts
    if not parts or parts[0].casefold() in {"test", "tests"}:
        return ""
    return parts[0]


def _test_language(evidence: RepositoryEvidence) -> str | None:
    value = evidence.metadata.get("language")
    return str(value) if value not in (None, "") else None


def _ci_test_languages(command: str) -> set[str]:
    patterns = {
        "python": r"\b(?:pytest|python(?:3)?\s+-m\s+(?:pytest|unittest))\b",
        "csharp": r"\bdotnet\s+test\b",
        "dart": r"\b(?:dart|flutter)\s+test\b",
        "kotlin": r"\bgradlew?\b[^\n]*\btest[A-Za-z0-9]*\b",
        "swift": r"\b(?:swift\s+test|xcodebuild\s+test)\b",
    }
    return {
        language
        for language, pattern in patterns.items()
        if re.search(pattern, command, re.IGNORECASE)
    }


def _ci_invokes_tests(command: str) -> bool:
    return bool(
        re.search(r"\b(?:test|pytest|ctest|xcodebuild\s+test)\b", command, re.IGNORECASE)
        or re.search(r"(?:^|:)test[A-Z][A-Za-z0-9]*", command)
    )


def _ci_command_invocations(job: RepositoryEvidence) -> list[dict[str, str]]:
    configured = job.metadata.get("command_invocations")
    if isinstance(configured, list):
        return [
            {
                "command": str(item.get("command", "")),
                "working_directory": str(item.get("working_directory", "")),
            }
            for item in configured
            if isinstance(item, dict)
        ]
    commands = [str(value) for value in job.metadata.get("commands", [])]
    directories = [str(value) for value in job.metadata.get("working_directories", [])]
    if len(directories) == 1:
        return [{"command": command, "working_directory": directories[0]} for command in commands]
    if not directories:
        return [{"command": command, "working_directory": ""} for command in commands]
    return []


def _targeted_tests(
    command: str,
    tests: Iterable[RepositoryEvidence],
    working_directory: str,
) -> set[str]:
    arguments = {
        argument.split("::", 1)[0].replace("\\", "/").lstrip("./")
        for argument in _shell_arguments(command)
        if not argument.startswith("-")
    }
    if not arguments:
        return set()
    result: set[str] = set()
    for test in tests:
        path = test.path.replace("\\", "/").strip("/")
        relative_path = path
        if working_directory:
            prefix = working_directory.rstrip("/") + "/"
            if not path.startswith(prefix):
                continue
            relative_path = path[len(prefix) :]
        if any(
            relative_path == argument
            or relative_path.startswith(argument.rstrip("/") + "/")
            for argument in arguments
        ):
            result.add(test.evidence_id)
    return result


def _shell_arguments(command: str) -> list[str]:
    try:
        return shlex.split(command)
    except ValueError:
        return command.split()


def _unique(items: Iterable[RepositoryEvidence]) -> list[RepositoryEvidence]:
    result: list[RepositoryEvidence] = []
    seen: set[str] = set()
    for item in items:
        if item.evidence_id in seen:
            continue
        seen.add(item.evidence_id)
        result.append(item)
    return result
