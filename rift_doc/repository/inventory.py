"""Read-only local repository inventory and evidence indexing."""

from __future__ import annotations

from dataclasses import dataclass
import fnmatch
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import time
from typing import Any, Iterable
import xml.etree.ElementTree as ET

import yaml

from .languages import DEFAULT_ADAPTERS
from .manifests import is_manifest, parse_manifest
from .model import (
    EvidenceKind,
    RepositoryEvidence,
    RepositoryLineRange,
    RepositorySnapshot,
    RepositoryVcsMetadata,
)
from ..trace_model import normalize_identifier, normalize_name


_DEFAULT_EXCLUDED_COMPONENTS = frozenset(
    {
        ".git",
        ".hg",
        ".svn",
        ".dart_tool",
        ".gradle",
        ".idea",
        ".pytest_cache",
        ".tox",
        ".venv",
        ".vs",
        "__pycache__",
        "build",
        "coverage",
        "dist",
        "logs",
        "node_modules",
        "obj",
        "Pods",
        "TestResults",
        "vendor",
    }
)
_CI_PATH_PATTERNS = (
    ".github/workflows/*.yml",
    ".github/workflows/*.yaml",
    ".gitlab-ci.yml",
    "azure-pipelines.yml",
)
_TEST_RESULT_SUFFIXES = {".trx", ".junit", ".tap"}
_SOURCE_LIMIT_BYTES = 2 * 1024 * 1024


@dataclass(frozen=True)
class InventoryOptions:
    excluded_paths: tuple[str, ...] = ()
    max_source_bytes: int = _SOURCE_LIMIT_BYTES


@dataclass(frozen=True)
class _PlainIgnoreRule:
    pattern: str
    negated: bool
    directory_only: bool
    anchored: bool


