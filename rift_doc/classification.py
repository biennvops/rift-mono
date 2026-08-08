"""Conservative, configuration-driven text classification."""

from __future__ import annotations

from dataclasses import dataclass, field
import re
from typing import Any, Iterable

from .model import Block, Cell, ContentClass, Table


@dataclass(frozen=True)
class ClassificationMatch:
    category: ContentClass
    pattern_id: str
    matched_text: str

    def to_dict(self) -> dict[str, str]:
        return {
            "category": self.category.value,
            "pattern_id": self.pattern_id,
            "matched_text": self.matched_text,
        }


@dataclass(frozen=True)
class ClassifiedText:
    original_text: str
    classification: ContentClass
    matches: tuple[ClassificationMatch, ...] = ()

    @property
    def has_real_text(self) -> bool:
        return bool(self.original_text.strip()) and self.classification == ContentClass.REAL_CONTENT

    def to_dict(self) -> dict[str, Any]:
        return {
            "original_text": self.original_text,
            "classification": self.classification.value,
            "matches": [match.to_dict() for match in self.matches],
        }


_DEFAULT_PLACEHOLDERS = (
    ("double_angle_placeholder", r"<<[^<>\n]{1,200}>>"),
    ("single_angle_placeholder", r"(?<!<)<\s*[A-Za-z][^<>\n]{0,160}>\s*(?!>)"),
    ("placeholder_token", r"\b(?:TBD|TODO|TO BE COMPLETED|FILL[- ]?IN)\b"),
)
_DEFAULT_INSTRUCTIONS = (
    ("bracketed_instruction", r"\[\s*(?:Describe|Provide|List|Add|Write|Fill|Include|Define|Prepare|Create|Draw|Replace|Identify|The section|This section|An actor|A use case)[\s\S]{0,1200}?\]"),
    ("angle_instruction", r"<\s*(?:List|Describe|Provide|Add|Write|Fill|Include|Define|Prepare|Create|Draw|Replace|Date when)[^<>\n]{0,240}>"),
    ("ellipsis_placeholder", r"(?m)^\s*(?:…|\.\.\.)\s*$"),
)


@dataclass
class _Pattern:
    pattern_id: str
    regex: re.Pattern[str]
    category: ContentClass


class ContentClassifier:
    """Classify text without trying to infer its meaning.

    Pattern order is intentional: explicit sample markers and instructions are
    checked before generic placeholders.  A configured sample fingerprint is
    required for sample classification; arbitrary prose is never treated as a
    sample merely because it looks illustrative.
    """

    def __init__(
        self,
        *,
        placeholder_patterns: Iterable[dict[str, Any] | tuple[str, str]] = (),
        instruction_patterns: Iterable[dict[str, Any] | tuple[str, str]] = (),
        sample_patterns: Iterable[dict[str, Any] | tuple[str, str]] = (),
        flags: int = re.IGNORECASE,
    ) -> None:
        self._patterns: list[_Pattern] = []
        self._add_defaults(ContentClass.TEMPLATE_INSTRUCTION, _DEFAULT_INSTRUCTIONS, flags)
        self._add_defaults(ContentClass.PLACEHOLDER, _DEFAULT_PLACEHOLDERS, flags)
        self._add_configured(ContentClass.TEMPLATE_INSTRUCTION, instruction_patterns, flags)
        self._add_configured(ContentClass.PLACEHOLDER, placeholder_patterns, flags)
        self._add_configured(ContentClass.SAMPLE_RESIDUE, sample_patterns, flags)

    @classmethod
    def from_config(cls, config: dict[str, Any] | None) -> "ContentClassifier":
        config = config or {}
        return cls(
            placeholder_patterns=config.get("placeholder_patterns", ()),
            instruction_patterns=config.get("instruction_patterns", ()),
            sample_patterns=config.get("sample_fingerprints", config.get("sample_patterns", ())),
        )

    def classify(self, text: Any) -> ClassifiedText:
        original = "" if text is None else str(text)
        if not original.strip():
            return ClassifiedText(original, ContentClass.EMPTY)

        matches: list[ClassificationMatch] = []
        for pattern in self._patterns:
            for match in pattern.regex.finditer(original):
                matches.append(
                    ClassificationMatch(
                        category=pattern.category,
                        pattern_id=pattern.pattern_id,
                        matched_text=match.group(0),
                    )
                )

        if not matches:
            return ClassifiedText(original, ContentClass.REAL_CONTENT)

        # Samples are only emitted when the contract explicitly configured a
        # fingerprint.  If a real paragraph contains one, the residue is still
        # invalid and the original text remains available in the match.
        for category in (
            ContentClass.SAMPLE_RESIDUE,
            ContentClass.TEMPLATE_INSTRUCTION,
            ContentClass.PLACEHOLDER,
        ):
            selected = tuple(match for match in matches if match.category == category)
            if selected:
                return ClassifiedText(original, category, selected)
        return ClassifiedText(original, matches[0].category, tuple(matches))

    def classify_block(self, block: Block) -> ClassifiedText:
        result = self.classify(block.original_text if block.original_text is not None else block.text)
        block.classification = result.classification
        block.metadata["classification_matches"] = [match.to_dict() for match in result.matches]
        return result

    def classify_cell(self, cell: Cell) -> ClassifiedText:
        result = self.classify(cell.original_text)
        cell.classification = result.classification
        cell.metadata["classification_matches"] = [match.to_dict() for match in result.matches]
        return result

    def classify_table(self, table: Table) -> list[ClassifiedText]:
        return [self.classify_cell(cell) for row in table.rows for cell in row]

    def classify_document_blocks(self, blocks: Iterable[Block]) -> list[ClassifiedText]:
        return [self.classify_block(block) for block in blocks]

    def _add_defaults(
        self,
        category: ContentClass,
        patterns: Iterable[tuple[str, str]],
        flags: int,
    ) -> None:
        for pattern_id, expression in patterns:
            self._patterns.append(_Pattern(pattern_id, re.compile(expression, flags), category))

    def _add_configured(
        self,
        category: ContentClass,
        patterns: Iterable[dict[str, Any] | tuple[str, str]],
        flags: int,
    ) -> None:
        for index, item in enumerate(patterns):
            if isinstance(item, dict):
                pattern_id = str(item.get("id", f"configured_{category.value}_{index}"))
                expression = item.get("pattern", item.get("regex"))
                pattern_flags = flags
                if item.get("multiline"):
                    pattern_flags |= re.MULTILINE
                if item.get("dotall"):
                    pattern_flags |= re.DOTALL
            else:
                if isinstance(item, str):
                    pattern_id, expression = f"configured_{category.value}_{index}", item
                else:
                    pattern_id, expression = item
                pattern_flags = flags
            if not expression:
                continue
            try:
                compiled = re.compile(str(expression), pattern_flags)
            except re.error as exc:
                raise ValueError(f"invalid {category.value} pattern {pattern_id!r}: {exc}") from exc
            self._patterns.append(_Pattern(pattern_id, compiled, category))


def classify_text(text: Any, config: dict[str, Any] | None = None) -> ClassifiedText:
    return ContentClassifier.from_config(config).classify(text)
