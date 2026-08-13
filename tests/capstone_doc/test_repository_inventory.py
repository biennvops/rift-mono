from __future__ import annotations

from pathlib import Path
import subprocess

from rift_doc.repository import EvidenceKind, InventoryOptions, RepositoryInventory


def _write(path: Path, text: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


def test_plain_tree_inventory_excludes_outputs_and_indexes_supported_languages(tmp_path: Path) -> None:
    _write(
        tmp_path / "core" / "SyncService.cs",
        """
namespace Demo;
public sealed class SyncService {
    // FE-03 documented identifier
    public void SyncNotifications() {}
}
""",
    )
    _write(
        tmp_path / "core" / "SyncServiceTests.cs",
        """
public sealed class SyncServiceTests {
    [Fact]
    public void SyncNotifications_FE03() {}
}
""",
    )
    _write(tmp_path / "build" / "Generated.cs", "public class Generated {}")
    _write(tmp_path / "vendor" / "ThirdParty.dart", "class ThirdParty {}")
    _write(tmp_path / "ignored" / "Hidden.py", "def hidden(): pass")

    snapshot = RepositoryInventory(InventoryOptions(excluded_paths=("ignored",))).scan(tmp_path)

    assert snapshot.vcs_metadata is None
    assert snapshot.metadata["inventory_source"] == "filesystem"
    assert {item.symbol for item in snapshot.symbols} >= {"SyncService", "SyncNotifications", "SyncServiceTests"}
    assert {item.symbol for item in snapshot.tests} == {"SyncNotifications_FE03"}
    assert all(not item.path.startswith(("build/", "vendor/", "ignored/")) for item in snapshot.all_evidence())
    symbol = next(item for item in snapshot.symbols if item.symbol == "SyncNotifications")
    assert "FE-03" in symbol.metadata["identifiers"]


def test_plain_gitignore_reincludes_a_file_after_an_ignored_glob(tmp_path: Path) -> None:
    _write(tmp_path / ".gitignore", "*.py\n!important.py\n")
    _write(tmp_path / "important.py", "def important_sync():\n    return True\n")
    _write(tmp_path / "other.py", "def ignored_sync():\n    return False\n")

    snapshot = RepositoryInventory().scan(tmp_path)

    assert snapshot.metadata["inventory_source"] == "filesystem"
    assert any(item.symbol == "important_sync" for item in snapshot.symbols)
    assert all(item.path != "other.py" for item in snapshot.all_evidence())


    _write(
        tmp_path / "daemon-cs" / "Core" / "Core.csproj",
        """<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net10.0</TargetFramework><Version>1.2.3</Version></PropertyGroup><ItemGroup><PackageReference Include="xunit" Version="2.9" /></ItemGroup></Project>""",
    )
    _write(
        tmp_path / "daemon-dart" / "pubspec.yaml",
        "name: daemon_dart\nversion: 2.0.0\ndev_dependencies:\n  test: any\n",
    )
    _write(
        tmp_path / "app" / "android" / "settings.gradle.kts",
        "rootProject.name = \"rift\"\ninclude(\":app\")\n",
    )
    _write(
        tmp_path / "daemon-dart" / "test" / "sync_test.dart",
        "void main() { test('syncs notifications', () {}); }",
    )
    _write(
        tmp_path / "app" / "android" / "src" / "test" / "SyncTest.kt",
        """
import org.junit.Test
class SyncTest {
  @Test
  fun `syncs remote notifications`() {}
}
""",
    )
    _write(
        tmp_path / ".github" / "workflows" / "ci.yml",
        """
name: CI
on: push
jobs:
  test-dart:
    runs-on: ubuntu-latest
    steps:
      - run: dart test
  test-android:
    runs-on: ubuntu-latest
    steps:
      - working-directory: app/android
        run: ./gradlew :app:testDebugUnitTest
""",
    )

    snapshot = RepositoryInventory().scan(tmp_path)

    modules = {item.module for item in snapshot.modules}
    assert {"Core", "daemon_dart", "rift", "app"}.issubset(modules)
    assert any(item.metadata.get("version") == "1.2.3" for item in snapshot.manifests)
    assert any(item.metadata.get("version") == "2.0.0" for item in snapshot.manifests)
    assert any(item.symbol == "syncs notifications" for item in snapshot.tests)
    assert any(item.symbol == "syncs remote notifications" for item in snapshot.tests)
    ci_jobs = [item for item in snapshot.ci_configs if item.kind == EvidenceKind.CI_JOB]
    assert len(ci_jobs) == 2
    assert all(item.metadata["invokes_tests"] is True for item in ci_jobs)
    assert next(item for item in ci_jobs if item.symbol == "test-android").metadata["working_directories"] == ["app/android"]
    assert snapshot.metadata["repository_code_executed"] is False
    assert snapshot.metadata["network_access"] is False


def test_git_metadata_and_gitignore_semantics_are_captured(tmp_path: Path) -> None:
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "config", "user.email", "test@example.invalid"], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "config", "user.name", "Test"], check=True)
    _write(tmp_path / ".gitignore", "ignored/\n")
    _write(tmp_path / "lib" / "sync.py", "def sync_notifications():\n    return True\n")
    _write(tmp_path / "ignored" / "secret.py", "def ignored(): pass\n")
    subprocess.run(["git", "-C", str(tmp_path), "add", ".gitignore", "lib/sync.py"], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "commit", "-qm", "fixture"], check=True)

    clean = RepositoryInventory().scan(tmp_path)
    assert clean.vcs_metadata is not None
    assert len(clean.vcs_metadata.commit_sha or "") == 40
    assert clean.vcs_metadata.dirty is False
    assert all(not item.path.startswith("ignored/") for item in clean.all_evidence())

    _write(tmp_path / "lib" / "dirty.py", "def changed(): pass\n")
    dirty = RepositoryInventory().scan(tmp_path)
    assert dirty.vcs_metadata is not None
    assert dirty.vcs_metadata.dirty is True