class RepositoryInventory:
    """Inventory one worktree once without running its build or test code."""

    def __init__(self, options: InventoryOptions | None = None) -> None:
        self.options = options or InventoryOptions()
        self.adapters = DEFAULT_ADAPTERS
        self.adapters_by_suffix = {
            suffix: adapter
            for adapter in self.adapters
            for suffix in adapter.suffixes
        }

    def scan(
        self,
        root: str | Path,
        *,
        artifact_root: str | Path | None = None,
    ) -> RepositorySnapshot:
        started = time.monotonic()
        repository_root = Path(root).expanduser().resolve()
        if not repository_root.is_dir():
            raise ValueError(f"repository path is not a directory: {repository_root}")

        paths, source = self._repository_paths(repository_root)
        vcs = _git_metadata(repository_root)
        snapshot = RepositorySnapshot(root=str(repository_root), vcs_metadata=vcs)
        snapshot.metadata.update(
            {
                "inventory_source": source,
                "excluded_paths": sorted(self.options.excluded_paths),
                "max_source_bytes": self.options.max_source_bytes,
                "network_access": False,
                "repository_code_executed": False,
            }
        )

        scanned_files = 0
        skipped_large = 0
        languages: dict[str, int] = {}
        directory_paths: set[str] = set()
        for relative_path in paths:
            if self._is_excluded(relative_path):
                continue
            absolute_path = repository_root / relative_path
            if absolute_path.is_symlink() or not absolute_path.is_file():
                continue
            size = absolute_path.stat().st_size
            scanned_files += 1
            directory_paths.update(_ancestor_directories(relative_path))
            suffix = PurePosixPath(relative_path).suffix.casefold()
            adapter = self.adapters_by_suffix.get(suffix)
            manifest = is_manifest(relative_path)
            ci_config = _is_ci_path(relative_path)
            if not adapter and not manifest and not ci_config:
                continue
            if size > self.options.max_source_bytes:
                skipped_large += 1
                continue
            data = absolute_path.read_bytes()
            if _looks_binary(data):
                continue
            text = data.decode("utf-8", errors="replace")

            if adapter is not None:
                languages[adapter.language] = languages.get(adapter.language, 0) + 1
                snapshot.source_files.append(
                    RepositoryEvidence(
                        evidence_id=f"file:{relative_path}",
                        kind=EvidenceKind.FILE,
                        path=relative_path,
                        module=_source_module(relative_path),
                        metadata={"language": adapter.language, "size_bytes": size},
                    )
                )
                result = adapter.scan(relative_path, text)
                snapshot.symbols.extend(result.symbols)
                snapshot.tests.extend(result.tests)
                snapshot.configurations.extend(_identifier_configurations(relative_path, text))

            if manifest:
                result = parse_manifest(relative_path, data, text)
                snapshot.manifests.extend(result.manifests)
                snapshot.modules.extend(result.modules)
                snapshot.build_configs.extend(result.build_configs)

            if ci_config:
                snapshot.ci_configs.extend(_parse_ci_config(relative_path, text))

        snapshot.modules.extend(_directory_evidence(path) for path in sorted(directory_paths))
        if artifact_root is not None:
            self._scan_artifacts(snapshot, Path(artifact_root).expanduser().resolve())
        snapshot.generated_indexes = _build_serialized_indexes(snapshot)
        snapshot.metadata.update(
            {
                "scanned_file_count": scanned_files,
                "skipped_large_file_count": skipped_large,
                "languages": dict(sorted(languages.items())),
                "duration_ms": round((time.monotonic() - started) * 1000, 3),
                "counts": _snapshot_counts(snapshot),
            }
        )
        return snapshot

    def _repository_paths(self, root: Path) -> tuple[list[str], str]:
        git_paths = _git_file_paths(root)
        if git_paths is not None:
            return sorted(dict.fromkeys(git_paths)), "git"
        ignore_patterns = _read_plain_gitignore(root)
        paths: list[str] = []
        for directory, names, filenames in os.walk(root, followlinks=False):
            relative_directory = Path(directory).relative_to(root)
            names[:] = sorted(
                name
                for name in names
                if not self._is_excluded(_posix(relative_directory / name))
            )
            for filename in sorted(filenames):
                relative_path = _posix(relative_directory / filename)
                if self._is_excluded(relative_path) or _matches_ignore(relative_path, ignore_patterns):
                    continue
                paths.append(relative_path)
        return paths, "filesystem"

    def _is_excluded(self, path: str) -> bool:
        value = path.strip("/")
        parts = PurePosixPath(value).parts
        if any(part in _DEFAULT_EXCLUDED_COMPONENTS for part in parts):
            return True
        return _matches_configured_exclusion(value, self.options.excluded_paths)

    def _scan_artifacts(self, snapshot: RepositorySnapshot, root: Path) -> None:
        if not root.is_dir():
            raise ValueError(f"artifact path is not a directory: {root}")
        snapshot.metadata["artifact_root"] = str(root)
        for absolute_path in sorted(root.rglob("*")):
            if absolute_path.is_symlink() or not absolute_path.is_file():
                continue
            relative_path = _posix(absolute_path.relative_to(root))
            if _matches_configured_exclusion(relative_path, self.options.excluded_paths):
                continue
            file_stat = absolute_path.stat()
            metadata: dict[str, Any] = {
                "artifact_root": str(root),
                "size_bytes": file_stat.st_size,
                "modified_time_ns": file_stat.st_mtime_ns,
            }
            if _is_test_result_path(relative_path):
                snapshot.test_results.append(_test_result_evidence(absolute_path, relative_path, metadata))
                continue
            release = RepositoryEvidence(
                evidence_id=f"release_artifact:{relative_path}",
                kind=EvidenceKind.RELEASE_ARTIFACT,
                path=relative_path,
                metadata=metadata,
                excerpt_or_signature=absolute_path.name,
            )
            snapshot.release_artifacts.append(release)


def _git_file_paths(root: Path) -> list[str] | None:
    result = _run_git(root, "rev-parse", "--is-inside-work-tree")
    if result is None or result.stdout.strip() != "true":
        return None
    files = _run_git(root, "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", ".")
    if files is None:
        return None
    return [value for value in files.stdout.split("\0") if value]


def _git_metadata(root: Path) -> RepositoryVcsMetadata | None:
    inside = _run_git(root, "rev-parse", "--is-inside-work-tree")
    if inside is None or inside.stdout.strip() != "true":
        return None
    commit = _run_git(root, "rev-parse", "HEAD")
    branch = _run_git(root, "symbolic-ref", "--quiet", "--short", "HEAD")
    status = _run_git(root, "status", "--porcelain", "--untracked-files=normal", "--", ".")
    return RepositoryVcsMetadata(
        commit_sha=commit.stdout.strip() if commit and commit.returncode == 0 else None,
        dirty=bool(status.stdout) if status is not None and status.returncode == 0 else None,
        branch=branch.stdout.strip() if branch and branch.returncode == 0 else None,
    )


