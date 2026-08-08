"""Format-independent normalized document models.

The extractors intentionally produce these dataclasses instead of exposing
python-docx/openpyxl/xlrd objects to validators.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Iterable


class ContentClass(str, Enum):
    """Deterministic classification of extracted text."""

    REAL_CONTENT = "real_content"
    PLACEHOLDER = "placeholder"
    TEMPLATE_INSTRUCTION = "template_instruction"
    SAMPLE_RESIDUE = "sample_residue"
    EMPTY = "empty"


@dataclass(frozen=True)
class SourceLocation:
    """Stable, format-specific location information.

    DOCX locations use paragraph/table indexes and spreadsheet locations use a
    sheet plus one-based row/column coordinates.  Rendered page numbers are
    deliberately not part of this model.
    """

    kind: str
    paragraph_index: int | None = None
    table_index: int | None = None
    sheet_name: str | None = None
    row: int | None = None
    column: int | None = None
    end_row: int | None = None
    end_column: int | None = None
    detail: str | None = None

    def display(self) -> str:
        if self.sheet_name is not None:
            address = ""
            if self.row is not None and self.column is not None:
                address = f"{_column_name(self.column)}{self.row}"
                if self.end_row is not None or self.end_column is not None:
                    address += ".."
                    address += _column_name(self.end_column or self.column)
                    address += str(self.end_row or self.row)
            value = f"sheet {self.sheet_name}"
            return f"{value}!{address}" if address else value
        if self.paragraph_index is not None:
            value = f"paragraph {self.paragraph_index}"
        elif self.table_index is not None:
            value = f"table {self.table_index}"
            if self.row is not None and self.column is not None:
                value += f" cell {self.row},{self.column}"
        else:
            value = self.kind
        return f"{value} ({self.detail})" if self.detail else value

    def to_dict(self) -> dict[str, Any]:
        result: dict[str, Any] = {"kind": self.kind, "display": self.display()}
        for name in (
            "paragraph_index",
            "table_index",
            "sheet_name",
            "row",
            "column",
            "end_row",
            "end_column",
            "detail",
        ):
            value = getattr(self, name)
            if value is not None:
                result[name] = value
        return result


@dataclass
class Block:
    kind: str
    text: str = ""
    source_location: SourceLocation | None = None
    metadata: dict[str, Any] = field(default_factory=dict)
    style_name: str | None = None
    level: int | None = None
    numbering: str | None = None
    section_path: str | None = None
    original_text: str | None = None
    classification: ContentClass | None = None

    def __post_init__(self) -> None:
        if self.original_text is None:
            self.original_text = self.text

    @property
    def is_heading(self) -> bool:
        return self.kind == "heading"

    def to_dict(self) -> dict[str, Any]:
        return {
            "kind": self.kind,
            "text": self.text,
            "original_text": self.original_text,
            "classification": self.classification.value if self.classification else None,
            "source_location": self.source_location.to_dict() if self.source_location else None,
            "style_name": self.style_name,
            "level": self.level,
            "numbering": self.numbering,
            "section_path": self.section_path,
            "metadata": _json_value(self.metadata),
        }


@dataclass
class Image:
    relationship_id: str | None = None
    description: str | None = None
    source_location: SourceLocation | None = None
    parent_section: str | None = None
    filename: str | None = None
    width: int | None = None
    height: int | None = None
    metadata: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "relationship_id": self.relationship_id,
            "description": self.description,
            "source_location": self.source_location.to_dict() if self.source_location else None,
            "parent_section": self.parent_section,
            "filename": self.filename,
            "width": self.width,
            "height": self.height,
            "metadata": _json_value(self.metadata),
        }


@dataclass
class Cell:
    value: Any = None
    row: int = 0
    column: int = 0
    source_location: SourceLocation | None = None
    original_text: str = ""
    classification: ContentClass | None = None
    formula: str | None = None
    metadata: dict[str, Any] = field(default_factory=dict)

    def __post_init__(self) -> None:
        if not self.original_text:
            self.original_text = "" if self.value is None else str(self.value)

    @property
    def is_empty(self) -> bool:
        if self.formula is not None and self.formula.strip():
            return False
        return self.value is None or not str(self.value).strip()

    def to_dict(self) -> dict[str, Any]:
        return {
            "value": _json_value(self.value),
            "original_text": self.original_text,
            "classification": self.classification.value if self.classification else None,
            "formula": self.formula,
            "row": self.row,
            "column": self.column,
            "source_location": self.source_location.to_dict() if self.source_location else None,
            "metadata": _json_value(self.metadata),
        }


@dataclass
class Table:
    rows: list[list[Cell]] = field(default_factory=list)
    source_location: SourceLocation | None = None
    merged_regions: list[str] = field(default_factory=list)
    parent_section: str | None = None
    metadata: dict[str, Any] = field(default_factory=dict)

    @property
    def dimensions(self) -> tuple[int, int]:
        return len(self.rows), max((len(row) for row in self.rows), default=0)

    @property
    def values(self) -> list[list[Any]]:
        return [[cell.value for cell in row] for row in self.rows]

    @property
    def non_empty_cells(self) -> list[Cell]:
        return [cell for row in self.rows for cell in row if not cell.is_empty]

    def to_dict(self) -> dict[str, Any]:
        row_count, column_count = self.dimensions
        return {
            "dimensions": {"rows": row_count, "columns": column_count},
            "rows": [[cell.to_dict() for cell in row] for row in self.rows],
            "merged_regions": list(self.merged_regions),
            "source_location": self.source_location.to_dict() if self.source_location else None,
            "parent_section": self.parent_section,
            "metadata": _json_value(self.metadata),
        }


@dataclass
class Section:
    title: str
    normalized_title: str
    numbering: str | None
    level: int
    source_location: SourceLocation | None = None
    blocks: list[Block] = field(default_factory=list)
    children: list["Section"] = field(default_factory=list)
    parent_path: str | None = None
    path: str | None = None
    metadata: dict[str, Any] = field(default_factory=dict)

    def all_descendants(self) -> Iterable["Section"]:
        for child in self.children:
            yield child
            yield from child.all_descendants()

    def all_sections(self) -> Iterable["Section"]:
        yield self
        yield from self.all_descendants()

    def all_blocks(self) -> Iterable[Block]:
        yield from self.blocks
        for child in self.children:
            yield from child.all_blocks()

    def to_dict(self) -> dict[str, Any]:
        return {
            "title": self.title,
            "normalized_title": self.normalized_title,
            "numbering": self.numbering,
            "level": self.level,
            "source_location": self.source_location.to_dict() if self.source_location else None,
            "path": self.path,
            "parent_path": self.parent_path,
            "blocks": [block.to_dict() for block in self.blocks],
            "children": [child.to_dict() for child in self.children],
            "metadata": _json_value(self.metadata),
        }


@dataclass
class Document:
    source_path: str
    format: str = "docx"
    metadata: dict[str, Any] = field(default_factory=dict)
    sections: list[Section] = field(default_factory=list)
    tables: list[Table] = field(default_factory=list)
    images: list[Image] = field(default_factory=list)
    raw_blocks: list[Block] = field(default_factory=list)

    def all_sections(self) -> Iterable[Section]:
        for section in self.sections:
            yield from section.all_sections()

    def all_blocks(self) -> Iterable[Block]:
        yield from self.raw_blocks

    def find_sections(self, normalized_title: str) -> list[Section]:
        return [section for section in self.all_sections() if section.normalized_title == normalized_title]

    def to_dict(self) -> dict[str, Any]:
        return {
            "source_path": self.source_path,
            "format": self.format,
            "metadata": _json_value(self.metadata),
            "sections": [section.to_dict() for section in self.sections],
            "tables": [table.to_dict() for table in self.tables],
            "images": [image.to_dict() for image in self.images],
            "raw_blocks": [block.to_dict() for block in self.raw_blocks],
        }


@dataclass
class Sheet:
    name: str
    rows: list[list[Cell]] = field(default_factory=list)
    merged_regions: list[str] = field(default_factory=list)
    detected_header_rows: list[int] = field(default_factory=list)
    source_location: SourceLocation | None = None
    metadata: dict[str, Any] = field(default_factory=dict)
    images: list[Image] = field(default_factory=list)

    @property
    def dimensions(self) -> tuple[int, int]:
        return len(self.rows), max((len(row) for row in self.rows), default=0)

    @property
    def non_empty_cells(self) -> list[Cell]:
        return [cell for row in self.rows for cell in row if not cell.is_empty]

    def row_values(self, row_number: int) -> list[Any]:
        if row_number < 1 or row_number > len(self.rows):
            return []
        return [cell.value for cell in self.rows[row_number - 1]]

    def to_dict(self) -> dict[str, Any]:
        row_count, column_count = self.dimensions
        return {
            "name": self.name,
            "dimensions": {"rows": row_count, "columns": column_count},
            "rows": [[cell.to_dict() for cell in row] for row in self.rows],
            "merged_regions": list(self.merged_regions),
            "detected_header_rows": list(self.detected_header_rows),
            "source_location": self.source_location.to_dict() if self.source_location else None,
            "metadata": _json_value(self.metadata),
            "images": [image.to_dict() for image in self.images],
        }


@dataclass
class Workbook:
    source_path: str
    format: str
    metadata: dict[str, Any] = field(default_factory=dict)
    sheets: list[Sheet] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "source_path": self.source_path,
            "format": self.format,
            "metadata": _json_value(self.metadata),
            "sheets": [sheet.to_dict() for sheet in self.sheets],
        }


NormalizedDocument = Document | Workbook


def _column_name(number: int) -> str:
    result = ""
    while number > 0:
        number, remainder = divmod(number - 1, 26)
        result = chr(65 + remainder) + result
    return result or "?"


def _json_value(value: Any) -> Any:
    if isinstance(value, Enum):
        return value.value
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, dict):
        return {str(key): _json_value(item) for key, item in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [_json_value(item) for item in value]
    return str(value)
