"""Build/package manifest parsing without invoking repository tooling."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import PurePosixPath
import plistlib
import re
import tomllib
from typing import Any
import xml.etree.ElementTree as ET

import yaml

from .model import EvidenceKind, RepositoryEvidence, RepositoryLineRange


_CSPROJ_SUFFIXES = {".csproj", ".fsproj", ".vbproj"}
_BUILD_SCRIPT_RE = re.compile(r"^(?:build|package|publish|release|install)[-_].*\.(?:sh|ps1|bat)$", re.IGNORECASE)


@dataclass
class ManifestResult:
    manifests: list[RepositoryEvidence] = field(default_factory=list)
    modules: list[RepositoryEvidence] = field(default_factory=list)
    build_configs: list[RepositoryEvidence] = field(default_factory=list)


def is_manifest(path: str) -> bool:
    value = PurePosixPath(path)
    name = value.name.casefold()
    return (
        value.suffix.casefold() in _CSPROJ_SUFFIXES
        or value.suffix.casefold() == ".sln"
        or name in {"pubspec.yaml", "pyproject.toml", "settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts", "androidmanifest.xml", "info.plist"}
        or name == "project.pbxproj"
        or value.suffix.casefold() in {".desktop", ".service", ".manifest"}
        or bool(_BUILD_SCRIPT_RE.match(value.name))
    )


def parse_manifest(path: str, data: bytes, text: str) -> ManifestResult:
    value = PurePosixPath(path)
    name = value.name.casefold()
    if value.suffix.casefold() in _CSPROJ_SUFFIXES:
        return _parse_dotnet_project(path, text)
    if value.suffix.casefold() == ".sln":
        return _parse_solution(path, text)
    if name == "pubspec.yaml":
        return _parse_pubspec(path, text)
    if name == "pyproject.toml":
        return _parse_pyproject(path, data)
    if name in {"settings.gradle", "settings.gradle.kts"}:
        return _parse_gradle_settings(path, text)
    if name in {"build.gradle", "build.gradle.kts"}:
        return _parse_gradle_build(path, text)
    if name == "project.pbxproj":
        return _parse_xcode_project(path, text)
    if name in {"androidmanifest.xml", "info.plist"}:
        return _parse_platform_manifest(path, data, text)
    if value.suffix.casefold() in {".desktop", ".service", ".manifest"} or _BUILD_SCRIPT_RE.match(value.name):
        return _generic_packaging_config(path)
    return ManifestResult()


def _parse_dotnet_project(path: str, text: str) -> ManifestResult:
    root = _xml_root(text)
    properties = _xml_properties(root)
    name = properties.get("AssemblyName") or PurePosixPath(path).stem
    version = properties.get("Version") or properties.get("VersionPrefix")
    frameworks = _split_values(properties.get("TargetFrameworks") or properties.get("TargetFramework"))
    packages: list[str] = []
    references: list[str] = []
    if root is not None:
        for element in root.iter():
            tag = _local_tag(element.tag)
            include = element.attrib.get("Include")
            if tag == "PackageReference" and include:
                packages.append(include)
            elif tag == "ProjectReference" and include:
                references.append(include.replace("\\", "/"))
    metadata = {
        "manifest_type": "dotnet_project",
        "name": name,
        "version": version,
        "target_frameworks": frameworks,
        "package_references": sorted(set(packages)),
        "project_references": sorted(set(references)),
    }
    return ManifestResult(
        manifests=[_manifest_evidence(path, metadata)],
        modules=[_module_evidence(path, name, EvidenceKind.PACKAGE, metadata)],
        build_configs=[_build_evidence(path, name, metadata)],
    )


def _parse_solution(path: str, text: str) -> ManifestResult:
    result = ManifestResult(manifests=[_manifest_evidence(path, {"manifest_type": "dotnet_solution"})])
    pattern = re.compile(r'^Project\("[^"]+"\)\s*=\s*"([^"]+)",\s*"([^"]+)"', re.MULTILINE)
    for match in pattern.finditer(text):
        name, project_path = match.groups()
        if project_path.casefold().endswith((".csproj", ".fsproj", ".vbproj")):
            line = _line_number(text, match.start())
            metadata = {"manifest_type": "dotnet_solution_entry", "name": name, "manifest": path}
            normalized_path = _relative_reference(path, project_path)
            result.modules.append(_module_evidence(normalized_path, name, EvidenceKind.MODULE, metadata, line=line))
            result.build_configs.append(_build_evidence(normalized_path, name, metadata, line=line))
    return result


def _parse_pubspec(path: str, text: str) -> ManifestResult:
    try:
        raw = yaml.safe_load(text)
    except yaml.YAMLError:
        raw = {}
    data = raw if isinstance(raw, dict) else {}
    name = str(data.get("name") or PurePosixPath(path).parent.name)
    dependencies = data.get("dependencies", {})
    dev_dependencies = data.get("dev_dependencies", {})
    metadata = {
        "manifest_type": "dart_pubspec",
        "name": name,
        "version": data.get("version"),
        "dependencies": sorted(str(key) for key in dependencies) if isinstance(dependencies, dict) else [],
        "dev_dependencies": sorted(str(key) for key in dev_dependencies) if isinstance(dev_dependencies, dict) else [],
        "flutter": "flutter" in data,
    }
    return ManifestResult(
        manifests=[_manifest_evidence(path, metadata)],
        modules=[_module_evidence(path, name, EvidenceKind.PACKAGE, metadata)],
        build_configs=[_build_evidence(path, name, metadata)],
    )


def _parse_pyproject(path: str, data: bytes) -> ManifestResult:
    try:
        raw = tomllib.loads(data.decode("utf-8"))
    except (tomllib.TOMLDecodeError, UnicodeDecodeError):
        raw = {}
    project = raw.get("project", {}) if isinstance(raw, dict) else {}
    project = project if isinstance(project, dict) else {}
    name = str(project.get("name") or PurePosixPath(path).parent.name or PurePosixPath(path).stem)
    metadata = {
        "manifest_type": "python_pyproject",
        "name": name,
        "version": project.get("version"),
        "requires_python": project.get("requires-python"),
    }
    return ManifestResult(
        manifests=[_manifest_evidence(path, metadata)],
        modules=[_module_evidence(path, name, EvidenceKind.PACKAGE, metadata)],
        build_configs=[_build_evidence(path, name, metadata)],
    )


def _parse_gradle_settings(path: str, text: str) -> ManifestResult:
    root_match = re.search(r"rootProject\.name\s*=\s*['\"]([^'\"]+)", text)
    root_name = root_match.group(1) if root_match else PurePosixPath(path).parent.name
    includes = [
        value
        for match in re.finditer(r"\binclude\s*\(?\s*([^\n)]+)", text)
        for value in re.findall(r"['\"]:([^'\"]+)['\"]", match.group(1))
    ]
    metadata = {"manifest_type": "gradle_settings", "name": root_name, "modules": includes}
    result = ManifestResult(
        manifests=[_manifest_evidence(path, metadata)],
        modules=[_module_evidence(path, root_name, EvidenceKind.MODULE, metadata)],
        build_configs=[_build_evidence(path, root_name, metadata)],
    )
    for module in includes:
        module_path = f"{PurePosixPath(path).parent}/{module.replace(':', '/')}".lstrip("./")
        values = {"manifest_type": "gradle_module", "name": module, "manifest": path}
        result.modules.append(_module_evidence(module_path, module, EvidenceKind.MODULE, values))
        result.build_configs.append(_build_evidence(module_path, module, values))
    return result


def _parse_gradle_build(path: str, text: str) -> ManifestResult:
    values = {}
    for key in ("namespace", "applicationId", "versionName"):
        match = re.search(rf"\b{key}\s*(?:=\s*)?['\"]([^'\"]+)", text)
        if match:
            values[key] = match.group(1)
    name = str(values.get("applicationId") or values.get("namespace") or PurePosixPath(path).parent.name)
    metadata = {"manifest_type": "gradle_build", "name": name, **values}
    return ManifestResult(
        manifests=[_manifest_evidence(path, metadata)],
        modules=[_module_evidence(path, name, EvidenceKind.MODULE, metadata)],
        build_configs=[_build_evidence(path, name, metadata)],
    )


def _parse_xcode_project(path: str, text: str) -> ManifestResult:
    names = list(dict.fromkeys(re.findall(r"\bproductName\s*=\s*\"?([^;\"\n]+)\"?;", text)))
    metadata = {"manifest_type": "xcode_project", "targets": names}
    result = ManifestResult(manifests=[_manifest_evidence(path, metadata)])
    for name in names:
        clean_name = name.strip()
        result.modules.append(_module_evidence(path, clean_name, EvidenceKind.MODULE, metadata))
        result.build_configs.append(_build_evidence(path, clean_name, metadata))
    return result


def _parse_platform_manifest(path: str, data: bytes, text: str) -> ManifestResult:
    name = PurePosixPath(path).parent.name
    metadata: dict[str, Any] = {"manifest_type": "platform_manifest", "name": name}
    if PurePosixPath(path).name.casefold() == "androidmanifest.xml":
        root = _xml_root(text)
        if root is not None and root.attrib.get("package"):
            metadata["package_identifier"] = root.attrib["package"]
    else:
        try:
            plist = plistlib.loads(data)
        except Exception:
            plist = {}
        if isinstance(plist, dict):
            metadata["package_identifier"] = plist.get("CFBundleIdentifier")
            metadata["version"] = plist.get("CFBundleShortVersionString")
            name = str(plist.get("CFBundleName") or name)
            metadata["name"] = name
    return ManifestResult(
        manifests=[_manifest_evidence(path, metadata)],
        build_configs=[_build_evidence(path, name, metadata)],
    )


def _generic_packaging_config(path: str) -> ManifestResult:
    name = PurePosixPath(path).stem
    metadata = {"manifest_type": "packaging_config", "name": name}
    return ManifestResult(
        manifests=[_manifest_evidence(path, metadata)],
        build_configs=[_build_evidence(path, name, metadata)],
    )


def _manifest_evidence(path: str, metadata: dict[str, Any]) -> RepositoryEvidence:
    return RepositoryEvidence(
        evidence_id=f"manifest:{path}",
        kind=EvidenceKind.MANIFEST_ENTRY,
        path=path,
        line_range=RepositoryLineRange(1),
        metadata=metadata,
        excerpt_or_signature=_manifest_signature(metadata),
    )


def _module_evidence(
    path: str,
    name: str,
    kind: EvidenceKind,
    metadata: dict[str, Any],
    *,
    line: int = 1,
) -> RepositoryEvidence:
    return RepositoryEvidence(
        evidence_id=f"{kind.value.casefold()}:{path}:{name}",
        kind=kind,
        path=path,
        line_range=RepositoryLineRange(line),
        symbol=name,
        module=name,
        metadata=metadata,
        excerpt_or_signature=name,
    )


def _build_evidence(path: str, name: str, metadata: dict[str, Any], *, line: int = 1) -> RepositoryEvidence:
    return RepositoryEvidence(
        evidence_id=f"build_target:{path}:{name}",
        kind=EvidenceKind.BUILD_TARGET,
        path=path,
        line_range=RepositoryLineRange(line),
        symbol=name,
        module=name,
        metadata=metadata,
        excerpt_or_signature=name,
    )


def _manifest_signature(metadata: dict[str, Any]) -> str:
    return " ".join(f"{key}={value}" for key, value in metadata.items() if value not in (None, "", [], {}))


def _xml_root(text: str) -> ET.Element | None:
    try:
        return ET.fromstring(text)
    except ET.ParseError:
        return None


def _xml_properties(root: ET.Element | None) -> dict[str, str]:
    result: dict[str, str] = {}
    if root is None:
        return result
    for element in root.iter():
        tag = _local_tag(element.tag)
        if tag in {"AssemblyName", "Version", "VersionPrefix", "TargetFramework", "TargetFrameworks"} and element.text:
            result.setdefault(tag, element.text.strip())
    return result


def _local_tag(value: str) -> str:
    return value.rsplit("}", 1)[-1]


def _split_values(value: str | None) -> list[str]:
    return [item.strip() for item in str(value or "").split(";") if item.strip()]


def _line_number(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def _relative_reference(manifest_path: str, reference: str) -> str:
    parent = PurePosixPath(manifest_path).parent
    parts: list[str] = []
    for part in (parent / reference.replace("\\", "/")).parts:
        if part == "..":
            if parts:
                parts.pop()
        elif part not in {"", "."}:
            parts.append(part)
    return "/".join(parts)