def _run_git(root: Path, *arguments: str) -> subprocess.CompletedProcess[str] | None:
    try:
        return subprocess.run(
            ["git", "-C", str(root), *arguments],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        return None


def _parse_ci_config(path: str, text: str) -> list[RepositoryEvidence]:
    result = [
        RepositoryEvidence(
            evidence_id=f"configuration:{path}",
            kind=EvidenceKind.CONFIGURATION,
            path=path,
            line_range=RepositoryLineRange(1),
            metadata={"configuration_type": "ci"},
            excerpt_or_signature=PurePosixPath(path).name,
        )
    ]
    try:
        raw = yaml.safe_load(text)
    except yaml.YAMLError:
        raw = {}
    jobs = raw.get("jobs", {}) if isinstance(raw, dict) else {}
    if not isinstance(jobs, dict):
        return result
    workflow_directory = _ci_default_working_directory(raw)
    for job_name, raw_job in jobs.items():
        job = raw_job if isinstance(raw_job, dict) else {}
        raw_steps = job.get("steps", [])
        steps = raw_steps if isinstance(raw_steps, list) else []
        job_directory = _ci_default_working_directory(job)
        command_invocations: list[dict[str, str]] = []
        for step in steps:
            if not isinstance(step, dict) or step.get("run") is None:
                continue
            step_directory = step.get("working-directory", step.get("working_directory"))
            effective_directory = (
                step_directory
                if step_directory not in (None, "")
                else job_directory
                if job_directory is not None
                else workflow_directory
            )
            command_invocations.append(
                {
                    "command": str(step["run"]),
                    "working_directory": _normalize_ci_working_directory(effective_directory),
                }
            )
        commands = [item["command"] for item in command_invocations]
        working_directories = list(
            dict.fromkeys(
                item["working_directory"]
                for item in command_invocations
                if item["working_directory"]
            )
        )
        line = _yaml_key_line(text, str(job_name))
        signature = " ".join(command.replace("\n", " ") for command in commands)
        result.append(
            RepositoryEvidence(
                evidence_id=f"ci_job:{path}:{job_name}",
                kind=EvidenceKind.CI_JOB,
                path=path,
                line_range=RepositoryLineRange(line),
                symbol=str(job_name),
                module=str(job.get("name") or job_name),
                metadata={
                    "job_name": str(job_name),
                    "display_name": job.get("name"),
                    "commands": commands,
                    "working_directories": working_directories,
                    "command_invocations": command_invocations,
                    "invokes_tests": _invokes_tests(signature),
                },
                excerpt_or_signature=signature or str(job_name),
            )
        )
    return result


def _ci_default_working_directory(configuration: dict[str, Any]) -> Any:
    defaults = configuration.get("defaults", {})
    if not isinstance(defaults, dict):
        return None
    run_defaults = defaults.get("run", {})
    if not isinstance(run_defaults, dict):
        return None
    return run_defaults.get("working-directory", run_defaults.get("working_directory"))


def _normalize_ci_working_directory(value: Any) -> str:
    path = str(value or "").replace("\\", "/").strip()
    parts = [part for part in path.split("/") if part not in {"", "."}]
    if any(part == ".." for part in parts):
        return path.strip("/")
    return "/".join(parts)


def _invokes_tests(command: str) -> bool:
    return bool(
        re.search(r"\b(?:test|pytest|ctest|xcodebuild\s+test)\b", command, re.IGNORECASE)
        or re.search(r"(?:^|:)test[A-Z][A-Za-z0-9]*", command)
    )


def _identifier_configurations(path: str, text: str) -> list[RepositoryEvidence]:
    result: list[RepositoryEvidence] = []
    seen: set[tuple[str, int]] = set()
    for line_number, line in enumerate(text.splitlines(), start=1):
        for match in re.finditer(r"(?<![A-Za-z0-9])([A-Za-z]{1,16}\s*[-_./]?\s*\d{1,8})(?![A-Za-z0-9])", line):
            identifier = normalize_identifier(match.group(1))
            key = (identifier, line_number)
            if not identifier or key in seen:
                continue
            seen.add(key)
            result.append(
                RepositoryEvidence(
                    evidence_id=f"configuration:{path}:{line_number}:{identifier}",
                    kind=EvidenceKind.CONFIGURATION,
                    path=path,
                    line_range=RepositoryLineRange(line_number),
                    module=_source_module(path),
                    metadata={"identifiers": [identifier], "configuration_type": "explicit_identifier_reference"},
                    excerpt_or_signature=line.strip(),
                )
            )
    return result


def _test_result_evidence(path: Path, relative_path: str, metadata: dict[str, Any]) -> RepositoryEvidence:
    result_metadata = dict(metadata)
    result_metadata["result_format"] = path.suffix.casefold().lstrip(".") or "unknown"
    status = "UNKNOWN"
    test_outcomes: dict[str, str] = {}
    if path.suffix.casefold() in {".xml", ".trx", ".junit"} and path.stat().st_size <= _SOURCE_LIMIT_BYTES:
        try:
            root = ET.fromstring(path.read_bytes())
        except (ET.ParseError, OSError):
            root = None
        if root is not None:
            for element in root.iter():
                tag = element.tag.rsplit("}", 1)[-1]
                attribute = "testName" if tag == "UnitTestResult" else "name" if tag == "testcase" else None
                if not attribute or not element.attrib.get(attribute):
                    continue
                name = str(element.attrib[attribute])
                if tag == "UnitTestResult":
                    outcome = _normalized_test_outcome(element.attrib.get("outcome"))
                else:
                    child_tags = {child.tag.rsplit("}", 1)[-1] for child in element}
                    outcome = "FAIL" if child_tags.intersection({"failure", "error"}) else "UNKNOWN" if "skipped" in child_tags else "PASS"
                previous = test_outcomes.get(name)
                test_outcomes[name] = _aggregate_test_outcomes([previous, outcome]) if previous else outcome
            status = _aggregate_test_outcomes(test_outcomes.values())
    result_metadata.update(
        {
            "suite_result": status,
            "test_names": list(test_outcomes),
            "test_outcomes": test_outcomes,
        }
    )
    return RepositoryEvidence(
        evidence_id=f"test_result:{relative_path}",
        kind=EvidenceKind.TEST_RESULT,
        path=relative_path,
        metadata=result_metadata,
        excerpt_or_signature=f"{PurePosixPath(relative_path).name}: {status}",
    )


def _normalized_test_outcome(value: Any) -> str:
    outcome = str(value or "").casefold()
    if outcome in {"fail", "failed", "error"}:
        return "FAIL"
    if outcome in {"pass", "passed", "success", "successful", "completed"}:
        return "PASS"
    return "UNKNOWN"


def _aggregate_test_outcomes(outcomes: Iterable[str]) -> str:
    values = set(outcomes)
    if "FAIL" in values:
        return "FAIL"
    if values == {"PASS"}:
        return "PASS"
    return "UNKNOWN"


def _build_serialized_indexes(snapshot: RepositorySnapshot) -> dict[str, Any]:
    names: dict[str, list[str]] = {}
    identifiers: dict[str, list[str]] = {}
    paths: dict[str, list[str]] = {}
    for evidence in snapshot.all_evidence():
        path_key = normalize_name(evidence.path)
        if path_key:
            paths.setdefault(path_key, []).append(evidence.evidence_id)
        values = [evidence.symbol, evidence.module, PurePosixPath(evidence.path).stem]
        values.extend(_path_names(evidence.path))
        for value in values:
            normalized = normalize_name(str(value or ""))
            if normalized:
                names.setdefault(normalized, []).append(evidence.evidence_id)
        for identifier in evidence.metadata.get("identifiers", []):
            normalized = normalize_identifier(str(identifier))
            if normalized:
                identifiers.setdefault(normalized, []).append(evidence.evidence_id)
    return {
        "by_name": {key: sorted(set(value)) for key, value in sorted(names.items())},
        "by_identifier": {key: sorted(set(value)) for key, value in sorted(identifiers.items())},
        "by_path": {key: sorted(set(value)) for key, value in sorted(paths.items())},
    }


def _snapshot_counts(snapshot: RepositorySnapshot) -> dict[str, int]:
    return {
        "manifests": len(snapshot.manifests),
        "source_files": len(snapshot.source_files),
        "modules": len(snapshot.modules),
        "symbols": len(snapshot.symbols),
        "tests": len(snapshot.tests),
        "test_results": len(snapshot.test_results),
        "ci_configs": len(snapshot.ci_configs),
        "configurations": len(snapshot.configurations),
        "build_configs": len(snapshot.build_configs),
        "release_artifacts": len(snapshot.release_artifacts),
    }


def _directory_evidence(path: str) -> RepositoryEvidence:
    return RepositoryEvidence(
        evidence_id=f"directory:{path}",
        kind=EvidenceKind.DIRECTORY,
        path=path,
        module=PurePosixPath(path).name,
        metadata={"name": PurePosixPath(path).name},
        excerpt_or_signature=path,
    )


def _ancestor_directories(path: str) -> set[str]:
    result: set[str] = set()
    parent = PurePosixPath(path).parent
    while str(parent) not in {"", "."}:
        result.add(str(parent))
        parent = parent.parent
    return result


def _source_module(path: str) -> str | None:
    parent = PurePosixPath(path).parent
    return str(parent) if str(parent) != "." else None


def _path_names(path: str) -> Iterable[str]:
    for part in PurePosixPath(path).parts:
        if part not in {"lib", "src", "test", "tests"}:
            yield PurePosixPath(part).stem


def _read_plain_gitignore(root: Path) -> list[_PlainIgnoreRule]:
    path = root / ".gitignore"
    if not path.is_file():
        return []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    rules: list[_PlainIgnoreRule] = []
    for line in lines:
        value = line.strip()
        if not value or value.startswith("#"):
            continue
        negated = value.startswith("!")
        if negated:
            value = value[1:]
        value = value.replace("\\", "/")
        directory_only = value.endswith("/")
        value = value.rstrip("/")
        if not value:
            continue
        rules.append(
            _PlainIgnoreRule(
                pattern=value,
                negated=negated,
                directory_only=directory_only,
                anchored=value.startswith("/"),
            )
        )
    return rules


def _matches_ignore(path: str, rules: list[_PlainIgnoreRule]) -> bool:
    value = path.strip("/")
    ignored = False
    for rule in rules:
        if _ignore_rule_matches(value, rule):
            ignored = not rule.negated
    return ignored


def _ignore_rule_matches(path: str, rule: _PlainIgnoreRule) -> bool:
    pattern = rule.pattern.strip("/")
    if rule.directory_only and (path == pattern or path.startswith(pattern + "/")):
        return True
    if path == pattern or path.startswith(pattern + "/") or fnmatch.fnmatchcase(path, pattern):
        return True
    if "/" not in pattern and not rule.anchored:
        return any(fnmatch.fnmatchcase(part, pattern) for part in PurePosixPath(path).parts)
    return False


def _matches_configured_exclusion(path: str, patterns: Iterable[str]) -> bool:
    value = path.strip("/")
    for raw_pattern in patterns:
        pattern = str(raw_pattern).strip().replace("\\", "/").strip("/")
        if not pattern:
            continue
        if value == pattern or value.startswith(pattern + "/"):
            return True
        if fnmatch.fnmatchcase(value, pattern) or PurePosixPath(value).match(pattern):
            return True
    return False


def _is_ci_path(path: str) -> bool:
    return any(fnmatch.fnmatchcase(path, pattern) for pattern in _CI_PATH_PATTERNS)


def _is_test_result_path(path: str) -> bool:
    value = PurePosixPath(path)
    name = value.name.casefold()
    return (
        value.suffix.casefold() in _TEST_RESULT_SUFFIXES
        or (value.suffix.casefold() == ".xml" and any(word in name for word in ("test", "junit", "result")))
        or "test-results" in (part.casefold() for part in value.parts)
    )


def _yaml_key_line(text: str, key: str) -> int:
    match = re.search(rf"(?m)^\s*{re.escape(key)}\s*:", text)
    return text.count("\n", 0, match.start()) + 1 if match else 1


def _looks_binary(data: bytes) -> bool:
    return b"\0" in data[:4096]


def _posix(path: Path) -> str:
    value = path.as_posix()
    return "" if value == "." else value
