"""Deterministic source-format extractors."""

from .docx import extract_docx, normalize_heading
from .spreadsheets import extract_workbook, extract_xls, extract_xlsx

__all__ = ["extract_docx", "extract_workbook", "extract_xls", "extract_xlsx", "normalize_heading"]
