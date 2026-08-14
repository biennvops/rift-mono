"""Versioned prompt loading and bounded packet rendering."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re

from .model import EvidencePacket, SemanticReviewTask


_PROMPT_NAME_RE = re.compile(r"^[a-z][a-z0-9_]*\.v\d+$")


@dataclass(frozen=True)
class RenderedPrompt:
    version: str
    system: str
    user: str
    prompt_hash: str


class PromptRenderer:
    def __init__(self, prompt_directory: str | Path | None = None) -> None:
        self.prompt_directory = (
            Path(prompt_directory)
            if prompt_directory is not None
            else Path(__file__).resolve().parent.parent / "prompts"
        )

    def render(self, task: SemanticReviewTask, packet: EvidencePacket) -> RenderedPrompt:
        version = str(task.metadata.get("prompt_version", ""))
        if not _PROMPT_NAME_RE.fullmatch(version):
            raise ValueError(f"invalid semantic prompt version {version!r}")
        path = self.prompt_directory / f"{version}.txt"
        try:
            system = path.read_text(encoding="utf-8").strip()
        except OSError as exc:
            raise ValueError(f"semantic prompt {version!r} is unavailable: {exc}") from exc
        user = "\n\n".join(
            [
                "REVIEW QUESTION\n" + task.question,
                "BOUNDED EVIDENCE PACKET\n"
                + json.dumps(packet.model_payload(), ensure_ascii=False, sort_keys=True, indent=2),
                (
                    "OUTPUT CONTRACT\nReturn one JSON object with status, confidence, summary, "
                    "reasoning_summary, evidence_refs, unsupported_claims, contradictions, and "
                    "recommended_action. Do not include markdown fences or extra keys."
                ),
            ]
        )
        prompt_hash = hashlib.sha256((system + "\0" + user).encode("utf-8")).hexdigest()
        return RenderedPrompt(version=version, system=system, user=user, prompt_hash=prompt_hash)
