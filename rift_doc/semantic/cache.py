"""Content-addressed cache for schema-valid semantic results."""

from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import tempfile
from typing import Any

from .model import SemanticResult


class SemanticResultCache:
    def __init__(self, root: str | Path) -> None:
        self.root = Path(root)

    @staticmethod
    def key(
        *,
        provider: str,
        model: str,
        prompt_version: str,
        packet_hash: str,
    ) -> str:
        payload = json.dumps(
            {
                "provider": provider,
                "model": model,
                "prompt_version": prompt_version,
                "packet_hash": packet_hash,
            },
            sort_keys=True,
            separators=(",", ":"),
        )
        return hashlib.sha256(payload.encode("utf-8")).hexdigest()

    def load(self, key: str) -> dict[str, Any] | None:
        path = self.root / f"{key}.json"
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return None
        except (OSError, json.JSONDecodeError):
            return None
        if not isinstance(raw, dict) or raw.get("cache_key") != key:
            return None
        result = raw.get("result")
        return raw if isinstance(result, dict) else None

    def store(
        self,
        key: str,
        result: SemanticResult,
        *,
        audit_metadata: dict[str, Any],
    ) -> Path:
        self.root.mkdir(parents=True, exist_ok=True)
        path = self.root / f"{key}.json"
        cached_result = result.to_dict()
        cached_result.pop("metadata", None)
        payload = {
            "cache_key": key,
            "cached_at": datetime.now(timezone.utc).isoformat(),
            "audit_metadata": audit_metadata,
            "result": cached_result,
        }
        handle = tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=self.root,
            prefix=f".{key}.",
            suffix=".tmp",
            delete=False,
        )
        temporary = Path(handle.name)
        try:
            with handle:
                json.dump(payload, handle, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
                handle.flush()
            temporary.replace(path)
        except OSError:
            temporary.unlink(missing_ok=True)
            raise
        return path