def test_artifact_directory_indexes_deliverables_and_test_results(tmp_path: Path) -> None:
    repository = tmp_path / "repo"
    artifacts = tmp_path / "artifacts"
    repository.mkdir()
    _write(repository / "README.md", "demo")
    _write(artifacts / "dist" / "rift-client.pkg", "package")
    _write(
        artifacts / "results" / "junit-test-results.xml",
        '<testsuite tests="1"><testcase name="syncs notifications" /></testsuite>',
    )

    snapshot = RepositoryInventory().scan(repository, artifact_root=artifacts)

    assert any(item.kind == EvidenceKind.RELEASE_ARTIFACT and item.path.endswith("rift-client.pkg") for item in snapshot.release_artifacts)
    assert all(not item.path.endswith(".xml") for item in snapshot.release_artifacts)
    result = next(item for item in snapshot.test_results if item.kind == EvidenceKind.TEST_RESULT)
    assert result.metadata["suite_result"] == "PASS"
    assert result.metadata["test_names"] == ["syncs notifications"]
    assert result.metadata["test_outcomes"] == {"syncs notifications": "PASS"}
    assert isinstance(result.metadata["modified_time_ns"], int)
    assert "latest_result" not in result.metadata
    assert snapshot.audit_metadata["artifact_root"] == str(artifacts.resolve())


def test_trx_artifact_indexes_passed_and_failed_test_names(tmp_path: Path) -> None:
    repository = tmp_path / "repo"
    artifacts = tmp_path / "artifacts"
    repository.mkdir()
    fixture = Path(__file__).parent / "fixtures" / "results" / "mixed.trx"
    _write(artifacts / "results" / "mixed.trx", fixture.read_text(encoding="utf-8"))

    snapshot = RepositoryInventory().scan(repository, artifact_root=artifacts)

    result = snapshot.test_results[0]
    assert result.metadata["suite_result"] == "FAIL"
    assert result.metadata["test_names"] == [
        "SyncsNotifications",
        "LeavesUnchangedNotificationsAlone",
    ]
    assert result.metadata["test_outcomes"] == {
        "SyncsNotifications": "FAIL",
        "LeavesUnchangedNotificationsAlone": "PASS",
    }
    assert "latest_result" not in result.metadata


def test_skipped_junit_test_is_not_reported_as_passing(tmp_path: Path) -> None:
    repository = tmp_path / "repo"
    artifacts = tmp_path / "artifacts"
    repository.mkdir()
    _write(
        artifacts / "results" / "junit.xml",
        '<testsuite tests="1" skipped="1"><testcase name="syncs notifications"><skipped /></testcase></testsuite>',
    )

    snapshot = RepositoryInventory().scan(repository, artifact_root=artifacts)

    result = snapshot.test_results[0]
    assert result.metadata["suite_result"] == "UNKNOWN"
    assert result.metadata["test_outcomes"] == {"syncs notifications": "UNKNOWN"}


def test_test_result_artifact_indexes_more_than_100_tests(tmp_path: Path) -> None:
    repository = tmp_path / "repo"
    artifacts = tmp_path / "artifacts"
    repository.mkdir()
    testcases = "".join(f'<testcase name="test_{index}" />' for index in range(101))
    _write(artifacts / "results" / "junit.xml", f"<testsuite>{testcases}</testsuite>")

    snapshot = RepositoryInventory().scan(repository, artifact_root=artifacts)

    result = snapshot.test_results[0]
    assert len(result.metadata["test_outcomes"]) == 101
    assert result.metadata["test_outcomes"]["test_100"] == "PASS"


    root = Path(__file__).resolve().parents[2]
    snapshot = RepositoryInventory(InventoryOptions(excluded_paths=("capstone-documents",))).scan(root)

    manifest_types = {item.metadata.get("manifest_type") for item in snapshot.manifests}
    assert {"dotnet_project", "dart_pubspec", "python_pyproject", "gradle_settings", "xcode_project"}.issubset(manifest_types)
    assert {"csharp", "dart", "python", "kotlin", "swift"}.issubset(snapshot.metadata["languages"])
    assert snapshot.tests
    assert snapshot.ci_configs
