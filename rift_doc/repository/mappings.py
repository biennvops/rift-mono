"""Schema-validated, auditable project-specific repository mappings."""

from __future__ import annotations

from dataclasses import dataclass, field
import json
from pathlib import Path
from typing import Any

import jsonschema
import yaml

from .model import RepositoryClaim, RepositoryClaimKind
from ..trace_model import normalize_identifier, normalize_name


_MAPPING_SCHEMA: dict[str, Any] = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "type": "object",
    "properties": {
        "repository_mappings": {"$ref": "#/$defs/mappings"},
        "repository_mapping": {"$ref": "#/$defs/mappings"},
        "excluded_paths": {"type": "array", "items": {"type": "string", "minLength": 1}},
    },
    "anyOf": [
        {"required": ["repository_mappings"]},
        {"required": ["repository_mapping"]},
        {"required": ["excluded_paths"]},
    ],
    "additionalProperties": False,
    "$defs": {
        "mappings": {
            "type": "object",
            "properties": {
                "features": {"$ref": "#/$defs/category"},
                "functions": {"$ref": "#/$defs/category"},
                "components": {"$ref": "#/$defs/category"},
                "tests": {"$ref": "#/$defs/category"},
                "deliverables": {"$ref": "#/$defs/category"},
            },
            "additionalProperties": False,
        },
        "category": {
            "type": "object",
            "additionalProperties": {"$ref": "#/$defs/entry"},
        },
        "entry": {
            "type": "object",
            "properties": {
                "paths": {"type": "array", "items": {"type": "string", "minLength": 1}},
                "symbols": {"type": "array", "items": {"type": "string", "minLength": 1}},
                "packages": {"type": "array", "items": {"type": "string", "minLength": 1}},
                "tests": {"type": "array", "items": {"type": "string", "minLength": 1}},
                "artifacts": {"type": "array", "items": {"type": "string", "minLength": 1}},
                "contradicts": {
                    "oneOf": [
                        {"type": "boolean"},
                        {"type": "string", "minLength": 1},
                    ]
                },
                "executable_required": {"type": "boolean"},
            },
            "minProperties": 1,
            "additionalProperties": False,
        },
    },
}


class RepositoryMappingError(ValueError):
    pass


@dataclass(frozen=True)
class RepositoryMappingEntry:
    category: str
    key: str
    paths: tuple[str, ...] = ()
    symbols: tuple[str, ...] = ()
    packages: tuple[str, ...] = ()
    tests: tuple[str, ...] = ()
    artifacts: tuple[str, ...] = ()
    contradicts: bool | str = False
    executable_required: bool | None = None
    source_path: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "category": self.category,
            "key": self.key,
            "paths": list(self.paths),
            "symbols": list(self.symbols),
            "packages": list(self.packages),
            "tests": list(self.tests),
            "artifacts": list(self.artifacts),
            "contradicts": self.contradicts,
            "executable_required": self.executable_required,
            "source_path": self.source_path,
        }


@dataclass
class RepositoryMappingConfig:
    entries: list[RepositoryMappingEntry] = field(default_factory=list)
    excluded_paths: tuple[str, ...] = ()
    source_path: str | None = None

    @classmethod
    def load(cls, path: str | Path) -> "RepositoryMappingConfig":
        source = Path(path)
        try:
            data = yaml.safe_load(source.read_text(encoding="utf-8"))
        except (OSError, yaml.YAMLError) as exc:
            raise RepositoryMappingError(f"could not parse repository mapping {source}: {exc}") from exc
        return cls.from_dict(data, source_path=str(source))

    @classmethod
    def from_dict(cls, data: Any, *, source_path: str | None = None) -> "RepositoryMappingConfig":
        if not isinstance(data, dict):
            raise RepositoryMappingError("repository mapping must be a YAML/JSON object")
        validator = jsonschema.Draft202012Validator(_MAPPING_SCHEMA)
        errors = sorted(validator.iter_errors(data), key=lambda error: list(error.absolute_path))
        if errors:
            messages = []
            for error in errors:
                location = "$" + "".join(f"[{json.dumps(value)}]" for value in error.absolute_path)
                messages.append(f"{location}: {error.message}")
            raise RepositoryMappingError("invalid repository mapping:\n" + "\n".join(f"- {message}" for message in messages))
        raw_mappings = data.get("repository_mappings", data.get("repository_mapping", {}))
        entries: list[RepositoryMappingEntry] = []
        for category, raw_category in raw_mappings.items() if isinstance(raw_mappings, dict) else ():
            if not isinstance(raw_category, dict):
                continue
            for key, raw_entry in raw_category.items():
                if not isinstance(raw_entry, dict):
                    continue
                entries.append(
                    RepositoryMappingEntry(
                        category=str(category),
                        key=str(key),
                        paths=_strings(raw_entry.get("paths")),
                        symbols=_strings(raw_entry.get("symbols")),
                        packages=_strings(raw_entry.get("packages")),
                        tests=_strings(raw_entry.get("tests")),
                        artifacts=_strings(raw_entry.get("artifacts")),
                        contradicts=raw_entry.get("contradicts", False),
                        executable_required=raw_entry.get("executable_required"),
                        source_path=source_path,
                    )
                )
        return cls(
            entries=entries,
            excluded_paths=_strings(data.get("excluded_paths")),
            source_path=source_path,
        )

    def mapping_for(self, claim: RepositoryClaim) -> RepositoryMappingEntry | None:
        allowed_categories = _categories_for_kind(claim.kind)
        identifiers = {normalize_identifier(value) for value in claim.identifiers}
        identifiers.add(normalize_identifier(claim.claim_id))
        names = {normalize_name(claim.canonical_name), normalize_name(claim.claim_id)}
        for entry in self.entries:
            if entry.category not in allowed_categories:
                continue
            normalized_identifier = normalize_identifier(entry.key)
            normalized_entry_name = normalize_name(entry.key)
            if normalized_identifier in identifiers or normalized_entry_name in names:
                return entry
        return None


def _categories_for_kind(kind: RepositoryClaimKind) -> set[str]:
    if kind == RepositoryClaimKind.FUNCTION_OR_FEATURE:
        return {"features", "functions"}
    if kind == RepositoryClaimKind.ARCHITECTURE_COMPONENT:
        return {"components"}
    if kind == RepositoryClaimKind.TEST_CLAIM:
        return {"tests"}
    return {"deliverables"}


def _strings(value: Any) -> tuple[str, ...]:
    if isinstance(value, str):
        return (value,)
    if isinstance(value, (list, tuple)):
        return tuple(str(item) for item in value)
    return ()
