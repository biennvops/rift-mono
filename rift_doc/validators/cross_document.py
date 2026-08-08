"""Phase 2 extension point.

No cross-document rules are implemented in Phase 1.  Keeping this interface
separate lets later traceability checks consume normalized documents and
findings without changing format extractors or the structural result model.
"""

from __future__ import annotations

from typing import Any

from ..model import NormalizedDocument
from ..results import Finding


class CrossDocumentValidator:
    """Placeholder extension point for Report 1-to-7 consistency checks."""

    def validate(self, documents: dict[str, NormalizedDocument]) -> list[Finding]:
        del documents
        return []
